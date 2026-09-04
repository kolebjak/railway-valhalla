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
   | `tile_urls` | `https://download.geofabrik.de/europe/monaco-latest.osm.pbf` | Required, with a description pointing at Geofabrik |
   | `server_threads` | `1` | Optional |
   | `VALHALLA_MAX_LOCATIONS` | `2000` | Optional |
   | `VALHALLA_MAX_MATRIX_PAIRS` | `4000000` | Optional |
   | `VALHALLA_COSTINGS` | `auto,taxi` | Optional |

   The composer never reads these from the repo — `railway.json` carries build and
   deploy settings only, so "No variables added" is expected until you add them by
   hand. **Add variables** → *Raw Editor* takes the whole block at once:

   ```
   tile_urls=https://download.geofabrik.de/europe/monaco-latest.osm.pbf
   server_threads=1
   VALHALLA_MAX_LOCATIONS=2000
   VALHALLA_MAX_MATRIX_PAIRS=4000000
   VALHALLA_COSTINGS=auto,taxi
   ```

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
