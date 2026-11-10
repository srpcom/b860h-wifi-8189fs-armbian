#!/bin/bash
# ==============================================================================
# Universal Installer Wi-Fi Internal + USB TL-WN722N + WAN Failover (Armbian)
# Mendukung STB ZTE B860H / P212 (8189fs/es) & Fiberhome HG680-P / HG860P (rtl8xxxu)
# Repo: https://github.com/srpcom/b860h-wifi-8189fs-armbian
# ==============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main"

WIFI_SSID=""
WIFI_PASS=""
LAN_IF="eth0"
SKIP_WIFI_PROFILE=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ssid)
            WIFI_SSID="${2:-}"
            shift 2
            ;;
        --pass|--password)
            WIFI_PASS="${2:-}"
            shift 2
            ;;
        --lan-if)
            LAN_IF="${2:-eth0}"
            shift 2
            ;;
        --skip-wifi)
            SKIP_WIFI_PROFILE=1
            shift
            ;;
        *)
            log_warn "Argumen tidak dikenal: $1"
            shift
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    log_err "Harap jalankan sebagai root (gunakan sudo bash)!"
    exit 1
fi

echo "======================================================================"
echo "  SRPCOM Armbian Wi-Fi Auto-Detect + Smart WAN Failover Installer"
echo "======================================================================"

# 1. Deteksi Otomatis Tipe STB & Pasang Driver/Firmware Wi-Fi Internal
log_info "Langkah 1/5: Mendeteksi hardware Wi-Fi STB & memastikan driver/firmware aktif..."
curl -fsSL "${REPO_RAW}/install-driver.sh" | bash

# 2. Konfigurasi Dukungan USB Wi-Fi Eksternal (TP-Link TL-WN722N v1/v2/v3)
log_info "Langkah 2/5: Menyiapkan optimasi USB Wi-Fi eksternal (TL-WN722N)..."
cat > /etc/udev/rules.d/70-wifi-usb-power.rules <<'EOF'
# Disable USB autosuspend for TP-Link TL-WN722N (Atheros AR9271 & Realtek RTL8188EUS)
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0cf3", ATTR{idProduct}=="9271", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2357", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="8179", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="0179", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="f179", TEST=="power/control", ATTR{power/control}="on"
EOF

cat > /etc/modprobe.d/wifi-tlwn722n.conf <<'EOF'
options ath9k_htc ps_enable=0 blink=1
EOF
udevadm control --reload-rules 2>/dev/null || true

# 3. Optimasi Kernel Sysctl & DNS Fallback
log_info "Langkah 3/5: Mengatur sysctl multi-WAN (rp_filter loose & anti-ARP flux) serta DNS fallback..."
cat > /etc/sysctl.d/99-wan-failover.conf <<'EOF'
# Loose reverse path filter for multi-WAN per-interface health probing
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 2

# Prevent ARP flux if LAN and Wi-Fi happen to share the same subnet
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
EOF
sysctl -p /etc/sysctl.d/99-wan-failover.conf >/dev/null 2>&1 || true

mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-failover.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=9.9.9.9 1.0.0.1
EOF
systemctl reload-or-restart systemd-resolved 2>/dev/null || true
nmcli dev reapply "$LAN_IF" 2>/dev/null || true

# 4. Profil Wi-Fi NetworkManager Auto-Connect
log_info "Langkah 4/5: Menyiapkan profil koneksi Wi-Fi otomatis..."
if [ "$SKIP_WIFI_PROFILE" -eq 0 ] && [ -z "$WIFI_SSID" ] && [ -r /dev/tty ]; then
    printf "Masukkan Nama Wi-Fi (SSID) untuk failover [kosongkan jika ingin setel manual nanti]: " > /dev/tty
    read -r WIFI_SSID < /dev/tty || true
    if [ -n "$WIFI_SSID" ]; then
        printf "Masukkan Password Wi-Fi untuk '%s': " "$WIFI_SSID" > /dev/tty
        read -rs WIFI_PASS < /dev/tty || true
        echo "" > /dev/tty
    fi
fi

if [ -n "$WIFI_SSID" ]; then
    SAFE_NAME="$(echo "$WIFI_SSID" | tr -cd '[:alnum:]._-')"
    [ -z "$SAFE_NAME" ] && SAFE_NAME="wifi-backup"
    CON_FILE="/etc/NetworkManager/system-connections/${SAFE_NAME}.nmconnection"
    UUID_VAL="$(cat /proc/sys/kernel/random/uuid)"

    cat > "$CON_FILE" <<EOF
[connection]
id=${WIFI_SSID}
uuid=${UUID_VAL}
type=wifi
autoconnect=true
autoconnect-priority=10
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}
powersave=2

[ipv4]
method=auto
route-metric=500
dns-priority=50

[ipv6]
addr-gen-mode=default
method=auto
route-metric=500
dns-priority=50
EOF

    if [ -n "$WIFI_PASS" ]; then
        cat >> "$CON_FILE" <<EOF

[wifi-security]
key-mgmt=wpa-psk
psk=${WIFI_PASS}
EOF
    fi

    chmod 600 "$CON_FILE"
    chown root:root "$CON_FILE"
    nmcli con reload
    log_ok "Profil Wi-Fi auto-connect '${WIFI_SSID}' siap (metric 500)."
else
    log_warn "Tidak ada SSID Wi-Fi diberikan. Anda dapat menghubungkan Wi-Fi nanti dengan: nmcli dev wifi connect \"NAMA_WIFI\" password \"SANDI\""
fi

# 5. Pasang Layanan Smart WAN Failover & Failback Watchdog + Perintah cek-wan
log_info "Langkah 5/5: Memasang layanan failover & failback otomatis (LAN=${LAN_IF} utama <-> Wi-Fi cadangan)..."

cat > /usr/local/sbin/wan-failover.sh <<EOF
#!/bin/bash
set -u

LAN_IF="${LAN_IF}"
LAN_METRIC_PRIMARY=100
WIFI_METRIC=500
LAN_METRIC_BACKUP=900

STATE_DIR="/run/wan-failover"
STATE_FILE="\$STATE_DIR/state"
STATUS_FILE="\$STATE_DIR/status"
mkdir -p "\$STATE_DIR"

FAIL_THRESHOLD=2
OK_THRESHOLD=2
CHECK_INTERVAL=4

LAN_FAIL_COUNT=0
LAN_OK_COUNT=0
PREV_WAN="lan"
LAST_CF_RESTART=0
SLEEP_PID=""

handle_wakeup() {
    [ -n "\$SLEEP_PID" ] && kill "\$SLEEP_PID" 2>/dev/null || true
}
trap "" USR1 HUP

log_msg() {
    logger -t wan-failover "\$1"
    echo "\$(date '+%Y-%m-%d %H:%M:%S') \$1"
}

get_wifi_iface() {
    local wdev
    wdev=\$(nmcli -t -f DEVICE,TYPE,STATE dev 2>/dev/null | awk -F: '\$2=="wifi" && (\$3=="connected" || \$3=="terhubung") {print \$1; exit}')
    if [ -n "\$wdev" ]; then
        echo "\$wdev"
        return 0
    fi
    return 1
}

iface_has_ip_and_link() {
    local iface="\$1"
    [ -d "/sys/class/net/\$iface" ] || return 1
    local carrier
    carrier=\$(cat "/sys/class/net/\$iface/carrier" 2>/dev/null || echo "0")
    [ "\$carrier" = "1" ] || return 1
    ip -4 addr show dev "\$iface" 2>/dev/null | grep -q "inet " || return 1
    return 0
}

get_iface_gw() {
    local iface="\$1"
    local gw
    gw=\$(nmcli -t -f IP4.GATEWAY dev show "\$iface" 2>/dev/null | awk -F: 'NF>=2 && \$2!="" && \$2!="--" {print \$2; exit}')
    if [ -z "\$gw" ]; then
        gw=\$(ip -4 route show default dev "\$iface" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="via") {print \$(i+1); exit}}')
    fi
    echo "\$gw"
}

get_iface_ip() {
    local iface="\$1"
    ip -4 -o addr show dev "\$iface" 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1
}

ensure_iface_route_exists() {
    local iface="\$1"
    local target_metric="\$2"
    local gw ip_addr
    gw=\$(get_iface_gw "\$iface")
    ip_addr=\$(get_iface_ip "\$iface")
    [ -n "\$gw" ] && [ -n "\$ip_addr" ] || return 1

    local count
    count=\$(ip -4 route show default dev "\$iface" | grep -cE "\\bmetric \${target_metric}\\b" || true)
    if [ "\$count" -eq 0 ]; then
        ip -4 route replace default via "\$gw" dev "\$iface" proto static src "\$ip_addr" metric "\$target_metric" 2>/dev/null || true
    elif [ "\$count" -gt 1 ]; then
        ip -4 route del default via "\$gw" dev "\$iface" proto static metric "\$target_metric" 2>/dev/null || true
    fi

    ip -4 route show default dev "\$iface" | while read -r line; do
        if ! echo "\$line" | grep -qE "\\bmetric \${target_metric}\\b"; then
            local m
            m=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="metric") {print \$(i+1); exit}}')
            if [ -n "\$m" ]; then
                ip -4 route del default dev "\$iface" metric "\$m" 2>/dev/null || true
            else
                ip -4 route del default dev "\$iface" 2>/dev/null || true
            fi
        fi
    done
    return 0
}

check_internet() {
    local iface="\$1"
    iface_has_ip_and_link "\$iface" || return 1

    local gw ip_addr
    gw=\$(get_iface_gw "\$iface")
    ip_addr=\$(get_iface_ip "\$iface")
    [ -n "\$gw" ] && [ -n "\$ip_addr" ] || return 1

    if ! ip -4 route show default dev "\$iface" | grep -q "^default "; then
        local fallback_metric=900
        [ "\$iface" = "\$LAN_IF" ] || fallback_metric=\$WIFI_METRIC
        ip -4 route replace default via "\$gw" dev "\$iface" proto static src "\$ip_addr" metric "\$fallback_metric" 2>/dev/null || true
    fi

    if ping -I "\$iface" -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        return 0
    fi
    if ping -I "\$iface" -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        return 0
    fi
    if command -v curl >/dev/null 2>&1 && curl --interface "\$iface" -sf --connect-timeout 2 --max-time 3 -o /dev/null https://1.1.1.1/cdn-cgi/trace 2>/dev/null; then
        return 0
    fi

    return 1
}

apply_wan_mode() {
    local mode="\$1"
    local wifi_if="\$2"

    if [ "\$mode" = "wifi" ] && [ -n "\$wifi_if" ]; then
        ensure_iface_route_exists "\$wifi_if" "\$WIFI_METRIC" >/dev/null 2>&1 || true

        if iface_has_ip_and_link "\$LAN_IF"; then
            ensure_iface_route_exists "\$LAN_IF" "\$LAN_METRIC_BACKUP" >/dev/null 2>&1 || true
        fi

        ip -6 route show default dev "\$LAN_IF" 2>/dev/null | while read -r line; do
            local m6
            m6=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="metric") {print \$(i+1); exit}}')
            [ -n "\$m6" ] && [ "\$m6" -lt 900 ] 2>/dev/null && ip -6 route del default dev "\$LAN_IF" metric "\$m6" 2>/dev/null || true
        done

        if ! resolvectl dns "\$wifi_if" 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
            local wifi_gw
            wifi_gw=\$(get_iface_gw "\$wifi_if")
            [ -n "\$wifi_gw" ] && resolvectl dns "\$wifi_if" "\$wifi_gw" 1.1.1.1 8.8.8.8 >/dev/null 2>&1 || true
        fi
        resolvectl default-route "\$LAN_IF" false >/dev/null 2>&1 || true
        resolvectl default-route "\$wifi_if" true >/dev/null 2>&1 || true
    else
        if iface_has_ip_and_link "\$LAN_IF"; then
            ensure_iface_route_exists "\$LAN_IF" "\$LAN_METRIC_PRIMARY" >/dev/null 2>&1 || true
        fi
        if ! resolvectl dns "\$LAN_IF" 2>/dev/null | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
            local lan_gw
            lan_gw=\$(get_iface_gw "\$LAN_IF")
            [ -n "\$lan_gw" ] && resolvectl dns "\$LAN_IF" "\$lan_gw" 1.1.1.1 8.8.8.8 >/dev/null 2>&1 || true
        fi
        resolvectl default-route "\$LAN_IF" true >/dev/null 2>&1 || true
        if [ -n "\$wifi_if" ]; then
            ensure_iface_route_exists "\$wifi_if" "\$WIFI_METRIC" >/dev/null 2>&1 || true
            resolvectl default-route "\$wifi_if" false >/dev/null 2>&1 || true
        fi
    fi
}

restart_cloudflared_if_needed() {
    local now
    now=\$(date +%s)
    if [ \$((now - LAST_CF_RESTART)) -ge 15 ]; then
        LAST_CF_RESTART=\$now
        if systemctl is-active --quiet cloudflared 2>/dev/null; then
            log_msg "Restarting cloudflared to bind to new active WAN interface..."
            systemctl restart cloudflared --no-block 2>/dev/null || true
        fi
    fi
}

if [ -f "\$STATE_FILE" ]; then
    PREV_WAN=\$(cat "\$STATE_FILE" 2>/dev/null || echo "lan")
fi

log_msg "WAN Failover daemon started (LAN=\$LAN_IF primary metric \$LAN_METRIC_PRIMARY, WiFi backup metric \$WIFI_METRIC)"

while true; do
    WIFI_IF=\$(get_wifi_iface || true)
    LAN_ONLINE=0
    WIFI_ONLINE=0

    if ! iface_has_ip_and_link "\$LAN_IF"; then
        LAN_ONLINE=0
        LAN_FAIL_COUNT=\$FAIL_THRESHOLD
        LAN_OK_COUNT=0
    else
        if check_internet "\$LAN_IF"; then
            LAN_ONLINE=1
            LAN_FAIL_COUNT=0
            LAN_OK_COUNT=\$((LAN_OK_COUNT + 1))
        else
            LAN_ONLINE=0
            LAN_OK_COUNT=0
            LAN_FAIL_COUNT=\$((LAN_FAIL_COUNT + 1))
        fi
    fi

    DESIRED_WAN="\$PREV_WAN"

    if [ "\$LAN_ONLINE" -eq 1 ]; then
        if [ "\$PREV_WAN" = "wifi" ]; then
            if [ "\$LAN_OK_COUNT" -ge "\$OK_THRESHOLD" ]; then
                DESIRED_WAN="lan"
            fi
        else
            DESIRED_WAN="lan"
        fi
    else
        if [ -n "\$WIFI_IF" ] && iface_has_ip_and_link "\$WIFI_IF"; then
            if [ "\$LAN_FAIL_COUNT" -ge "\$FAIL_THRESHOLD" ]; then
                if check_internet "\$WIFI_IF"; then
                    WIFI_ONLINE=1
                    DESIRED_WAN="wifi"
                elif ! iface_has_ip_and_link "\$LAN_IF"; then
                    DESIRED_WAN="wifi"
                fi
            fi
        else
            DESIRED_WAN="lan"
        fi
    fi

    apply_wan_mode "\$DESIRED_WAN" "\$WIFI_IF"

    if [ "\$DESIRED_WAN" != "\$PREV_WAN" ]; then
        log_msg "ACTIVE WAN SWITCHED: \$PREV_WAN -> \$DESIRED_WAN (LAN_ONLINE=\$LAN_ONLINE, WIFI_IF=\${WIFI_IF:-none}, WIFI_ONLINE=\$WIFI_ONLINE)"
        echo "\$DESIRED_WAN" > "\$STATE_FILE"
        resolvectl flush-caches >/dev/null 2>&1 || true
        restart_cloudflared_if_needed
        PREV_WAN="\$DESIRED_WAN"
    else
        [ -f "\$STATE_FILE" ] || echo "\$DESIRED_WAN" > "\$STATE_FILE"
    fi

    cat > "\$STATUS_FILE" <<STATUS_EOF
ACTIVE_WAN=\$DESIRED_WAN
LAN_IF=\$LAN_IF
LAN_ONLINE=\$LAN_ONLINE
LAN_FAIL_COUNT=\$LAN_FAIL_COUNT
LAN_OK_COUNT=\$LAN_OK_COUNT
WIFI_IF=\${WIFI_IF:-none}
WIFI_ONLINE=\$WIFI_ONLINE
UPDATED_AT=\$(date '+%Y-%m-%d %H:%M:%S')
STATUS_EOF

    trap handle_wakeup USR1 HUP
    sleep "\$CHECK_INTERVAL" &
    SLEEP_PID=\$!
    wait "\$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
    trap "" USR1 HUP
done
EOF
chmod 755 /usr/local/sbin/wan-failover.sh

cat > /etc/NetworkManager/dispatcher.d/99-wan-failover <<EOF
#!/bin/bash
IFACE="\$1"
ACTION="\$2"
STATE_FILE="/run/wan-failover/state"

case "\$ACTION" in
    up|dhcp4-change|down|connectivity-change)
        if [ "\$IFACE" = "${LAN_IF}" ] && { [ "\$ACTION" = "up" ] || [ "\$ACTION" = "dhcp4-change" ]; }; then
            if [ -f "\$STATE_FILE" ] && [ "\$(cat "\$STATE_FILE" 2>/dev/null)" = "wifi" ]; then
                GW=\$(nmcli -t -f IP4.GATEWAY dev show "${LAN_IF}" 2>/dev/null | awk -F: 'NF>=2 && \$2!="" && \$2!="--" {print \$2; exit}')
                IP=\$(ip -4 -o addr show dev "${LAN_IF}" 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -n1)
                if [ -n "\$GW" ] && [ -n "\$IP" ]; then
                    ip -4 route replace default via "\$GW" dev "${LAN_IF}" proto static src "\$IP" metric 900 2>/dev/null || true
                    ip -4 route show default dev "${LAN_IF}" 2>/dev/null | while read -r line; do
                        if ! echo "\$line" | grep -qE "\\bmetric 900\\b"; then
                            m=\$(echo "\$line" | awk '{for(i=1;i<=NF;i++) if(\$i=="metric") {print \$(i+1); exit}}')
                            if [ -n "\$m" ]; then
                                ip -4 route del default dev "${LAN_IF}" metric "\$m" 2>/dev/null || true
                            else
                                ip -4 route del default dev "${LAN_IF}" 2>/dev/null || true
                            fi
                        fi
                    done
                fi
                resolvectl default-route "${LAN_IF}" false >/dev/null 2>&1 || true
            fi
        fi
        systemctl kill --kill-who=main -s USR1 wan-failover.service 2>/dev/null || true
        ;;
esac
exit 0
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/99-wan-failover
chown root:root /etc/NetworkManager/dispatcher.d/99-wan-failover

cat > /etc/systemd/system/wan-failover.service <<'EOF'
[Unit]
Description=Smart LAN Primary + Wi-Fi Internet Failover & Failback Watchdog
After=NetworkManager.service systemd-resolved.service
Wants=NetworkManager.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/wan-failover.sh
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat > /usr/local/bin/cek-wan <<'EOF'
#!/bin/bash
echo "=== STATUS WAN FAILOVER ==="
cat /run/wan-failover/status 2>/dev/null || echo "Status belum tersedia"
echo ""
echo "=== TABEL RUTE DEFAULT ==="
ip -4 route show default
echo ""
echo "=== PERANGKAT JARINGAN ==="
nmcli dev
echo ""
echo "=== STATUS DNS (RESOLVECTL) ==="
resolvectl status | grep -E "Link |Current DNS|DNS Servers|Protocols"
EOF
chmod 755 /usr/local/bin/cek-wan

systemctl daemon-reload
systemctl enable wan-failover.service
systemctl restart wan-failover.service

sleep 4
log_ok "Instalasi lengkap selesai! Anda dapat memantau status jalur internet dengan perintah: cek-wan"
/usr/local/bin/cek-wan
