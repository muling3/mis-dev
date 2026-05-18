#!/usr/bin/env bash
# Open a tmux window per service, each running `make dev`.
set -euo pipefail

SESSION="${TMUX_SESSION:-mis}"
PARENT="$(realpath "$(dirname "$0")/../..")"

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux not installed. Either install it or run services one-at-a-time:"
  echo "  cd mis-dev && make dev s=auth"
  exit 1
fi

services=(auth registration case sandbox notification reporting document admin)

tmux has-session -t "$SESSION" 2>/dev/null && {
  echo "tmux session '$SESSION' already exists. Attaching…"
  exec tmux attach -t "$SESSION"
}

first=1
for s in "${services[@]}"; do
  cmd="cd $PARENT/mis-$s-service && make dev"
  if [ $first -eq 1 ]; then
    tmux new-session -d -s "$SESSION" -n "$s" "$cmd"
    first=0
  else
    tmux new-window -t "$SESSION" -n "$s" "$cmd"
  fi
done

tmux attach -t "$SESSION"
