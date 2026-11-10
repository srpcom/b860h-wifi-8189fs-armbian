#!/bin/bash
# ==============================================================================
# Universal Installer Driver Wi-Fi STB Armbian (SDIO & USB Auto-Detect)
# Mendukung:
#   - ZTE B860H / S905X P212 : SDIO Realtek RTL8189FTV/FS (8189fs) & RTL8189ES (8189es)
#   - Fiberhome HG680-P / HG860P : USB Internal RTL8188EUS (0bda:8179 -> rtl8xxxu + firmware)
#   - USB Wi-Fi Eksternal : TP-Link TL-WN722N v1 (ath9k_htc) & v2/v3 (rtl8xxxu)
# Repo: https://github.com/srpcom/b860h-wifi-8189fs-armbian
# ==============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main"
KVER="$(uname -r)"
ARCH="$(uname -m)"
BOARD_MODEL="$(tr -d '\0' </proc/device-tree/model 2>/dev/null || echo 'Unknown')"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }

FORCE_8189FS=0
for arg in "$@"; do
    case "$arg" in
        --force-8189fs) FORCE_8189FS=1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    log_err "Harap jalankan sebagai root (gunakan sudo bash)!"
    exit 1
fi

has_wifi_iface() {
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -qE '^wl'
}

ensure_downloader() {
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        log_info "Memasang curl untuk mengunduh paket/firmware..."
        apt-get update -qq
        apt-get install -y curl ca-certificates
    fi
}

download_file() {
    local url="$1"
    local dest="$2"
    ensure_downloader
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest"
    else
        wget -qO "$dest" "$url"
    fi
}

remote_file_exists() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSLI "$url" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --spider "$url" >/dev/null 2>&1
    else
        return 1
    fi
}

ensure_build_tools() {
    local need_pkgs=""
    for tool in git gcc make bc strip; do
        command -v "$tool" >/dev/null 2>&1 || need_pkgs="$need_pkgs $tool"
    done
    if [ -n "$need_pkgs" ]; then
        log_info "Menginstal dependensi build:$need_pkgs ..."
        apt-get update -qq
        apt-get install -y build-essential git bc
    fi
}

patch_cfg80211_backports() {
    local ksrc="$1"
    local cfg_src="$2"
    local cfg_hdr="$ksrc/include/net/cfg80211.h"

    [ -f "$cfg_hdr" ] && [ -f "$cfg_src" ] || return 0

    if awk '/^void cfg80211_new_sta\(/,/\);/' "$cfg_hdr" | grep -q "struct wireless_dev"; then
        log_info "Mendeteksi API cfg80211 wireless_dev (backport 7.1 -> ${KVER}), menyesuaikan ioctl_cfg80211.c..."
        sed -i 's/KERNEL_VERSION(7, 1, 0)/KERNEL_VERSION(6, 18, 0)/g' "$cfg_src"
    fi
    if awk '/\(\*remain_on_channel\)\(/,/\);/' "$cfg_hdr" | grep -q "rx_addr"; then
        log_info "Mendeteksi parameter rx_addr / strscpy (backport 7.2 -> ${KVER}), menyesuaikan ioctl_cfg80211.c..."
        sed -i 's/KERNEL_VERSION(7, 2, 0)/KERNEL_VERSION(6, 18, 0)/g' "$cfg_src"
    fi
    if awk '/\(\*mgmt_tx\)\(/,/\);/' "$cfg_hdr" | grep -qE "u64[[:space:]]+cookie"; then
        log_info "Mendeteksi parameter u64 cookie by-value (backport 7.3 -> ${KVER}), menyesuaikan ioctl_cfg80211.c..."
        sed -i 's/KERNEL_VERSION(7, 3, 0)/KERNEL_VERSION(6, 18, 0)/g' "$cfg_src"
    fi
    if awk '/\(\*add_key\)\(/,/\);/' "$cfg_hdr" | grep -q "nl80211_key_type" && command -v python3 >/dev/null 2>&1; then
        log_info "Mendeteksi enum nl80211_key_type pada add_key/get_key/del_key, menyesuaikan ioctl_cfg80211.c..."
        python3 - "$cfg_src" <<'PYEOF'
import sys, re
p = sys.argv[1]
with open(p, 'r') as f:
    s = f.read()
s = re.sub(
    r'(static int cfg80211_rtw_(?:add|get)_key\(.*?\n#endif\n\s*), bool pairwise\b',
    r'\1, enum nl80211_key_type type',
    s,
    flags=re.DOTALL
)
s = s.replace('u8 key_index, bool pairwise, const u8 *mac_addr', 'u8 key_index, enum nl80211_key_type type, const u8 *mac_addr')
for fn in ['cfg80211_rtw_add_key', 'cfg80211_rtw_get_key', 'cfg80211_rtw_del_key']:
    idx = s.find(fn + '(')
    if idx != -1:
        brace = s.find('\n{\n', idx)
        if brace != -1:
            s = s[:brace+3] + '\tbool pairwise = (type == NL80211_KEYTYPE_PAIRWISE);\n' + s[brace+3:]
with open(p, 'w') as f:
    f.write(s)
PYEOF
    fi
}

prepare_kbuild_env() {
    local ksrc="$1"
    local build_dir="$2"
    local gcc_wrap="$build_dir/gcc-wrap"

    cat > "$gcc_wrap" <<'EOF'
#!/bin/bash
args=()
for a in "$@"; do
    case "$a" in
        -fmin-function-alignment=*)
            if ! /usr/bin/gcc -Q --help=optimizers 2>/dev/null | grep -q "fmin-function-alignment"; then
                args+=("-falign-functions=${a#-fmin-function-alignment=}")
            else
                args+=("$a")
            fi
            ;;
        *)
            args+=("$a")
            ;;
    esac
done
exec /usr/bin/gcc "${args[@]}"
EOF
    chmod +x "$gcc_wrap"

    if [ -x "$ksrc/scripts/mod/modpost" ]; then
        if "$ksrc/scripts/mod/modpost" 2>&1 | grep -q "GLIBC_"; then
            log_warn "Biner modpost bawaan headers membutuhkan GLIBC lebih baru. Mengompilasi ulang modpost secara native..."
            if [ ! -f "$ksrc/scripts/mod/modpost.orig" ]; then
                cp "$ksrc/scripts/mod/modpost" "$ksrc/scripts/mod/modpost.orig"
            fi
            (
                cd "$ksrc/scripts/mod"
                /usr/bin/gcc -O2 -I. -I../include -o "$ksrc/scripts/mod/modpost" modpost.c file2alias.c sumversion.c symsearch.c
            )
            log_ok "modpost berhasil disesuaikan dengan GLIBC sistem."
        fi
    fi
}

compile_jwrdegoede_sdio() {
    local modname="$1"
    local branch="$2"
    local modopts="$3"

    ensure_build_tools

    local ksrc="/lib/modules/${KVER}/build"
    if [ ! -d "$ksrc" ]; then
        log_err "Direktori kernel headers ($ksrc) tidak ditemukan! Silakan pasang linux-headers-${KVER} terlebih dahulu."
        return 1
    fi

    local build_dir="/tmp/rtl${modname}-build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    log_info "Mengkloning source driver jwrdegoede/rtl8189ES_linux (branch ${branch})..."
    git clone --depth 1 --branch "$branch" https://github.com/jwrdegoede/rtl8189ES_linux.git "$build_dir/src"

    patch_cfg80211_backports "$ksrc" "$build_dir/src/os_dep/linux/ioctl_cfg80211.c"
    prepare_kbuild_env "$ksrc" "$build_dir"

    log_info "Mengompilasi modul kernel ${modname}.ko (estimasi 1-3 menit)..."
    (
        cd "$build_dir/src"
        make -j"$(nproc)" ARCH=arm64 KSRC="$ksrc" CC="$build_dir/gcc-wrap" HOSTCC=/usr/bin/gcc modules
        strip --strip-unneeded "${modname}.ko" || true
        mkdir -p "/lib/modules/${KVER}/extra"
        install -p -m 644 "${modname}.ko" "/lib/modules/${KVER}/extra/${modname}.ko"
    )

    cat > "/etc/modprobe.d/99-b860h-${modname}.conf" <<EOF
options ${modname} ${modopts}
EOF
    echo "${modname}" > "/etc/modules-load.d/b860h-${modname}.conf"

    depmod -a "$KVER"
    modprobe "$modname"
    rm -rf "$build_dir"
}

install_sdio_realtek() {
    local modname="$1"
    local branch="$2"
    local modopts="$3"

    if lsmod | grep -q "^${modname} "; then
        log_ok "Modul ${modname} sudah aktif di kernel saat ini."
        return 0
    fi

    if modinfo "$modname" >/dev/null 2>&1; then
        log_info "Modul ${modname} sudah ada di /lib/modules/${KVER}, memuat modul..."
        echo "${modname}" > "/etc/modules-load.d/b860h-${modname}.conf"
        if modprobe "$modname"; then
            log_ok "Modul ${modname} berhasil dimuat."
            return 0
        fi
    fi

    if [ "$modname" = "8189fs" ]; then
        local deb_url="${REPO_RAW}/prebuilt/${KVER}/rtl8189fs-${KVER}_arm64.deb"
        local tmp_deb="/tmp/rtl8189fs-${KVER}_arm64.deb"
        if remote_file_exists "$deb_url"; then
            log_info "Paket prebuilt ditemukan untuk kernel ${KVER}! Mengunduh paket .deb..."
            download_file "$deb_url" "$tmp_deb"
            log_info "Memasang paket .deb..."
            dpkg -i "$tmp_deb" || apt-get install -f -y
            rm -f "$tmp_deb"
            depmod -a "$KVER" || true
            modprobe 8189fs || true
            return 0
        fi
    fi

    log_warn "Paket prebuilt ${modname} untuk kernel ${KVER} tidak tersedia. Beralih ke mode Auto-Compile..."
    compile_jwrdegoede_sdio "$modname" "$branch" "$modopts"
}

install_usb_rtlwifi() {
    local fw_dir="/lib/firmware/rtlwifi"
    local fw_list="rtl8188eufw.bin rtl8188fufw.bin rtl8188efw.bin rtl8192eu_nic.bin"
    local fw_added=0

    mkdir -p "$fw_dir"
    for fw in $fw_list; do
        if [ ! -s "${fw_dir}/${fw}" ]; then
            log_info "Mengunduh firmware USB Wi-Fi yang hilang: rtlwifi/${fw}..."
            if download_file "${REPO_RAW}/firmware/rtlwifi/${fw}" "${fw_dir}/${fw}.tmp"; then
                mv -f "${fw_dir}/${fw}.tmp" "${fw_dir}/${fw}"
                chmod 644 "${fw_dir}/${fw}"
                fw_added=1
            else
                rm -f "${fw_dir}/${fw}.tmp"
                log_warn "Gagal mengunduh firmware ${fw}, melanjutkan..."
            fi
        fi
    done

    if [ ! -f /etc/udev/rules.d/70-wifi-usb-power.rules ]; then
        cat > /etc/udev/rules.d/70-wifi-usb-power.rules <<'EOF'
# Disable USB autosuspend for internal/external Realtek & Atheros Wi-Fi
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0cf3", ATTR{idProduct}=="9271", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="2357", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="8179", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="0179", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="f179", TEST=="power/control", ATTR{power/control}="on"
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0bda", ATTR{idProduct}=="818b", TEST=="power/control", ATTR{power/control}="on"
EOF
        udevadm control --reload-rules 2>/dev/null || true
    fi

    if [ "$fw_added" -eq 1 ] || ! has_wifi_iface; then
        log_info "Memuat ulang driver kernel rtl8xxxu agar membaca firmware baru..."
        modprobe -r rtl8xxxu 2>/dev/null || true
        sleep 1
        modprobe rtl8xxxu || true
    else
        log_ok "Firmware Realtek USB Wi-Fi (/lib/firmware/rtlwifi) sudah lengkap dan aktif."
    fi
}

install_usb_ath9k() {
    if [ ! -e /lib/firmware/ath9k_htc/htc_9271-1.4.0.fw ] && [ ! -e /lib/firmware/htc_9271.fw ]; then
        log_warn "Firmware ath9k_htc (htc_9271) belum ditemukan, mencoba memasang firmware-atheros..."
        apt-get update -qq && apt-get install -y firmware-atheros || true
    fi
    modprobe ath9k_htc || true
}

# ==============================================================================
# Deteksi Hardware Wi-Fi Otomatis (SDIO & USB)
# ==============================================================================
log_info "Mendeteksi STB: Board=\"$BOARD_MODEL\" | Arch=$ARCH | Kernel=$KVER"

NEED_8189FS=0
NEED_8189ES=0
NEED_USB_RTLWIFI=0
NEED_USB_ATH9K=0
BUILTIN_SDIO_MOD=""
DETECTED_COUNT=0

for dev in /sys/bus/sdio/devices/*; do
    [ -e "$dev" ] || continue
    vendor="$(tr '[:upper:]' '[:lower:]' < "$dev/vendor" 2>/dev/null || true)"
    device="$(tr '[:upper:]' '[:lower:]' < "$dev/device" 2>/dev/null || true)"
    vendor="${vendor#0x}"
    device="${device#0x}"
    case "${vendor}:${device}" in
        024c:f179)
            NEED_8189FS=1
            DETECTED_COUNT=$((DETECTED_COUNT + 1))
            log_ok "Terdeteksi Wi-Fi SDIO Internal: Realtek RTL8189FTV/FS (024c:f179 -> driver 8189fs)"
            ;;
        024c:8179|024c:8189)
            NEED_8189ES=1
            DETECTED_COUNT=$((DETECTED_COUNT + 1))
            log_ok "Terdeteksi Wi-Fi SDIO Internal: Realtek RTL8189ES (${vendor}:${device} -> driver 8189es)"
            ;;
        024c:b723|024c:d723)
            BUILTIN_SDIO_MOD="r8723bs"
            DETECTED_COUNT=$((DETECTED_COUNT + 1))
            log_ok "Terdeteksi Wi-Fi SDIO Internal: Realtek RTL8723 (${vendor}:${device})"
            ;;
        02d0:*)
            BUILTIN_SDIO_MOD="brcmfmac"
            DETECTED_COUNT=$((DETECTED_COUNT + 1))
            log_ok "Terdeteksi Wi-Fi SDIO Internal: Broadcom/Ampak (${vendor}:${device} -> driver brcmfmac)"
            ;;
        3030:3030)
            BUILTIN_SDIO_MOD="ssv6051"
            DETECTED_COUNT=$((DETECTED_COUNT + 1))
            log_ok "Terdeteksi Wi-Fi SDIO Internal: SSV6051 (${vendor}:${device} -> driver ssv6051)"
            ;;
    esac
done

for dev in /sys/bus/usb/devices/*; do
    [ -f "$dev/idVendor" ] && [ -f "$dev/idProduct" ] || continue
    vid="$(tr '[:upper:]' '[:lower:]' < "$dev/idVendor" 2>/dev/null || true)"
    pid="$(tr '[:upper:]' '[:lower:]' < "$dev/idProduct" 2>/dev/null || true)"
    case "${vid}:${pid}" in
        0bda:8179|0bda:0179|0bda:f179|0bda:818b|0bda:b711|0bda:8176|0bda:8178|2357:010c|2357:0111|2357:0107|2357:0108|2357:0109)
            NEED_USB_RTLWIFI=1
            DETECTED_COUNT=$((DETECTED_COUNT + 1))
            log_ok "Terdeteksi Wi-Fi USB (Internal HG680-P / Dongle): Realtek (${vid}:${pid} -> driver rtl8xxxu + firmware)"
            ;;
        0cf3:9271)
            NEED_USB_ATH9K=1
            DETECTED_COUNT=$((DETECTED_COUNT + 1))
            log_ok "Terdeteksi Wi-Fi USB: Atheros AR9271 / TL-WN722N v1 (${vid}:${pid} -> driver ath9k_htc)"
            ;;
    esac
done

# Eksekusi instalasi sesuai perangkat yang terdeteksi
if [ "$NEED_8189FS" -eq 1 ]; then
    install_sdio_realtek "8189fs" "rtl8189fs" "rtw_power_mgnt=0 rtw_ips_mode=0 rtw_enusbss=0 rtw_drv_log_level=1 rtw_country_code=ID"
fi

if [ "$NEED_8189ES" -eq 1 ]; then
    install_sdio_realtek "8189es" "master" "rtw_power_mgnt=0 rtw_ips_mode=0 rtw_drv_log_level=1 rtw_country_code=ID"
fi

if [ -n "$BUILTIN_SDIO_MOD" ]; then
    modprobe "$BUILTIN_SDIO_MOD" || log_warn "Gagal memuat modul $BUILTIN_SDIO_MOD (periksa firmware/ketersediaan modul kernel)."
fi

if [ "$NEED_USB_RTLWIFI" -eq 1 ]; then
    install_usb_rtlwifi
fi

if [ "$NEED_USB_ATH9K" -eq 1 ]; then
    install_usb_ath9k
fi

if [ "$DETECTED_COUNT" -eq 0 ]; then
    if [ "$FORCE_8189FS" -eq 1 ]; then
        log_warn "Mode paksa --force-8189fs aktif, melanjutkan pemasangan driver 8189fs..."
        install_sdio_realtek "8189fs" "rtl8189fs" "rtw_power_mgnt=0 rtw_ips_mode=0 rtw_enusbss=0 rtw_drv_log_level=1 rtw_country_code=ID"
    elif has_wifi_iface; then
        log_ok "Interface Wi-Fi sudah aktif pada sistem."
    else
        log_warn "Tidak ada chip Wi-Fi SDIO/USB yang dikenali di /sys/bus/. Mencoba fallback pemasangan driver 8189fs..."
        install_sdio_realtek "8189fs" "rtl8189fs" "rtw_power_mgnt=0 rtw_ips_mode=0 rtw_enusbss=0 rtw_drv_log_level=1 rtw_country_code=ID"
    fi
fi

if ! has_wifi_iface; then
    sleep 2
fi
if has_wifi_iface; then
    log_ok "Driver Wi-Fi berhasil dipasang dan interface wireless aktif!"
    echo ""
    ip -brief link show | grep -E "^wl" || true
    command -v nmcli >/dev/null 2>&1 && nmcli dev | grep -E "DEVICE|wifi" || true
else
    log_err "Driver selesai diproses tetapi interface wlan belum muncul. Periksa 'dmesg | tail -n 30'."
    exit 1
fi
