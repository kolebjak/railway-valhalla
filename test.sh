#!/usr/bin/env bash
# Verifies a running Valhalla: it answers, it routes, and the matrix limits are
# actually raised (a stock image rejects the 25-location matrix below).
set -o errexit -o pipefail -o nounset

HOST="${1:-http://localhost:8002}"
fail() { echo "FAIL: $*" >&2; exit 1; }

echo "waiting for ${HOST}/status ..."
for _ in $(seq 1 180); do
  if curl -fsS "${HOST}/status" >/dev/null 2>&1; then break; fi
  sleep 5
done
curl -fsS "${HOST}/status" >/dev/null || fail "no /status after 15 minutes (still building tiles?)"

echo "1/3 status"
curl -fsS "${HOST}/status" | grep -q version || fail "/status has no version"

echo "2/3 route"
route="$(curl -fsS "${HOST}/route" -H 'Content-Type: application/json' -d '{
  "locations":[{"lat":43.7384,"lon":7.4246},{"lat":43.7325,"lon":7.4189}],
  "costing":"auto"
}')" || fail "/route request failed"
grep -q '"legs"' <<<"${route}" || fail "/route returned no legs: ${route}"

echo "3/3 matrix over 25 locations (stock limit is 20)"
locations="$(python3 - <<'PY'
import json
pts = [{"lat": 43.7300 + i * 0.0008, "lon": 7.4150 + i * 0.0008} for i in range(25)]
print(json.dumps({"sources": pts, "targets": pts, "costing": "auto"}))
PY
)"
matrix="$(curl -fsS "${HOST}/sources_to_targets" -H 'Content-Type: application/json' -d "${locations}")" \
  || fail "/sources_to_targets failed - matrix limits were not raised"
grep -q 'sources_to_targets' <<<"${matrix}" || fail "unexpected matrix response: ${matrix:0:300}"

echo "PASS"
