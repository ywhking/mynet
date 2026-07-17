#!/usr/bin/env bash
# Mynet — 启动所有服务
# 用法: ./start.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

load_config

step "启动服务..."

if [ "${USE_CADDY:-true}" = "true" ]; then
    info "Caddy 模式: ${CERT_MODE:-auto}"
fi

compose up -d --wait 2>/dev/null || compose up -d
info "服务启动完成"

echo ""
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Mynet 已就绪${NC}"
echo -e "${GREEN}══════════════════════════════════════════${NC}"
echo ""

if [ "${USE_CADDY:-true}" = "true" ]; then
    proto="https"
    if [ "${CERT_MODE:-auto}" = "manual" ]; then
        proto="http"
    fi
    echo -e "  Web UI:    ${CYAN}${proto}://${DOMAIN}/admin/${NC}"
    echo -e "  API:       ${CYAN}${proto}://${DOMAIN}/api/${NC}"
else
    echo -e "  Headscale: ${CYAN}http://${DOMAIN}:${HEADSCALE_PORT:-8080}/${NC}"
    echo -e "  Headplane: ${CYAN}http://${DOMAIN}:${HEADPLANE_PORT:-3000}/admin/${NC}"
fi

echo -e "  DERP:      ${DERP_DOMAIN:-${DOMAIN}}:${DERP_PORT:-3340}"
echo -e "  STUN:      ${DERP_DOMAIN:-${DOMAIN}}:${STUN_PORT:-3478}"
echo ""

step "服务状态..."
compose ps
echo ""
docker ps --filter "name=mynet-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || true
echo ""
echo -e "  查看日志: ${CYAN}docker compose logs -f [服务名]${NC}"
echo -e "  创建用户: ${CYAN}docker exec mynet-headscale /ko-app/headscale users create <用户名>${NC}"

if [ "${USE_CADDY:-true}" = "true" ]; then
    echo -e "  客户端:   ${CYAN}tailscale up --login-server=${proto}://${DOMAIN}${NC}"
else
    echo -e "  客户端:   ${CYAN}tailscale up --login-server=http://${DOMAIN}:${HEADSCALE_PORT:-8080}${NC}"
fi
echo ""
