FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/mholt/caddy-webdav

FROM debian:bookworm-slim

# 필요한 패키지 (Samba, Supervisor, Caddy 구동용 필수 도구) 설치
RUN apt-get update && apt-get install -y --no-install-recommens \
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
