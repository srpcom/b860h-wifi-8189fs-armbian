# Auto-Installer Driver Wi-Fi STB Armbian — Tipe B (`ZTE B860H`) & Tipe HG (`Fiberhome HG680-P / HG860P`)

Satu skrip untuk **kedua tipe STB Armbian (Amlogic S905X / Debian & Ubuntu, kernel `6.12.x` – `6.18.x+`)**. Skrip otomatis mendeteksi chipset Wi-Fi internal STB (**Tipe B** maupun **Tipe HG**) lewat bus **SDIO** dan **USB**, sehingga Anda cukup menjalankan **1 baris perintah yang sama** tanpa perlu memilih driver secara manual.

---

## Dukungan STB (Tipe B & Tipe HG)

| Tipe STB | Chip Wi-Fi Terdeteksi | Driver / Mekanisme | Penanganan Otomatis Skrip |
| :--- | :--- | :--- | :--- |
| **Tipe B — ZTE B860H** (`v1` / `v2` / S905X) | SDIO `024c:f179` (`RTL8189FTV/FS`) / `024c:8179` (`RTL8189ES`) | `8189fs` / `8189es` | Memasang paket `.deb` *prebuilt* (`6.12.111-ophub`) atau *Auto-Compile* dengan patch kernel `6.18+`, wrapper GCC & `modpost` |
| **Tipe HG — Fiberhome HG680-P / HG860P** *(Varian USB Internal)* | USB Internal `0bda:8179` (`RTL8188EUS`) | `rtl8xxxu` (bawaan kernel) | Mengunduh otomatis `/lib/firmware/rtlwifi/*.bin` yang hilang di image Armbian & memuat ulang `rtl8xxxu` (~2 detik, tanpa kompilasi) |
| **Tipe HG — Fiberhome HG860P v2 / Board P212** *(Varian SDIO)* | SDIO `024c:f179` / `024c:8179` | `8189fs` / `8189es` | Sama seperti Tipe B: *Auto-Compile* + penyesuaian otomatis API `cfg80211` pada kernel `6.18.56-ophub` ke atas |
| **USB Wi-Fi Eksternal (`TP-Link TL-WN722N` v1 / v2 / v3)** | USB `0cf3:9271`, `0bda:*`, `2357:*` | `ath9k_htc` / `rtl8xxxu` | Melengkapi firmware, aturan `udev` anti-autosuspend, serta integrasi penuh ke sistem failover |

---

## Pilih Salah Satu Mode Instalasi

Gunakan **perintah yang sama** baik untuk **STB Tipe B (`B860H`)** maupun **STB Tipe HG (`HG680-P` / `HG860P`)**:

### Opsi 1: Pasang Driver & Firmware Wi-Fi Internal Saja
Otomatis mengenali tipe STB (SDIO `8189fs`/`8189es` atau USB `rtl8xxxu`), memasang driver/firmware yang sesuai, dan mengaktifkan `wlan0`:

```bash
curl -sSL https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main/install-driver.sh | sudo bash
```

---

### Opsi 2: Versi Lengkap (Driver Wi-Fi Auto-Detect + USB TL-WN722N + Auto-Failover LAN ↔ Wi-Fi)
Otomatis mengaktifkan Wi-Fi internal STB **Tipe B** maupun **Tipe HG**, mengoptimalkan dukungan USB Wi-Fi TP-Link TL-WN722N, membuat profil *auto-connect* Wi-Fi, serta memasang layanan **`wan-failover.service`** (LAN sebagai internet utama, otomatis beralih ke Wi-Fi saat LAN/ISP putus, dan kembali ke LAN saat pulih).

**Dengan menyertakan SSID & Password langsung (disarankan):**
```bash
curl -sSL https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main/install-full.sh | sudo bash -s -- --ssid "NAMA_WIFI_ANDA" --pass "PASSWORD_WIFI_ANDA"
```

**Atau tanpa profil Wi-Fi dulu (atur Wi-Fi belakangan lewat `nmcli`):**
```bash
curl -sSL https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main/install-full.sh | sudo bash -s -- --skip-wifi
```

---

## Instalasi Offline Menggunakan File `.deb` (Khusus Tipe B / SDIO `8189fs` Kernel `6.12.111-ophub`)
Untuk STB dengan kernel `6.12.111-ophub` (`aarch64` / `arm64`) tanpa akses internet saat instalasi:
1. Unduh file `prebuilt/6.12.111-ophub/rtl8189fs-6.12.111-ophub_arm64.deb` (atau dari halaman Releases).
2. Salin ke STB lalu jalankan:
```bash
sudo dpkg -i rtl8189fs-6.12.111-ophub_arm64.deb
```

---

## Cek Status Setelah Instalasi
- **Cek driver & interface Wi-Fi aktif:**
  ```bash
  lsmod | grep -E "8189fs|8189es|rtl8xxxu|ath9k_htc" && nmcli dev wifi list
  ```
- **Cek status failover LAN ↔ Wi-Fi (untuk versi lengkap):**
  ```bash
  cek-wan
  ```
- **Hubungkan Wi-Fi secara manual (jika memakai Opsi 1 atau `--skip-wifi`):**
  ```bash
  sudo nmcli dev wifi connect "NAMA_WIFI_ANDA" password "PASSWORD_WIFI_ANDA"
  ```

---

## Bagaimana Cara Kerja Skrip Ini?
- **Auto-Detect Bus SDIO & USB:** Memindai `/sys/bus/sdio/devices/*` (`024c:f179` -> `8189fs`, `024c:8179`/`8189` -> `8189es`, `02d0:*` -> `brcmfmac`, `3030:3030` -> `ssv6051`) dan `/sys/bus/usb/devices/*` (`0bda:8179` internal HG680-P / TL-WN722N v2/v3 -> firmware `rtlwifi/` + `rtl8xxxu`, `0cf3:9271` -> `ath9k_htc`).
- **Prebuilt Fast-Path (< 5 detik):** Pada kernel `6.12.111-ophub` (`8189fs`), skrip mengunduh paket `.deb` resmi dari repo ini lalu memasangnya langsung.
- **Auto-Compile & Kernel 6.18+ Support:** Jika kernel Armbian berbeda (`6.18.56-ophub`, dll.), skrip mengkloning [`jwrdegoede/rtl8189ES_linux`](https://github.com/jwrdegoede/rtl8189ES_linux), mendeteksi API `cfg80211` yang di-backport (`7.1–7.3` -> `6.18`), memperbaiki mismatch `GLIBC` pada `modpost`, membungkus `-fmin-function-alignment` untuk GCC < 14, lalu mengompilasi & memasang `.ko`.
- **Firmware USB Internal (`rtl8xxxu`):** Jika `armbian-firmware` pada STB Tipe HG tidak menyertakan `/lib/firmware/rtlwifi/*.bin`, skrip mengunduh langsung firmware Realtek (`rtl8188eufw.bin`, `rtl8188fufw.bin`, `rtl8188efw.bin`, `rtl8192eu_nic.bin`) dan memuat ulang `rtl8xxxu`.
- **Smart WAN Failover (`wan-failover.service`):** Memeriksa konektivitas internet nyata langsung ke `eth0` (`ping -I eth0` + fallback HTTPS `1.1.1.1`) tanpa memutus SSH lokal, menukar rute default DNS `systemd-resolved`, dan me-restart `cloudflared` (jika terpasang) saat berpindah jalur antara LAN dan Wi-Fi.
