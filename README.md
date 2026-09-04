# Valhalla on Railway

One-click [Valhalla](https://valhalla.github.io/valhalla/) routing engine — routes,
matrices, isochrones and map matching over any OpenStreetMap region you point it at.

## What you get

`ghcr.io/valhalla/valhalla-scripted:3.7.0` with an entrypoint that makes it behave
on Railway:

- **Binds `$PORT`.** The stock image hardcodes 8002, which Railway will not route to.
- **Raises the matrix limits.** Stock Valhalla rejects any matrix past 20 locations
  (`Exceeded max locations: 20`). No environment variable exists for this upstream,
  so the generated config is patched on every boot. Needed by anything that builds
  an NxN matrix — VROOM, OR-Tools, your own solver.
- **Defaults to one server thread.** A container reads the *host* core count (32+ on
  Railway) and Valhalla spawns a worker per thread. Left at the upstream default,
  the service OOMs under load.
- **Builds the tile extract**, so workers mmap one shared archive instead of each
  holding a private tile cache.
- **Answers on IPv6.** Valhalla's zmq listener cannot bind IPv6 — `tcp://[::]:PORT`
  dies with `No such device`, `tcp://*:PORT` quietly binds IPv4 only — and Railway's
  private network is IPv6-only. The router listens on loopback and a dual-stack
  proxy owns `$PORT`, so public and private-network callers both reach it.

## Setup

Deploying with nothing set gives you a working router over Monaco, so you can see
it answer before committing to a region. Two things to change after that:

1. **`tile_urls`** — one or more `.osm.pbf` URLs, space separated. Grab your region
   from [Geofabrik](https://download.geofabrik.de/):
   `https://download.geofabrik.de/europe/monaco-latest.osm.pbf`. Unset, it falls
   back to Monaco and says so in the deploy log.
2. **A volume mounted at `/custom_files`.** Tiles live here. Without a volume every
   deploy rebuilds them from scratch.

### First boot takes a while

Tiles are built before the service accepts traffic. Monaco takes about a minute;
a country takes tens of minutes; a continent takes hours and wants a large volume.
The deployment log is the honest progress bar. Subsequent boots reuse the volume
and start in seconds.

Because of this, **do not set a healthcheck path** on this service — any healthcheck
window is shorter than a real first tile build, and Railway will kill the deploy
mid-build.

## Configuration

Added by this template:

| Variable | Default | What it does |
| --- | --- | --- |
| `PORT` | `8002` | Set by Railway. The dual-stack listener binds it. |
| `VALHALLA_MAX_LOCATIONS` | `500` | Max locations per matrix request. |
| `VALHALLA_MAX_MATRIX_PAIRS` | `250000` | Max source×target pairs. Keep it at `VALHALLA_MAX_LOCATIONS²`, or the smaller limit binds first. |
| `VALHALLA_COSTINGS` | `auto,taxi` | Which costings get the raised limits. Unknown names are warned about and skipped. |
| `VALHALLA_INTERNAL_PORT` | `8102` | Loopback port Valhalla itself listens on, behind the proxy. |
| `server_threads` | `1` | Worker threads. See below before raising. |

Passed through to the upstream image (see its
[documentation](https://github.com/valhalla/valhalla/tree/master/docker) for the
full list):

| Variable | Default | What it does |
| --- | --- | --- |
| `tile_urls` | Monaco | Space-separated `.osm.pbf` URLs. Falls back to Monaco with a warning. |
| `build_admins` | `True` | Admin areas. Needed for country-crossing logic. |
| `build_time_zones` | `True` | Timezone database. Needed for time-dependent routing. |
| `build_elevation` | `False` | Elevation tiles. Large; only for bike/foot grades. |
| `build_tar` | `True` | Pack tiles into one mmap-able extract. Leave on. |
| `force_rebuild` | `False` | Rebuild tiles even when the volume has them. |
| `serve_tiles` | `True` | Set `False` to build tiles and exit. |

### Raising `server_threads`

Memory scales with threads, but far less steeply while `build_tar=True`, because
workers share one mmap'd extract instead of each caching tiles privately. Raise it
in small steps and watch the memory graph — the safe number depends on your region
size and matrix width, so measure rather than copy a number from anywhere.

## Using it

Valhalla's [HTTP API](https://valhalla.github.io/valhalla/api/), unchanged:

```bash
curl "$VALHALLA_URL/status"

curl "$VALHALLA_URL/route" -H 'Content-Type: application/json' -d '{
  "locations":[{"lat":43.7384,"lon":7.4246},{"lat":43.7325,"lon":7.4189}],
  "costing":"auto"
}'
```

From another Railway service in the same project, use the private network:
`http://${{valhalla.RAILWAY_PRIVATE_DOMAIN}}:${{valhalla.PORT}}`. Private
networking carries no egress cost and keeps the router off the public internet.
It works because of the dual-stack proxy described above; stock Valhalla is not
reachable over Railway's IPv6-only private network.

Need vehicle routing (multi-stop optimisation) on top? See the companion
**VROOM + Valhalla** template.

## Local development

```bash
docker compose up --build     # builds Monaco, ~1 minute
./test.sh http://localhost:8002
```

`test.sh` checks `/status`, a real route, and a 25-location matrix — the last one
fails on a stock image, so it proves the limit patch is live. Override the host
port with `VALHALLA_HOST_PORT=8102` if 8002 is taken.

## License

MIT
