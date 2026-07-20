#!/usr/bin/env bash
source <(curl -fsSL "${COMMUNITY_SCRIPTS_URL:-https://raw.githubusercontent.com/community-scripts/ProxmoxVED/main}/misc/build.func")
# Copyright (c) 2021-2026 community-scripts ORG
# Author: javexed
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://github.com/javexed/nanoclaw

APP="NanoClaw"
var_tags="${var_tags:-ai;assistant}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"
var_unprivileged="${var_unprivileged:-1}"
# The agent sandboxes run on Docker. Nesting is already on by default; keyctl is
# the systemd/Docker workaround needed to start dockerd in an unprivileged CT.
var_keyctl="${var_keyctl:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -d /opt/nanoclaw ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  if check_for_gh_release "nanoclaw" "javexed/nanoclaw"; then
    msg_info "Stopping Service"
    systemctl stop nanoclaw
    msg_ok "Stopped Service"

    msg_info "Backing up Data"
    cp -r /opt/nanoclaw/data /opt/nanoclaw_data_backup
    cp /opt/nanoclaw/.env /opt/nanoclaw_env_backup
    msg_ok "Backed up Data"

    CLEAN_INSTALL=1 fetch_and_deploy_gh_release "nanoclaw" "javexed/nanoclaw" "tarball" "latest" "/opt/nanoclaw"

    msg_info "Restoring Data"
    cp -r /opt/nanoclaw_data_backup/. /opt/nanoclaw/data
    cp /opt/nanoclaw_env_backup /opt/nanoclaw/.env
    rm -rf /opt/nanoclaw_data_backup /opt/nanoclaw_env_backup
    msg_ok "Restored Data"

    msg_info "Rebuilding"
    cd /opt/nanoclaw
    $STD pnpm install --frozen-lockfile
    $STD pnpm run build
    # Re-stamp the upgrade marker for the newly deployed version — this is the
    # sanctioned update path, so the first-boot tripwire must not fire on it.
    $STD pnpm exec tsx scripts/upgrade-state.ts set
    $STD ./container/build.sh
    msg_ok "Rebuilt"

    msg_info "Starting Service"
    systemctl start nanoclaw
    msg_ok "Started Service"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:3100${CL}"
# First-login bearer token — read from the container's .env so the operator sees
# it here (not just in the website notes). First browser login becomes owner;
# add Tailscale/SSO in the wizard and retire the token afterwards.
WEBCHAT_TOKEN="$(pct exec "$CTID" -- awk -F= '/^WEBCHAT_TOKEN=/{print $2}' /opt/nanoclaw/.env 2>/dev/null)"
echo -e "${INFO}${YW}First login — paste this bearer token (also in /opt/nanoclaw/.env):${CL}"
echo -e "${TAB}${BGN}${WEBCHAT_TOKEN}${CL}"
