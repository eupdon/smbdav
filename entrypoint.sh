#!/bin/bash
set -e

BASE_DIR="/srv/share"
mkdir -p "$BASE_DIR"

mkdir -p /etc/caddy /etc/samba

# Caddyfile 및 smb.conf 초기 설정 생성
echo -e "{\n    order webdav before file_server\n}\n\nhttp://:80 {\n    root * $BASE_DIR" > /etc/caddy/Caddyfile
echo -e "[global]\n    workgroup = WORKGROUP\n    security = user\n    map to guest = Bad User\n    invalid users = root\n" > /etc/samba/smb.conf

# 1부터 10까지 유저 탐색
for i in $(seq 1 10); do
    eval USER=\$USER$i
    eval PASS=\$PASS$i

    if [ -z "$USER" ] || [ -z "$PASS" ]; then
        continue
    fi

    USERNAME=$(echo "$USER" | cut -d';' -f1)
    FOLDERS=$(echo "$USER" | cut -d';' -f2 | tr ',' ' ')

    # 중복 유저 에러 방지 처리 후 생성
    if ! id "$USERNAME" >/dev/null 2>&1; then
        useradd -M -s /sbin/nologin "$USERNAME"
    fi
    echo -e "$PASS\n$PASS" | smbpasswd -a "$USERNAME" -s

    HASHED_PASS=$(caddy hash-password --plaintext "$PASS")
    
    for FOLDER in $FOLDERS; do
        TARGET_DIR="$BASE_DIR/$FOLDER"
        mkdir -p "$TARGET_DIR"
        chmod 777 "$TARGET_DIR"

        echo -e "\n    handle /$FOLDER/* {\n        basicauth {\n            $USERNAME $HASHED_PASS\n        }\n        webdav\n    }" >> /etc/caddy/Caddyfile
        
        if grep -q "\[$FOLDER\]" /etc/samba/smb.conf; then
            sed -i "/valid users =/s/$/ $USERNAME/" /etc/samba/smb.conf
        else
            echo -e "\n[$FOLDER]\n    path = $TARGET_DIR\n    writable = yes\n    valid users = $USERNAME\n    force create mode = 0777\n    force directory mode = 0777" >> /etc/samba/smb.conf
        fi
    done
done

echo -e "\n    handle {\n        respond \"Not Found or Unauthorized\" 404\n    }\n}" >> /etc/caddy/Caddyfile

exec /usr/bin/supervisord -c /etc/supervisord.conf
