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
    
    # [핵심] 유저 이름으로 된 가상 폴더(/srv/users/유저명)를 만드는 코드를 완전히 삭제했습니다!
    # 오직 실제 공유할 폴더들만 베이스 디렉토리에 생성합니다.
    for FOLDER in $FOLDERS; do
        TARGET_DIR="$BASE_DIR/$FOLDER"
        mkdir -p "$TARGET_DIR"
        chmod 777 "$TARGET_DIR"
        echo "$FOLDER:$USERNAME" >> /tmp/folder_mappings.txt
    done
done

# 2. Caddyfile 생성
echo -e "{\n    order webdav before file_server\n}\n\nhttp://:80 {" > /etc/caddy/Caddyfile

# 전체 루트에 단일 basicauth 적용 (로그인 창은 단 1번만 팝업)
echo "    basicauth {" >> /etc/caddy/Caddyfile
if [ -f /tmp/user_hashes.txt ]; then
    while read -r LINE; do
        UNAME=$(echo "$LINE" | cut -d':' -f1)
        U_HASH=$(echo "$LINE" | cut -d':' -f2-)
        echo "        $UNAME $U_HASH" >> /etc/caddy/Caddyfile
    done < /tmp/user_hashes.txt
fi
echo -e "    }\n" >> /etc/caddy/Caddyfile

# 최상위 루트 경로는 무조건 실제 데이터 저장소인 /srv/share를 바라봅니다.
# (이로 인해 최상위에는 folder1, folder2 같은 실제 폴더들만 존재하게 됩니다)
echo "    root * $BASE_DIR" >> /etc/caddy/Caddyfile

# 3. 하위 폴더별로 접근 권한이 있는 유저만 진입할 수 있도록 방어벽 구성
if [ -f /tmp/folder_mappings.txt ]; then
    cut -d':' -f1 /tmp/folder_mappings.txt | sort -u | while read -r FOLDER; do
        USERS_FOR_FOLDER=$(grep "^$FOLDER:" /tmp/folder_mappings.txt | cut -d':' -f2)
        
        # 권한 유저 검증 조건문 생성
        EXPR=""
        for UNAME in $USERS_FOR_FOLDER; do
            if [ -z "$EXPR" ]; then
                EXPR="http.auth.user.id == '$UNAME'"
            else
                EXPR="$EXPR || http.auth.user.id == '$UNAME'"
            fi
        done

        # 해당 폴더 경로로 들어왔을 때 조건 검사
        echo "    handle /$FOLDER/* {" >> /etc/caddy/Caddyfile
        echo "        @listens expression $EXPR" >> /etc/caddy/Caddyfile
        echo "        handle @listens {" >> /etc/caddy/Caddyfile
        echo "            @browser method GET HEAD" >> /etc/caddy/Caddyfile
        echo "            file_server @browser browse" >> /etc/caddy/Caddyfile
        echo "            webdav" >> /etc/caddy/Caddyfile
        echo "        }" >> /etc/caddy/Caddyfile
        # 권한이 없는 유저가 주소를 직접 치고 들어오면 국물도 없이 거부(Forbidden)
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


# 4. smb.conf 조립 (기존 정상 스펙 유지)
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
