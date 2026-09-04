#!/usr/bin/env bash
# Railway entrypoint for the Valhalla scripted image.
#
# Mirrors upstream's `build_tiles` branch (configure -> tar -> permissions ->
# serve) and inserts a config patch before serving. The patch exists because the
# upstream image exposes no environment variables for these settings, so they can
# only be changed by editing the generated valhalla.json. Doing it here keeps the
# config reproducible on every boot instead of hand-edited on a live container.
set -o errexit -o pipefail -o nounset

# Upstream sets these in the image's ENV, and helpers.sh reads some of them while
# being sourced. Restated here so a tag bump that drops one turns into a default
# rather than a `nounset` boot crash.
export path_extension="${path_extension:-}"
export traffic_name="${traffic_name:-}"
export build_tar="${build_tar:-True}"
export force_rebuild="${force_rebuild:-False}"
export serve_tiles="${serve_tiles:-True}"
# tile_urls has no default in the image. Default it to Monaco (~700 KB, ~1 minute
# to build) so a template deploy with no variables set still comes up serving
# instead of exiting. Loudly, because the region is almost certainly not the one
# the user wants.
DEFAULT_TILE_URLS="https://download.geofabrik.de/europe/monaco-latest.osm.pbf"
export tile_urls="${tile_urls:-}"

. /valhalla/scripts/helpers.sh

require_uint() {
  if ! [[ "${2}" =~ ^[0-9]+$ ]] || [[ "${2}" -eq 0 ]]; then
    echo "ERROR: ${1} must be a positive integer, got '${2}'." >&2
    exit 1
  fi
}

# Valhalla's zmq listener cannot bind IPv6 (`tcp://[::]:PORT` dies with "No such
# device", `tcp://*:PORT` silently binds v4 only), and Railway's private network
# is IPv6-only. So Valhalla listens on loopback and a dual-stack socat proxy owns
# $PORT, which serves both the public edge (v4) and private peers (v6).
LISTEN_PORT="${PORT:-8002}"
require_uint PORT "${LISTEN_PORT}"
INTERNAL_PORT="${VALHALLA_INTERNAL_PORT:-8102}"
require_uint VALHALLA_INTERNAL_PORT "${INTERNAL_PORT}"
if [[ "${INTERNAL_PORT}" == "${LISTEN_PORT}" ]]; then
  INTERNAL_PORT=$((LISTEN_PORT + 1))
fi

# VROOM builds an NxN duration matrix over every stop in a solve. Valhalla's
# stock caps (max_locations 20, max_matrix_location_pairs 2500) reject anything
# past 20 stops with "Exceeded max locations: 20".
MAX_LOCATIONS="${VALHALLA_MAX_LOCATIONS:-500}"
MAX_MATRIX_PAIRS="${VALHALLA_MAX_MATRIX_PAIRS:-250000}"
COSTINGS="${VALHALLA_COSTINGS:-auto,taxi}"
require_uint VALHALLA_MAX_LOCATIONS "${MAX_LOCATIONS}"
require_uint VALHALLA_MAX_MATRIX_PAIRS "${MAX_MATRIX_PAIRS}"

# Default 1, not $(nproc) as upstream does: a container reads the HOST core count
# (32+ on Railway), and Valhalla spawns a worker per thread, each with its own
# tile cache, each able to chew a large matrix concurrently -> OOM under load.
# With build_tar=True the workers mmap one shared extract, so raising this is
# far cheaper; see README.
export server_threads="${server_threads:-1}"
require_uint server_threads "${server_threads}"

if [[ -z "${tile_urls}" ]] && ! test -f "${TILE_TAR}" && ! test -d "${TILE_DIR}"; then
  export tile_urls="${DEFAULT_TILE_URLS}"
  echo "WARNING: tile_urls is not set. Falling back to Monaco:"
  echo "         ${DEFAULT_TILE_URLS}"
  echo "         Set tile_urls to your own region from https://download.geofabrik.de/"
  echo "         and redeploy; the volume rebuilds with the new region."
fi

if [[ "${force_rebuild}" == "True" ]]; then
  build_tar="Force"
fi

# Downloads the PBF, builds tiles, admin + timezone databases, and writes
# ${CONFIG_FILE}. Skips work already present under ${CUSTOM_FILES}, which is why
# that path must be a Railway volume: without one this reruns on every deploy.
/valhalla/scripts/configure_valhalla.sh "${CONFIG_FILE}" "${CUSTOM_FILES}" "${TILE_DIR}" "${TILE_TAR}"

# Pack the tiles into a single extract. Workers mmap it instead of each holding
# its own tile cache, which is what makes server_threads > 1 affordable.
if { [[ "${build_tar}" == "True" ]] && ! test -f "${TILE_TAR}"; } || [[ "${build_tar}" == "Force" ]]; then
  extract_options=(-c "${CONFIG_FILE}" -v)
  if [[ -n "${traffic_name}" ]]; then
    extract_options+=(-t)
  fi
  if [[ "${build_tar}" == "Force" ]]; then
    extract_options+=(--overwrite)
  fi
  valhalla_build_extract "${extract_options[@]}"
elif [[ "${build_tar}" != "True" && "${build_tar}" != "Force" ]]; then
  echo "WARNING: build_tar is '${build_tar}'. Serving loose tiles; expect higher memory per thread."
fi

# Only patch costings the generated config actually knows about. jq would happily
# create `service_limits.autp`, leaving the real limit at 20 with no error.
known_costings="$(jq -r '.service_limits | keys[]' "${CONFIG_FILE}")"
patch_costings=()
for costing in ${COSTINGS//,/ }; do
  if grep -qx -- "${costing}" <<<"${known_costings}"; then
    patch_costings+=("${costing}")
  else
    echo "WARNING: '${costing}' is not a costing in valhalla.json; its limits stay at the stock 20." >&2
  fi
done
if [[ ${#patch_costings[@]} -eq 0 ]]; then
  echo "ERROR: VALHALLA_COSTINGS ('${COSTINGS}') matched no costing in valhalla.json." >&2
  exit 1
fi
costings_json="$(printf '%s\n' "${patch_costings[@]}" | jq -R . | jq -s .)"

jq \
  --argjson costings "${costings_json}" \
  --argjson max_locations "${MAX_LOCATIONS}" \
  --argjson max_matrix_pairs "${MAX_MATRIX_PAIRS}" \
  --arg listen "tcp://127.0.0.1:${INTERNAL_PORT}" '
    reduce $costings[] as $costing (.;
      .service_limits[$costing].max_locations = $max_locations
      | .service_limits[$costing].max_matrix_location_pairs = $max_matrix_pairs
    )
    | .httpd.service.listen = $listen
  ' "${CONFIG_FILE}" > "${CONFIG_FILE}.patched"
mv "${CONFIG_FILE}.patched" "${CONFIG_FILE}"

find "${CUSTOM_FILES}" -type d -exec chmod 775 {} \;
find "${CUSTOM_FILES}" -type f -exec chmod 664 {} \;

if [[ "${serve_tiles}" != "True" ]]; then
  echo "INFO: serve_tiles is not True. Tiles are built; exiting without serving."
  exit 0
fi

echo "INFO: serving on port ${LISTEN_PORT} (valhalla on 127.0.0.1:${INTERNAL_PORT}) with ${server_threads} thread(s)."
echo "INFO: raised ${patch_costings[*]} limits to max_locations=${MAX_LOCATIONS}, max_matrix_location_pairs=${MAX_MATRIX_PAIRS}."

# ipv6only=0 so the one listener answers both v6 (private network) and
# v4-mapped (public edge, local Docker). Falls back to v4 if the kernel has no
# IPv6 at all, which costs private networking but keeps the service up.
proxy() {
  if ! socat "TCP6-LISTEN:${LISTEN_PORT},fork,reuseaddr,ipv6only=0" "TCP4:127.0.0.1:${INTERNAL_PORT}"; then
    echo "WARNING: IPv6 listener unavailable; serving IPv4 only. Private networking will not work." >&2
    exec socat "TCP4-LISTEN:${LISTEN_PORT},fork,reuseaddr" "TCP4:127.0.0.1:${INTERNAL_PORT}"
  fi
}

valhalla_service "${CONFIG_FILE}" "${server_threads}" &
valhalla_pid=$!
proxy &
proxy_pid=$!

# Either process dying is fatal: a live proxy in front of a dead router answers
# every request with a connection error, which Railway cannot distinguish from a
# healthy service.
shutdown() {
  trap - TERM INT
  kill "${valhalla_pid}" "${proxy_pid}" 2>/dev/null || true
}
trap shutdown TERM INT

status=0
wait -n "${valhalla_pid}" "${proxy_pid}" || status=$?
shutdown
exit "${status}"
