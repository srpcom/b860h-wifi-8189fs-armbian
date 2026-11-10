# STB Armbian Internal Wi-Fi Auto-Detect (`8189fs` / `8189es` / `rtl8xxxu`) & Smart WAN Failover

Repository ini menyediakan solusi instalasi cepat **1 baris perintah** yang otomatis mendeteksi jenis chipset Wi-Fi internal STB Armbian (Amlogic S905X, Debian/Ubuntu `6.12.x` hingga `6.18.x+`), beserta opsi **Smart WAN Failover (LAN Utama ↔ Wi-Fi Cadangan)**:

- **ZTE B860H / P212 S905X (`024c:f179` SDIO):** Memasang paket `.deb` *prebuilt* `8189fs` (kernel `6.12.111-ophub`) atau *Auto-Compile* dengan penyesuaian otomatis API `cfg80211` `6.18+`, wrapper GCC, dan `modpost`.
- **STB Realtek SDIO (`024c:8179` / `8189`):** Otomatis kompilasi & memasang driver `8189es`.
- **Fiberhome HG680-P / HG860P (`0bda:8179` USB Internal RTL8188EUS) & TL-WN722N v2/v3:** Otomatis mengunduh firmware `/lib/firmware/rtlwifi/*.bin` yang sering hilang di image Armbian terbaru dan mengaktifkan driver kernel `rtl8xxxu` tanpa perlu kompilasi.

---

## Pilih Salah Satu Mode Instalasi

### Opsi 1: Pasang Driver & Firmware Wi-Fi Internal Saja (Auto-Detect Tipe STB)
Otomatis mendeteksi apakah STB memakai chip SDIO (`8189fs` / `8189es`) atau USB internal (`rtl8xxxu`), lalu mengaktifkan interface `wlan0`:

```bash
curl -sSL https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main/install-driver.sh | sudo bash
```

---

### Opsi 2: Versi Lengkap (Driver Wi-Fi Auto-Detect + USB TL-WN722N + Auto-Failover LAN ↔ Wi-Fi)
Otomatis mengaktifkan Wi-Fi internal sesuai tipe STB (`B860H` maupun `HG680-P` / `HG860P`), mengoptimalkan dukungan USB Wi-Fi TP-Link TL-WN722N, membuat profil auto-connect Wi-Fi, serta memasang layanan **`wan-failover.service`** (LAN sebagai internet utama, otomatis beralih ke Wi-Fi saat LAN/ISP terputus, dan kembali ke LAN saat pulih).

**Dengan menyertakan SSID & Password langsung (disarankan):**
```bash
curl -sSL https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main/install-full.sh | sudo bash -s -- --ssid "NAMA_WIFI_ANDA" --pass "PASSWORD_WIFI_ANDA"
```

**Atau tanpa profil Wi-Fi dulu (atur Wi-Fi belakangan lewat `nmcli`):**
```bash
curl -sSL https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main/install-full.sh | sudo bash -s -- --skip-wifi
```

---

## Instalasi Offline Menggunakan File `.deb`
Untuk STB dengan kernel `6.12.111-ophub` (`aarch64` / `arm64`) tanpa akses internet saat instalasi:
1. Unduh file `prebuilt/6.12.111-ophub/rtl8189fs-6.12.111-ophub_arm64.deb` (atau dari halaman Releases).
2. Salin ke STB lalu jalankan:
```bash
sudo dpkg -i rtl8189fs-6.12.111-ophub_arm64.deb
```

---

## Cek Status Setelah Instalasi
- **Cek driver & interface Wi-Fi:**
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
- **Auto-Detect Bus SDIO & USB:** Memindai `/sys/bus/sdio/devices/*` (`024c:f179` -> `8189fs`, `024c:8179/8189` -> `8189es`) dan `/sys/bus/usb/devices/*` (`0bda:8179` internal HG680-P / TL-WN722N v2/v3 -> firmware `rtlwifi/` + `rtl8xxxu`, `0cf3:9271` -> `ath9k_htc`).
- **Prebuilt Fast-Path (< 5 detik):** Pada kernel `6.12.111-ophub` (`8189fs`), skrip mengunduh paket `.deb` resmi dari repo ini lalu memasangnya langsung.
- **Auto-Compile & Kernel 6.18+ Support:** Jika kernel Armbian berbeda (`6.18.56-ophub`, dll.), skrip mengkloning [`jwrdegoede/rtl8189ES_linux`](https://github.com/jwrdegoede/rtl8189ES_linux), mendeteksi API `cfg80211` yang di-backport (`7.1–7.3` -> `6.18`), memperbaiki mismatch `GLIBC` pada `modpost`, membungkus `-fmin-function-alignment` untuk GCC < 14, lalu mengompilasi & memasang `.ko`.
- **Firmware USB Internal (`rtl8xxxu`):** Jika `armbian-firmware` tidak menyertakan `/lib/firmware/rtlwifi/*.bin`, skrip mengunduh langsung firmware Realtek (`rtl8188eufw.bin`, `rtl8188fufw.bin`, `rtl8188efw.bin`, `rtl8192eu_nic.bin`) dan memuat ulang `rtl8xxxu`.
- **Smart WAN Failover (`wan-failover.service`):** Memeriksa konektivitas internet nyata langsung ke `eth0` (`ping -I eth0` + fallback HTTPS `1.1.1.1`) tanpa memutus SSH lokal, menukar rute default DNS `systemd-resolved`, dan me-restart `cloudflared` (jika terpasang) saat berpindah jalur antara LAN dan Wi-Fi.
