#!/usr/bin/env bash
# Mynet — 停止所有服务
# 用法: ./shutdown.sh

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

step "停止所有服务..."
compose down
info "服务已停止"
