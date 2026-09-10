# Upstream owns proxy code and dependencies; this image only adds supervision and HTTP MCP.
# Weekly CI rebuilds pull latest upstream and run regression/lifecycle tests before publication.
ARG HEADROOM_IMAGE=ghcr.io/chopratejas/headroom:latest
FROM ${HEADROOM_IMAGE}
COPY docker-entrypoint.py mcp-http-bridge.py healthcheck.py /opt/headroom/
EXPOSE 8787 8788
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD ["python", "/opt/headroom/healthcheck.py"]
ENTRYPOINT ["python", "/opt/headroom/docker-entrypoint.py"]
CMD ["--host", "0.0.0.0", "--port", "8787", "--no-ccr-inject-tool"]
