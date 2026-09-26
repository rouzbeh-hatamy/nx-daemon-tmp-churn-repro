#!/usr/bin/env bash
# Measures whether the Nx daemon settles after a single graph computation.
set -u
LOG=.nx/workspace-data/d/daemon.log
SETTLE=${SETTLE:-25}
npx nx daemon --stop >/dev/null 2>&1
rm -rf .nx/workspace-data/d
echo "nx $(node -p "require('nx/package.json').version")  .nxignore: $([ -f .nxignore ] && cat .nxignore | tr '\n' ' ' || echo none)"
npx nx graph --file=/tmp/nxrepro-graph.json >/dev/null 2>&1
sleep "$SETTLE"
A=$(stat -f%z "$LOG" 2>/dev/null || echo 0); sleep 10; B=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
printf 'log=%s  growth=+%sKB/10s  tmp_events=%s  recomputes=%s  node_cpu=%s\n' \
  "$(du -h "$LOG" 2>/dev/null | cut -f1)" "$(( (B-A)/1024 ))" \
  "$(grep -ac '_tmp_' "$LOG" 2>/dev/null || echo 0)" \
  "$(grep -ac 'Recomputing project graph' "$LOG" 2>/dev/null || echo 0)" \
  "$(ps -Ao %cpu,args | grep -i node | grep -v grep | awk '{c+=$1}END{printf "%.1f%%",c}')"
npx nx daemon --stop >/dev/null 2>&1
