FROM nginx:1.27-alpine

# rsvg-convert — rasterize SVG icons to PNG at build time.
RUN apk add --no-cache rsvg-convert

# Rasterize icons and stage static assets under /usr/share/nginx/html/install-pwa/.
COPY host-services/coder-pwa/pwa/ /build/pwa/
RUN set -eux; \
    mkdir -p /usr/share/nginx/html/install-pwa/icons; \
    rsvg-convert -w 192 -h 192 /build/pwa/icon.svg          -o /usr/share/nginx/html/install-pwa/icons/icon-192.png; \
    rsvg-convert -w 512 -h 512 /build/pwa/icon.svg          -o /usr/share/nginx/html/install-pwa/icons/icon-512.png; \
    rsvg-convert -w 512 -h 512 /build/pwa/icon-maskable.svg -o /usr/share/nginx/html/install-pwa/icons/icon-512-maskable.png; \
    rsvg-convert -w 180 -h 180 /build/pwa/icon.svg          -o /usr/share/nginx/html/install-pwa/icons/apple-touch-icon.png; \
    cp /build/pwa/index.html           /usr/share/nginx/html/install-pwa/index.html; \
    cp /build/pwa/sw.js                /usr/share/nginx/html/install-pwa/sw.js; \
    cp /build/pwa/manifest.webmanifest /usr/share/nginx/html/install-pwa/manifest.webmanifest; \
    rm -rf /build

RUN rm -f /etc/nginx/conf.d/default.conf
COPY host-services/coder-pwa/coder-pwa.conf /etc/nginx/conf.d/coder-pwa.conf

EXPOSE 80
