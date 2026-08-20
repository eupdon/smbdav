#!/bin/bash
set -e

BASE_DIR="/srv/share"
mkdir -p "$BASE_DIR"
mkdir -p /etc/caddy /etc/samba

# 유저 데이터 수집을 위한 임시 파일 초기화
> /tmp/user_hashes.txt
> /tmp/folder_mappings.txt

# 1. 모든 환경변수를 돌며 시스템/SMB 유저 생성 및 권한 매핑 수집
for i in $(seq 1 10); do
    eval USER=\$USER$i
    eval PASS=\$PASS$i

    if [ -z "$USER" ] || [ -z "$PASS" ]; then
        continue
    fi

    USERNAME=$(echo "$USER" | cut -d';' -f1)
    FOLDERS=$(echo "$USER" | cut -d';' -f2 | tr ',' ' ')

    # 시스템 유저 및 SMB 유저 생성
    if ! id "$USERNAME" >/dev/null 2>&1; then
        useradd -M -s /sbin/nologin "$USERNAME"
    fi
    echo -e "$PASS\n$PASS" | smbpasswd -a "$USERNAME" -s

    # Caddy WebDAV용 비밀번호 해싱 및 저장
    HASHED_PASS=$(caddy hash-password --plaintext "$PASS")
    echo "$USERNAME:$HASHED_PASS" >> /tmp/user_hashes.txt
    
    # 실제 공유할 폴더 생성 및 권한 매핑 기록
    for FOLDER in $FOLDERS; do
        TARGET_DIR="$BASE_DIR/$FOLDER"
        mkdir -p "$TARGET_DIR"
        chmod 777 "$TARGET_DIR"
        echo "$FOLDER:$USERNAME" >> /tmp/folder_mappings.txt
    done
done

# 2. Caddyfile 생성
echo -e "{\n    order webdav before file_server\n}\n\nhttp://:80 {" > /etc/caddy/Caddyfile

# 전체 루트에 단일 basicauth 적용
echo "    basicauth {" >> /etc/caddy/Caddyfile
if [ -f /tmp/user_hashes.txt ]; then
    while read -r LINE; do
        UNAME=$(echo "$LINE" | cut -d':' -f1)
        U_HASH=$(echo "$LINE" | cut -d':' -f2-)
        echo "        $UNAME $U_HASH" >> /etc/caddy/Caddyfile
    done < /tmp/user_hashes.txt
fi
echo -e "    }\n" >> /etc/caddy/Caddyfile

# 최상위 루트 경로는 무조건 실제 데이터 저장소 지정
echo "    root * $BASE_DIR" >> /etc/caddy/Caddyfile

# 3. [핵심 수정] Caddy 내장 vars 매처를 이용해 에러 없는 완벽한 다중 권한 제어 필터 구축
if [ -f /tmp/folder_mappings.txt ]; then
    cut -d':' -f1 /tmp/folder_mappings.txt | sort -u | while read -r FOLDER; do
        USERS_FOR_FOLDER=$(grep "^$FOLDER:" /tmp/folder_mappings.txt | cut -d':' -f2)
        
        # 해당 폴더 경로 블록 선언
        echo "    handle /$FOLDER/* {" >> /etc/caddy/Caddyfile
        
        # 권한이 있는 유저마다 각각 vars 매처와 내부 핸들러 매핑 (중복 매칭 가능)
        for UNAME in $USERS_FOR_FOLDER; do
            echo "        @allowed_$UNAME vars {http.auth.user.id} $UNAME" >> /etc/caddy/Caddyfile
            echo "        handle @allowed_$UNAME {" >> /etc/caddy/Caddyfile
            echo "            @browser method GET HEAD" >> /etc/caddy/Caddyfile
            echo "            file_server @browser browse" >> /etc/caddy/Caddyfile
            echo "            webdav" >> /etc/caddy/Caddyfile
            echo "        }" >> /etc/caddy/Caddyfile
        done
        
        # 위 필터들(vars) 중 그 어디에도 해당하지 않는 타인 계정은 일괄 거부(Forbidden)
        echo "        handle {" >> /etc/caddy/Caddyfile
        echo "            respond \"Forbidden\" 403" >> /etc/caddy/Caddyfile
        echo "        }" >> /etc/caddy/Caddyfile
        echo "    }" >> /etc/caddy/Caddyfile
    done
fi

# 최상위 루트(/) 자체에 대한 브라우저 뷰어 및 WebDAV 활성화
echo -e "\n    handle / {" >> /etc/caddy/Caddyfile
echo "        @browser method GET HEAD" >> /etc/caddy/Caddyfile
echo "        file_server @browser browse" >> /etc/caddy/Caddyfile
echo "        webdav" >> /etc/caddy/Caddyfile
echo "    }" >> /etc/caddy/Caddyfile

echo -e "\n    handle {\n        respond \"Not Found\" 404\n    }\n}" >> /etc/caddy/Caddyfile


# 4. smb.conf 조립 (기존 기능 유지)
echo -e "[global]\n    workgroup = WORKGROUP\n    security = user\n    map to guest = Bad User\n    invalid users = root\n" > /etc/samba/smb.conf
if [ -f /tmp/folder_mappings.txt ]; then
    cut -d':' -f1 /tmp/folder_mappings.txt | sort -u | while read -r FOLDER; do
        TARGET_DIR="$BASE_DIR/$FOLDER"
        USERS_FOR_FOLDER=$(grep "^$FOLDER:" /tmp/folder_mappings.txt | cut -d':' -f2)
        SMB_USER_LIST=$(echo "$USERS_FOR_FOLDER" | tr '\n' ' ' | sed 's/ $//' | sed 's/ /, /g')
        
        echo -e "\n[$FOLDER]\n    path = $TARGET_DIR\n    writable = yes\n    valid users = $SMB_USER_LIST\n    force create mode = 0777\n    force directory mode = 0777" >> /tmp/smb_folders.conf
    done
fi

if [ -f /tmp/smb_folders.conf ]; then
    cat /tmp/smb_folders.conf >> /etc/samba/smb.conf
fi

rm -f /tmp/user_hashes.txt /tmp/folder_mappings.txt /tmp/smb_folders.conf
exec /usr/bin/supervisord -c /etc/supervisord.conf
