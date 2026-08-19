#!/usr/bin/env bash
#
# bootstrap.sh - siapkan database dari kondisi bersih (setelah docker compose down -v, atau clone baru) 
# sampai siap dipakai. Aman dijalankan berulang.
#
# migrate --force melewati migration yang sudah jalan, aman diulang.
# db:seed --force cuma dipanggil kalau tabel roles masih kosong - seeder-nya pakai Model::create(), 
# bukan firstOrCreate(), jadi re-run di database yang sudah ter-seed gagal karena unique constraint (email, nama role/permission).
#
# Prasyarat: certs/ sudah ada, APP_KEY dan JWT_SECRET sudah terisi di ../laravel-swagger-roles/.env. 
# Langkah itu sekali per clone, tidak diulang
# di sini karena .env bukan volume Docker, tidak ikut hilang saat docker compose down -v.
#
# Pakai:
#   bash scripts/bootstrap.sh

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

echo "==> docker compose up -d"
docker compose up -d

echo "==> php artisan migrate --force"
docker compose run --rm php-fpm php artisan migrate --force

ROLE_COUNT=$(docker compose exec -T mysql mysql -N -uroot laravel -e "SELECT COUNT(*) FROM roles;" 2>/dev/null | tr -d '[:space:]')

if [ "$ROLE_COUNT" = "0" ] || [ -z "$ROLE_COUNT" ]; then
    echo "==> php artisan db:seed --force"
    docker compose run --rm php-fpm php artisan db:seed --force
else
    echo "==> Sudah pernah di-seed ($ROLE_COUNT role), db:seed dilewati."
fi

echo "==> Selesai. Jalankan 'bash scripts/verify.sh' untuk memverifikasi."
