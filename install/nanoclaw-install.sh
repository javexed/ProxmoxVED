#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: javexed
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/javexed/nanoclaw

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y \
  git \
  build-essential \
  python3 \
  zstd
msg_ok "Installed Dependencies"

NODE_VERSION="22" setup_nodejs
setup_docker

msg_info "Enabling pnpm"
$STD corepack enable
msg_ok "Enabled pnpm"

msg_info "Fetching NanoClaw"
# Latest tagged GitHub release. Pin a specific version with var_appversion —
# fetch_and_deploy_gh_release honors it natively (${var_appversion:-latest}),
# same as every other script in this framework; no custom override needed.
# Deliberately release-only: upstream requires official release tarballs, not
# branch/HEAD tracking (verified against all 72 install/*.sh scripts upstream
# ships — none install from a branch), so there is no "test" mode here even
# though this entry hasn't been submitted upstream yet.
fetch_and_deploy_gh_release "nanoclaw" "javexed/nanoclaw" "tarball" "latest" "/opt/nanoclaw"
msg_ok "Fetched NanoClaw"

cd /opt/nanoclaw
# Build + configure + service all live in the app's shared deploy script
# (deploy/webchat-deploy.sh) — the SAME script a clean-VM install runs — so the
# webchat deploy flow never drifts between the two. The inline block below is a
# fallback for app branches that predate it; remove once channels-webchat ships
# the script everywhere.
if [ -f deploy/webchat-deploy.sh ]; then
  msg_info "Installing NanoClaw (shared webchat deploy)"
  $STD bash deploy/webchat-deploy.sh --dir /opt/nanoclaw --port 3100
  msg_ok "Installed NanoClaw"
else
  msg_info "Building NanoClaw"
  $STD pnpm install --frozen-lockfile
  $STD pnpm run build
  NANOCLAW_BOOTSTRAPPED=1 NANOCLAW_DISPLAY_NAME=operator \
    NANOCLAW_SKIP='auth,channel,first-chat,cli-agent,timezone,service' \
    $STD pnpm run setup:auto </dev/null
  $STD pnpm exec tsx scripts/upgrade-state.ts set
  msg_ok "Built NanoClaw"

  msg_info "Configuring NanoClaw"
  TOKEN="$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 32)"
  HOST_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")"
  DOCKER_BRIDGE_IP="$(ip -4 -o addr show docker0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)"
  DOCKER_BRIDGE_IP="${DOCKER_BRIDGE_IP:-172.17.0.1}"
  cat <<EOF >/opt/nanoclaw/.env
WEBCHAT_ENABLED=true
WEBCHAT_HOST=0.0.0.0
WEBCHAT_PORT=3100
WEBCHAT_TOKEN=${TOKEN}
WEBCHAT_TAILSCALE=true
ONECLI_URL=http://${DOCKER_BRIDGE_IP}:10254
TZ=${HOST_TZ}
EOF
  msg_ok "Configured NanoClaw"

  msg_info "Creating Service"
  cat <<EOF >/etc/systemd/system/nanoclaw.service
[Unit]
Description=NanoClaw
After=docker.service
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/nanoclaw
Environment=HOME=/root
ExecStart=/usr/bin/node /opt/nanoclaw/dist/index.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable -q --now nanoclaw
  msg_ok "Created Service"
fi

motd_ssh
customize
cleanup_lxc
