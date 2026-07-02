#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

VERSION=${1:-v1.135.0-deploy.1}
PACKAGE_NAME="victoriametrics-deploy-offline-${VERSION}"
DIST_DIR="$REPO_ROOT/dist"
STAGE_DIR="$DIST_DIR/$PACKAGE_NAME"
ARCHIVE="$DIST_DIR/${PACKAGE_NAME}.tar.gz"

required_artifacts=(
  victoria-metrics-linux-amd64-v1.135.0-cluster.tar.gz
  vmutils-linux-amd64-v1.135.0.tar.gz
  vmutils-linux-amd64-v1.144.0.tar.gz
  victoria-metrics.tar.gz
  vmctl-prod
)

cd "$REPO_ROOT"

mkdir -p "$DIST_DIR"
rm -rf -- "$STAGE_DIR" "$ARCHIVE" "$ARCHIVE.sha256"
mkdir -p "$STAGE_DIR"

for artifact in "${required_artifacts[@]}"; do
  [[ -f "$artifact" ]] || {
    echo "[ERROR] 缺少发布制品：$artifact" >&2
    exit 1
  }
done

git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$STAGE_DIR"

for artifact in "${required_artifacts[@]}"; do
  cp -p "$artifact" "$STAGE_DIR/"
done

{
  echo "# 离线包内容"
  echo
  echo "生成版本：$VERSION"
  echo
  echo "包含制品："
  for artifact in "${required_artifacts[@]}"; do
    echo "- $artifact"
  done
  echo
  echo "使用步骤："
  echo "1. 解压本离线包。"
  echo "2. 复制 cluster.conf.example 为 cluster.conf，并按环境修改。"
  echo "3. 复制 nodes.conf.example 为 nodes.conf，并按环境修改。"
  echo "4. 执行 ./scripts/check.sh 做本地检查。"
  echo "5. 按 README.md 执行集群或单机部署。"
} >"$STAGE_DIR/OFFLINE_PACKAGE.md"

(cd "$STAGE_DIR" && sha256sum "${required_artifacts[@]}" > SHA256SUMS)
(cd "$DIST_DIR" && tar -czf "$ARCHIVE" "$PACKAGE_NAME")
(cd "$DIST_DIR" && sha256sum "$(basename "$ARCHIVE")" >"$(basename "$ARCHIVE").sha256")

echo "[INFO] 已生成：$ARCHIVE"
echo "[INFO] 已生成：$ARCHIVE.sha256"
