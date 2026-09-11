#!/usr/bin/env bash
# Install or remove this plugin's Claude Code statusLine hook.
#
# Usage: claude-hook.sh install|remove
#
# The hook makes Claude Code hand its `rate_limits` to the plugin. It replaces
# whatever statusLine command is already configured, so any existing file is
# backed up next to the original before the change.
set -euo pipefail

action="${1:-install}"
settings="${HERDR_USAGE_CLAUDE_SETTINGS:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "$0")" && pwd)}"
state="${HERDR_USAGE_STATE_DIR:-${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-usage-popup}}"
statusline="$root/claude-statusline.sh"

command -v jq > /dev/null 2>&1 || { echo "jq is required but was not found on PATH" >&2; exit 1; }
[[ -x $statusline ]] || { echo "$statusline is missing or not executable" >&2; exit 1; }

# Claude Code runs this command itself, outside Herdr, so the state directory
# has to be baked into the command line.
command_line="HERDR_USAGE_STATE_DIR='$state' '$statusline'"
written=$([ "$action" = "remove" ] && echo "null" || echo "{\"type\":\"command\",\"command\":\"$command_line\",\"refreshInterval\":60}")

mkdir -p "$(dirname "$settings")"
[[ -f $settings ]] || echo '{}' > "$settings"

current=$(jq -r '.statusLine.command // empty' "$settings" 2>/dev/null || true)
if [[ $current == *"$root"* && $action = "install" ]]; then
  echo "statusLine already points at this plugin; nothing to do."
  exit 0
fi

backup=$(mktemp "$settings.bak-$(date +%Y%m%d-%H%M%S).XXXXXX")
cp "$settings" "$backup"

tmp="$settings.$$"
if [[ $action = "remove" ]]; then
  if [[ -z $current || $current != *"$root"* ]]; then
    rm -f "$tmp"
    echo "statusLine is not owned by this plugin; leaving it untouched."
    exit 0
  fi
  jq 'del(.statusLine)' "$settings" > "$tmp"
  mv -f "$tmp" "$settings"
  echo "Removed the statusLine hook. Previous settings: $backup"
  exit 0
fi

if [[ -n $current ]]; then
  echo "Replacing the existing statusLine command: $current"
fi
jq --argjson sl "$written" '.statusLine = $sl' "$settings" > "$tmp"
mv -f "$tmp" "$settings"

echo "Installed the statusLine hook in $settings"
echo "Backup of the previous file: $backup"
echo "Restart a running Claude Code session to pick it up."
