#!/usr/bin/env bash
# =============================================================================
# 通过 NetBird 管理服务(内嵌 Dex IDP)获取 setup key
#
# 原理:管理服务 REST API 不接受账密,必须先用 IDP 完成 OIDC 登录。
#       本脚本走"设备码流程 + 自动提交本地登录表单",全程无需浏览器:
#         device/code → verify_code → auth/local/login → callback → token → API
#
# 用法:
#   ./get_setup_key.sh [--pat] [--days N] [--name NAME] [--no-key]
#     --pat       额外创建一个 PAT(Personal Access Token),打印 nbp_ 开头的令牌
#     --days N    setup key 有效天数(默认 1 天)
#     --name NAME setup key 名称(默认 auto-key)
#     --no-key    只验证登录(设备码流程 → /api/users/current),不创建 setup key
#
# 环境变量:
#   MGMT_URL / EMAIL / PASSWORD   连接与账号(默认 vpn.ohmynet.vip / admin@ohmynet.vip / QWe123.456,
#                                 与 setup-netbird.yml 自动注册的初始 admin 一致)
#   DEBUG=1                       打印调试信息
# =============================================================================
set -uo pipefail

MGMT_URL="${MGMT_URL:-https://vpn.ohmynet.vip}"
EMAIL="${EMAIL:-admin@ohmynet.vip}"
PASSWORD="${PASSWORD:-QWe123.456}"
CLIENT_ID="netbird-dashboard"          # Dex 静态客户端(Dashboard)
SCOPE="openid email profile offline_access"
CURL_TIMEOUT=60                        # 服务器偶发慢响应,超时给足
MAX_ROUNDS=3                           # 整轮流程最多尝试次数
DEBUG="${DEBUG:-0}"                    # 1 = 打印调试信息

CREATE_PAT=false
CREATE_KEY=true            # 默认创建 setup key;--no-key 时仅验证登录
DAYS=1
NAME="auto-key"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pat)  CREATE_PAT=true ;;
    --no-key) CREATE_KEY=false ;;
    --days) DAYS="$2"; shift ;;
    --name) NAME="$2"; shift ;;
    *) echo "未知参数: $1" >&2; exit 1 ;;
  esac
  shift
done

for cmd in curl python3; do
  command -v "$cmd" >/dev/null || { echo "缺少依赖: $cmd" >&2; exit 1; }
done

# 注意: cookie jar 必须在每轮 run_flow 内新建 —— Dex 登录成功后会话 cookie
# 会留在 jar 里，复用同一 jar 会让下一轮的设备码授权被残留会话自动放行
# （GET 链直接落到 callback，POST 上去即 400，误报"账号或密码错误"）

# 发送请求并输出重定向 Location;失败或状态码异常时重试,并打印原因
# 用法:get_loc <method> <url> [curl 参数...]
get_loc() {
  local method="$1" url="$2"; shift 2
  local out rc code location attempt
  for attempt in $(seq 1 3); do
    out=$(curl -sS -m "$CURL_TIMEOUT" -o /dev/null \
      -w "%{http_code}|%{redirect_url}" \
      -X "$method" "$url" "$@" -c "$COOKIE_JAR" -b "$COOKIE_JAR" 2>&1)
    rc=$?
    if [[ $rc -eq 0 ]]; then
      code="${out%%|*}"
      location="${out#*|}"
      [[ $DEBUG == 1 ]] && echo "     [debug] $method $url -> HTTP $code" >&2
      if [[ "$code" =~ ^(200|301|302|303)$ ]]; then
        echo "$location"
        return 0
      fi
      echo "     警告:HTTP $code($method $url),重试 $attempt/3" >&2
    else
      echo "     警告:curl 失败 rc=$rc $(echo "$out" | tail -1)($method $url),重试 $attempt/3" >&2
    fi
    sleep 2
  done
  return 1
}

# 整轮流程;任何一步失败即返回非零,由外层重试(每轮全新设备码 + 全新会话)
run_flow() {
  # 首轮 COOKIE_JAR 未定义,须带默认展开避免 set -u 崩溃;重试轮清掉上一轮遗留 jar
  rm -f "${COOKIE_JAR:-}"   # 清掉上一轮遗留 jar（COOKIE_JAR 为全局变量）
  COOKIE_JAR=$(mktemp)  # 每轮独立会话 cookie，避免残留会话污染下一轮
  trap 'rm -f "$COOKIE_JAR"' EXIT
  echo "==> [1/6] 请求设备码 ..."
  local DC_JSON
  DC_JSON=$(curl -sf -m "$CURL_TIMEOUT" -X POST "$MGMT_URL/oauth2/device/code" \
    -d "client_id=$CLIENT_ID&scope=$(echo "$SCOPE" | sed 's/ /%20/g')") \
    || { echo "     错误:请求设备码失败" >&2; return 1; }
  local USER_CODE DEVICE_CODE
  USER_CODE=$(echo "$DC_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['user_code'])")
  DEVICE_CODE=$(echo "$DC_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['device_code'])")

  echo "==> [2/6] 验证设备码 ..."
  local AUTH_URL
  AUTH_URL=$(get_loc POST "$MGMT_URL/oauth2/device/auth/verify_code" -d "user_code=$USER_CODE") \
    || { echo "     错误:设备码验证失败" >&2; return 1; }

  echo "==> [3/6] 进入 Dex 登录 ..."
  local LOCAL_URL LOGIN_URL
  LOCAL_URL=$(get_loc GET "$AUTH_URL") || { echo "     错误:无法进入授权页" >&2; return 1; }
  LOGIN_URL=$(get_loc GET "$LOCAL_URL") || { echo "     错误:无法进入登录表单" >&2; return 1; }

  echo "==> [4/6] 提交账号密码 ..."
  local CALLBACK_URL
  CALLBACK_URL=$(get_loc POST "$LOGIN_URL" -d "login=$EMAIL&password=$PASSWORD") \
    || { echo "     错误:登录失败(账号或密码错误?)" >&2; return 1; }

  echo "==> [5/6] 完成设备授权并获取 token ..."
  # 关键:GET callback 会把设备码标记为已授权
  if ! curl -sf -m "$CURL_TIMEOUT" -L "$CALLBACK_URL" -c "$COOKIE_JAR" -b "$COOKIE_JAR" -o /dev/null; then
    echo "     错误:设备授权回调失败" >&2; return 1
  fi
  local TOKEN=""
  for _ in $(seq 1 30); do
    local TOKEN_JSON
    TOKEN_JSON=$(curl -sS -m "$CURL_TIMEOUT" -X POST "$MGMT_URL/oauth2/token" \
      -d "grant_type=urn:ietf:params:oauth:grant-type:device_code&device_code=$DEVICE_CODE&client_id=$CLIENT_ID" 2>/dev/null) \
      || { sleep 3; continue; }
    if echo "$TOKEN_JSON" | grep -q '"access_token"'; then
      TOKEN=$(echo "$TOKEN_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['access_token'])")
      break
    fi
    sleep 3
  done
  [[ -n "$TOKEN" ]] || { echo "     错误:获取 token 超时" >&2; return 1; }

  echo "==> [6/6] 调用管理 API ..."
  local USER_INFO HTTP_CODE
  USER_INFO=$(mktemp)
  HTTP_CODE=$(curl -sS -m "$CURL_TIMEOUT" -o "$USER_INFO" -w "%{http_code}" \
    -H "Authorization: Bearer $TOKEN" "$MGMT_URL/api/users/current")
  local USER_ID
  USER_ID=$(python3 -c "import sys,json;print(json.load(open(sys.argv[1]))['id'])" "$USER_INFO" 2>/dev/null) \
    || { echo "     错误:获取用户信息失败(HTTP $HTTP_CODE,响应: $(head -c 300 "$USER_INFO"))" >&2; rm -f "$USER_INFO"; return 1; }
  rm -f "$USER_INFO"
  echo "    当前用户: $EMAIL (id=$USER_ID)"

  if $CREATE_PAT; then
    local PAT PLAIN_TOKEN
    PAT=$(curl -sf -m "$CURL_TIMEOUT" -X POST "$MGMT_URL/api/users/$USER_ID/tokens" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "{\"name\":\"$NAME\",\"expires_in\":365}") || { echo "     错误:创建 PAT 失败" >&2; return 1; }
    PLAIN_TOKEN=$(echo "$PAT" | python3 -c "import sys,json;print(json.load(sys.stdin)['plain_token'])")
    echo ""
    echo "------------------------------------------------------------"
    echo " Personal Access Token: $PLAIN_TOKEN"
    echo " 用法: curl -H \"Authorization: Token $PLAIN_TOKEN\" $MGMT_URL/api/setup-keys"
    echo "------------------------------------------------------------"
  fi

  # --no-key: 仅验证登录（上面 users/current 已成功）,不再创建 setup key
  if $CREATE_KEY; then
    local EXPIRES_IN=$((DAYS * 86400))
    local RESULT
    RESULT=$(curl -sf -m "$CURL_TIMEOUT" -X POST "$MGMT_URL/api/setup-keys" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "{\"name\":\"$NAME\",\"type\":\"reusable\",\"expires_in\":$EXPIRES_IN,\"auto_groups\":[],\"usage_limit\":0}") \
      || { echo "     错误:创建 setup key 失败" >&2; return 1; }

    echo ""
    echo "============================================================"
    echo " Setup Key: $(echo "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin)['key'])")"
    echo " 有效期:   $(echo "$RESULT" | python3 -c "import sys,json;print(json.load(sys.stdin)['expires'])")"
    echo "============================================================"
  fi
  return 0
}

# 整轮重试:服务器偶发慢响应/限流时自动重来
for round in $(seq 1 "$MAX_ROUNDS"); do
  [[ $MAX_ROUNDS -gt 1 ]] && [[ $round -gt 1 ]] && echo "==> 第 $round/$MAX_ROUNDS 轮重试 ..."
  if run_flow; then
    exit 0
  fi
  echo "    本轮失败,5 秒后重试 ..." >&2
  sleep 5
done

echo "错误:连续 $MAX_ROUNDS 轮都失败,请检查网络与账号" >&2
exit 1
