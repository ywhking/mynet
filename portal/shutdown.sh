#!/usr/bin/env bash
# 停止 portal 栈（保留数据卷）。
#
#   cd portal && ./shutdown.sh
#
# 数据卷 portal_db / portal_tenants 会保留 —— 重建镜像后数据仍在。
# 要连数据一起清掉（不可恢复）： docker compose down -v
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

docker compose down "$@"
echo "portal 已停止（数据卷保留）。"
