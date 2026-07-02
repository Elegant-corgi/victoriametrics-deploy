#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NODES_FILE="$SCRIPT_DIR/nodes.conf"
CLUSTER_CONFIG="$SCRIPT_DIR/cluster.conf"
CLUSTER_TAR="$SCRIPT_DIR/victoria-metrics-linux-amd64-v1.135.0-cluster.tar.gz"
VMUTILS_TAR="$SCRIPT_DIR/vmutils-linux-amd64-v1.135.0.tar.gz"
CFG_SOURCE="$SCRIPT_DIR/cfg"

readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log() { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
fail() { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; exit 1; }
usage() {
  cat <<'EOF'
用法：
  ./deploy_vm_cluster.sh [install] <数据根目录>
  ./deploy_vm_cluster.sh check <数据根目录>
  ./deploy_vm_cluster.sh status <数据根目录>
  ./deploy_vm_cluster.sh verify <数据根目录>
  ./deploy_vm_cluster.sh sync-config <数据根目录>
  ./deploy_vm_cluster.sh enable-alerting <数据根目录>
  ./deploy_vm_cluster.sh disable-alerting <数据根目录>

示例：./deploy_vm_cluster.sh check /data/local/vm
EOF
}

[[ -r "$CLUSTER_CONFIG" ]] || fail "缺少配置文件：$CLUSTER_CONFIG"
# shellcheck disable=SC1090
source "$CLUSTER_CONFIG"

: "${APP_DIR:=/data/apps/victoriametrics}"
: "${REMOTE_CONFIG_DIR:=/etc/victoriametrics-cluster}"
: "${SERVICE_USER:=victoriametrics-cluster}"
: "${TENANT_ID:=0}"
: "${RETENTION_PERIOD:=1y}"
: "${DEDUP_INTERVAL:=5s}"
: "${ALERTMANAGER_URL:=http://10.27.3.68:9093}"
: "${VMSTORAGE_INSERT_PORT:=18400}"
: "${VMSTORAGE_SELECT_PORT:=18401}"
: "${VMSTORAGE_HTTP_PORT:=18482}"
: "${VMINSERT_HTTP_PORT:=18480}"
: "${VMSELECT_HTTP_PORT:=18481}"
: "${VMAGENT_HTTP_PORT:=18429}"
: "${VMALERT_HTTP_PORT:=18880}"
: "${VMAUTH_HTTP_PORT:=18427}"
: "${SSH_OPTIONS:=-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new}"
SECRETS_DIR="$REMOTE_CONFIG_DIR/secrets"
SECRETS_FILE="$SECRETS_DIR/cluster.env"

ACTION=${1:-}
DATA_ROOT=${2:-}
if [[ "$ACTION" == /* ]]; then DATA_ROOT=$ACTION; ACTION=install; fi
[[ -n "$ACTION" && -n "$DATA_ROOT" ]] || { usage; exit 2; }
case "$ACTION" in check|install|status|verify|sync-config|enable-alerting|disable-alerting) ;; *) usage; exit 2 ;; esac
[[ "$DATA_ROOT" == /* && "$DATA_ROOT" != / ]] || fail "数据根目录必须是非根目录的绝对路径"
CLUSTER_DATA="$DATA_ROOT/cluster"

declare -a NODE_IPS=() STORAGE_NODES=() INSERT_NODES=() SELECT_NODES=() AGENT_NODES=() ALERT_NODES=() AUTH_NODES=()
has_role() { [[ ",$2," == *",$1,"* ]]; }
load_nodes() {
  [[ -r "$NODES_FILE" ]] || fail "缺少节点清单：$NODES_FILE"
  local line ip roles extra lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    ((lineno+=1)); line=${line%%#*}; [[ -z "${line//[[:space:]]/}" ]] && continue
    read -r ip roles extra <<<"$line"
    [[ -z "${extra:-}" && "$roles" == roles=* ]] || fail "nodes.conf 第 $lineno 行格式错误"
    roles=${roles#roles=}
    [[ "$ip" != "NODE" && "$ip" != *"<"* ]] || fail "nodes.conf 尚未填写真实 IP"
    [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]] || fail "节点地址格式不合法：$ip"
    [[ " ${NODE_IPS[*]-} " != *" $ip "* ]] || fail "节点重复：$ip"
    NODE_IPS+=("$ip")
    local role
    IFS=',' read -ra parsed_roles <<<"$roles"
    for role in "${parsed_roles[@]}"; do
      case "$role" in
        vmstorage) STORAGE_NODES+=("$ip") ;;
        vminsert) INSERT_NODES+=("$ip") ;;
        vmselect) SELECT_NODES+=("$ip") ;;
        vmagent) AGENT_NODES+=("$ip") ;;
        vmalert) ALERT_NODES+=("$ip") ;;
        vmauth) AUTH_NODES+=("$ip") ;;
        *) fail "节点 $ip 包含未知角色：$role" ;;
      esac
    done
  done < "$NODES_FILE"
  [[ ${#NODE_IPS[@]} -eq 3 ]] || fail "必须配置恰好 3 个节点"
  [[ ${#STORAGE_NODES[@]} -eq 3 ]] || fail "三个节点都必须部署 vmstorage"
  [[ ${#INSERT_NODES[@]} -ge 2 && ${#SELECT_NODES[@]} -ge 2 ]] || fail "vminsert、vmselect 各至少需要 2 个"
  [[ ${#AGENT_NODES[@]} -eq 2 && ${#ALERT_NODES[@]} -eq 2 && ${#AUTH_NODES[@]} -eq 2 ]] || fail "vmagent、vmalert、vmauth 必须各配置 2 个"
}
load_nodes

ssh_node() { local node=$1; shift; ssh $SSH_OPTIONS "root@$node" "$@"; }
node_has_role() { local node=$1 role=$2 n; shift 2; for n in "$@"; do [[ "$n" == "$node" ]] && return 0; done; return 1; }
join_addrs() { local port=$1; shift; local out= n; for n in "$@"; do out+="${out:+,}$n:$port"; done; printf '%s' "$out"; }

check_local_files() {
  local cluster_entries vmutils_entries
  [[ -r "$CLUSTER_TAR" && -r "$VMUTILS_TAR" ]] || fail "缺少 v1.135.0 cluster/vmutils tar 包"
  [[ -r "$CFG_SOURCE/prometheus.yml" ]] || fail "缺少 $CFG_SOURCE/prometheus.yml"
  cluster_entries=$(tar -tzf "$CLUSTER_TAR")
  vmutils_entries=$(tar -tzf "$VMUTILS_TAR")
  for bin in vmstorage-prod vminsert-prod vmselect-prod; do grep -Fx "$bin" <<<"$cluster_entries" >/dev/null || fail "cluster tar 缺少 $bin"; done
  for bin in vmagent-prod vmalert-prod vmauth-prod; do grep -Fx "$bin" <<<"$vmutils_entries" >/dev/null || fail "vmutils tar 缺少 $bin"; done
}

check_node() {
  local node=$1 ports=("$VMSTORAGE_INSERT_PORT" "$VMSTORAGE_SELECT_PORT" "$VMSTORAGE_HTTP_PORT" "$VMINSERT_HTTP_PORT" "$VMSELECT_HTTP_PORT" "$VMAGENT_HTTP_PORT" "$VMALERT_HTTP_PORT" "$VMAUTH_HTTP_PORT")
  log "检查节点 $node"
  ssh_node "$node" "test \"\$(id -u)\" = 0 && test \"\$(uname -m)\" = x86_64" || return 1
  ssh_node "$node" "command -v systemctl >/dev/null && command -v rsync >/dev/null && command -v curl >/dev/null && command -v sha256sum >/dev/null" || return 1
  ssh_node "$node" "p='$DATA_ROOT'; while [ ! -e \"\$p\" ]; do p=\$(dirname \"\$p\"); done; test \"\$(df -Pk \"\$p\" | awk 'NR==2{print \$4}')\" -ge 1048576" || { warn "$node 数据盘可用空间不足 1GiB"; return 1; }
  local port
  for port in "${ports[@]}"; do
    if ssh_node "$node" "ss -lntH 2>/dev/null | awk '{print \$4}' | grep -Eq '(^|:)$port$'"; then
      if ! ssh_node "$node" "for s in vmcluster-vmstorage vmcluster-vminsert vmcluster-vmselect vmcluster-vmagent vmcluster-vmalert vmcluster-vmauth; do systemctl is-active --quiet \$s && exit 0; done; exit 1"; then
        warn "$node 端口 $port 已被非本集群服务占用"; return 1
      fi
    fi
  done
  ssh_node "$node" "systemctl is-active --quiet chronyd || systemctl is-active --quiet systemd-timesyncd || systemctl is-active --quiet ntpd" || warn "$node 未检测到活动的时间同步服务"
  ssh_node "$node" "legacy=''; for s in vmstorage vminsert vmselect vmagent vmalert; do if systemctl is-active --quiet \$s; then legacy=\"\${legacy}\${legacy:+,}\$s\"; fi; done; if [ -n \"\$legacy\" ]; then echo \"  受保护旧服务：\$legacy（仅检测，不修改）\"; else echo '  受保护旧服务：未发现'; fi; if [ -d /data/local/vm/data ]; then echo '  受保护旧数据：/data/local/vm/data（仅检测，不修改）'; else echo '  受保护旧数据：未发现'; fi"
  ssh_node "$node" "if command -v firewall-cmd >/dev/null; then state=\$(firewall-cmd --state 2>&1 || true); echo \"  防火墙状态：firewalld \${state:-unknown}\"; elif command -v ufw >/dev/null; then state=\$(ufw status 2>/dev/null | head -1); if echo \"\$state\" | grep -qi inactive; then echo '  防火墙状态：ufw 未启用（请确认外部 ACL 或安全组）'; elif echo \"\$state\" | grep -qi active; then echo '  防火墙状态：ufw 已启用'; else echo \"  防火墙状态：ufw unknown（\$state）\"; fi; else echo '  防火墙状态：未检测到 firewalld/ufw（请确认外部 ACL 或安全组）'; fi"
}

check_connectivity() {
  local src dst port failed=0
  for src in "${NODE_IPS[@]}"; do
    for dst in "${NODE_IPS[@]}"; do
      [[ "$src" == "$dst" ]] && continue
      ssh_node "$src" "timeout 3 bash -c '</dev/tcp/$dst/22'" || { warn "$src 无法连接 $dst:22"; failed=1; }
    done
  done
  return "$failed"
}

run_check() {
  check_local_files
  local check_tmp render_tmp check_log
  check_tmp=$(mktemp -d)
  tar -xzf "$VMUTILS_TAR" -C "$check_tmp" vmagent-prod
  check_log="$check_tmp/vmagent-source-check.log"
  if ! (cd "$CFG_SOURCE" && "$check_tmp/vmagent-prod" -promscrape.config=prometheus.yml -dryRun) >"$check_log" 2>&1; then
    cat "$check_log" >&2
    rm -rf "$check_tmp"
    fail "源 prometheus.yml 或其引用文件校验失败"
  fi
  log "源 vmagent 抓取配置校验通过"
  rm -rf "$check_tmp"
  render_tmp=$(mktemp -d)
  VM_WRITE_USER=check_write VM_WRITE_PASSWORD=check-password VM_QUERY_USER=check_query VM_QUERY_PASSWORD=check-password
  build_stage_for_node "${NODE_IPS[0]}" "$render_tmp"
  check_log="$render_tmp/vmauth-check.log"
  if ! "$render_tmp/bin/vmauth-prod" -auth.config="$render_tmp/config/vmauth.yml" -dryRun >"$check_log" 2>&1; then
    cat "$check_log" >&2
    rm -rf "$render_tmp"
    fail "生成的 vmauth 配置校验失败"
  fi
  log "vmauth 双账号及后端路由配置校验通过"
  check_log="$render_tmp/vmagent-rendered-check.log"
  if ! (cd "$render_tmp/config/scrape" && "$render_tmp/bin/vmagent-prod" -promscrape.config=prometheus.yml -dryRun) >"$check_log" 2>&1; then
    cat "$check_log" >&2
    rm -rf "$render_tmp"
    fail "生成的集群采集配置校验失败"
  fi
  log "生成后的集群采集配置校验通过"
  rm -rf "$render_tmp"
  local failed=0 node
  for node in "${NODE_IPS[@]}"; do check_node "$node" || failed=1; done
  check_connectivity || failed=1
  [[ $failed -eq 0 ]] || fail "环境检查失败，请处理以上问题后重试"
  log "环境检查完成；未修改节点、防火墙或现有单点服务"
}

ensure_secrets() {
  install -d -m 700 "$SECRETS_DIR"
  if [[ ! -f "$SECRETS_FILE" ]]; then
    umask 077
    cat >"$SECRETS_FILE" <<EOF
VM_WRITE_USER=vmcluster_write
VM_WRITE_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
VM_QUERY_USER=vmcluster_query
VM_QUERY_PASSWORD=$(openssl rand -base64 32 | tr -d '\n')
EOF
  fi
  chmod 600 "$SECRETS_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  [[ -n "$VM_WRITE_USER" && -n "$VM_WRITE_PASSWORD" && -n "$VM_QUERY_USER" && -n "$VM_QUERY_PASSWORD" ]] || fail "凭据文件不完整"
}

write_unit() {
  local file=$1 description=$2 exec_start=$3
  cat >"$file" <<EOF
[Unit]
Description=$description
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$REMOTE_CONFIG_DIR
ExecStart=$exec_start
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
}

build_stage_for_node() {
  local node=$1 stage=$2 agent_index=-1 auth_index=-1 i storage_addrs select_addrs insert_urls query_urls
  mkdir -p "$stage/bin" "$stage/config/scrape" "$stage/units"
  tar -xzf "$CLUSTER_TAR" -C "$stage/bin"
  tar -xzf "$VMUTILS_TAR" -C "$stage/bin" vmagent-prod vmalert-prod vmauth-prod
  rsync -a --delete --exclude 'bak/' --exclude '*.swp' --exclude '.*.swp' "$CFG_SOURCE/" "$stage/config/scrape/"
  # 旧配置中的 localhost 自监控目标属于单点部署；仅在分发副本中替换为新集群目标。
  awk '
    /^  - job_name:/ {
      if ($0 ~ /victoriametrics/ || $0 ~ /vmalert/ || $0 ~ /vmagent/) { skip=1; next }
      skip=0
    }
    !skip { print }
  ' "$stage/config/scrape/prometheus.yml" >"$stage/config/scrape/prometheus.yml.cluster"
  mv "$stage/config/scrape/prometheus.yml.cluster" "$stage/config/scrape/prometheus.yml"
  {
    printf "\n  - job_name: 'victoriametrics-cluster'\n    static_configs:\n      - targets:\n"
    for i in "${INSERT_NODES[@]}"; do printf "          - '%s:%s'\n" "$i" "$VMINSERT_HTTP_PORT"; done
    for i in "${SELECT_NODES[@]}"; do printf "          - '%s:%s'\n" "$i" "$VMSELECT_HTTP_PORT"; done
    for i in "${STORAGE_NODES[@]}"; do printf "          - '%s:%s'\n" "$i" "$VMSTORAGE_HTTP_PORT"; done
    printf "    metrics_path: /metrics\n\n  - job_name: 'vmagent-cluster'\n    static_configs:\n      - targets:\n"
    for i in "${AGENT_NODES[@]}"; do printf "          - '%s:%s'\n" "$i" "$VMAGENT_HTTP_PORT"; done
    printf "    metrics_path: /metrics\n\n  - job_name: 'vmalert-cluster'\n    static_configs:\n      - targets:\n"
    for i in "${ALERT_NODES[@]}"; do printf "          - '%s:%s'\n" "$i" "$VMALERT_HTTP_PORT"; done
    printf "    metrics_path: /metrics\n"
  } >>"$stage/config/scrape/prometheus.yml"
  storage_addrs=$(join_addrs "$VMSTORAGE_INSERT_PORT" "${STORAGE_NODES[@]}")
  select_addrs=$(join_addrs "$VMSTORAGE_SELECT_PORT" "${STORAGE_NODES[@]}")
  insert_urls=; for i in "${INSERT_NODES[@]}"; do insert_urls+="      - http://$i:$VMINSERT_HTTP_PORT/insert/$TENANT_ID/prometheus\n"; done
  query_urls=; for i in "${SELECT_NODES[@]}"; do query_urls+="      - http://$i:$VMSELECT_HTTP_PORT/select/$TENANT_ID/prometheus\n"; done
  printf '%s' "$VM_WRITE_PASSWORD" >"$stage/config/write.password"
  printf '%s' "$VM_QUERY_PASSWORD" >"$stage/config/query.password"
  if [[ -f "$SECRETS_FILE" ]]; then
    mkdir -p "$stage/config/secrets"
    cp "$SECRETS_FILE" "$stage/config/secrets/cluster.env"
  fi
  printf 'VMALERT_NOTIFIER_ARGS=-notifier.blackhole\n' >"$stage/config/vmalert.env"
  printf 'users:\n  - username: %s\n    password: %s\n    url_prefix:\n%b  - username: %s\n    password: %s\n    url_prefix:\n%b' \
    "$VM_WRITE_USER" "$VM_WRITE_PASSWORD" "$insert_urls" "$VM_QUERY_USER" "$VM_QUERY_PASSWORD" "$query_urls" >"$stage/config/vmauth.yml"

  if node_has_role "$node" vmstorage "${STORAGE_NODES[@]}"; then
    write_unit "$stage/units/vmcluster-vmstorage.service" "VictoriaMetrics Cluster Storage" "$APP_DIR/bin/vmstorage-prod -storageDataPath=$CLUSTER_DATA/vmstorage-data -retentionPeriod=$RETENTION_PERIOD -dedup.minScrapeInterval=$DEDUP_INTERVAL -vminsertAddr=:$VMSTORAGE_INSERT_PORT -vmselectAddr=:$VMSTORAGE_SELECT_PORT -httpListenAddr=:$VMSTORAGE_HTTP_PORT"
  fi
  if node_has_role "$node" vminsert "${INSERT_NODES[@]}"; then
    write_unit "$stage/units/vmcluster-vminsert.service" "VictoriaMetrics Cluster Insert" "$APP_DIR/bin/vminsert-prod -storageNode=$storage_addrs -replicationFactor=2 -httpListenAddr=:$VMINSERT_HTTP_PORT"
  fi
  if node_has_role "$node" vmselect "${SELECT_NODES[@]}"; then
    write_unit "$stage/units/vmcluster-vmselect.service" "VictoriaMetrics Cluster Select" "$APP_DIR/bin/vmselect-prod -storageNode=$select_addrs -replicationFactor=2 -dedup.minScrapeInterval=$DEDUP_INTERVAL -cacheDataPath=$CLUSTER_DATA/vmselect-cache -httpListenAddr=:$VMSELECT_HTTP_PORT"
  fi
  if node_has_role "$node" vmauth "${AUTH_NODES[@]}"; then
    write_unit "$stage/units/vmcluster-vmauth.service" "VictoriaMetrics Cluster Auth" "$APP_DIR/bin/vmauth-prod -auth.config=$REMOTE_CONFIG_DIR/vmauth.yml -httpListenAddr=:$VMAUTH_HTTP_PORT"
  fi
  for i in "${!AGENT_NODES[@]}"; do [[ "${AGENT_NODES[$i]}" == "$node" ]] && agent_index=$i; done
  if (( agent_index >= 0 )); then
    local auth_node=${AUTH_NODES[$agent_index]}
    write_unit "$stage/units/vmcluster-vmagent.service" "VictoriaMetrics Cluster Agent" "$APP_DIR/bin/vmagent-prod -promscrape.config=$REMOTE_CONFIG_DIR/scrape/prometheus.yml -promscrape.cluster.membersCount=2 -promscrape.cluster.memberNum=$agent_index -promscrape.cluster.replicationFactor=2 -remoteWrite.url=http://$auth_node:$VMAUTH_HTTP_PORT/ -remoteWrite.basicAuth.username=$VM_WRITE_USER -remoteWrite.basicAuth.passwordFile=$REMOTE_CONFIG_DIR/write.password -remoteWrite.tmpDataPath=$CLUSTER_DATA/vmagent-remotewrite-data -httpListenAddr=:$VMAGENT_HTTP_PORT"
  fi
  if node_has_role "$node" vmalert "${ALERT_NODES[@]}"; then
    for i in "${!ALERT_NODES[@]}"; do [[ "${ALERT_NODES[$i]}" == "$node" ]] && auth_index=$i; done
    local query_auth=${AUTH_NODES[$auth_index]}
    write_unit "$stage/units/vmcluster-vmalert.service" "VictoriaMetrics Cluster Alert" "$APP_DIR/bin/vmalert-prod -datasource.url=http://$query_auth:$VMAUTH_HTTP_PORT/ -datasource.basicAuth.username=$VM_QUERY_USER -datasource.basicAuth.passwordFile=$REMOTE_CONFIG_DIR/query.password -rule=$REMOTE_CONFIG_DIR/scrape/rules/*.yml -httpListenAddr=:$VMALERT_HTTP_PORT -configCheckInterval=30s \$VMALERT_NOTIFIER_ARGS"
    sed -i "/WorkingDirectory/a EnvironmentFile=-$REMOTE_CONFIG_DIR/vmalert.env" "$stage/units/vmcluster-vmalert.service"
  fi
  chmod 600 "$stage/config/"*.password "$stage/config/vmauth.yml" "$stage/config/vmalert.env"
}

install_node() {
  local node=$1 stage=$2 backup
  log "分发并安装节点 $node"
  ssh_node "$node" "id -u '$SERVICE_USER' >/dev/null 2>&1 || useradd --system --home-dir '$APP_DIR' --shell /usr/sbin/nologin '$SERVICE_USER'; install -d -o '$SERVICE_USER' -g '$SERVICE_USER' '$APP_DIR/bin' '$REMOTE_CONFIG_DIR' '$CLUSTER_DATA'; install -d -m 700 -o root -g root '$SECRETS_DIR'; install -d -o '$SERVICE_USER' -g '$SERVICE_USER' '$CLUSTER_DATA/vmstorage-data' '$CLUSTER_DATA/vmselect-cache' '$CLUSTER_DATA/vmagent-remotewrite-data'"
  backup=$(date +%Y%m%d%H%M%S)
  ssh_node "$node" "test ! -d '$REMOTE_CONFIG_DIR' || cp -a '$REMOTE_CONFIG_DIR' '${REMOTE_CONFIG_DIR}.backup.$backup'; test ! -d '$APP_DIR/bin' || cp -a '$APP_DIR/bin' '$APP_DIR/bin.backup.$backup'"
  rsync -a -e "ssh $SSH_OPTIONS" "$stage/bin/" "root@$node:$APP_DIR/bin/"
  rsync -a --delete -e "ssh $SSH_OPTIONS" "$stage/config/" "root@$node:$REMOTE_CONFIG_DIR/"
  rsync -a -e "ssh $SSH_OPTIONS" "$stage/units/" "root@$node:/etc/systemd/system/"
  ssh_node "$node" "chown -R '$SERVICE_USER:$SERVICE_USER' '$APP_DIR' '$REMOTE_CONFIG_DIR' '$CLUSTER_DATA'; chmod 600 '$REMOTE_CONFIG_DIR'/*.password '$REMOTE_CONFIG_DIR/vmauth.yml' '$REMOTE_CONFIG_DIR/vmalert.env'; if [ -d '$SECRETS_DIR' ]; then chown -R root:root '$SECRETS_DIR'; chmod 700 '$SECRETS_DIR'; find '$SECRETS_DIR' -type f -exec chmod 600 {} +; fi; chmod 755 '$APP_DIR/bin/'*-prod; systemctl daemon-reload"
}

start_role() { local role=$1 node; shift; for node in "$@"; do ssh_node "$node" "systemctl enable vmcluster-$role.service >/dev/null; systemctl restart vmcluster-$role.service"; done; }
run_install() {
  run_check; ensure_secrets
  local tmp node; tmp=$(mktemp -d); trap "rm -rf -- '$tmp'" EXIT
  for node in "${NODE_IPS[@]}"; do mkdir -p "$tmp/$node"; build_stage_for_node "$node" "$tmp/$node"; install_node "$node" "$tmp/$node"; done
  start_role vmstorage "${STORAGE_NODES[@]}"
  start_role vminsert "${INSERT_NODES[@]}"; start_role vmselect "${SELECT_NODES[@]}"
  start_role vmauth "${AUTH_NODES[@]}"; start_role vmagent "${AGENT_NODES[@]}"; start_role vmalert "${ALERT_NODES[@]}"
  log "安装完成；新 vmalert 当前为 blackhole，不会通知现有 Alertmanager"
  log "查询入口：${AUTH_NODES[0]}:$VMAUTH_HTTP_PORT、${AUTH_NODES[1]}:$VMAUTH_HTTP_PORT；凭据保存在 $SECRETS_FILE"
  rm -rf -- "$tmp"
  trap - EXIT
}

run_sync_config() {
  check_local_files
  ensure_secrets
  local tmp stage node backup seen=" "
  tmp=$(mktemp -d)
  trap "rm -rf -- '$tmp'" EXIT
  stage="$tmp/rendered"
  build_stage_for_node "${NODE_IPS[0]}" "$stage"

  (cd "$stage/config/scrape" && "$stage/bin/vmagent-prod" -promscrape.config=prometheus.yml -dryRun) \
    || fail "生成的 vmagent 配置校验失败，未同步任何节点"
  "$stage/bin/vmalert-prod" -rule="$stage/config/scrape/rules/*.yml" -dryRun \
    || fail "vmalert 规则校验失败，未同步任何节点"

  backup=$(date +%Y%m%d%H%M%S)
  for node in "${AGENT_NODES[@]}" "${ALERT_NODES[@]}"; do
    [[ "$seen" == *" $node "* ]] && continue
    seen+="$node "
    ssh_node "$node" "test -d '$REMOTE_CONFIG_DIR/scrape' && cp -a '$REMOTE_CONFIG_DIR/scrape' '$REMOTE_CONFIG_DIR/scrape.backup.$backup'" \
      || fail "$node 备份当前配置失败，停止同步"
    rsync -a --delete -e "ssh $SSH_OPTIONS" "$stage/config/scrape/" "root@$node:$REMOTE_CONFIG_DIR/scrape/" \
      || fail "$node 配置同步失败；备份位于 $REMOTE_CONFIG_DIR/scrape.backup.$backup"
    ssh_node "$node" "chown -R '$SERVICE_USER:$SERVICE_USER' '$REMOTE_CONFIG_DIR/scrape'"
  done

  for node in "${AGENT_NODES[@]}"; do
    ssh_node "$node" "systemctl is-active --quiet vmcluster-vmagent && systemctl kill --kill-who=main -s HUP vmcluster-vmagent"
  done
  for node in "${ALERT_NODES[@]}"; do
    ssh_node "$node" "systemctl is-active --quiet vmcluster-vmalert && systemctl kill --kill-who=main -s HUP vmcluster-vmalert"
  done
  sleep 3
  for node in "${AGENT_NODES[@]}"; do
    ssh_node "$node" "systemctl is-active --quiet vmcluster-vmagent" || fail "$node 的 vmagent 热加载后状态异常"
  done
  for node in "${ALERT_NODES[@]}"; do
    ssh_node "$node" "systemctl is-active --quiet vmcluster-vmalert" || fail "$node 的 vmalert 热加载后状态异常"
  done
  log "配置同步及热加载完成；备份后缀：$backup"
  log "未重启 vmstorage、vminsert、vmselect、vmauth，也未操作旧单点服务"
  rm -rf -- "$tmp"
  trap - EXIT
}

run_status() {
  local node
  for node in "${NODE_IPS[@]}"; do
    printf '\n=== %s ===\n' "$node"
    ssh_node "$node" "systemctl --no-pager --full status 'vmcluster-*' 2>/dev/null | grep -E 'Loaded:|Active:|vmcluster-' || true; df -h '$CLUSTER_DATA' 2>/dev/null || true; ss -lntp | grep -E ':($VMSTORAGE_INSERT_PORT|$VMSTORAGE_SELECT_PORT|$VMSTORAGE_HTTP_PORT|$VMINSERT_HTTP_PORT|$VMSELECT_HTTP_PORT|$VMAGENT_HTTP_PORT|$VMALERT_HTTP_PORT|$VMAUTH_HTTP_PORT)[[:space:]]' || true"
  done
}

old_snapshot() {
  local node
  for node in "${NODE_IPS[@]}"; do
    printf 'node=%s\n' "$node"
    ssh_node "$node" "for s in vmstorage vminsert vmselect vmagent vmalert; do systemctl cat \$s >/dev/null 2>&1 || continue; printf '%s ' \$s; systemctl show \$s -p MainPID -p ActiveEnterTimestampMonotonic -p ActiveState --value 2>/dev/null | tr '\n' ' '; echo; done; if systemctl is-active --quiet vmselect; then curl -fsS http://127.0.0.1:8481/health >/dev/null && echo old-query-health=ok || echo old-query-health=failed; fi"
  done
}
run_verify() {
  ensure_secrets
  local before after test_id now auth code result
  before=$(old_snapshot); printf '%s\n' "$before"
  test_id="vmcluster-$(date +%s)-$$"; now=$(date +%s%3N)
  for auth in "${AUTH_NODES[@]}"; do
    curl -fsS -u "$VM_WRITE_USER:$VM_WRITE_PASSWORD" --data-binary "vmcluster_deployment_test{deployment_test_id=\"$test_id\"} 1 $now" "http://$auth:$VMAUTH_HTTP_PORT/api/v1/import/prometheus" >/dev/null || fail "$auth 测试写入失败"
    result=; for _ in {1..10}; do
      result=$(curl -fsS -u "$VM_QUERY_USER:$VM_QUERY_PASSWORD" --get --data-urlencode "query=vmcluster_deployment_test{deployment_test_id=\"$test_id\"}" "http://$auth:$VMAUTH_HTTP_PORT/api/v1/query") || true
      grep -q "$test_id" <<<"$result" && break
      sleep 1
    done
    grep -q "$test_id" <<<"$result" || fail "$auth 测试查询未返回刚写入的序列"
    code=$(curl -sS -o /dev/null -w '%{http_code}' "http://$auth:$VMAUTH_HTTP_PORT/api/v1/query?query=up"); [[ "$code" == 401 ]] || fail "$auth 无凭据查询未被拒绝（HTTP $code）"
    code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$VM_WRITE_USER:$VM_WRITE_PASSWORD" "http://$auth:$VMAUTH_HTTP_PORT/api/v1/query?query=up"); [[ "$code" != 2* ]] || fail "$auth 写入账号不应具备查询权限"
    code=$(curl -sS -o /dev/null -w '%{http_code}' -u "$VM_QUERY_USER:$VM_QUERY_PASSWORD" --data-binary 'x 1' "http://$auth:$VMAUTH_HTTP_PORT/api/v1/import/prometheus"); [[ "$code" != 2* ]] || fail "$auth 查询账号不应具备写入权限"
  done
  run_status
  after=$(old_snapshot); printf '%s\n' "$after"
  [[ "$before" == "$after" ]] || fail "旧单点进程状态发生变化；验证已停止，未自动操作任何服务"
  log "无影响验证完成，测试标签 deployment_test_id=$test_id"
}

set_alerting() {
  local mode=$1 node args
  if [[ "$mode" == enable ]]; then
    [[ -t 0 ]] || fail "启用生产告警必须在交互终端执行"
    read -r -p "确认让两个新 vmalert 向 $ALERTMANAGER_URL 发送告警？输入 yes：" answer
    [[ "$answer" == yes ]] || fail "用户取消"
    args="-notifier.url=$ALERTMANAGER_URL"
  else args="-notifier.blackhole"; fi
  for node in "${ALERT_NODES[@]}"; do
    ssh_node "$node" "printf '%s\n' 'VMALERT_NOTIFIER_ARGS=$args' > '$REMOTE_CONFIG_DIR/vmalert.env'; chown '$SERVICE_USER:$SERVICE_USER' '$REMOTE_CONFIG_DIR/vmalert.env'; chmod 600 '$REMOTE_CONFIG_DIR/vmalert.env'; systemctl restart vmcluster-vmalert"
  done
  log "新集群告警模式已设置为：$mode；未操作旧 vmalert"
}

case "$ACTION" in
  check) run_check ;;
  install) run_install ;;
  status) run_status ;;
  verify) run_verify ;;
  sync-config) run_sync_config ;;
  enable-alerting) set_alerting enable ;;
  disable-alerting) set_alerting disable ;;
esac
