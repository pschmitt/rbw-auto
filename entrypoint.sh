#!/usr/bin/env bash

cd "$(cd "$(dirname "$0")" >/dev/null 2>&1; pwd -P)" || exit 9
# shellcheck source=./lib.sh
source lib.sh

RBW_CONFIG_DIR="${HOME:-/root}/.config/rbw"
RBW_CONFIG_FILE="${RBW_CONFIG_DIR}/config.json"

# Renders one account entry (name/email/baseUrl) as JSON. rbw's config.json
# only ever holds this non-secret connection metadata -- master passwords
# and register API keys stay in env vars, read by bw-backup.sh/bw-sync.sh
# and piped to `rbw ... --stdin`, never written to disk here.
account_json() {
  local name="$1"
  local email="$2"
  local base_url="$3"

  jq -nc --arg name "$name" --arg email "$email" --arg base_url "$base_url" \
    '{name: $name, email: $email} + (if $base_url != "" then {baseUrl: $base_url} else {} end)'
}

write_rbw_config() {
  mkdir -p "$RBW_CONFIG_DIR"
  jq -sc '{accounts: ., primaryAccount: .[0].name}' "$@" > "$RBW_CONFIG_FILE"
}

COMMAND="${1:-backup}"
if [[ "$COMMAND" == "sync" ]]
then
  shift
  write_rbw_config \
    <(account_json "${SRC_ACCOUNT:-source}" "${SRC_ACCOUNT_EMAIL:-}" "${SRC_ACCOUNT_BASE_URL:-}") \
    <(account_json "${DEST_ACCOUNT:-destination}" "${DEST_ACCOUNT_EMAIL:-}" "${DEST_ACCOUNT_BASE_URL:-}")
  exec /usr/local/bin/rbw-auto-sync "$@"
elif [[ "$COMMAND" == "backup" ]]
then
  shift
  write_rbw_config <(account_json "${ACCOUNT:-backup}" "${ACCOUNT_EMAIL:-}" "${ACCOUNT_BASE_URL:-}")
else
  echo_error "Unknown command: $COMMAND"
  exit 2
fi

# oneshot mode
if [[ -z "$CRON" ]]
then
  exec /usr/local/bin/rbw-auto-backup "$@"
fi

forward_signal() {
  echo "Caught signal, forwarding..." >&2
  kill -s "$1" "$CHILD" >&2
}

# Trap termination signals and forward them to the child process
trap 'forward_signal SIGTERM' SIGTERM
trap 'forward_signal SIGINT' SIGINT
# https://blog.thesparktree.com/cron-in-docker
echo_info "Running in cron mode: CRON='$CRON'"

USER=${USER:-$(whoami)}
# Save all environment variables to /etc/environment
export > /etc/environment

cat <<EOF > /etc/crontab
SHELL=/bin/bash
BASH_ENV=/etc/environment

$CRON $USER /usr/local/bin/rbw-auto-backup >/proc/1/fd/1 2>/proc/1/fd/2
EOF

if [[ -n "$START_RIGHT_NOW" ]]
then
  echo_info "Running backup right away! cron will take over after"
  /usr/local/bin/rbw-auto-backup "$@"
fi

echo_info "Starting cron"
cron -f -l 2 &
CHILD=$!
trap 'kill "$CHILD" 2>/dev/null' EXIT

wait "$CHILD"
