FROM caddy:2-builder AS builder
RUN xcaddy build --with ://github.com

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    samba \
    smbclient \
    supervisor \
    ca-certificates \
    bash \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/bin/caddy /usr/bin/caddy

COPY supervisord.conf /etc/supervisord.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 80 445

ENTRYPOINT ["/entrypoint.sh"]
