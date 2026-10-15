#!/usr/bin/env bash
# ============================================================
# 脚本名称: seed_netbird_admin.sh
# 功能描述: 为已部署的 NetBird 服务端（combined 单二进制 + 内嵌 Dex IDP）
#           自动注册初始 admin 用户，无需浏览器走 Dashboard 引导流程。
#
# 原理: netbird-server 的 config.yaml 支持 server.auth.owner
#       （combined/cmd/config.go 的 AuthOwnerConfig），server 启动时把该
#       用户写入内嵌 Dex 的静态密码存储（idp/dex/provider.go 的
#       ensureStaticPasswords，幂等: 已存在且 hash 相同则不动）。
#       注意: owner.password 字段必须是 bcrypt 哈希 —— Dex 登录校验
#       （netbirdio/dex fork 的 checkCost + CompareHashAndPassword）
#       严格要求合法 bcrypt（成本 10 起），明文会直接登录失败；
#       哈希由调用方（Ansible 控制机 python3-bcrypt）预生成。
#
# 适用系统: 目标机为堡垒机，/opt/netbird-install 为安装目录
# 使用方法: sudo bash seed_netbird_admin.sh
#
# 必填环境变量:
#   NB_INSTALL_DIR             NetBird 安装目录（含 config.yaml / compose / dashboard.env）
#   NB_ADMIN_PASSWORD_BCRYPT   admin 密码的 bcrypt 哈希（成本 ≥ 10）
# 可选环境变量:
#   NB_ADMIN_EMAIL             admin 登录邮箱（默认 admin@ohmynet.vip）
#   NB_ADMIN_DOMAIN            管理服务 URL（含 scheme，如 https://vpn.ohmynet.vip），
#                              就绪检查用（默认从 dashboard.env 的
#                              NETBIRD_MGMT_API_ENDPOINT 提取）
#
# 幂等性: config.yaml 已含相同 owner 块时跳过（输出 SKIPPED）；
#         哈希不同则就地更新（输出 UPDATED，重新播种 = 重置该用户密码）。
# 输出:   SEEDED（新写入）/ UPDATED（更新哈希）/ SKIPPED（已一致）
# ============================================================

set -euo pipefail

NB_INSTALL_DIR="${NB_INSTALL_DIR:?缺少 NB_INSTALL_DIR}"
NB_ADMIN_EMAIL="${NB_ADMIN_EMAIL:-admin@ohmynet.vip}"
NB_ADMIN_PASSWORD_BCRYPT="${NB_ADMIN_PASSWORD_BCRYPT:?缺少 NB_ADMIN_PASSWORD_BCRYPT}"
NB_ADMIN_DOMAIN="${NB_ADMIN_DOMAIN:-}"

CONFIG="$NB_INSTALL_DIR/config.yaml"

[[ -f "$CONFIG" ]] || { echo "[错误] 未找到 $CONFIG（确认安装目录）" >&2; exit 1; }

# ---- 就绪检查域名（未显式指定时从 dashboard.env 提取）----
if [[ -z "$NB_ADMIN_DOMAIN" ]]; then
  NB_ADMIN_DOMAIN=$(grep -m1 '^NETBIRD_MGMT_API_ENDPOINT=' "$NB_INSTALL_DIR/dashboard.env" 2>/dev/null | cut -d= -f2- || true)
fi
[[ -n "$NB_ADMIN_DOMAIN" ]] || { echo "[错误] 无法确定管理服务域名（NB_ADMIN_DOMAIN 或 dashboard.env）" >&2; exit 1; }

# ---- 幂等判断: 已有 owner 块 ----
if grep -q '^    owner:' "$CONFIG"; then
  existing_email=$(grep -m1 '^      email:' "$CONFIG" | awk '{print $2}')
  existing_hash=$(grep -m1 '^      password:' "$CONFIG" | awk '{print $2}')
  if [[ "$existing_email" == "$NB_ADMIN_EMAIL" && "$existing_hash" == "$NB_ADMIN_PASSWORD_BCRYPT" ]]; then
    echo "SKIPPED: owner 已存在且一致（$NB_ADMIN_EMAIL），无需变更"
    exit 0
  fi
  echo "UPDATED: 更新 owner（$NB_ADMIN_EMAIL）..."
  # 就地替换 email/hash（bcrypt 含 $ 与 / 字符，| 作分隔符，替换串中 $ 无特殊含义）
  sed -i -E \
    -e "s|^      email:.*|      email: $NB_ADMIN_EMAIL|" \
    -e "s|^      password:.*|      password: $NB_ADMIN_PASSWORD_BCRYPT|" \
    "$CONFIG"
else
  echo "SEEDED: 写入 owner（$NB_ADMIN_EMAIL）..."
  # 在 "  auth:" 段首行后插入 owner 块（python3 行级插入，无 yaml 依赖；
  # 结构由安装包 install.sh 渲染，缩进固定为 2/4/6 空格）
  python3 - "$CONFIG" "$NB_ADMIN_EMAIL" "$NB_ADMIN_PASSWORD_BCRYPT" <<'PYEOF'
import sys
path, email, bcrypt_hash = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
out, done = [], False
for line in lines:
    out.append(line)
    if not done and line.rstrip() == "  auth:":
        out.append("    owner:")
        out.append("      email: " + email)
        out.append("      password: " + bcrypt_hash)
        done = True
if not done:
    print("错误: config.yaml 中未找到 '  auth:' 段，无法注入 owner", file=sys.stderr)
    sys.exit(1)
open(path, "w").write("\n".join(out) + "\n")
PYEOF
fi

# ---- 重启 server: 重新读取 config.yaml → ensureStaticPasswords 播种/更新 ----
# 注意: 必须 restart 而非 compose up -d —— 配置文件是只读挂载，
#       up -d 检测不到 compose 文件变化不会重建容器
cd "$NB_INSTALL_DIR"
docker compose restart netbird-server

# ---- 等待就绪（首启需等 Let's Encrypt 证书签发，已有证书则秒级）----
# NB_ADMIN_DOMAIN 已含 scheme（如 https://vpn.ohmynet.vip），直接使用
echo -n "==> 等待服务就绪"
for i in $(seq 1 30); do
  if curl -sk -f -o /dev/null "$NB_ADMIN_DOMAIN/oauth2/.well-known/openid-configuration"; then
    echo " OK"
    echo ""
    echo "初始 admin 已配置: $NB_ADMIN_EMAIL（密码由 Ansible 汇总输出）"
    exit 0
  fi
  if [[ $i -eq 30 ]]; then
    echo ""
    echo "[错误] 服务 60s 内未就绪，请检查: docker compose logs netbird-server" >&2
    exit 1
  fi
  echo -n " ."
  sleep 2
done
