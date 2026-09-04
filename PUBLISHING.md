# Publishing this as a Railway template

Railway's `railway.json` covers build and deploy settings only. Volumes, variables
and their descriptions live in the template composer, so the steps below cannot be
committed to the repo — they are done once in the UI.

1. Push this repo to GitHub.
2. Go to [railway.com/templates](https://railway.com/templates) → **New Template**.
3. Add a service from this GitHub repo. Name it `valhalla` — the companion
   VROOM template references that name.
4. **Attach a volume** (right-click the service → *Attach Volume*) with mount path
   `/custom_files`. This is the single most important step: without it, every
   deploy rebuilds tiles from scratch.
5. Add the variables:

   | Variable | Value | Mark as |
   | --- | --- | --- |
   | `tile_urls` | `https://download.geofabrik.de/europe/monaco-latest.osm.pbf` | Optional, with a description pointing at Geofabrik |
   | `server_threads` | `1` | Optional |
   | `VALHALLA_MAX_LOCATIONS` | `500` | Optional |
   | `VALHALLA_MAX_MATRIX_PAIRS` | `250000` | Optional |

   Railway scans the repo root for `.env*` files and offers their keys for import,
   so `.env.example` should populate this in one click. If it does not, **Add
   variables** → *Raw Editor* takes the same block pasted by hand. `railway.json`
   cannot carry variables — it is build and deploy settings only.

   Every one of these already has the same default baked into `entrypoint.sh`, so
   only `tile_urls` is load-bearing; the rest are there to be discoverable and
   editable at deploy time. Keep the `tile_urls` default small (Monaco) so a
   first-time deploy finishes in a minute rather than an hour.
6. **Leave the healthcheck path empty.** First boot builds tiles before serving,
   which outlasts any healthcheck window and would fail the deploy.
7. Enable public networking only if the router should be reachable from outside
   the project. If it is only consumed by other Railway services, leave it private.
8. Publish, then add the deploy button to `README.md` using the template code:
   `[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/TEMPLATE_CODE)`
