# Valhalla routing engine, packaged for Railway.
#
# Wraps the upstream scripted image with an entrypoint that:
#   - binds the HTTP service to Railway's $PORT
#   - raises the per-costing matrix limits (no env exists for these upstream)
#   - defaults server_threads to 1 (containers see the HOST core count)
#   - fronts the router with a dual-stack listener, since Valhalla's zmq socket
#     cannot bind IPv6 and Railway's private network is IPv6-only
# See entrypoint.sh for the reasoning behind each.
FROM ghcr.io/valhalla/valhalla-scripted:3.7.0

RUN export DEBIAN_FRONTEND=noninteractive && apt-get update && \
  apt-get install -y --no-install-recommends socat && \
  rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /railway_entrypoint.sh
RUN chmod +x /railway_entrypoint.sh

EXPOSE 8002

ENTRYPOINT ["bash", "/railway_entrypoint.sh"]
