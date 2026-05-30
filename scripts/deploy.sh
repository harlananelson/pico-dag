#!/usr/bin/env bash
# Deploy pico-dag to the production VPS — git-pull only, never file-copy.
#
# This is the ONLY supported way to update production. It deliberately refuses
# to run against a dirty working tree, because hand-editing / scp-ing onto the
# prod clone is exactly what produced the 2026-05-30 divergence (see
# snapshots/2026-05-30-*.md). If this script aborts with "working tree not
# clean", do NOT force it — snapshot the box first (instructions are printed).
#
# Usage:  scripts/deploy.sh            # deploy origin/main to prod
#         HOST=root@1.2.3.4 scripts/deploy.sh
set -euo pipefail

HOST="${HOST:-root@5.78.69.136}"
APP_DIR="${APP_DIR:-/srv/shiny-server/pico-dag}"
URL="${URL:-https://picodag.globalpatientsafety.com/}"

echo "==> Deploying ${APP_DIR} on ${HOST} to origin/main"

ssh "$HOST" "set -euo pipefail
  cd '${APP_DIR}'
  git fetch -q origin

  # Guard: refuse to deploy onto a dirty tree. Tracked-file edits OR untracked
  # files that collide with upstream both break a clean ff and risk data loss.
  dirty=\$(git status --porcelain | grep -v '^?? \\.Renviron\$' || true)
  if [ -n \"\$dirty\" ]; then
    echo 'ABORT: production working tree is not clean:' >&2
    echo \"\$dirty\" >&2
    echo >&2
    echo 'Someone edited/copied onto prod directly. Preserve it before deploying:' >&2
    echo '  git checkout -b vps-snapshot-\$(date +%F) && git add -A && git commit -m \"VPS tree\"' >&2
    echo 'then re-run this script. (Keep .Renviron VPS-local; never push that branch publicly.)' >&2
    exit 1
  fi

  git pull --ff-only origin main
  echo '==> restarting shiny-server'
  systemctl restart shiny-server
"

echo "==> smoke-test ${URL}"
sleep 3
code=$(curl -s -o /dev/null -w '%{http_code}' "$URL")
echo "HTTP ${code}"
[ "$code" = "200" ] || { echo "ABORT: expected HTTP 200" >&2; exit 1; }
echo "==> deploy OK ($(ssh "$HOST" "cd '${APP_DIR}' && git rev-parse --short HEAD"))"
