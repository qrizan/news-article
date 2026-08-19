#!/usr/bin/env bash
#
# verify.sh - verifikasi ulang progres orkestrasi News Article.
#
# Sifat: READ-ONLY. Script ini tidak mem-build, tidak menjalankan, dan tidak menghentikan apa pun. 
# Script ini hanya memeriksa keadaan yang sedang berjalan dan melaporkan hasilnya, 
# supaya klaim bisa diuji ulang kapan saja tanpa mengubah keadaan sistem.
#
# Pakai:
#   bash scripts/verify.sh
#
# Exit code: 0 kalau semua cek WAJIB lolos, 1 kalau ada yang gagal.
#
# [INFO] tidak memengaruhi exit code, dan dipakai untuk dua hal saja:
#   1. menyatakan batas alat ini (hal yang memang tidak diuji di sini)
#   2. keadaan yang belum terisi tapi bukan kerusakan (mis. belum ada kategori)
#

set -u

cd "$(dirname "$0")/.." || exit 1

PASS=0
FAIL=0

pass() { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '  [INFO] %s\n' "$1"; }
section() { printf '\n== %s\n' "$1"; }

# Ambil status HTTP. Mengembalikan kode (mis. 200) atau "ERR:<exit_code_curl>"
# kalau curl gagal - mis. exit 60 = sertifikat TLS tidak dipercaya, 7 = tidak bisa konek. 
# Sengaja TIDAK memakai -k, karena validitas TLS termasuk yang diuji.
http_code() {
    local url="$1" code rc
    # --max-time 25: request pertama ke news.localhost memicu SSR yang memanggil
    # Laravel dalam kondisi dingin (opcache kosong). 10 detik pernah tidak cukup
    # dan menghasilkan ERR:28 palsu.
    code=$(curl -s -o /dev/null -w '%{http_code}' -I --max-time 25 "$url" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'ERR:%s' "$rc"
    else
        printf '%s' "$code"
    fi
}

# Sama seperti http_code, tapi memakai GET, bukan HEAD. Dipakai untuk endpoint
# JSON: HEAD memang dilayani Laravel, tapi GET yang benar-benar menjalankan
# controller sampai ke query database - yang ingin diuji di bagian selanjutnya.
http_code_get() {
    local url="$1" code rc
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 "$url" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'ERR:%s' "$rc"
    else
        printf '%s' "$code"
    fi
}

section "0. Prasyarat"

for bin in docker curl; do
    if command -v "$bin" >/dev/null 2>&1; then
        pass "$bin tersedia"
    else
        fail "$bin tidak ditemukan di PATH"
    fi
done

if docker compose version >/dev/null 2>&1; then
    pass "docker compose (plugin v2) tersedia"
else
    fail "docker compose tidak tersedia - script ini butuh Compose v2, bukan docker-compose v1"
fi

section "1. Sertifikat TLS lokal"

# certs/ di-gitignore. Environment baru wajib generate sendiri:
#   mkdir -p certs && cd certs && mkcert news.localhost admin.localhost api.localhost grafana.localhost
for f in certs/news.localhost+3.pem certs/news.localhost+3-key.pem; do
    if [ -f "$f" ]; then
        pass "$f ada"
    else
        fail "$f tidak ada - jalankan: mkdir -p certs && cd certs && mkcert news.localhost admin.localhost api.localhost grafana.localhost"
    fi
done

section "2. Konfigurasi Compose"

if docker compose config -q 2>/dev/null; then
    pass "docker-compose.yml valid (docker compose config -q)"
else
    fail "docker-compose.yml tidak valid - jalankan 'docker compose config' untuk detail"
fi

section "3. Container"

SERVICES="traefik mysql php-fpm nginx-api admin public cadvisor prometheus loki promtail grafana"

for svc in $SERVICES; do
    # -a supaya container yang ada tapi mati tetap terlihat. Tanpa ini,
    # "exited" dan "belum pernah dibuat" tidak bisa dibedakan.
    cid=$(docker compose ps -aq "$svc" 2>/dev/null)
    if [ -z "$cid" ]; then
        fail "service '$svc' belum punya container sama sekali - jalankan 'docker compose up -d'"
        continue
    fi

    state=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)
    if [ "$state" = "running" ]; then
        pass "service '$svc' running"
    else
        fail "service '$svc' status '$state' (bukan running)"
    fi

    health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$cid" 2>/dev/null)
    if [ "$health" != "-" ]; then
        if [ "$health" = "healthy" ]; then
            pass "service '$svc' healthcheck: healthy"
        else
            fail "service '$svc' healthcheck: $health"
        fi
    fi
done

section "4. Redirect HTTP -> HTTPS (Traefik entrypoint web)"

code=$(http_code http://news.localhost)
if [ "$code" = "308" ]; then
    pass "http://news.localhost -> $code Permanent Redirect"
else
    fail "http://news.localhost -> $code (diharapkan 308)"
fi

section "5. TLS + routing per domain"

# Tiap host diukur SEKALI di sini, hasilnya dipakai ulang di bagian berikutya.
# Sebelumnya tiap host di-request dua kali (sekali per bagian), sehingga kedua
# bagian bisa melihat keadaan berbeda - mis. 404 saat container baru start lalu
# 200 beberapa detik kemudian. Satu pengukuran = satu potret yang konsisten.
CODE_ADMIN=$(http_code https://admin.localhost)
CODE_NEWS=$(http_code https://news.localhost)
CODE_API=$(http_code https://api.localhost)
CODE_GRAFANA=$(http_code https://grafana.localhost)

code_of() {
    case "$1" in
        admin.localhost)   printf '%s' "$CODE_ADMIN" ;;
        news.localhost)    printf '%s' "$CODE_NEWS" ;;
        api.localhost)     printf '%s' "$CODE_API" ;;
        grafana.localhost) printf '%s' "$CODE_GRAFANA" ;;
    esac
}

# curl dijalankan tanpa -k: kalau CA mkcert tidak dipercaya di mesin ini,
# curl gagal (ERR:60) dan itu memang harus dilaporkan sebagai FAIL.
#
# Bagian ini HANYA menilai lapisan TLS - apakah handshake berhasil dan
# sertifikatnya dipercaya. Kode HTTP-nya dicetak sebagai informasi, tidak
# dinilai di sini: dari kode saja tidak mungkin dibedakan 404 dari Traefik
# (router hilang) dan 404 dari aplikasi (route tidak ada). Penilaian
# "aplikasi benar-benar jalan" adalah tugas bagian 6.
for host in admin.localhost news.localhost api.localhost grafana.localhost; do
    code=$(code_of "$host")
    case "$code" in
        ERR:60)
            fail "https://$host - sertifikat tidak dipercaya (mkcert -install belum dijalankan?)"
            ;;
        ERR:*)
            fail "https://$host - curl gagal ($code)"
            ;;
        *)
            pass "https://$host - TLS handshake ok, sertifikat dipercaya (HTTP $code)"
            ;;
    esac
done

section "6. Status aplikasi end-to-end"

# Ini bagian yang membedakan "routing jalan" dari "aplikasi jalan".
check_app() {
    local host="$1" label="$2" code
    code=$(code_of "$host")
    if [ "$code" = "200" ]; then
        pass "$host -> 200 ($label)"
    else
        fail "$host -> $code (diharapkan 200)"
    fi
}

check_app admin.localhost "React SPA"
check_app api.localhost   "Laravel API"
check_app news.localhost  "Next.js SSR"

# Grafana bukan dicek lewat root: tanpa sesi login, root me-redirect 302 ke
# /login, itu perilaku normal Grafana, bukan kegagalan. /api/health adalah
# endpoint liveness resminya, selalu 200 tanpa autentikasi kalau Grafana benar
# jalan dan bisa membaca database internalnya sendiri.
CODE_GRAFANA_HEALTH=$(http_code_get https://grafana.localhost/api/health)
if [ "$CODE_GRAFANA_HEALTH" = "200" ]; then
    pass "grafana.localhost/api/health -> 200 (Grafana dashboard)"
else
    fail "grafana.localhost/api/health -> $CODE_GRAFANA_HEALTH (diharapkan 200)"
fi

section "7. API menjawab di endpoint data"

# Bagian 6 hanya membuktikan '/' menjawab 200 - itu bisa saja halaman sambutan
# Laravel, yang tidak menyentuh database sama sekali. 
# Endpoint di bawah ini dipakai sungguhan oleh situs publik saat merender halaman depan, 
# jadi 200 di sini berarti request menembus routing -> controller -> database.
CODE_POSTS=$(http_code_get https://api.localhost/api/public/posts)

if [ "$CODE_POSTS" = "200" ]; then
    pass "GET /api/public/posts -> 200 (routing sampai ke controller + database)"
else
    fail "GET /api/public/posts -> $CODE_POSTS (diharapkan 200)"
fi

# Batas alat ini, dinyatakan terbuka supaya tidak disalahartikan sebagai bukti
# bahwa sistemnya berfungsi. Bagian 8 memeriksa data yang SUDAH ada; 
# yang tidak bisa diperiksa di sini adalah tindakan yang mengubah keadaan.
info "Script ini TIDAK menguji login maupun pembuatan kategori/artikel."
info "Keduanya mengubah keadaan, jadi pembuktiannya manual lewat panel admin."

section "8. URL absolut yang dikeluarkan API"

# Laravel membentuk URL absolut dari host request, dan ada dua pemanggil dengan
# host berbeda (browser lewat Traefik vs SSR dari dalam container). Tanpa
# URL::forceRootUrl + fastcgi_param HTTPS on, respons bisa berisi
# http://... atau https://nginx-api/... - dua-duanya tidak berguna bagi browser,
# dan gejalanya jauh dari sebabnya: gambar rusak hanya di situs publik.
#
# Cek ini butuh minimal satu kategori. Environment yang baru disiapkan belum
# punya (tidak ada seeder untuk kategori), jadi ketiadaan data dilaporkan
# [INFO], bukan [FAIL] - itu bukan regresi.
BODY=$(curl -s --max-time 25 https://api.localhost/api/public/categories 2>/dev/null)
CURL_RC=$?

# Membedakan "API tidak menjawab" dari "belum ada data" itu wajib, bukan kosmetik. 
# Versi pertama cek ini hanya melihat apakah ada data, sehingga saat
# API timeout ia melaporkan "belum ada kategori di database" - padahal datanya
# ada dan yang rusak justru routing-nya. Kegagalan tidak boleh menyamar jadi
# keadaan normal (2026-08-15).
if [ "$CURL_RC" -ne 0 ]; then
    fail "GET /api/public/categories - curl gagal (exit $CURL_RC), API tidak menjawab"
elif ! printf '%s' "$BODY" | grep -q '"success"'; then
    fail "GET /api/public/categories - respons bukan JSON API yang diharapkan"
else
    # JSON Laravel meng-escape slash: "image":"https:\/\/api.localhost\/storage\/..."
    RAW_IMG=$(printf '%s' "$BODY" | grep -o '"image":"[^"]*"' | head -1)

    if [ -z "$RAW_IMG" ]; then
        info "API menjawab, tapi belum ada kategori - cek URL & gambar dilewati"
        info "buat satu kategori dari panel admin untuk mengaktifkan cek ini"
    else
        if printf '%s' "$RAW_IMG" | grep -qF '"image":"https:\/\/api.localhost\/'; then
            pass "URL gambar berakar di https://api.localhost (bukan http, bukan nama internal)"
        else
            fail "URL gambar tidak kanonik: $RAW_IMG"
        fi

        # Buang pembungkus JSON dan kembalikan \/ menjadi /
        IMG_URL=$(printf '%s' "$RAW_IMG" | sed -e 's/^"image":"//' -e 's/"$//' -e 's|\\/|/|g')
        CODE_IMG=$(http_code "$IMG_URL")

        if [ "$CODE_IMG" = "200" ]; then
            pass "gambar unggahan dilayani -> 200 (volume bersama php-fpm -> nginx-api bekerja)"
        else
            fail "gambar unggahan -> $CODE_IMG (diharapkan 200) - $IMG_URL"
        fi
    fi
fi

section "9. Isolasi network (uji negatif)"

# mysql dan php-fpm harus tertutup dari network edge. Itu dibuktikan lewat model
# network Docker: dua container hanya bisa saling menjangkau kalau berbagi
# minimal satu network. Kalau irisannya kosong, tidak ada jalur - tanpa perlu
# container probe, dan tanpa menebak nama project.
nets_of() {
    local svc="$1" cid
    cid=$(docker compose ps -aq "$svc" 2>/dev/null)
    [ -z "$cid" ] && return 1
    docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$cid" 2>/dev/null
}

ADMIN_NETS=$(nets_of admin)

check_isolated() {
    local svc="$1" svc_nets shared n m
    svc_nets=$(nets_of "$svc")

    if [ -z "$svc_nets" ] || [ -z "$ADMIN_NETS" ]; then
        fail "tidak bisa membaca daftar network '$svc' atau 'admin'"
        return
    fi

    shared=""
    for n in $svc_nets; do
        for m in $ADMIN_NETS; do
            [ "$n" = "$m" ] && shared="$shared $n"
        done
    done

    if [ -z "$shared" ]; then
        pass "'$svc' tidak berbagi network dengan 'admin' - tidak terjangkau dari edge"
    else
        fail "'$svc' berbagi network dengan 'admin':$shared - isolasi bocor"
    fi
}

check_isolated mysql
check_isolated php-fpm

section "Ringkasan"

printf '  PASS: %s   FAIL: %s\n' "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf '\nAda cek wajib yang gagal. Jangan tandai progres sebagai "terverifikasi"\n'
    printf 'sebelum ini bersih.\n'
    exit 1
fi

printf '\nSemua cek wajib lolos.\n'
exit 0
