#!/bin/bash
# ==============================================================================
# Installer Driver Wi-Fi Internal Realtek RTL8189FTV/FS (8189fs)
# Untuk STB ZTE B860H / S905X (Armbian Debian/Ubuntu aarch64)
# Repo: https://github.com/srpcom/b860h-wifi-8189fs-armbian
# ==============================================================================
set -e

REPO_RAW="https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main"
KVER="$(uname -r)"
ARCH="$(uname -m)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }

if [ "$(id -u)" -ne 0 ]; then
    log_err "Harap jalankan sebagai root (gunakan sudo bash)!"
    exit 1
fi

log_info "Mendeteksi STB: Arch=$ARCH | Kernel=$KVER"

# Cek SDIO chip 024c:f179
if grep -rqi "024c" /sys/bus/sdio/devices/*/vendor 2>/dev/null; then
    log_ok "Chip Wi-Fi internal Realtek SDIO terdeteksi pada perangkat keras."
else
    log_warn "Perangkat SDIO Realtek (024c:f179) tidak terdeteksi saat ini, tetap melanjutkan instalasi modul."
fi

# Cek jika modul sudah terpasang dan aktif
if lsmod | grep -q "^8189fs"; then
    log_ok "Modul 8189fs sudah aktif di kernel saat ini."
    ip -brief link show | grep wlan || true
    exit 0
fi

# 1. Jalur Cepat: Coba download paket .deb prebuilt sesuai versi kernel
DEB_URL="${REPO_RAW}/prebuilt/${KVER}/rtl8189fs-${KVER}_arm64.deb"
TMP_DEB="/tmp/rtl8189fs-${KVER}_arm64.deb"

if command -v curl >/dev/null 2>&1 && curl -fsSLI "$DEB_URL" >/dev/null 2>&1; then
    log_info "Paket prebuilt ditemukan untuk kernel ${KVER}! Mengunduh paket .deb..."
    curl -fsSL "$DEB_URL" -o "$TMP_DEB"
    log_info "Memasang paket .deb..."
    dpkg -i "$TMP_DEB" || apt-get install -f -y
    rm -f "$TMP_DEB"
    depmod -a "$KVER" || true
    modprobe 8189fs || true
else
    log_warn "Paket prebuilt untuk kernel ${KVER} tidak tersedia. Beralih ke mode kompilasi otomatis (Auto-Compile)..."

    # Pastikan paket build tools terpasang
    NEED_PKGS=""
    for tool in git gcc make bc strip; do
        command -v "$tool" >/dev/null 2>&1 || NEED_PKGS="$NEED_PKGS $tool"
    done
    if [ -n "$NEED_PKGS" ]; then
        log_info "Menginstal dependensi build:$NEED_PKGS ..."
        apt-get update -qq
        apt-get install -y build-essential git bc
    fi

    KSRC="/lib/modules/${KVER}/build"
    if [ ! -d "$KSRC" ]; then
        log_err "Direktori kernel headers ($KSRC) tidak ditemukan! Silakan pasang linux-headers-${KVER} terlebih dahulu."
        exit 1
    fi

    BUILD_DIR="/tmp/rtl8189fs-build"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"

    log_info "Mengkloning source driver jwrdegoede/rtl8189ES_linux (branch rtl8189fs)..."
    git clone --depth 1 --branch rtl8189fs https://github.com/jwrdegoede/rtl8189ES_linux.git "$BUILD_DIR/src"

    # Deteksi backport API cfg80211 pada kernel Linux 6.18+ (PR #149 jwrdegoede/rtl8189ES_linux)
    CFG_HDR="$KSRC/include/net/cfg80211.h"
    CFG_SRC="$BUILD_DIR/src/os_dep/linux/ioctl_cfg80211.c"
    if [ -f "$CFG_HDR" ] && [ -f "$CFG_SRC" ]; then
        if awk '/^void cfg80211_new_sta\(/,/\);/' "$CFG_HDR" | grep -q "struct wireless_dev"; then
            log_info "Mendeteksi API cfg80211 wireless_dev (backport 7.1 -> ${KVER}), menyesuaikan ioctl_cfg80211.c..."
            sed -i 's/KERNEL_VERSION(7, 1, 0)/KERNEL_VERSION(6, 18, 0)/g' "$CFG_SRC"
        fi
        if awk '/\(\*remain_on_channel\)\(/,/\);/' "$CFG_HDR" | grep -q "rx_addr"; then
            log_info "Mendeteksi parameter rx_addr / strscpy (backport 7.2 -> ${KVER}), menyesuaikan ioctl_cfg80211.c..."
            sed -i 's/KERNEL_VERSION(7, 2, 0)/KERNEL_VERSION(6, 18, 0)/g' "$CFG_SRC"
        fi
        if awk '/\(\*mgmt_tx\)\(/,/\);/' "$CFG_HDR" | grep -qE "u64[[:space:]]+cookie"; then
            log_info "Mendeteksi parameter u64 cookie by-value (backport 7.3 -> ${KVER}), menyesuaikan ioctl_cfg80211.c..."
            sed -i 's/KERNEL_VERSION(7, 3, 0)/KERNEL_VERSION(6, 18, 0)/g' "$CFG_SRC"
        fi
        if awk '/\(\*add_key\)\(/,/\);/' "$CFG_HDR" | grep -q "nl80211_key_type"; then
            log_info "Mendeteksi enum nl80211_key_type pada add_key/get_key/del_key, menyesuaikan ioctl_cfg80211.c..."
            python3 - "$CFG_SRC" <<'PYEOF'
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
    fi

    # Buat GCC wrapper agar kompatibel dengan kernel yang dibangun dengan GCC versi lebih baru (flag -fmin-function-alignment)
    GCC_WRAP="$BUILD_DIR/gcc-wrap"
    cat > "$GCC_WRAP" <<'EOF'
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
    chmod +x "$GCC_WRAP"

    # Cek apakah binary scripts/mod/modpost mengalami error GLIBC mismatch
    if [ -x "$KSRC/scripts/mod/modpost" ]; then
        if "$KSRC/scripts/mod/modpost" 2>&1 | grep -q "GLIBC_"; then
            log_warn "Biner modpost bawaan headers membutuhkan GLIBC lebih baru. Mengompilasi ulang modpost secara native..."
            if [ ! -f "$KSRC/scripts/mod/modpost.orig" ]; then
                cp "$KSRC/scripts/mod/modpost" "$KSRC/scripts/mod/modpost.orig"
            fi
            (
                cd "$KSRC/scripts/mod"
                /usr/bin/gcc -O2 -I. -I../include -o "$KSRC/scripts/mod/modpost" modpost.c file2alias.c sumversion.c symsearch.c
            )
            log_ok "modpost berhasil disesuaikan dengan GLIBC sistem."
        fi
    fi

    log_info "Mengompilasi modul kernel 8189fs.ko (estimasi 1-3 menit)..."
    cd "$BUILD_DIR/src"
    make -j"$(nproc)" ARCH=arm64 KSRC="$KSRC" CC="$GCC_WRAP" HOSTCC=/usr/bin/gcc modules

    strip --strip-unneeded 8189fs.ko || true
    mkdir -p "/lib/modules/${KVER}/extra"
    install -p -m 644 8189fs.ko "/lib/modules/${KVER}/extra/8189fs.ko"

    cat > /etc/modprobe.d/99-b860h-8189fs.conf <<'EOF'
options 8189fs rtw_power_mgnt=0 rtw_ips_mode=0 rtw_enusbss=0 rtw_drv_log_level=1 rtw_country_code=ID
EOF
    echo "8189fs" > /etc/modules-load.d/b860h-8189fs.conf

    depmod -a "$KVER"
    modprobe 8189fs
    rm -rf "$BUILD_DIR"
fi

sleep 2
if lsmod | grep -q "^8189fs"; then
    log_ok "Driver 8189fs berhasil dipasang dan aktif!"
    echo ""
    ip -brief link show | grep wlan || true
    command -v nmcli >/dev/null 2>&1 && nmcli dev | grep -E "DEVICE|wifi" || true
else
    log_err "Modul 8189fs terpasang tetapi gagal dimuat. Periksa 'dmesg | tail -n 30'."
    exit 1
fi
