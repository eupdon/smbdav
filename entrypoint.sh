#!/bin/bash
set -e

BASE_DIR="/srv/share"
USER_HOMES="/srv/users" # 유저별 개인 루트 공간 생성용
mkdir -p "$BASE_DIR" "$USER_HOMES"
mkdir -p /etc/caddy /etc/samba

# 유저 데이터 수집을 위한 임시 파일 초기화
> /tmp/user_hashes.txt
> /tmp/folder_mappings.txt

# 1. 모든 환경변수를 돌며 유저 생성 및 인증 정보 수집
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
    
    # 유저별 개인 가상 루트 디렉토리 생성
    U_HOME="$USER_HOMES/$USERNAME"
    mkdir -p "$U_HOME"

    # 폴더별 접근 권한 매핑 기록 및 심볼릭 링크 연결
    for FOLDER in $FOLDERS; do
        TARGET_DIR="$BASE_DIR/$FOLDER"
        mkdir -p "$TARGET_DIR"
        chmod 777 "$TARGET_DIR"
        echo "$FOLDER:$USERNAME" >> /tmp/folder_mappings.txt

        # 유저 홈 디렉토리 내부에 권한이 있는 실제 폴더를 바로가기(링크)로 연결
        ln -sf "$TARGET_DIR" "$U_HOME/$FOLDER"
    done
done

# 2. Caddyfile 생성 시작
# 지시어 순서에 webdav와 file_server를 명시합니다.
echo -e "{\n    order webdav before file_server\n}\n\nhttp://:80 {" > /etc/caddy/Caddyfile

# 3. 유저별 루트 WebDAV 환경 구성
# 루트 상태로 진입하면 각 유저의 아이디를 식별해 해당 유저의 가상 홈(/srv/users/유저명)을 WebDAV로 보여줍니다.
if [ -f /tmp/user_hashes.txt ]; then
    while read -r LINE; do
        UNAME=$(echo "$LINE" | cut -d':' -f1)
        U_HASH=$(echo "$LINE" | cut -d':' -f2-)
        
        echo -e "\n    # $UNAME 전용 가상 루트 및 하위 폴더 처리" >> /etc/caddy/Caddyfile
        echo "    @auth_$UNAME {" >> /etc/caddy/Caddyfile
        echo "        expression {http.auth.user} == '$UNAME'" >> /etc/caddy/Caddyfile
        echo "    }" >> /etc/caddy/Caddyfile
        
        echo "    handle @auth_$UNAME {" >> /etc/caddy/Caddyfile
        echo "        root * $USER_HOMES/$UNAME" >> /etc/caddy/Caddyfile
        echo "        basicauth {" >> /etc/caddy/Caddyfile
        echo "            $UNAME $U_HASH" >> /etc/caddy/Caddyfile
        echo "        }" >> /etc/caddy/Caddyfile
        echo "        webdav" >> /etc/caddy/Caddyfile
        echo "    }" >> /etc/caddy/Caddyfile
    done < /tmp/user_hashes.txt
fi

# 기본 인증 요구 (기본적으로 들어올 때 누군지 알아야 하므로 루트 레벨에 인증 배치)
echo -e "\n    basicauth {" >> /etc/caddy/Caddyfile
if [ -f /tmp/user_hashes.txt ]; then
    while read -r LINE; do
        UNAME=$(echo "$LINE" | cut -d':' -f1)
        U_HASH=$(echo "$LINE" | cut -d':' -f2-)
        echo "        $UNAME $U_HASH" >> /etc/caddy/Caddyfile
    done < /tmp/user_hashes.txt
fi
echo -e "    }\n" >> /etc/caddy/Caddyfile

# 예외 처리 닫기
echo -e "    handle {\n        respond \"Unauthorized\" 401\n    }\n}" >> /etc/caddy/Caddyfile


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

# 임시 파일 정리 후 프로세스 관리자 가동
rm -f /tmp/user_hashes.txt /tmp/folder_mappings.txt /tmp/smb_folders.conf
exec /usr/bin/supervisord -c /etc/supervisord.conf
