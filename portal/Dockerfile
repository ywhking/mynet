# syntax=docker/dockerfile:1.7
#
# The portal image. Build context is the REPO ROOT, because the worker shells
# out to the existing `terraform/` + `terraform/ansible/` assets, which live
# outside `portal/`:
#
#     docker build -f portal/Dockerfile --target api .
#
# One image serves two processes (`api` and `worker`); only the command differs.

# ============================================================
# Stage: frontend — build the SPA bundle
# ============================================================
FROM node:22-alpine AS frontend

WORKDIR /build

# registry mirror for mainland-China builds; empty = default registry
ARG NPM_REGISTRY=
COPY portal/frontend/package.json portal/frontend/package-lock.json ./
RUN if [ -n "$NPM_REGISTRY" ]; then npm config set registry "$NPM_REGISTRY"; fi \
 && npm ci --no-audit --no-fund

COPY portal/frontend/ ./
RUN npm run build


# ============================================================
# Stage: api — the FastAPI app + the worker (same image)
# ============================================================
FROM python:3.12-slim-bookworm AS api

# terraform: take the binary from the official image rather than curl|unzip —
# the version is pinned by the tag, and there is no checksum handling to get
# wrong. Licensing: terraform >= 1.6 is BUSL; self-hosting is fine.
COPY --from=hashicorp/terraform:1.9.8 /bin/terraform /usr/local/bin/terraform

ENV DEBIAN_FRONTEND=noninteractive
# bash    — deployer.py invokes the inventory script via ["bash", ...]
# jq      — hard-required by generate_inventory.sh and generate_key.sh
# openssh — `ssh` for the inventory's ProxyCommand, `ssh-keygen` for keys
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      jq \
      openssh-client \
 && rm -rf /var/lib/apt/lists/*

# The app's dependencies FIRST, while `pip` still resolves to the base
# interpreter. Doing this after the ansible venv exists would install the app
# into that venv (whichever `pip` is first on PATH wins).
ARG PIP_INDEX_URL=
COPY portal/backend/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir ${PIP_INDEX_URL:+--index-url "$PIP_INDEX_URL"} \
      -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

# ansible in its OWN venv, so its jinja2/PyYAML/packaging/resolvelib pins can
# never fight the app's pinned set. Only ansible-core is required — every
# module in the four playbooks is `ansible.builtin.*`, so there are no Galaxy
# collections to install. Floor is 2.13 (ansible.cfg uses `callback_result_format`).
#
# Expose ONLY the ansible binaries, by symlink, instead of putting the venv on
# PATH: the venv's `python` would otherwise shadow the interpreter the app was
# installed into, and `python -m app.worker` would fail to import fastapi. The
# symlinked scripts carry a shebang pointing at the venv's interpreter, so they
# still run fully isolated. `--version` here makes a broken link fail the build
# rather than the first deployment.
RUN python -m venv /opt/ansible \
 && /opt/ansible/bin/pip install --no-cache-dir \
      ${PIP_INDEX_URL:+--index-url "$PIP_INDEX_URL"} 'ansible-core==2.16.14' \
 && for b in /opt/ansible/bin/ansible*; do ln -sf "$b" /usr/local/bin/; done \
 && ansible-playbook --version | head -n 1

# --- the app, plus the terraform/ansible assets it drives ---
WORKDIR /app
COPY portal/ /app/portal/
COPY terraform/ /app/terraform/
COPY --from=frontend /build/dist /app/portal/frontend/dist

# --- build-time secret guard ----------------------------------------------
# `portal/.env` is the COMPOSE env (Alibaba Cloud credentials + the JWT signing
# key); `deploy.sh` creates it before building. It is listed in .dockerignore,
# but a missing line there fails silently — and the cost of that silence is a
# credential baked into a shipped layer. So assert its absence positively: if
# it ever appears here, the build must stop.
RUN test ! -e /app/portal/.env \
 || { echo "portal/.env leaked into the build context — refusing to bake credentials" >&2; exit 1; }

# --- build-time assertion -------------------------------------------------
# The worker runs these by path. Three of the four playbooks are untracked in
# git, so a build from a fresh clone would otherwise produce an image that
# registers tenants, queues runs, and only then dies inside Ansible — after
# `terraform apply` has already created (and billed for) real infrastructure.
RUN set -e; for f in \
      /app/terraform/main.tf \
      /app/terraform/rg.tf \
      /app/terraform/vpc.tf \
      /app/terraform/ecs.tf \
      /app/terraform/dns.tf \
      /app/terraform/scripts/generate_key.sh \
      /app/terraform/scripts/install_docker.sh \
      /app/terraform/scripts/install_nat_gateway.sh \
      /app/terraform/scripts/set_nat_gateway.sh \
      /app/terraform/scripts/get_setup_key.sh \
      /app/terraform/scripts/install_netbird_bin.sh \
      /app/terraform/ansible/ansible.cfg \
      /app/terraform/ansible/inventory/generate_inventory.sh \
      /app/terraform/ansible/playbooks/setup-network.yml \
      /app/terraform/ansible/playbooks/setup-docker.yml \
      /app/terraform/ansible/playbooks/setup-netbird.yml \
      /app/terraform/ansible/playbooks/setup-netbird-agent.yml \
      /app/portal/frontend/dist/index.html \
    ; do test -e "$f" || { echo "MISSING ASSET: $f" >&2; exit 1; }; done

# --- runtime user ---------------------------------------------------------
# The worker holds the platform's Alibaba credentials and every tenant's SSH
# private key, so a container escape must not land as root.
RUN useradd -m -u 1000 portal \
 && mkdir -p /data/db /data/tenants /home/portal/.ansible/tmp \
 && chown -R portal:portal /data /home/portal /app

ENV HOME=/home/portal \
    ANSIBLE_LOCAL_TEMP=/home/portal/.ansible/tmp \
    TF_IN_AUTOMATION=1 \
    CHECKPOINT_DISABLE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER portal
WORKDIR /app/portal/backend
EXPOSE 8000

# Overridden by `command:` for the worker service — see docker-compose.yml.
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*"]
