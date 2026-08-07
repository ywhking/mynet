#!/bin/bash
# Generate SSH key pair for Alibaba Cloud ECS
# Called by Terraform data "external" — reads query JSON from stdin.
#
# Input (stdin JSON):
#   key_name   - key pair name
#   public_key - user-provided SSH public key (optional, empty string if not set)
#
# Output (stdout JSON):
#   public_key - SSH public key to upload to Alibaba Cloud

set -euo pipefail

INPUT=$(cat)
KEY_NAME=$(echo "$INPUT" | jq -r '.key_name // "tf-key"')
PROVIDED_KEY=$(echo "$INPUT" | jq -r '.public_key // ""')

if [ -n "$PROVIDED_KEY" ]; then
  # User provided their own public key — use it directly
  jq -n --arg pk "$PROVIDED_KEY" '{"public_key": $pk}'
  exit 0
fi

# Auto-generate key pair locally
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_DIR="$SCRIPT_DIR/../keys"
KEY_FILE="$KEY_DIR/$KEY_NAME"

mkdir -p "$KEY_DIR"

if [ ! -f "$KEY_FILE" ]; then
  ssh-keygen -t rsa -b 4096 -f "$KEY_FILE" -N "" -C "$KEY_NAME" >&2
  echo "🔑 Generated new key pair: $KEY_FILE" >&2
else
  echo "🔑 Key pair already exists: $KEY_FILE" >&2
fi

PUBLIC_KEY=$(cat "$KEY_FILE.pub")
echo "📋 Private key: $KEY_FILE" >&2

jq -n --arg pk "$PUBLIC_KEY" '{"public_key": $pk}'
