FROM oven/bun:latest
RUN bun install -g @twsxtd/hapi
EXPOSE 3006
VOLUME /data
ENV HAPI_DATA_DIR=/data
ENTRYPOINT ["hapi", "hub", "--port", "3006", "--host", "0.0.0.0"]