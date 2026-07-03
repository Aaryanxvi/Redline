#!/usr/bin/env bash
# gear.sh — terminal gearbox for Claude Code (macOS / Linux)
# Pick a gear, launch claude in that model. Optional second pick for effort.
#
#   ./gear.sh          interactive menu
#   ./gear.sh 3        straight into gear 3
#   ./gear.sh 3 xhigh  gear 3 at xhigh effort

set -euo pipefail

names=("Haiku 4.5 (light, zippy)" "Sonnet 5 (cruising)" "Sonnet 5 1M (long haul)" "Opus 4.8 (full power)" "Fable 5 (sport)")
models=("haiku" "sonnet" "sonnet[1m]" "opus" "claude-fable-5")

g="${1:-}"
if [[ -z "$g" ]]; then
  printf '\n  CLAUDE GEARBOX\n'
  for i in "${!names[@]}"; do printf '  [%d] %s\n' "$((i+1))" "${names[$i]}"; done
  printf '\n  shift into gear: '
  read -r g
fi

if ! [[ "$g" =~ ^[1-5]$ ]]; then
  echo "  no such gear: $g" >&2
  exit 1
fi

model="${models[$((g-1))]}"
echo "  >> ${names[$((g-1))]}"

effort="${2:-}"
if [[ -n "$effort" ]]; then
  exec claude --model "$model" --effort "$effort"
else
  exec claude --model "$model"
fi
