#!/bin/bash
set -e

BASE_DIR="/srv/share"
mkdir -p "$BASE_DIR"
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
    
    # 폴더별 접근 권한 매핑 기록
    for FOLDER in $FOLDERS; do
        TARGET_DIR="$BASE_DIR/$FOLDER"
        mkdir -p "$TARGET_DIR"
        chmod 777 "$TARGET_DIR"
        echo "$FOLDER:$USERNAME" >> /tmp/folder_mappings.txt
    done
done

# 2. Caddyfile 기본 뼈대 생성 시작
echo -e "{\n    order webdav before file_server\n}\n\nhttp://:80 {\n    root * $BASE_DIR" > /etc/caddy/Caddyfile

# 3. 고유 폴더 목록을 추출하여 WebDAV 및 SMB 설정 작성
if [ -f /tmp/folder_mappings.txt ]; then
    cut -d':' -f1 /tmp/folder_mappings.txt | sort -u | while read -r FOLDER; do
        TARGET_DIR="$BASE_DIR/$FOLDER"
        
        # 해당 폴더에 접근 권한이 있는 유저 목록 추출
        USERS_FOR_FOLDER=$(grep "^$FOLDER:" /tmp/folder_mappings.txt | cut -d':' -f2)
        
        # --- WebDAV (Caddyfile) 작성 ---
        # 하나의 handle 블록 안에 여러 유저의 basicauth 정보를 모아서 채워 넣음
        echo -e "\n    handle /$FOLDER/* {\n        basicauth {" >> /etc/caddy/Caddyfile
        for UNAME in $USERS_FOR_FOLDER; do
            U_HASH=$(grep "^$UNAME:" /tmp/user_hashes.txt | cut -d':' -f2-)
            echo "            $UNAME $U_HASH" >> /etc/caddy/Caddyfile
        done
        echo -e "        }\n        webdav\n    }" >> /etc/caddy/Caddyfile

        # --- SMB (smb.conf) 작성 ---
        SMB_USER_LIST=$(echo "$USERS_FOR_FOLDER" | tr '\n' ' ' | sed 's/ $//' | sed 's/ /, /g')
        echo -e "\n[$FOLDER]\n    path = $TARGET_DIR\n    writable = yes\n    valid users = $SMB_USER_LIST\n    force create mode = 0777\n    force directory mode = 0777" >> /tmp/smb_folders.conf
    done
fi

# Caddyfile 마무리 닫기
echo -e "\n    handle {\n        respond \"Not Found or Unauthorized\" 404\n    }\n}" >> /etc/caddy/Caddyfile

# smb.conf 최종 결합
echo -e "[global]\n    workgroup = WORKGROUP\n    security = user\n    map to guest = Bad User\n    invalid users = root\n" > /etc/samba/smb.conf
if [ -f /tmp/smb_folders.conf ]; then
    cat /tmp/smb_folders.conf >> /etc/samba/smb.conf
fi

# 임시 파일 정리 후 프로세스 관리자 가동
rm -f /tmp/user_hashes.txt /tmp/folder_mappings.txt /tmp/smb_folders.conf
exec /usr/bin/supervisord -c /etc/supervisord.conf
