#!/usr/bin/env bash
# Backup sederhana untuk stack Nextcloud ini: dump database MariaDB +
# arsip named volume (data, config, custom_apps) ke folder ./backups.
#
# Jalankan manual:      ./scripts/backup.sh
# Atau jadwalkan cron (host, di luar docker-compose):
#   0 3 * * * cd /path/to/nextcloud && ./scripts/backup.sh >> backups/backup.log 2>&1

set -euo pipefail

cd "$(dirname "$0")/.."
set -a
source .env
set +a

BACKUP_DIR="./backups/$(date +%Y-%m-%d_%H-%M-%S)"
mkdir -p "$BACKUP_DIR"

echo "[1/3] Mengaktifkan maintenance mode..."
docker compose exec -T -u www-data app php occ maintenance:mode --on

echo "[2/3] Backup database MariaDB..."
docker compose exec -T db sh -c \
  "exec mariadb-dump -u root -p\"\${MYSQL_ROOT_PASSWORD}\" \"\${MYSQL_DATABASE}\"" \
  > "$BACKUP_DIR/db.sql"

echo "[3/3] Backup named volumes (data, config, custom_apps)..."
docker run --rm \
  -v nextcloud_data:/data \
  -v nextcloud_config:/config \
  -v nextcloud_custom_apps:/custom_apps \
  -v "$(pwd)/$BACKUP_DIR":/backup \
  alpine \
  tar czf /backup/volumes.tar.gz /data /config /custom_apps

docker compose exec -T -u www-data app php occ maintenance:mode --off

echo "Backup selesai: $BACKUP_DIR"
echo "  - db.sql        (dump database)"
echo "  - volumes.tar.gz (data + config + custom_apps)"
