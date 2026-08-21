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

# 요청 헤더를 분석하여 일반 웹 브라우저(html 요구)인지 WebDAV 프로그램인지 완벽 분기하는 매처 정의
echo "    @is_browser header Accept *text/html*" >> /etc/caddy/Caddyfile

# 3. 하위 폴더별 권한 제어 필터 구축
if [ -f /tmp/folder_mappings.txt ]; then
    cut -d':' -f1 /tmp/folder_mappings.txt | sort -u | while read -r FOLDER; do
        USERS_FOR_FOLDER=$(grep "^$FOLDER:" /tmp/folder_mappings.txt | cut -d':' -f2)
        
        echo "    handle /$FOLDER/* {" >> /etc/caddy/Caddyfile
        
        # 권한이 있는 유저 인증 처리
        for UNAME in $USERS_FOR_FOLDER; do
            echo "        @allowed_$UNAME vars {http.auth.user.id} $UNAME" >> /etc/caddy/Caddyfile
            echo "        handle @allowed_$UNAME {" >> /etc/caddy/Caddyfile
            # 브라우저 접속이면 파일 서버 뷰어로 연결, 아니면 WebDAV 연결
            echo "            route {" >> /etc/caddy/Caddyfile
            echo "                file_server @is_browser browse" >> /etc/caddy/Caddyfile
            echo "                webdav" >> /etc/caddy/Caddyfile
            echo "            }" >> /etc/caddy/Caddyfile
            echo "        }" >> /etc/caddy/Caddyfile
        done
        
        # 권한 없는 유저 거부 (주소를 직접 치거나 브라우저에서 눌렀을 때 작동)
        echo "        handle {" >> /etc/caddy/Caddyfile
        echo "            respond \"Forbidden\" 403" >> /etc/caddy/Caddyfile
        echo "        }" >> /etc/caddy/Caddyfile
        echo "    }" >> /etc/caddy/Caddyfile
    done
fi

# 최상위 루트(/) 자체에 대한 브라우저 뷰어 및 WebDAV 활성화 분기
echo -e "\n    handle / {" >> /etc/caddy/Caddyfile
echo "        route {" >> /etc/caddy/Caddyfile
echo "            file_server @is_browser browse" >> /etc/caddy/Caddyfile
echo "            webdav" >> /etc/caddy/Caddyfile
echo "        }" >> /etc/caddy/Caddyfile
echo "    }" >> /etc/caddy/Caddyfile

echo -e "\n    handle {\n        respond \"Not Found\" 404\n    }\n}" >> /etc/caddy/Caddyfile


# 4. smb.conf 조립 (기존 정상 스펙 동일 유지)
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
