# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Mynet is a self-hosted, Tailscale-compatible VPN deployment solution. It orchestrates pre-built Docker images (Headscale control server, Headplane Web UI, DERP relay) via Docker Compose, with optional Caddy reverse proxy and automatic Let's Encrypt TLS.

There is no application source code in this repo — it is purely deployment infrastructure: shell scripts, Docker Compose files, service configuration templates, and test suites.

## Architecture

```
Internet
  :80/:443 (Caddy reverse proxy, optional)
    → Caddy terminates TLS → Headplane (Web UI, port 3000) + Headscale (control API, port 8080)
  :3340 (DERP relay TLS) + :3478/UDP (STUN)
    → DERP relay for mesh traffic when nodes can't connect directly

All services run on an internal Docker network named `mynet`.
```

Three deployment modes (controlled by `.env` vars):
- **Caddy + auto TLS** (`USE_CADDY=true`, `CERT_MODE=auto`): Production, Let's Encrypt via acme.sh
- **Caddy + HTTP** (`USE_CADDY=true`, `CERT_MODE=manual`): No TLS, self-signed certs for DERP
- **Direct** (`USE_CADDY=false`): No Caddy, Headscale on :8080, Headplane on :3000

## Directory structure

```
deploy/
  config.sh / install.sh / start.sh / shutdown.sh   — Deployment lifecycle scripts
  lib.sh                                             — Shared shell utilities (logging, compose_args helper)
  docker-compose.yml                                 — Base services (headscale, headplane, derper)
  docker-compose.caddy.yml                           — Caddy overlay (merged when USE_CADDY=true)
  docker-compose.nocaddy.yml                         — Direct-expose overlay (merged when USE_CADDY=false)
  config/                                            — Service config templates with __PLACEHOLDER__ substitution
  images/*.tar                                       — Pre-built Docker images
  certs/  volumes/                                   — Generated at install time (gitignored)

tests/
  specs/                     — Playwright E2E tests for Headplane web UI
    helpers/auth.ts          — Login/logout helpers
  system/                    — BATS-based Docker service integration tests
    run.sh                   — Unified test runner (auto-detects BATS, falls back to native bash)
    helpers/common.bash      — Shared assertions and HTTP/container utilities
```

## Common commands

### Deployment (run from `deploy/`)

```bash
./config.sh              # Interactive configuration → writes .env
./install.sh             # Substitute configs, import images, issue certs
./start.sh               # Start all services (docker compose up -d)
./shutdown.sh            # Stop all services
./install.sh renew-certs # Renew Let's Encrypt certificates
```

### Service management

```bash
docker exec mynet-headscale /ko-app/headscale users list
docker exec mynet-headscale /ko-app/headscale users create <name>
docker exec mynet-headscale /ko-app/headscale nodes list
docker exec mynet-headscale /ko-app/headscale preauthkeys create --user <name>
```

### Tests

```bash
# Playwright E2E tests (from tests/)
npm test                  # Headless
npm run test:headed       # Browser visible
npm run test:debug        # Debug mode

# System integration tests (from tests/system/)
./run.sh                  # All suites
./run.sh container        # Container lifecycle only
./run.sh derp             # DERP functionality only
./run.sh integration      # Headscale ↔ DERP integration
./run.sh --native         # Force native bash mode (no BATS required)
```

Both test suites require the Docker services to be running. Playwright tests need `HEADPLANE_API_KEY` set in `tests/.env`.

## Key design patterns

- **Config substitution**: Service config templates in `deploy/config/` use `__PLACEHOLDER__` tokens. `install.sh` runs `sed` to replace them with values from `.env`, then mounts the resulting files read-only into containers.
- **Compose file merging**: `lib.sh`'s `compose_args()` selects `docker-compose.caddy.yml` or `docker-compose.nocaddy.yml` based on `USE_CADDY`. All scripts use the `compose()` helper from `lib.sh` rather than calling `docker compose` directly.
- **Shell library pattern**: `deploy/lib.sh` is sourced by all deploy scripts. It provides color-coded logging (`info`, `warn`, `error`, `step`), config loading (`load_config`), and the `compose()` wrapper. It uses `set -euo pipefail`.
- **Cert decision tree**: `CERT_MODE=auto` → acme.sh with Let's Encrypt (standalone HTTP-01 or DNS-01). `CERT_MODE=manual` → OpenSSL self-signed certs for DERP, no HTTPS.
- **Test runner fallback**: `tests/system/run.sh` auto-detects BATS. If not installed, it parses `.bats` files and runs tests in isolated subshells with native bash assertions.
