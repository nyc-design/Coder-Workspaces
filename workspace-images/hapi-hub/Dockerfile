FROM oven/bun:latest
RUN bun install -g @twsxtd/hapi
EXPOSE 3006
VOLUME /data
ENV HAPI_LISTEN_HOST=0.0.0.0
ENV HAPI_LISTEN_PORT=3006
ENV HAPI_PUBLIC_URL=https://hapi.tapiavala.com
ENV HOME=/data
ENTRYPOINT ["hapi", "hub"]