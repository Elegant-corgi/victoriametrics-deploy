#!/usr/bin/env bash
set -Eeuo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

TENANT_ID=${TENANT_ID:-0}
RETENTION_PERIOD=${RETENTION_PERIOD:-1y}

VMSTORAGE_HTTP_PORT=${VMSTORAGE_HTTP_PORT:-8482}
VMSTORAGE_INSERT_PORT=${VMSTORAGE_INSERT_PORT:-8400}
VMSTORAGE_SELECT_PORT=${VMSTORAGE_SELECT_PORT:-8401}
VMINSERT_HTTP_PORT=${VMINSERT_HTTP_PORT:-8480}
VMSELECT_HTTP_PORT=${VMSELECT_HTTP_PORT:-8481}
VMAGENT_HTTP_PORT=${VMAGENT_HTTP_PORT:-8429}
VMALERT_HTTP_PORT=${VMALERT_HTTP_PORT:-8880}
VMAUTH_HTTP_PORT=${VMAUTH_HTTP_PORT:-8427}
ALERTMANAGER_URL=${ALERTMANAGER_URL:-http://localhost:9093}

log_info() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
log_warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
log_error() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
fail() { log_error "$*"; exit 1; }

usage() {
  cat <<'EOF'
用法: ./deploy_vm_single_node.sh <部署路径> <tar包路径>
示例: ./deploy_vm_single_node.sh /data/local/vm ./victoria-metrics.tar.gz

说明:
  tar 包必须包含 vmstorage-prod、vminsert-prod、vmselect-prod、vmagent-prod、vmalert-prod、vmauth-prod。
EOF
}

[[ $# -eq 2 ]] || { usage; exit 2; }

DEPLOY_PATH=$1
TAR_PATH=$2
TAR_FILENAME=$(basename "$TAR_PATH")
TAR_NAME=${TAR_FILENAME%.tar.gz}
TAR_NAME=${TAR_NAME%.tgz}
CURRENT_DIR=$(pwd)

[[ -f "$TAR_PATH" ]] || fail "Tar 包不存在: $TAR_PATH"

check_port_available() {
  local port=$1 service=$2
  if ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)$port$"; then
    log_warn "端口 $port 已被占用，$service 服务可能启动失败"
  elif command -v netstat >/dev/null 2>&1 && netstat -tuln | grep -q ":$port "; then
    log_warn "端口 $port 已被占用，$service 服务可能启动失败"
  fi
}

require_tar_binaries() {
  local entries=$1 normalized bin
  normalized=$(sed 's#^\./##' <<<"$entries")
  for bin in vmstorage-prod vminsert-prod vmselect-prod vmagent-prod vmalert-prod vmauth-prod; do
    grep -Fx "$bin" <<<"$normalized" >/dev/null || fail "tar 包缺少必需二进制: $bin"
  done
}

create_default_prometheus_config() {
  cat >"$DEPLOY_PATH/cfg/prometheus.yml" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'victoriametrics'
    static_configs:
      - targets:
          - '127.0.0.1:$VMINSERT_HTTP_PORT'
          - '127.0.0.1:$VMSELECT_HTTP_PORT'
          - '127.0.0.1:$VMSTORAGE_HTTP_PORT'
          - '127.0.0.1:$VMAUTH_HTTP_PORT'
    metrics_path: /metrics

  - job_name: 'vmalert'
    static_configs:
      - targets: ['127.0.0.1:$VMALERT_HTTP_PORT']
    metrics_path: /metrics

  - job_name: 'vmagent'
    static_configs:
      - targets: ['127.0.0.1:$VMAGENT_HTTP_PORT']
    metrics_path: /metrics
EOF
}

create_default_alert_rules() {
  mkdir -p "$DEPLOY_PATH/cfg/rules"
  cat >"$DEPLOY_PATH/cfg/rules/node_alerts.yml" <<'EOF'
groups:
  - name: node_alerts
    rules:
      - alert: ServiceDown
        expr: up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "服务 {{ $labels.instance }} 下线"
          description: "服务 {{ $labels.job }} 在实例 {{ $labels.instance }} 上已经下线超过1分钟"
EOF
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
  else
    tr -dc 'A-Za-z0-9_@%+=:,.~-' </dev/urandom | head -c 48
  fi
}

ensure_secrets() {
  local secrets_dir=$DEPLOY_PATH/cfg/secrets
  local secrets_file=$secrets_dir/single.env
  install -d -m 700 "$secrets_dir"

  if [[ ! -f "$secrets_file" ]]; then
    umask 077
    cat >"$secrets_file" <<EOF
VM_WRITE_USER=vm_single_write
VM_WRITE_PASSWORD=$(generate_secret)
VM_QUERY_USER=vm_single_query
VM_QUERY_PASSWORD=$(generate_secret)
EOF
    log_info "已生成鉴权凭据: $secrets_file"
  fi

  chmod 600 "$secrets_file"
  # shellcheck disable=SC1090
  source "$secrets_file"
  [[ -n "${VM_WRITE_USER:-}" && -n "${VM_WRITE_PASSWORD:-}" && -n "${VM_QUERY_USER:-}" && -n "${VM_QUERY_PASSWORD:-}" ]] \
    || fail "鉴权凭据文件不完整: $secrets_file"
}

write_auth_config() {
  printf '%s' "$VM_WRITE_PASSWORD" >"$DEPLOY_PATH/cfg/write.password"
  printf '%s' "$VM_QUERY_PASSWORD" >"$DEPLOY_PATH/cfg/query.password"
  chmod 600 "$DEPLOY_PATH/cfg/write.password" "$DEPLOY_PATH/cfg/query.password"

  cat >"$DEPLOY_PATH/cfg/vmauth.yml" <<EOF
users:
  - username: "$VM_WRITE_USER"
    password: "$VM_WRITE_PASSWORD"
    url_map:
      - src_paths:
          - "/api/v1/write"
          - "/api/v1/import.*"
          - "/write"
          - "/insert.*"
        url_prefix: "http://127.0.0.1:$VMINSERT_HTTP_PORT/insert/$TENANT_ID/prometheus"

  - username: "$VM_QUERY_USER"
    password: "$VM_QUERY_PASSWORD"
    url_map:
      - src_paths:
          - "/api/v1/query"
          - "/api/v1/query_range"
          - "/api/v1/series"
          - "/api/v1/labels"
          - "/api/v1/label/.*"
          - "/api/v1/metadata"
          - "/api/v1/status/.*"
          - "/prometheus/.*"
        url_prefix: "http://127.0.0.1:$VMSELECT_HTTP_PORT/select/$TENANT_ID/prometheus"
      - src_paths:
          - "/select/$TENANT_ID/vmui.*"
          - "/select/$TENANT_ID/static/.*"
        url_prefix: "http://127.0.0.1:$VMSELECT_HTTP_PORT"
EOF
  chmod 600 "$DEPLOY_PATH/cfg/vmauth.yml"
}

copy_cfg() {
  log_info "检查当前目录的配置文件..."
  if [[ -d "$CURRENT_DIR/cfg" ]] && [[ -n "$(find "$CURRENT_DIR/cfg" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    log_info "发现现有配置文件，复制到部署目录"
    cp -a "$CURRENT_DIR/cfg/." "$DEPLOY_PATH/cfg/"
    if [[ ! -f "$DEPLOY_PATH/cfg/prometheus.yml" ]]; then
      log_warn "未找到 prometheus.yml，创建默认配置"
      create_default_prometheus_config
    else
      log_info "使用现有 prometheus.yml 配置"
    fi
  else
    log_info "未找到现有配置文件，创建默认配置"
    create_default_prometheus_config
    create_default_alert_rules
  fi

  mkdir -p "$DEPLOY_PATH/cfg/rules"
}

extract_binaries() {
  local temp_dir=$1 bin src
  for bin in vmstorage-prod vminsert-prod vmselect-prod vmagent-prod vmalert-prod vmauth-prod; do
    src=$(find "$temp_dir" -type f -name "$bin" -print -quit)
    [[ -n "$src" ]] || fail "解压后未找到二进制: $bin"
    install -m 755 "$src" "$DEPLOY_PATH/bin/$bin"
    log_info "安装二进制: $bin"
  done
}

validate_configs() {
  log_info "校验 vmauth、vmagent、vmalert 配置"
  "$DEPLOY_PATH/bin/vmauth-prod" -auth.config="$DEPLOY_PATH/cfg/vmauth.yml" -dryRun >/dev/null
  "$DEPLOY_PATH/bin/vmagent-prod" -promscrape.config="$DEPLOY_PATH/cfg/prometheus.yml" -dryRun >/dev/null
  "$DEPLOY_PATH/bin/vmalert-prod" -rule="$DEPLOY_PATH/cfg/rules/*.yml" -dryRun >/dev/null
}

create_systemd_service() {
  local service_name=$1 description=$2 exec_start=$3

  cat >"/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=$description
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DEPLOY_PATH
ExecStart=$exec_start
Restart=always
RestartSec=10
StartLimitInterval=300
StartLimitBurst=5

LimitNOFILE=65536
LimitNPROC=4096

Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=GOMAXPROCS=auto

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "/etc/systemd/system/${service_name}.service"
  log_info "创建服务: $service_name"
}

write_systemd_units() {
  log_info "创建 systemd 服务文件"

  create_systemd_service "vmstorage" "VictoriaMetrics Storage Node" \
    "$DEPLOY_PATH/bin/vmstorage-prod -storageDataPath=$DEPLOY_PATH/data/vmstorage-data -retentionPeriod=$RETENTION_PERIOD -httpListenAddr=:$VMSTORAGE_HTTP_PORT -vminsertAddr=:$VMSTORAGE_INSERT_PORT -vmselectAddr=:$VMSTORAGE_SELECT_PORT"

  create_systemd_service "vminsert" "VictoriaMetrics Insert Node" \
    "$DEPLOY_PATH/bin/vminsert-prod -storageNode=127.0.0.1:$VMSTORAGE_INSERT_PORT -httpListenAddr=:$VMINSERT_HTTP_PORT"

  create_systemd_service "vmselect" "VictoriaMetrics Select Node" \
    "$DEPLOY_PATH/bin/vmselect-prod -storageNode=127.0.0.1:$VMSTORAGE_SELECT_PORT -httpListenAddr=:$VMSELECT_HTTP_PORT -cacheDataPath=$DEPLOY_PATH/data/vmselect-cache"

  create_systemd_service "vmauth" "VictoriaMetrics Auth Proxy" \
    "$DEPLOY_PATH/bin/vmauth-prod -auth.config=$DEPLOY_PATH/cfg/vmauth.yml -httpListenAddr=:$VMAUTH_HTTP_PORT"

  create_systemd_service "vmagent" "VictoriaMetrics Agent" \
    "$DEPLOY_PATH/bin/vmagent-prod -promscrape.config=$DEPLOY_PATH/cfg/prometheus.yml -remoteWrite.url=http://127.0.0.1:$VMAUTH_HTTP_PORT/api/v1/write -remoteWrite.basicAuth.username=$VM_WRITE_USER -remoteWrite.basicAuth.passwordFile=$DEPLOY_PATH/cfg/write.password -httpListenAddr=:$VMAGENT_HTTP_PORT -remoteWrite.tmpDataPath=$DEPLOY_PATH/data/vmagent-remotewrite-data"

  create_systemd_service "vmalert" "VictoriaMetrics Alert Manager" \
    "$DEPLOY_PATH/bin/vmalert-prod -datasource.url=http://127.0.0.1:$VMAUTH_HTTP_PORT/ -datasource.basicAuth.username=$VM_QUERY_USER -datasource.basicAuth.passwordFile=$DEPLOY_PATH/cfg/query.password -notifier.url=$ALERTMANAGER_URL -rule=$DEPLOY_PATH/cfg/rules/*.yml -httpListenAddr=:$VMALERT_HTTP_PORT -configCheckInterval=30s"
}

restart_services() {
  systemctl daemon-reload
  local service
  for service in vmstorage vminsert vmselect vmauth vmagent vmalert; do
    systemctl enable "$service.service" >/dev/null
    systemctl restart "$service.service"
  done
}

check_service_status() {
  local service_name=$1
  if systemctl is-active --quiet "$service_name"; then
    log_info "服务 $service_name 启动成功"
  else
    log_error "服务 $service_name 启动失败"
    systemctl status "$service_name" --no-pager -l || true
    return 1
  fi
}

write_deploy_readme() {
  cat >"$DEPLOY_PATH/README.md" <<EOF
# VictoriaMetrics 单点部署

## 目录结构
\`\`\`
$DEPLOY_PATH/
├── bin/                  # 二进制文件
├── data/                 # 数据文件
├── cfg/                  # 配置文件
│   ├── prometheus.yml    # 采集配置
│   ├── vmauth.yml        # vmauth 鉴权和路由配置
│   ├── write.password    # 写入账号密码
│   ├── query.password    # 查询账号密码
│   ├── secrets/          # 原始凭据文件
│   └── rules/            # 告警规则目录
└── logs/                 # 预留日志目录
\`\`\`

## 服务端口
- vmstorage: $VMSTORAGE_HTTP_PORT（监控）、$VMSTORAGE_INSERT_PORT（vminsert）、$VMSTORAGE_SELECT_PORT（vmselect）
- vminsert: $VMINSERT_HTTP_PORT（内部写入入口）
- vmselect: $VMSELECT_HTTP_PORT（内部查询入口）
- vmauth: $VMAUTH_HTTP_PORT（对外鉴权入口）
- vmagent: $VMAGENT_HTTP_PORT（目标状态界面）
- vmalert: $VMALERT_HTTP_PORT（告警管理界面）

## 鉴权说明
- 写入账号: $VM_WRITE_USER
- 查询账号: $VM_QUERY_USER
- 凭据文件: $DEPLOY_PATH/cfg/secrets/single.env
- 客户写入示例:
  \`\`\`bash
  curl -u '$VM_WRITE_USER:<password>' --data-binary 'demo_metric 1' \\
    http://<server-ip>:$VMAUTH_HTTP_PORT/api/v1/import/prometheus
  \`\`\`
- 查询示例:
  \`\`\`bash
  curl -u '$VM_QUERY_USER:<password>' 'http://<server-ip>:$VMAUTH_HTTP_PORT/api/v1/query?query=up'
  \`\`\`

## 版本信息
- 部署版本: $TAR_NAME
- 部署时间: $(date)
EOF
}

main() {
  log_info "开始部署 VictoriaMetrics 单点"
  log_info "部署路径: $DEPLOY_PATH"
  log_info "源文件: $TAR_PATH"
  log_info "版本: $TAR_NAME"

  local entries temp_dir service failed=0
  entries=$(tar -tzf "$TAR_PATH")
  require_tar_binaries "$entries"

  for item in \
    "$VMSTORAGE_HTTP_PORT:vmstorage" \
    "$VMSTORAGE_INSERT_PORT:vmstorage-insert" \
    "$VMSTORAGE_SELECT_PORT:vmstorage-select" \
    "$VMINSERT_HTTP_PORT:vminsert" \
    "$VMSELECT_HTTP_PORT:vmselect" \
    "$VMAGENT_HTTP_PORT:vmagent" \
    "$VMALERT_HTTP_PORT:vmalert" \
    "$VMAUTH_HTTP_PORT:vmauth"; do
    check_port_available "${item%%:*}" "${item#*:}"
  done

  mkdir -p "$DEPLOY_PATH"/{bin,data,cfg,logs}
  copy_cfg
  ensure_secrets
  write_auth_config

  temp_dir=$(mktemp -d)
  trap 'rm -rf -- "$temp_dir"' EXIT
  log_info "解压文件到临时目录: $temp_dir"
  tar -xzf "$TAR_PATH" -C "$temp_dir"
  extract_binaries "$temp_dir"
  rm -rf -- "$temp_dir"
  trap - EXIT

  validate_configs
  write_systemd_units
  restart_services

  for service in vmstorage vminsert vmselect vmauth vmagent vmalert; do
    check_service_status "$service" || failed=1
  done
  [[ $failed -eq 0 ]] || fail "存在启动失败的服务，请查看上方 systemctl 输出"

  write_deploy_readme

  log_info "=== VictoriaMetrics 单点部署完成 ==="
  log_info "部署路径: $DEPLOY_PATH"
  log_info "配置目录: $DEPLOY_PATH/cfg/"
  log_info "vmauth 鉴权入口: http://localhost:$VMAUTH_HTTP_PORT"
  log_info "VMUI 内部入口: http://localhost:$VMSELECT_HTTP_PORT/select/$TENANT_ID/vmui/"
  log_info "vmagent 目标: http://localhost:$VMAGENT_HTTP_PORT/targets"
  log_info "vmalert 告警: http://localhost:$VMALERT_HTTP_PORT"
  log_info "凭据文件: $DEPLOY_PATH/cfg/secrets/single.env"
}

main
