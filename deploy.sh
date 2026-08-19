#!/bin/bash

# === ЦВЕТА И ЛОГИРОВАНИЕ ===
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'
log_info()  { echo -e "${GREEN}[✔]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# === ПАРСИНГ АРГУМЕНТОВ ===
GATEWAY_NAME="RU666_SIM"
EXT_START=101
EXT_END=132

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --gateway-name) GATEWAY_NAME="$2"; shift 2 ;;
        --ext-start) EXT_START="$2"; shift 2 ;;
        --ext-end) EXT_END="$2"; shift 2 ;;
        *) echo "⚠️ Неизвестный параметр: $1"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}[⚠]${NC} Скрипт требует root. Запусти через sudo или под root."
  exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
GOIP_WEB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
SMB_WEB_USER="admin"
SMB_WEB_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
RADM_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')
RADM_KEY=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9')
GATEWAY_PASS=$(openssl rand -base64 12 | tr -dc 'a-zA-Z0-9')

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  VoIP Server Deployment & Hardening v2.2${NC}"
echo -e "${GREEN}  IP: $SERVER_IP | Шлюз: $GATEWAY_NAME${NC}"
echo -e "${GREEN}============================================================${NC}"

# === 1. ОЖИДАНИЕ APT И БАЗОВАЯ УСТАНОВКА ===
log_step "1/8 Обновление системы и ожидание разблокировки apt"
wait_for_apt() {
  local timeout=300; local elapsed=0
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock &> /dev/null; do
    [ $elapsed -ge $timeout ] && { log_warn "apt заблокирован. Продолжаю с риском..."; break; }
    [ $elapsed -eq 0 ] && echo -ne "${YELLOW}[⚠]${NC} apt занят. Ожидание"
    echo -ne "."; sleep 5; elapsed=$((elapsed + 5))
  done
  [ $elapsed -gt 0 ] && echo "" && log_info "apt освобождён"
}
export DEBIAN_FRONTEND=noninteractive
wait_for_apt
apt-get update -y -qq
apt-get upgrade -y -qq
apt-get install -y ca-certificates curl gnupg lsb-release asterisk ufw fail2ban

# === 2. DOCKER ===
log_step "2/8 Установка Docker"
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update -y -qq
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# === 3. KLONIRovanie GOIP ===
log_step "3/8 Клонирование и инициализация GoIP"
rm -rf /opt/goip
cd /opt || { echo "❌ Ошибка: нет доступа к /opt"; exit 1; }
git clone --branch goip-no-aster https://github.com/VoipBuilders/goip.git || { echo "❌ Ошибка клонирования"; exit 1; }
cd /opt/goip || exit 1

sed -i 's/# *entrypoint: \[ "\/install.sh" \]/entrypoint: [ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" ]/' docker-compose.yaml
sed -i '/entrypoint: \[ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" \]/ { n; s/^\(.*\)/# \1/ }' docker-compose.yaml

sed -i "s/^GOIP_WEB_PASSWORD=.*/GOIP_WEB_PASSWORD=${GOIP_WEB_PASS}/" security/db.env
sed -i "s/^SMB_WEB_USER=.*/SMB_WEB_USER=${SMB_WEB_USER}/" security/db.env
sed -i "s/^SMB_WEB_PASSWORD=.*/SMB_WEB_PASSWORD=${SMB_WEB_PASS}/" security/db.env
sed -i "s/^RADM_PASSWORD=.*/RADM_PASSWORD=${RADM_PASS}/" security/radmin.env
sed -i "s/^RADM_KEY=.*/RADM_KEY=${RADM_KEY}/" security/radmin.env
grep -q "^RADM_KEY=" security/radmin.env || echo "RADM_KEY=${RADM_KEY}" >> security/radmin.env

docker compose up -d
while docker compose ps install 2>/dev/null | grep -q "Up"; do sleep 5; done
log_info "База данных инициализирована."

docker compose down
sed -i 's/^entrypoint: \[ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" \]/# entrypoint: [ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" ]/' docker-compose.yaml
sed -i '/# entrypoint: \[ "\/bin\/sh", "-c", "touch \/asterisk.sql \&\& \/install.sh" \]/ { n; s/^# *\(.*\)/  \1/ }' docker-compose.yaml
docker compose up -d

# === 4. НАСТРОЙКА ASTERISK ===
log_step "4/8 Настройка конфигурации Asterisk"
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

# Включаем логирование безопасности для Fail2ban
if ! grep -q "security" /etc/asterisk/logger.conf; then
    sed -i '/^\[logfiles\]/a security => notice,warning,error,security' /etc/asterisk/logger.conf
fi

chown asterisk:asterisk /etc/asterisk/pjsip.conf /etc/asterisk/extensions.conf
systemctl enable --now asterisk
asterisk -rx "core reload" > /dev/null 2>&1 || true

# === 5. ХАРДЕНИНГ: ОПРЕДЕЛЕНИЕ ПОРТОВ ===
log_step "5/8 Анализ портов для настройки защиты"
SIP_PORTS=()
while read -r port; do
  [ -n "$port" ] && SIP_PORTS+=("$port")
done < <(grep -E "^bind=" /etc/asterisk/pjsip.conf 2>/dev/null | grep -oE ":[0-9]+" | tr -d ':')
[ ${#SIP_PORTS[@]} -eq 0 ] && SIP_PORTS=(5090)
SIP_PORTS=($(echo "${SIP_PORTS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
log_info "Обнаружены SIP порты: ${SIP_PORTS[*]}"

# === 6. ХАРДЕНИНГ: UFW ===
log_step "6/8 Настройка брандмауэра (UFW)"
ufw --force reset > /dev/null 2>&1
ufw default deny incoming > /dev/null
ufw default allow outgoing > /dev/null

SSH_PORT=$(grep -E "^#?Port " /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')
SSH_PORT=${SSH_PORT:-22}
ufw allow "${SSH_PORT}/tcp" comment 'SSH' > /dev/null

for port in "${SIP_PORTS[@]}"; do
  ufw allow "${port}/udp" comment "SIP UDP" > /dev/null
  ufw allow "${port}/tcp" comment "SIP TCP" > /dev/null
done

# Порты GoIP Web
ufw allow 8080/tcp comment 'GoIP SMS Web' > /dev/null
ufw allow 8086/tcp comment 'GoIP Remote Web' > /dev/null
ufw allow 8188/tcp comment 'GoIP Scheduler Web' > /dev/null

# RTP и базовые
ufw allow 10000:20000/udp comment 'Asterisk RTP' > /dev/null
ufw allow 80/tcp comment 'HTTP' > /dev/null
ufw allow 443/tcp comment 'HTTPS' > /dev/null

ufw --force enable > /dev/null 2>&1
log_info "UFW настроен и включен"

# === 7. ХАРДЕНИНГ: FAIL2BAN ===
log_step "7/8 Настройка Fail2ban"
FAIL2BAN_PORTS=$(IFS=,; echo "${SIP_PORTS[*]}")
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime  = 86400
findtime = 3600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1
# ВАЖНО: Добавь IP своих GoIP шлюзов выше в ignoreip через пробел!

[sshd]
enabled = true
port    = ${SSH_PORT}
maxretry = 3

[asterisk]
enabled  = true
port     = ${FAIL2BAN_PORTS}
filter   = asterisk
logpath  = /var/log/asterisk/messages
maxretry = 5
bantime  = 604800
EOF
systemctl enable --now fail2ban > /dev/null 2>&1
systemctl restart fail2ban > /dev/null 2>&1
log_info "Fail2ban настроен"

# === 8. ХАРДЕНИНГ: ЯДРО ===
log_step "8/8 Защита сетевого стека ядра"
cat <<'EOF' > /etc/sysctl.d/99-voip-security.conf
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_all = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
EOF
sysctl --system > /dev/null 2>&1
log_info "Параметры ядра применены"

# === 9. ФИНАЛЬНЫЙ ОТЧЕТ ===
log_step "Генерация файла доступов"
DOST_FILE="/opt/goip/dost.txt"

{
    echo "⚙️ Ниже Ваши новые настройки:"
    echo ""
    echo "💬 Sim Bank Scheduler Server"
    echo "http://${SERVER_IP}:8188/smb/index.php?lan=3"
    echo "Логин: ${SMB_WEB_USER}"
    echo "Пароль: ${SMB_WEB_PASS}"
    echo ""
    echo "🎴 GoIP SMS Manage Server"
    echo "http://${SERVER_IP}:8188/goip/en/index.php"
    echo "Логин: admin"
    echo "Пароль: ${GOIP_WEB_PASS}"
    echo ""
    echo "🚦 Remote Server"
    echo "http://${SERVER_IP}:8086"
    echo "Логин: admin"
    echo "Пароль: ${RADM_PASS}"
    echo "Key: ${RADM_KEY}"
    echo ""
    echo "Прописали Вам шлюз ${GATEWAY_NAME}"
    echo "Логин: admin"
    echo "Пароль: ${GATEWAY_PASS}"
    echo ""
    echo "Данные для подключения по ☎️ SIP:"
    echo "${SERVER_IP}:${SIP_PORTS[0]}"
    echo ""
    echo "${EXT_START}-${EXT_END} <----> ${GATEWAY_NAME}"
    
    for i in $(seq $EXT_START $EXT_END); do
        echo "$i <--> SIM$((i - EXT_START + 1))"
    done
    echo ""
    
    if [ -f ext_temp ]; then
        grep -E "^(username|password)=" ext_temp | xargs -n 2
    fi
} > "$DOST_FILE"

chmod 600 "$DOST_FILE"

echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  ✅ РАЗВЕРТЫВАНИЕ И ЗАЩИТА ЗАВЕРШЕНЫ УСПЕШНО!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "${YELLOW}⚠️  ВАЖНО: Открой /etc/fail2ban/jail.local и добавь${NC}"
echo -e "${YELLOW}   IP-адреса твоих физических GoIP шлюзов в ignoreip,${NC}"
echo -e "${YELLOW}   иначе Fail2ban может их заблокировать!${NC}"
echo -e "${GREEN}============================================================${NC}"
cat "$DOST_FILE"
echo -e "${GREEN}============================================================${NC}"
