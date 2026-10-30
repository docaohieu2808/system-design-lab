#!/usr/bin/env bash
# Checker for capstone 13.1: point it at your URL shortener and it tells you whether it meets the course's contract.
#   tools/check-capstone.sh [base-url] [rate]      default http://localhost:8080, 500 redirects per second
# 1. Contract: POST /api/links {"url": "..."} -> 201 {"code": "..."}; GET /{code} -> 302 to that URL; unknown -> 404.
# 2. Load: RATE redirects/s for 30 s; passes if p99 < 50 ms, at least 99.9% correct answers and nothing dropped.
set -euo pipefail
base=${1:-http://localhost:8080}; rate=${2:-500}; fail=0
say() { printf '%-4s %s\n' "$1" "$2"; }
body=$(curl -s -w '\n%{http_code}' -X POST "$base/api/links" -H 'Content-Type: application/json' -d '{"url":"https://example.com/checker"}')
code=$(echo "$body" | head -1 | python3 -c "import json,sys; print(json.load(sys.stdin).get('code',''))" 2>/dev/null || true)
[ "$(echo "$body" | tail -1)" = 201 ] && [ -n "$code" ] && say ok "create answers 201 with a code ($code)" || { say FAIL "create: want 201 and {\"code\": ...}"; fail=1; }
loc=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' "$base/$code")
[ "$loc" = "302 https://example.com/checker" ] && say ok "redirect answers 302 to the right URL" || { say FAIL "redirect: got '$loc'"; fail=1; }
nf=$(curl -s -o /dev/null -w '%{http_code}' "$base/zz-no-such-code")
[ "$nf" = 404 ] && say ok "unknown code answers 404" || { say FAIL "unknown code: got $nf, want 404"; fail=1; }
[ $fail = 0 ] || exit 1
# Linux: share the host's network so localhost means your machine (a host firewall may block the docker bridge).
# Docker Desktop (macOS, Windows): reach your machine through host.docker.internal.
if [ "$(uname -s)" = Linux ]; then host=$base; net="--network host"
else host=$(echo "$base" | sed -E 's#https?://(localhost|127\.0\.0\.1)#http://host.docker.internal#'); net="--add-host host.docker.internal:host-gateway"; fi
docker run --rm -i $net -e BASE="$host" -e RATE="$rate" -e RESULT=/tmp/check.json \
  grafana/k6:1.8.2 run --quiet - < modules/m13-capstones/check.js 2>/dev/null | tail -1
