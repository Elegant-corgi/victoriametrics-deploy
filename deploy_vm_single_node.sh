#!/bin/bash

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 显示用法
usage() {
    echo "用法: $0 <部署路径> <tar包路径>"
    echo "示例: $0 /opt/victoriametrics ./victoriametrics-cluster-v1.135.0.tar.gz"
    exit 1
}

# 检查参数
if [ $# -ne 2 ]; then
    usage
fi

# 检查端口是否被占用
check_port_available() {
    local port=$1
    local service=$2
    if netstat -tuln | grep ":$port " > /dev/null; then
        log_warn "端口 $port 已被占用，$service 服务可能启动失败"
    fi
    return 0
}
check_port_available 8482 "vmstorage"
check_port_available 8480 "vminsert"
check_port_available 8400 "vminsert"
check_port_available 8401 "vmselect"
check_port_available 8481 "vmselect-vmui"
check_port_available 8429 "vmagent"
check_port_available 8880 "vmalert"

DEPLOY_PATH="$1"
TAR_PATH="$2"

# 创建默认prometheus配置文件
create_default_prometheus_config() {
    cat > "$DEPLOY_PATH/cfg/prometheus.yml" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'victoriametrics'
    static_configs:
      - targets: ['localhost:8480']  # vminsert
      - targets: ['localhost:8481']  # vmselect  
      - targets: ['localhost:8482']  # vmstorage
    metrics_path: /metrics

  - job_name: 'vmalert'
    static_configs:
      - targets: ['localhost:8880']
    metrics_path: /metrics

  - job_name: 'vmagent'
    static_configs:
      - targets: ['localhost:8429']
    metrics_path: /metrics
EOF
}

# 创建默认告警规则
create_default_alert_rules() {
    mkdir -p "$DEPLOY_PATH/cfg/rules"
    cat > "$DEPLOY_PATH/cfg/rules/node_alerts.yml" << 'EOF'
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

# 检查 tar 包是否存在
if [ ! -f "$TAR_PATH" ]; then
    log_error "Tar 包不存在: $TAR_PATH"
    exit 1
fi

# 获取 tar 包文件名（不含路径和扩展名）
TAR_FILENAME=$(basename "$TAR_PATH")
TAR_NAME="${TAR_FILENAME%.tar.gz}"
TAR_NAME="${TAR_NAME%.tgz}"

log_info "开始部署 VictoriaMetrics"
log_info "部署路径: $DEPLOY_PATH"
log_info "源文件: $TAR_PATH"
log_info "版本: $TAR_NAME"

# 创建目录结构
log_info "创建目录结构..."
mkdir -p "$DEPLOY_PATH"/{bin,data,cfg,logs}

# 解压 tar 包到临时目录
TEMP_DIR=$(mktemp -d)
log_info "解压文件到临时目录: $TEMP_DIR"

if ! tar -xzf "$TAR_PATH" -C "$TEMP_DIR"; then
    log_error "解压失败: $TAR_PATH"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# 检查当前目录是否有 cfg 文件，如果有则复制
log_info "检查当前目录的配置文件..."
CURRENT_DIR=$(pwd)

if [ -d "$CURRENT_DIR/cfg" ] && [ "$(ls -A $CURRENT_DIR/cfg)" ]; then
    log_info "发现现有配置文件，复制到部署目录..."
    cp -r "$CURRENT_DIR/cfg"/* "$DEPLOY_PATH/cfg/"
    
    # 检查是否已有 prometheus.yml
    if [ ! -f "$DEPLOY_PATH/cfg/prometheus.yml" ]; then
        log_warn "未找到 prometheus.yml，创建默认配置"
        create_default_prometheus_config
    else
        log_info "使用现有的 prometheus.yml 配置"
    fi
else
    log_info "未找到现有配置文件，创建默认配置..."
    create_default_prometheus_config
    create_default_alert_rules
fi

# 查找并复制二进制文件
log_info "查找二进制文件..."
find "$TEMP_DIR" -type f -name "*prod" -o -name "vm*" | while read -r binary; do
    if [ -x "$binary" ]; then
        filename=$(basename "$binary")
	target_file="$DEPLOY_PATH/bin/$filename"

	# 检查目标文件是否已存在
	if [ -e "$target_file" ]; then	
	  log_info "跳过: $filename 已存在"	
	  continue					
	fi

        # 如果是符号链接，找到真实文件
        if [ -L "$binary" ]; then
            real_binary=$(readlink -f "$binary")
            cp "$real_binary" "$DEPLOY_PATH/bin/$filename"
            log_info "复制: $filename"
        else
            cp "$binary" "$DEPLOY_PATH/bin/$filename"
            log_info "复制: $filename"
        fi
    fi
done

# 设置执行权限
chmod +x "$DEPLOY_PATH"/bin/*

# 清理临时目录
rm -rf "$TEMP_DIR"

# 守护进程
log_info "创建 systemd 服务文件..."

create_systemd_service() {
    local service_name="$1"
    local description="$2"
    local exec_start="$3"
    
    cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=$description
After=network.target
Wants=network.target

[Service]
Type=simple
WorkingDirectory=$DEPLOY_PATH
ExecStart=$exec_start
Restart=always
RestartSec=10
StartLimitInterval=300
StartLimitBurst=5

# 资源限制
LimitNOFILE=65536
LimitNPROC=4096

# 环境变量
Environment=PATH=/usr/local/bin:/usr/bin:/bin
Environment=GOMAXPROCS=auto

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "/etc/systemd/system/${service_name}.service"
    log_info "创建服务: $service_name"
}

# 创建各个组件的 systemd 服务
create_systemd_service "vmstorage" "VictoriaMetrics Storage Node" \
    "$DEPLOY_PATH/bin/vmstorage-prod -storageDataPath=$DEPLOY_PATH/data/vmstorage-data -retentionPeriod=1y -httpListenAddr=:8482 -vminsertAddr=:8400 -vmselectAddr=:8401"

create_systemd_service "vminsert" "VictoriaMetrics Insert Node" \
    "$DEPLOY_PATH/bin/vminsert-prod -storageNode=localhost:8400 -httpListenAddr=:8480"

create_systemd_service "vmselect" "VictoriaMetrics Select Node" \
    "$DEPLOY_PATH/bin/vmselect-prod -storageNode=localhost:8401 -httpListenAddr=:8481 -cacheDataPath=$DEPLOY_PATH/data/vmselect-cache"

create_systemd_service "vmagent" "VictoriaMetrics Agent" \
    "$DEPLOY_PATH/bin/vmagent-prod -promscrape.config=$DEPLOY_PATH/cfg/prometheus.yml -remoteWrite.url=http://localhost:8480/insert/0/prometheus/ -httpListenAddr=:8429 -remoteWrite.tmpDataPath=$DEPLOY_PATH/data/vmagent-remotewrite-data"

create_systemd_service "vmalert" "VictoriaMetrics Alert Manager" \
    "$DEPLOY_PATH/bin/vmalert-prod -datasource.url=http://localhost:8481/select/0/prometheus -notifier.url=http://localhost:9093 -rule=$DEPLOY_PATH/cfg/rules/*.yml -httpListenAddr=:8880 -notifier.basicAuth.username=user -notifier.basicAuth.password=pass -notifier.tlsInsecureSkipVerify=true -configCheckInterval=30s"

# 重新加载 systemd
systemctl daemon-reload
systemctl enable vmselect.service
systemctl restart vmselect.service
systemctl enable vminsert.service
systemctl restart vminsert.service
systemctl enable vmstorage.service
systemctl restart vmstorage.service
systemctl enable vmagent.service
systemctl restart vmagent.service
systemctl enable vmalert.service
systemctl restart vmalert.service
log_info "systemd 服务文件创建完成，已重新加载"

# 检查服务状态
check_service_status() {
    local service_name="$1"
    if systemctl is-active --quiet "$service_name"; then
        log_info "服务 $service_name 启动成功"
    else
        log_error "服务 $service_name 启动失败"
        systemctl status "$service_name" --no-pager -l
    fi
}
check_service_status "vmstorage"
check_service_status "vminsert"
check_service_status "vmselect"
check_service_status "vmagent"
check_service_status "vmalert"

# 创建README
cat > "$DEPLOY_PATH/README.md" << EOF
# VictoriaMetrics 部署

## 目录结构
\`\`\`
$DEPLOY_PATH/
├── bin/           # 二进制文件
├── data/          # 数据文件
├── cfg/           # 配置文件
│   ├── prometheus.yml          # 采集配置
│   └── rules/                  # 告警规则目录
│       └── node_alerts.yml     # 示例告警规则
├── logs/          # 日志文件
\`\`\`

## 服务端口
- vmstorage: 8482 (监控), 8400 (vminsert), 8401 (vmselect)
- vminsert: 8480
- vmselect: 8481 + VMUI界面
- vmagent: 8429 + 目标状态界面
- vmalert: 8880 + 告警管理界面

## 配置说明
1. 修改 \`cfg/prometheus.yml\` 配置采集目标
2. 修改 \`cfg/rules/\` 下的告警规则文件

## 版本信息
- 部署版本: $TAR_NAME
- 部署时间: $(date)
\`\`\`bash
# 验证版本
./bin/vmstorage-prod --version
\`\`\`
EOF

log_info "=== VictoriaMetrics 部署完成 ==="
log_info "部署路径: $DEPLOY_PATH"
log_info "二进制文件: $DEPLOY_PATH/bin/"
log_info "数据目录: $DEPLOY_PATH/data/" 
log_info "配置目录: $DEPLOY_PATH/cfg/"
log_info ""
log_info "下一步操作:"
log_info "1. 编辑配置文件: cd $DEPLOY_PATH && vim cfg/prometheus.yml"
log_info "2. 调整告警规则: vim cfg/rules/node_alerts.yml" 
log_info "3. 修改 vmalert 推送地址: /etc/systemd/system/vmalert (修改 -notifier.url 参数)"
log_info ""
log_info "访问地址:"
log_info "- VMUI界面: http://localhost:8481/select/0/vmui/"
log_info "- vmagent目标: http://localhost:8429/targets"
log_info "- vmalert告警: http://localhost:8880"
