# victoriametrics-deploy

VictoriaMetrics 单机和三节点集群部署脚本，以及配套的采集、告警、服务发现配置。

## 目录说明

```text
.
├── cfg/                         # vmagent 抓取配置、file_sd 配置和 vmalert 规则
├── cluster.conf                 # 集群部署参数
├── nodes.conf                   # 集群节点和角色清单
├── deploy_vm_cluster.sh         # 三节点 VictoriaMetrics Cluster 部署/检查/同步脚本
├── deploy_vm_single_node.sh     # 单机部署脚本
└── import_vm.sh                 # Prometheus 历史数据导入脚本
```

## 本地制品

以下文件体积较大或属于可再获取的二进制制品，默认不提交到 Git。运行部署前需要放在项目根目录：

- `victoria-metrics-linux-amd64-v1.135.0-cluster.tar.gz`
- `vmutils-linux-amd64-v1.135.0.tar.gz`
- `victoria-metrics.tar.gz`
- `vmctl-prod`

如需使用其他版本，需要同步调整脚本中的文件名和版本假设。

## 集群部署

1. 修改 `nodes.conf`，确认三台节点 IP 和角色分配。
2. 修改 `cluster.conf`，确认安装目录、数据目录、租户 ID、端口、告警地址等参数。
3. 将 VictoriaMetrics cluster 和 vmutils tar 包放到项目根目录。
4. 先执行检查：

```bash
./deploy_vm_cluster.sh check /data/local/vm
```

5. 检查通过后执行安装：

```bash
./deploy_vm_cluster.sh install /data/local/vm
```

常用维护命令：

```bash
./deploy_vm_cluster.sh status /data/local/vm
./deploy_vm_cluster.sh verify /data/local/vm
./deploy_vm_cluster.sh sync-config /data/local/vm
./deploy_vm_cluster.sh enable-alerting /data/local/vm
./deploy_vm_cluster.sh disable-alerting /data/local/vm
```

## 单机部署

```bash
./deploy_vm_single_node.sh /data/local/vm ./victoria-metrics.tar.gz
```

单机脚本会创建部署目录、复制 `cfg/` 配置、生成 systemd 服务并尝试启动相关组件。

## 配置更新

- 抓取配置入口：`cfg/prometheus.yml`
- 文件服务发现目录：`cfg/file_sd_configs/`
- 告警规则目录：`cfg/rules/`
- 节点分组示例：`cfg/nodes_*.yaml`

修改集群采集配置后，优先使用：

```bash
./deploy_vm_cluster.sh sync-config /data/local/vm
```

该命令会先校验生成后的 vmagent/vmalert 配置，再同步到 vmagent 和 vmalert 节点。

## 安全注意事项

- `.cluster-secrets`、`*.env`、`secrets/` 等凭据文件已加入 `.gitignore`，不要提交真实密码、令牌或生产凭据。
- `nodes.conf`、`cluster.conf` 和 `cfg/` 中可能包含内网 IP、告警地址和业务目标，推送到公开仓库前请确认可公开范围。
- 部署脚本会通过 SSH 连接目标节点，并写入 `/etc/systemd/system/`、应用目录和数据目录，请在测试环境验证后再用于生产。

## 建议的本地检查

```bash
bash -n deploy_vm_cluster.sh
bash -n deploy_vm_single_node.sh
bash -n import_vm.sh
```
