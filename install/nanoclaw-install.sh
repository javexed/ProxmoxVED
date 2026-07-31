#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: javexed
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/javexed/nanoclaw-webchat

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
# NANOCLAW_ARTIFACT_URL installs a specific composed tarball instead of the
# published release. It exists so a release candidate can be proven in a real CT
# BEFORE it is published: scripts/release.sh gates and stages the artifact
# without publishing, and scripts/publish-release.sh later ships exactly those
# bytes — so what is validated here is what end users receive, not a rebuild.
#
# Serve the staged file over the local network and pass its URL:
#   NANOCLAW_ARTIFACT_URL=http://<host>:8000/nanoclaw-webchat-composed-v2.3.8.tar.gz
#
# fetch_and_deploy_from_url is the framework's own helper: it auto-detects the
# gzip archive, strips the single top-level directory, and copies the payload
# into the target — the same result the prebuild path produces, so the override
# changes where the bytes come from and nothing about how they are deployed.
if [ -n "${NANOCLAW_ARTIFACT_URL:-}" ]; then
  fetch_and_deploy_from_url "$NANOCLAW_ARTIFACT_URL" "/opt/nanoclaw"
else
  # Latest tagged release of the webchat product. The asset is a COMPOSED tree
  # (upstream nanoclaw + the module hook seam + webchat), gated on release by a
  # coverage check and both test suites — so the CT installs a build that is
  # already proven, with no compile-from-source step here. Pin a specific
  # version with var_appversion; fetch_and_deploy_gh_release honors it natively.
  fetch_and_deploy_gh_release "nanoclaw" "javexed/nanoclaw-webchat" "prebuild" "latest" "/opt/nanoclaw" 'nanoclaw-webchat-composed-*.tar.gz'
fi
msg_ok "Fetched NanoClaw"

cd /opt/nanoclaw
# Build + configure + service all live in the app's shared deploy script
# (deploy/webchat-deploy.sh) — the SAME script a clean-VM install runs — so the
# webchat deploy flow never drifts between the two. Every release asset carries
# it (the release gate asserts so); the inline block below is a fallback for
# older pinned versions.
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
