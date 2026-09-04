# Valhalla routing engine, packaged for Railway.
#
# Wraps the upstream scripted image with an entrypoint that:
#   - binds the HTTP service to Railway's $PORT
#   - raises the per-costing matrix limits (no env exists for these upstream)
#   - defaults server_threads to 1 (containers see the HOST core count)
# See entrypoint.sh for the reasoning behind each.
FROM ghcr.io/valhalla/valhalla-scripted:3.7.0

COPY entrypoint.sh /railway_entrypoint.sh
RUN chmod +x /railway_entrypoint.sh

EXPOSE 8002

ENTRYPOINT ["bash", "/railway_entrypoint.sh"]
