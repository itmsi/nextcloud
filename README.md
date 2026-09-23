# Nextcloud - cloud.motorsights.com

Setup Nextcloud lengkap dengan Docker Compose: Nextcloud (Apache) + MariaDB +
Redis + cron container terpisah. Database dan Redis **tidak** diekspos ke
host/luar. Nextcloud terhubung ke reverse proxy global yang sudah berjalan
di server via Docker network eksternal (tidak bind port 80/443 sendiri).

## Struktur

- `docker-compose.yml` — orkestrasi utama (app, db, redis, cron)
- `.env.example` — template variabel environment (credential dsb)
- `config/php-uploads.ini` — override PHP `memory_limit`, `upload_max_filesize`, `post_max_size`
- `nginx/cloud.motorsights.com.conf` — contoh vhost untuk reverse proxy global (kalau nginx polos)
- `scripts/backup.sh` — backup database + volume data

## 1. Prasyarat: DNS

Sebelum SSL bisa di-generate oleh reverse proxy global (Let's Encrypt HTTP-01
atau DNS-01), pastikan dulu:

1. Buat **A record**: `cloud.motorsights.com` → IP publik server Anda.
2. Tunggu propagasi DNS (cek dengan `dig cloud.motorsights.com` atau
   `nslookup cloud.motorsights.com` sampai hasilnya sesuai IP server).
3. Pastikan port 80 dan 443 di server sudah diarahkan ke reverse proxy
   global (bukan ke stack ini) dan tidak diblok firewall.

Let's Encrypt tidak akan bisa menerbitkan sertifikat sebelum DNS ini aktif.

## 2. Cek reverse proxy global yang sudah ada

Stack ini **tidak** membuat reverse proxy baru — ia berasumsi sudah ada
reverse proxy global (nginx / nginx-proxy+acme-companion / Traefik) yang
menangani port 80/443 di server. Cari network Docker miliknya:

```bash
docker network ls
```

Catat nama network tsb, lalu isi `PROXY_NETWORK_NAME` di `.env` dengan nama
itu. Service `app` di stack ini akan join ke network tersebut sehingga bisa
dijangkau oleh reverse proxy global.

Ada 2 skenario, pilih salah satu di `nginx/cloud.motorsights.com.conf`:

- **Reverse proxy nginx native di host** (misal via `/etc/nginx/sites-available`,
  bukan container) — nginx host tidak bisa resolve nama service Docker
  `app` lewat DNS Docker. Karena itu `docker-compose.yml` sudah men-publish
  service `app` ke `127.0.0.1:8080` (lihat `ports:` pada service `app`), dan
  `nginx/cloud.motorsights.com.conf` sudah diarahkan ke `http://127.0.0.1:8080`
  (bukan `http://app:80`). Tinggal sesuaikan path
  `ssl_certificate`/`ssl_certificate_key` dengan sertifikat Let's Encrypt
  yang sudah dikelola nginx host tsb, lalu `sudo nginx -t && sudo systemctl reload nginx`.
- **Reverse proxy nginx sebagai container** yang join ke network eksternal
  yang sama (`PROXY_NETWORK_NAME`) — bisa pakai DNS Docker langsung: ganti
  `proxy_pass` di file nginx conf jadi `http://app:80`, dan baris `ports:`
  pada service `app` di `docker-compose.yml` boleh dihapus (tidak perlu
  publish ke host lagi).
- **jwilder/nginx-proxy + acme-companion (otomatis via env var)** — tidak
  perlu file vhost manual. Tambahkan environment `VIRTUAL_HOST`,
  `VIRTUAL_PORT=80`, `LETSENCRYPT_HOST`, `LETSENCRYPT_EMAIL` ke service
  `app` di `docker-compose.yml` (contoh sudah dituliskan sebagai komentar
  di bagian bawah file `nginx/cloud.motorsights.com.conf`).
- **Traefik** — ganti dengan `labels:` Traefik pada service `app`
  (`traefik.http.routers...rule=Host(...)`, `certresolver`, dsb) sesuai
  konfigurasi Traefik yang sudah berjalan.

## 3. Instalasi

```bash
git clone <repo-ini> nextcloud
cd nextcloud

cp .env.example .env
nano .env   # isi semua password & PROXY_NETWORK_NAME & TRUSTED_PROXIES

docker compose up -d
docker compose logs -f app   # tunggu sampai instalasi otomatis selesai
```

Environment `NEXTCLOUD_ADMIN_USER` / `NEXTCLOUD_ADMIN_PASSWORD` di `.env`
otomatis membuat akun admin pada instalasi pertama — tidak perlu wizard
"create admin" manual di browser. Setelah `docker compose logs -f app`
menunjukkan Apache siap (`Apache2 ... configured`), buka
`https://cloud.motorsights.com` dan login dengan kredensial tsb.

`TRUSTED_PROXIES` **wajib** diisi dengan subnet/IP reverse proxy global agar
Nextcloud mendeteksi HTTPS dengan benar (`OVERWRITEPROTOCOL=https` sudah
di-set otomatis oleh compose ini) — kalau salah, Nextcloud akan menampilkan
peringatan "Trusted proxy" atau redirect loop.

## 4. Verifikasi

```bash
docker compose ps
docker compose exec -u www-data app php occ status
docker compose exec -u www-data app php occ config:system:get trusted_domains
```

Cek juga Settings → Administration → Overview di web UI: seharusnya tidak
ada warning soal HTTPS/reverse proxy/memory_limit.

## 5. Update Nextcloud

```bash
docker compose pull
docker compose up -d
docker compose exec -u www-data app php occ upgrade
docker compose exec -u www-data app php occ maintenance:repair
```

Named volume (`nextcloud_db`, `nextcloud_html`, `nextcloud_data`,
`nextcloud_config`, `nextcloud_custom_apps`) tidak ikut terhapus oleh
`docker compose down`, jadi aman untuk `down` lalu `up -d` lagi tanpa
kehilangan data. Gunakan `docker compose down -v` **hanya** jika memang
sengaja ingin menghapus semua data.

## 6. Background jobs (cron)

Service `cron` menjalankan `cron.php` setiap 5 menit via loop shell di
dalam container terpisah (bukan AJAX). Pastikan di web UI:
Settings → Administration → Basic settings → Background jobs = **Cron**.

## 7. Backup

```bash
./scripts/backup.sh
```

Menghasilkan folder `backups/<timestamp>/` berisi `db.sql` (dump MariaDB)
dan `volumes.tar.gz` (data + config + custom_apps). Bisa dijadwalkan lewat
cron di host, contoh ada di komentar dalam `scripts/backup.sh`.

Restore manual (garis besar):

```bash
docker compose exec -T db sh -c 'mariadb -u root -p"$MYSQL_ROOT_PASSWORD" "$MYSQL_DATABASE"' < backups/<timestamp>/db.sql
docker run --rm -v nextcloud_data:/data -v nextcloud_config:/config \
  -v nextcloud_custom_apps:/custom_apps -v "$(pwd)/backups/<timestamp>":/backup \
  alpine sh -c "cd / && tar xzf /backup/volumes.tar.gz"
```

## Catatan port & keamanan

- Service `db` dan `redis` **tidak** punya bagian `ports:` sama sekali —
  hanya bisa diakses dari network internal (`internal: true`, tanpa akses
  keluar), tidak bisa dijangkau dari host maupun luar.
- Service `app` juga tidak bind port ke host — semua trafik masuk lewat
  reverse proxy global via network eksternal `proxy`. Jadi tidak ada
  konflik dengan service lain yang sudah memakai port 80/443 di server.
