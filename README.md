# STB ZTE B860H Internal Wi-Fi (`8189fs`) & Smart WAN Failover — Armbian

Repository ini menyediakan solusi instalasi cepat **1 baris perintah** untuk mengaktifkan Wi-Fi internal **Realtek RTL8189FTV/FS (`sdio:v024CdF179`)** pada STB **ZTE B860H (Amlogic S905X)** yang menjalankan Armbian Debian/Ubuntu (`6.12.111-ophub` maupun kernel 6.x lainnya), beserta opsi **Smart WAN Failover (LAN Utama ↔ Wi-Fi Cadangan)**.

---

## Pilih Salah Satu Mode Instalasi

### Opsi 1: Pasang Driver Wi-Fi Internal `8189fs` Saja
Hanya mengaktifkan chip Wi-Fi internal `wlan0` (menggunakan paket `.deb` *prebuilt* untuk kernel `6.12.111-ophub`, atau otomatis kompilasi dari *source* jika versi kernel berbeda).

```bash
curl -sSL https://raw.githubusercontent.com/srpcom/b860h-wifi-8189fs-armbian/main/install-driver.sh | sudo bash
```

---

### Opsi 2: Versi Lengkap (Driver `8189fs` + Dukungan USB TL-WN722N + Auto-Failover LAN ↔ Wi-Fi)
Mengaktifkan driver Wi-Fi internal `8189fs`, mengoptimalkan dukungan USB Wi-Fi TP-Link TL-WN722N, membuat profil auto-connect Wi-Fi, serta memasang layanan **`wan-failover.service`** (LAN sebagai internet utama, otomatis beralih ke Wi-Fi saat LAN/ISP terputus, dan kembali ke LAN saat pulih).

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
  lsmod | grep 8189fs && nmcli dev wifi list
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
- **Prebuilt Fast-Path (< 5 detik):** Pada kernel `6.12.111-ophub`, skrip mengunduh paket `.deb` resmi dari repo ini lalu memasangnya langsung.
- **Auto-Compile Fallback:** Jika kernel Armbian berbeda, skrip mengkloning [`jwrdegoede/rtl8189ES_linux`](https://github.com/jwrdegoede/rtl8189ES_linux) (branch `rtl8189fs`), otomatis menyesuaikan biner `modpost` jika terjadi mismatch `GLIBC`, membungkus flag compiler `-fmin-function-alignment` untuk GCC < 14, lalu mengompilasi & memasang `8189fs.ko`.
- **Smart WAN Failover (`wan-failover.service`):** Memeriksa konektivitas internet nyata langsung ke `eth0` (`ping -I eth0` + fallback HTTPS `1.1.1.1`) tanpa memutus SSH lokal, menukar rute default DNS `systemd-resolved`, dan me-restart `cloudflared` (jika terpasang) saat berpindah jalur antara LAN dan Wi-Fi.
