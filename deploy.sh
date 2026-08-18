cat << 'EOF' > deploy.sh
#!/bin/bash
set -e

GATEWAY_NAME="RU666_SIM"
EXT_START=101
EXT_END=132

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --gateway-name) GATEWAY_NAME="$2"; shift ;;
        --ext-start) EXT_START="$2"; shift ;;
        --ext-end) EXT_END="$2"; shift ;;
        *) echo "⚠️ Неизвестный параметр: $1"; exit 1 ;;
    esac
    shift
done

SERVER_IP=$(hostname -I | awk '{print $1}')
GOIP_WEB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
SMB_WEB_USER="admin"
SMB_WEB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
RADM_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
RADM_KEY=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
GATEWAY_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')

echo "🚀 Развертывание DBL GoIP + Asterisk | IP: $SERVER_IP | Шлюз: $GATEWAY_NAME"

echo "[1/8] Обновление и установка пакетов..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y ca-certificates curl gnupg lsb-release asterisk
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -qq && apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

echo "[2/8] Клонирование репозитория..."
rm -rf /opt/goip && cd /opt
git clone --branch goip-no-aster https://github.com/VoipBuilders/goip.git && cd /opt/goip

echo "[3/8] Подготовка docker-compose.yaml..."
sed -i 's/# *entrypoint: \[ "\/install.sh" \]/entrypoint: [ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" ]/' docker-compose.yaml
sed -i '/entrypoint: \[ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" \]/ { n; s/^\(.*\)/# \1/ }' docker-compose.yaml

echo "[4/8] Внедрение учетных данных..."
sed -i "s/^GOIP_WEB_PASSWORD=.*/GOIP_WEB_PASSWORD=${GOIP_WEB_PASS}/" security/db.env
sed -i "s/^SMB_WEB_USER=.*/SMB_WEB_USER=${SMB_WEB_USER}/" security/db.env
sed -i "s/^SMB_WEB_PASSWORD=.*/SMB_WEB_PASSWORD=${SMB_WEB_PASS}/" security/db.env
sed -i "s/^RADM_PASSWORD=.*/RADM_PASSWORD=${RADM_PASS}/" security/radmin.env
sed -i "s/^RADM_KEY=.*/RADM_KEY=${RADM_KEY}/" security/radmin.env
grep -q "^RADM_KEY=" security/radmin.env || echo "RADM_KEY=${RADM_KEY}" >> security/radmin.env

echo "[5/8] Инициализация БД..."
docker compose up -d
while docker compose ps install 2>/dev/null | grep -q "Up"; do sleep 5; done
echo "✅ БД инициализирована."

echo "[6/8] Переключение в боевой режим..."
docker compose down
sed -i 's/^entrypoint: \[ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" \]/# entrypoint: [ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" ]/' docker-compose.yaml
sed -i '/# entrypoint: \[ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" \]/ { n; s/^# *\(.*\)/  \1/ }' docker-compose.yaml
docker compose up -d

echo "[7/8] Настройка Asterisk..."
cd /opt/goip/presets
sed -i "s/192\.168\.0\.1/${SERVER_IP}/g" pjsip.conf
sed -i "s/RU666_SIM/${GATEWAY_NAME}/g" pjsip.conf
sed -i "s/RU666_SIM/${GATEWAY_NAME}/g" extensions.conf
sed -i "s/WATYZSUaWizZSUa/${GATEWAY_PASS}/g" pjsip.conf
sed -i 's/type=identify`/type=identify/g' pjsip.conf

chmod +x gen_ext.sh && ./gen_ext.sh ${EXT_START} ${EXT_END}

> /etc/asterisk/pjsip.conf
cp pjsip.conf /etc/asterisk/pjsip.conf
cp extensions.conf /etc/asterisk/extensions.conf
[ -f ext_temp ] && cat ext_temp >> /etc/asterisk/pjsip.conf

chown asterisk:asterisk /etc/asterisk/pjsip.conf /etc/asterisk/extensions.conf
systemctl enable --now asterisk
asterisk -rx "module reload res_pjsip.so" > /dev/null 2>&1 || true
asterisk -rx "dialplan reload" > /dev/null 2>&1 || true

echo "[8/8] Генерация файла доступов..."
DOST_FILE="/opt/goip/dost.txt"
cat << CREDS > $DOST_FILE
⚙️ Ниже Ваши новые настройки:

💬 Sim Bank Scheduler Server
http://${SERVER_IP}:8188/smb/index.php?lan=3
Логин: ${SMB_WEB_USER}
Пароль: ${SMB_WEB_PASS}

🎴 GoIP SMS Manage Server
http://${SERVER_IP}:8080/goip/en/index.php
Логин: admin
Пароль: ${GOIP_WEB_PASS}

🚦 Remote Server
http://${SERVER_IP}:8086
Логин: admin
Пароль: ${RADM_PASS}
Key: ${RADM_KEY}

Прописали Вам шлюз ${GATEWAY_NAME}
Логин: admin
Пароль: ${GATEWAY_PASS}

Данные для подключения по ☎️ SIP:
${SERVER_IP}:5090

CREDS

echo "${EXT_START}-${EXT_END} <----> ${GATEWAY_NAME}" >> $DOST_FILE
for i in $(seq $EXT_START $EXT_END); do
    echo "$i <--> SIM$((i - EXT_START + 1))" >> $DOST_FILE
done
echo "" >> $DOST_FILE
[ -f ext_temp ] && grep -E "^(username|password)=" ext_temp | xargs -n 2 >> $DOST_FILE

chmod 600 $DOST_FILE
echo "✅ ГОТОВО. Файл доступов: /opt/goip/dost.txt"
cat $DOST_FILE
EOF
chmod +x deploy.sh
