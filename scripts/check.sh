#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)

cd "$REPO_ROOT"

scripts=(
  deploy_vm_cluster.sh
  deploy_vm_single_node.sh
  import_vm.sh
)

echo "[INFO] bash 语法检查"
for script in "${scripts[@]}"; do
  bash -n "$script"
  echo "  ok: $script"
done

if command -v shellcheck >/dev/null 2>&1; then
  echo "[INFO] shellcheck 静态检查"
  shellcheck "${scripts[@]}"
else
  echo "[WARN] 未安装 shellcheck，跳过 shellcheck 静态检查"
fi
