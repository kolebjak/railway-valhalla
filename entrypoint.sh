#!/usr/bin/env bash
# Railway entrypoint for the Valhalla scripted image.
#
# Mirrors upstream's `build_tiles` branch (configure -> tar -> permissions ->
# serve) and inserts a config patch before serving. The patch exists because the
# upstream image exposes no environment variables for these settings, so they can
# only be changed by editing the generated valhalla.json. Doing it here keeps the
# config reproducible on every boot instead of hand-edited on a live container.
set -o errexit -o pipefail -o nounset

. /valhalla/scripts/helpers.sh

# tile_urls has no default in the image; keep nounset from tripping on it.
export tile_urls="${tile_urls:-}"

# Bind the HTTP service to the port Railway assigns. Falls back to Valhalla's
# conventional 8002 when PORT is unset (plain Docker / Compose).
LISTEN_PORT="${PORT:-8002}"
# `*` binds IPv4 (and IPv6 where the stack maps it). If a private-network peer
# cannot reach this service on Railway, set VALHALLA_LISTEN_HOST=[::] .
LISTEN_HOST="${VALHALLA_LISTEN_HOST:-*}"

# VROOM builds an NxN duration matrix over every stop in a solve. Valhalla's
# stock caps (max_locations 20, max_matrix_location_pairs 2500) reject anything
# past 20 stops with "Exceeded max locations: 20".
MAX_LOCATIONS="${VALHALLA_MAX_LOCATIONS:-2000}"
MAX_MATRIX_PAIRS="${VALHALLA_MAX_MATRIX_PAIRS:-4000000}"
COSTINGS="${VALHALLA_COSTINGS:-auto,taxi}"

# Default 1, not $(nproc) as upstream does: a container reads the HOST core count
# (32+ on Railway), and Valhalla spawns a worker per thread, each with its own
# tile cache, each able to chew a large matrix concurrently -> OOM under load.
# With build_tar=True the workers mmap one shared extract, so raising this is
# far cheaper; see README.
export server_threads="${server_threads:-1}"

if [[ -z "${tile_urls}" ]] && ! test -f "${TILE_TAR}" && ! test -d "${TILE_DIR}"; then
  echo "ERROR: no tiles and no tile_urls." >&2
  echo "       Set tile_urls to one or more .osm.pbf URLs, space separated, e.g." >&2
  echo "       https://download.geofabrik.de/europe/monaco-latest.osm.pbf" >&2
  exit 1
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

costings_json="$(printf '%s' "${COSTINGS}" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))')"

jq \
  --argjson costings "${costings_json}" \
  --argjson max_locations "${MAX_LOCATIONS}" \
  --argjson max_matrix_pairs "${MAX_MATRIX_PAIRS}" \
  --arg listen "tcp://${LISTEN_HOST}:${LISTEN_PORT}" '
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

echo "INFO: serving on tcp://${LISTEN_HOST}:${LISTEN_PORT} with ${server_threads} thread(s)."
echo "INFO: raised ${COSTINGS} limits to max_locations=${MAX_LOCATIONS}, max_matrix_location_pairs=${MAX_MATRIX_PAIRS}."
exec valhalla_service "${CONFIG_FILE}" "${server_threads}"
