#!/usr/bin/env bash
# Freeze the app container for a moment in the middle of a k6 run, the way a long GC pause or a stuck disk would.
#   tools/freeze-app.sh <after_s> <freeze_s>
set -euo pipefail
sleep "$1"; docker pause sdlab-app-1 >/dev/null; sleep "$2"; docker unpause sdlab-app-1 >/dev/null
