#!/bin/bash
# MESA VS Code entrypoint. HOME=/config (linuxserver code-server layout).

# iRODS env, Data Store dotfiles (.gitconfig/.aws/.ssh), .env files, OSN mounts
source /usr/local/bin/mesa-init.sh

# Restore VS Code server state and Cline MCP settings saved in the Data Store
if [ -d /data-store/iplant/home/$IPLANT_USER/.vscode-server ]; then
  cp -r /data-store/iplant/home/$IPLANT_USER/.vscode-server ~/
fi
if [ -f /data-store/iplant/home/$IPLANT_USER/.vscode-server/cline_mcp_settings.json ]; then
  mkdir -p /config/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev/settings/
  cp /data-store/iplant/home/$IPLANT_USER/.vscode-server/cline_mcp_settings.json \
     /config/.local/share/code-server/User/globalStorage/saoudrizwan.claude-dev/settings/
  echo "Cline MCP settings copied from data-store"
fi

# Open the user's Data Store home when mounted, else the local working dir
WORKSPACE=/data-store/iplant/home/$IPLANT_USER
[ -d "$WORKSPACE" ] || WORKSPACE=/home/vscode/data-store

# tini reaps zombies and forwards SIGTERM to code-server and any
# npx-spawned MCP servers when VICE stops the pod
exec /usr/bin/tini -g -- /app/code-server/bin/code-server --bind-addr 0.0.0.0:8080 --disable-telemetry "$WORKSPACE"
