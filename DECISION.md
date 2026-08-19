# Decision Log - News Article Orchestration

Catatan keputusan penting terkait orkestrasi. Tidak semua keputusan dicatat di sini, hanya yang punya trade-off nyata atau memengaruhi arah arsitektur. Format tiap entri: **Context**, **Decision**, **Trade-off**.

---

## Deployment and networking

### Tidak pakai VPS/cloud, orkestrasi lokal

**Context**: pertimbangan biaya untuk proyek portofolio.
**Decision**: semua service berjalan lokal via Docker Compose, tidak ada deployment ke cloud/VPS.
**Trade-off**: tidak bisa didemokan lewat URL publik tanpa langkah tambahan (mis. tunneling); cocok untuk demo lokal/screen-recording.

### Reverse proxy: Traefik

**Context**: perlu satu entrypoint dan routing host-based untuk beberapa layanan plus TLS lokal. Alternatif yang dipertimbangkan: nginx sebagai reverse proxy, atau Caddy.
**Decision**: Traefik.
**Trade-off**: routing didefinisikan lewat docker label di tiap service compose (`traefik.http.routers...`), bukan file config terpusat per-route.

### HTTPS lokal via Traefik + mkcert

**Context**: dibutuhkan HTTPS asli di lingkungan lokal, bukan sekadar HTTP.
**Decision**: mkcert untuk local CA dan sertifikat, Traefik untuk terminasi TLS.
**Trade-off**: butuh langkah manual per developer (`mkcert -install`, generate cert per domain), tidak otomatis portable ke mesin lain tanpa mengulang langkah ini.

### Network segmentation: `edge` vs `internal`

**Context**: database dan aplikasi backend tidak boleh langsung terekspos ke Traefik/publik.
**Decision**: `mysql` dan `php-fpm` hanya di network `internal`; `nginx-api` jadi satu-satunya service yang ada di kedua network, sebagai jembatan.
**Trade-off**: request ke API selalu lewat nginx dulu, tidak ada jalur pintas ke `php-fpm` dari luar `internal`.

### Network Traefik di-set global, bukan lewat label per-service

**Context**: `nginx-api` punya IP di dua network (`edge` dan `internal`), dan Traefik tidak dijamin memilih yang benar. Saat ia memilih IP `internal`, subnet yang tidak diikutinya, request menggantung sampai timeout, bukan ditolak, sehingga gejalanya jauh dari sebabnya. Alternatif yang dipertimbangkan: label `traefik.docker.network` pada `nginx-api` saja.
**Decision**: `--providers.docker.network=news-article_edge` di command Traefik, plus `name:` eksplisit untuk kedua network supaya nilainya tidak bergantung pada nama direktori project.
**Trade-off**: label per-service hanya menambal container yang kebetulan ketahuan; setelan global berlaku untuk setiap service yang di-route Traefik, termasuk yang ditambahkan nanti. Konsekuensinya: seluruh service yang di-route Traefik wajib berada di network itu, kalau tidak, Traefik tidak akan menemukannya. Efek samping dari `name:` eksplisit: mengganti nama direktori project tidak lagi mengubah nama network.

### `restart: unless-stopped` untuk seluruh service

**Context**: default Compose adalah `no`, sehingga stack tidak pernah naik sendiri setelah Docker daemon restart. Alternatif yang dipertimbangkan: `always`, atau membiarkannya manual.
**Decision**: `unless-stopped` di seluruh service.
**Trade-off**: `always` akan menyalakan ulang container yang sengaja dihentikan dengan `docker compose stop`, perilaku yang menyulitkan saat men-debug. `unless-stopped` menghormati penghentian yang disengaja, sekaligus menutup kasus `nginx-api` yang mati kalau kalah balapan start dengan `php-fpm`. Yang dibayar: stack ikut menyala tiap Docker daemon start, jadi memakan resource di latar belakang meski sedang tidak dipakai.

## Laravel API

### php-fpm + nginx sidecar, bukan `artisan serve`

**Context**: tujuan portofolio adalah menunjukkan pola yang mendekati production.
**Decision**: dua container terpisah (`php-fpm` + `nginx-api`) untuk satu aplikasi Laravel.
**Trade-off**: kompleksitas build lebih tinggi (multi-target Dockerfile, wiring fastcgi) dibanding satu container `artisan serve`, tapi pola inilah yang lazim dipakai di production.

### Dockerfile Laravel: multi-stage multi-target, bukan shared runtime volume

**Context**: `php-fpm` dan `nginx-api` perlu akses ke folder `public/` yang sama. Analisis awal hanya menimbang berkas yang dibaca (`public/` hasil build, isinya tetap) dan tidak mempertimbangkan berkas yang ditulis saat runtime, yaitu gambar unggahan.
**Decision**: satu Dockerfile dengan dua build target (`php-fpm`, `nginx`), masing-masing self-contained, `nginx` membawa salinan `public/`-nya sendiri saat build. Untuk berkas yang lahir saat runtime (unggahan), dipakai satu named volume tambahan yang di-mount di kedua container, bukan mengandalkan salinan build.
**Trade-off**: image `nginx` sedikit lebih besar karena duplikasi `public/` hasil build antar dua image, tapi keduanya immutable dan tidak ada race condition startup. Volume tambahan untuk unggahan menutup celah yang tidak tertangkap analisis awal, tanpa membatalkan pemisahan image itu sendiri.

### Volume bersama untuk berkas unggahan, bukan `storage:link`

**Context**: `php-fpm` menulis gambar unggahan, `nginx-api` yang harus melayaninya, dua container tanpa berkas bersama. Alternatif yang dipertimbangkan: `php artisan storage:link`, cara baku Laravel untuk kasus serupa.
**Decision**: satu named volume `uploads`, dipasang di `php-fpm` pada `storage/app/public` dan di `nginx-api` pada `public/storage` (read-only). `storage:link` tidak dipakai.
**Trade-off**: `storage:link` tidak menolong di topologi ini, symlink yang dibuat di dalam container `php-fpm` tetap tidak terlihat dari container lain. Volume menyelesaikan sekaligus persoalan persistensi: tanpa itu, `up -d --force-recreate php-fpm` menghapus seluruh unggahan. Harganya satu state baru yang harus ikut dipikirkan saat backup/reset, dan satu ketergantungan urutan: `php-fpm` wajib me-mount volume itu lebih dulu supaya kepemilikannya terbentuk sebagai `www-data`, bukan `root`.

### Skema HTTPS diberitahukan lewat nginx, bukan `TrustProxies`

**Context**: TLS berhenti di Traefik, jadi request yang sampai ke aplikasi selalu HTTP biasa dan Laravel salah membentuk setiap URL absolut. Cara baku Laravel untuk ini adalah middleware `TrustProxies` yang membaca header `X-Forwarded-Proto`.
**Decision**: `fastcgi_param HTTPS on;` di `docker/nginx/default.conf`.
**Trade-off**: `TrustProxies` akan gagal separuh jalur, karena SSR `public` memanggil `http://nginx-api` langsung tanpa lewat Traefik, jadi tidak ada header `X-Forwarded-Proto` sama sekali di jalur itu. Menyetel di nginx menutup kedua jalur tanpa menyentuh kode aplikasi. Yang dibayar: image nginx ini menyatakan API-nya selalu dilayani lewat HTTPS, benar untuk topologi ini, tidak berlaku kalau API-nya dijalankan tanpa TLS di depannya.

### URL absolut dipaksa berakar di `APP_URL`

**Context**: `asset()` dan link paginasi dibentuk dari host request. Dua pemanggil datang dengan host berbeda (`api.localhost` dari browser, `nginx-api` dari SSR), sehingga respons yang sama bisa berisi alamat internal yang tidak berarti bagi browser. Alternatif yang lebih sempit: menyetel `ASSET_URL`.
**Decision**: `URL::forceRootUrl(config('app.url'))` di `AppServiceProvider::boot()`.
**Trade-off**: `ASSET_URL` hanya membetulkan `asset()`, link paginasi tetap membawa hostname internal. `forceRootUrl` menutup seluruh kelas masalah ini sekaligus. Yang dibayar: aplikasi kehilangan kemampuan melayani lebih dari satu hostname publik, konsekuensi yang sesuai di sini karena API ini memang punya satu alamat kanonik.

### `APP_KEY`/`JWT_SECRET`/migration tidak auto-run saat container start

**Context**: trade-off antara kemudahan (auto-run tiap `docker compose up`) vs kontrol dan risiko (migration race kalau di-scale lebih dari satu replika, efek samping tidak disengaja tiap restart).
**Decision**: seluruh langkah ini manual (`docker compose run --rm php-fpm php artisan ...`), bukan bagian dari `CMD`/entrypoint image.
**Trade-off**: ada satu langkah manual tambahan tiap kali environment baru disiapkan dari nol, tapi lebih predictable dan aman untuk didemokan sebagai langkah eksplisit, bukan efek samping tersembunyi. `scripts/bootstrap.sh` membungkus `migrate`+`db:seed` jadi satu perintah yang aman diulang (`db:seed` dilewati kalau database sudah terisi, karena seeder-nya tidak idempoten), tapi tetap dipanggil eksplisit oleh manusia, bukan bagian dari `CMD`/entrypoint — trade-off ini tidak berubah, cuma langkah manualnya jadi satu perintah alih-alih dua.

### Unblock sementara advisory Composer untuk Laravel 10 (EOL)

**Context**: `laravel-swagger-roles` memakai Laravel 10 yang sudah tidak menerima perbaikan keamanan resmi. Composer memblokir instalasi apa pun karena advisory ini.
**Decision**: unblock sementara (`config.policy.advisories.block=false`, audit tetap dilaporkan, bukan dibungkam) supaya kerja orkestrasi bisa lanjut. Upgrade Laravel jadi task terpisah yang ditunda.
**Trade-off**: risiko keamanan riil dan disadari, aplikasi tetap berjalan tanpa security patch resmi selama upgrade belum dikerjakan. Ini kompromi sadar, bukan diabaikan diam-diam.

## Frontend build and runtime

### `VITE_BASE_URL`/`NEXT_PUBLIC_API_BACKEND` sebagai build arg

**Context**: Vite dan Next.js sama-sama meng-inline environment variable berawalan publik (`VITE_*`, `NEXT_PUBLIC_*`) ke bundle JavaScript saat build time, bukan membacanya saat runtime.
**Decision**: base URL API diteruskan sebagai `--build-arg` di compose untuk kedua service ini, bukan `environment:` container.
**Trade-off**: ganti target API mengharuskan build image ulang untuk `admin`/`public`, beda pola dari `php-fpm` yang cukup ganti `.env` lalu `up -d --force-recreate`. Ini bukan pilihan, melainkan keterbatasan alat (Vite/Next.js) yang harus diikuti.

### Panggilan API server-side lewat nama service Docker, bukan hostname publik

**Context**: SSR `public` gagal (`ENOTFOUND api.localhost`) karena DNS internal Docker tidak mengenal hostname publik yang dipakai browser. Alternatif yang dipertimbangkan: menambah network alias `api.localhost` ke `traefik` supaya nama itu bisa di-resolve dari dalam container.
**Decision**: arahkan panggilan server-side ke `http://nginx-api` (nama service Docker). Alias ditolak.
**Trade-off**: trafik internal tidak keluar ke edge proxy lalu berbalik masuk, dan tidak perlu menyuntikkan root CA mkcert ke image `public`, yang akan terjadi kalau memakai alias karena Node.js menolak sertifikat yang CA-nya tidak dipercaya. Efek samping yang harus diawasi: variabel berprefiks `NEXT_PUBLIC_*` sekarang berisi alamat yang tidak bisa dipakai browser. Ini aman hanya karena seluruh pemakaiannya ada di `getServerSideProps`.

### Optimasi gambar Next.js dimatikan

**Context**: `next/image` mengoptimasi dengan mengunduh gambarnya di sisi server, dari dalam container `public`, tempat `api.localhost` tidak bisa di-resolve. Alternatif yang dipertimbangkan: menambah network alias supaya nama itu dikenal di dalam container.
**Decision**: `images: { unoptimized: true }` di `next.config.mjs`.
**Trade-off**: menambahkan host ke `images.domains`/`remotePatterns` tidak menyelesaikan apa pun, daftar itu hanya mengizinkan, bukan membuat nama bisa di-resolve. Opsi alias menyeret kembali keharusan menyuntikkan root CA mkcert ke image `public`, opsi yang sudah ditolak pada keputusan panggilan API server-side dengan alasan yang sama. Yang dibayar: tidak ada penyesuaian ukuran maupun konversi WebP oleh Next.js, gambar dikirim apa adanya sebesar yang diunggah.

### Next.js `output: "standalone"` untuk image `public`

**Context**: tanpa ini, image production harus membawa seluruh `node_modules`, termasuk yang tidak terpakai saat runtime.
**Decision**: tambah `output: "standalone"` di `next.config.mjs`, rekomendasi resmi Next.js untuk deployment Docker. Ini perubahan source code aplikasi, bukan cuma file infra baru.
**Trade-off**: image jauh lebih ramping, tapi perubahan menyentuh source code aplikasi, bukan cuma layer orkestrasi, demi kebutuhan infra.

### Hapus direktif `# syntax=docker/dockerfile:1` dari ketiga Dockerfile

**Context**: direktif itu membuat BuildKit menarik frontend image dari Docker Hub setiap build. Saat koneksi ke registry gagal, build berhenti sebelum langkah pertama, padahal semua base image sudah ada di cache lokal.
**Decision**: hapus dari ketiga Dockerfile.
**Trade-off**: build tidak lagi punya dependensi jaringan di awal. Yang dilepas: akses ke fitur Dockerfile terbaru di luar frontend bawaan BuildKit, tidak ada yang dipakai di sini (`multi-stage`, `ARG`, `COPY --from`, `--chown` semuanya didukung bawaan). Kalau nanti butuh fitur baru (mis. `RUN --mount`), direktif ini perlu dikembalikan beserta konsekuensi jaringannya.

## Reproducibility

### Pin versi sibling repo lewat script checkout, bukan submodule atau registry

**Context**: `build.context` di `docker-compose.yml` menunjuk folder tetangga apa adanya, tanpa jejak versi, build hari ini dan build nanti bisa memakai kode berbeda tanpa ada yang tahu. Tiga alternatif dipertimbangkan: (a) git submodule, mekanisme native git untuk memin repo lain ke commit tertentu; (b) `build.context` diarahkan ke git URL berpin (`https://github.com/.../repo.git#sha`); (c) script yang men-checkout tiap sibling repo ke SHA yang sudah tercatat.
**Decision**: opsi (c), `scripts/checkout-versions.sh`, dijalankan manual sebelum `docker compose build`.
**Trade-off**: submodule ditolak karena mengharuskan ketiga repo pindah ke dalam `news-article/` (nested), membatalkan layout sejajar yang sudah jadi keputusan sadar. Git URL berpin ditolak karena mengubah `build.context` jadi selalu menarik dari remote, sehingga kode lokal yang belum di-commit tidak pernah ikut ter-build. Script checkout mempertahankan keduanya (layout sejajar, build dari folder lokal) dengan harga: pin-nya cuma berlaku kalau script benar-benar dijalankan, tidak dipaksakan oleh Docker sendiri seperti opsi (b). Solusi yang lebih penuh untuk reproducibility, yaitu image immutable di registry dirujuk lewat digest, sengaja tidak dikerjakan karena proyek ini lokal-saja tanpa VPS.

**Pengecualian**: `laravel-swagger-roles` dikeluarkan dari script ini setelah CD berjalan untuk repo itu (lihat [DEPLOYMENT.md](DEPLOYMENT.md)). Direktorinya sekarang dikelola live oleh CD, selalu mengikuti `main` terbaru, memin-nya ke SHA lama di script ini akan memutar balik deployment yang sedang live begitu script dijalankan.

### Verifikasi lewat script read-only, bukan script yang ikut membangun

**Context**: progres orkestrasi perlu bisa diuji ulang kapan saja. Alternatif yang dipertimbangkan: satu script "reproduce" yang sekaligus build, `up`, dan uji, supaya sekali jalan langsung dari nol.
**Decision**: `scripts/verify.sh` hanya memeriksa, tidak build/`up`/`down`. Langkah membangun tetap manual dan terdokumentasi di README.md.
**Trade-off**: butuh dua langkah terpisah (bangun dulu, baru verifikasi), tapi script-nya aman dijalankan kapan pun tanpa risiko mengubah keadaan sistem yang sedang diperiksa, termasuk saat sedang men-debug kegagalan. Turunannya: cek untuk tahap yang belum dikerjakan dilaporkan `[INFO]`, bukan `[FAIL]`, supaya exit code tetap bermakna sebagai deteksi regresi dan tidak selalu merah. Satu aturan tambahan: kegagalan tidak boleh dilaporkan sebagai `[INFO]`, pemeriksaan status harus memisahkan "request gagal" dari "data memang belum ada", supaya kerusakan nyata tidak pernah terbaca sebagai keadaan normal.

## Security pipeline

### Gate pipeline security diturunkan ke `CRITICAL` saja, remediasi ditunda

**Context**: ambang awal (`CRITICAL,HIGH`) membuat seluruh repo aplikasi merah sekaligus, bukan cuma temuan yang memang sengaja dibiarkan sebagai bukti pipeline bekerja, tapi juga volume besar temuan `HIGH` yang belum ditriase satu-satu. Keputusan: buktikan dulu mekanismenya jalan, remediasi menyeluruh belakangan setelah semua temuan terkumpul, bukan padam-kebakaran satu-satu tiap kali ada finding baru.
**Decision**: ambang Trivy (image scan di repo aplikasi dan config scan `news-article`) diturunkan dari `CRITICAL,HIGH` ke `CRITICAL` saja. `npm audit` ditambah `--audit-level=critical`. `semgrep scan` kehilangan flag `--error` sehingga tidak pernah menggagalkan job, bukan filter severity, karena flag `--severity` Semgrep punya laporan bug aktif dan taksonominya tidak selaras satu-satu dengan tingkat keparahan di rule set terbaru mereka. `composer audit` di `laravel-swagger-roles` sengaja tidak diubah, karena tidak ditemukan cara terverifikasi untuk filter severity di tool ini.
**Trade-off**: temuan `HIGH` (Trivy) dan non-critical (`npm audit`) tidak lagi menggagalkan CI, tetap tercetak di output job tapi harus dibaca manual. Semgrep berhenti total sebagai gate sampai ada cara filter severity yang terverifikasi bekerja. `laravel-swagger-roles` tetap merah lewat `composer audit` sampai Laravel diupgrade.

## Observability

### Tahap metrics + logs dibatasi infra-only, tracing ditunda

**Context**: observability lengkap lazimnya mencakup tiga pilar: metrics, logs, traces. Metrics dan logs bisa dikumpulkan murni dari luar (Docker socket, endpoint metrics, stdout container) tanpa menyentuh kode aplikasi. Tracing lintas layanan (mis. lewat OpenTelemetry) butuh instrumentasi SDK di dalam kode Laravel/Next.js/React, di tiga repo sibling, bukan cuma di repo orkestrasi ini.
**Decision**: metrics via Prometheus + cAdvisor, logs via Loki + Promtail, dashboard Grafana, dikerjakan sebagai murni infrastruktur. Tracing ditunda, belum diputuskan kapan atau apakah dikerjakan.
**Trade-off**: konsisten dengan prinsip bahwa repo ini tidak berisi kode aplikasi. Yang dibayar: observability yang ada sekarang tidak bisa menjawab "request lambat ini macet di layer mana", itu baru bisa dijawab tracing. Desainnya sengaja aditif (gaya LGTM: Grafana yang sudah ada tinggal menerima datasource tracing baru), jadi menunda ini tidak membuang kerja yang sudah dilakukan kalau tracing akhirnya dikerjakan.

### Traefik: naikkan `--log.level` ke `INFO` dan aktifkan `--accesslog`

**Context**: default Traefik adalah `--log.level=ERROR` dan `--accesslog` mati, container tidak menulis satu baris log pun kecuali ada error. Ditemukan saat verifikasi pipeline `promtail` ke `loki`: Traefik satu-satunya container yang tidak muncul di Loki, dan log container-nya terbukti kosong total.
**Decision**: tambah `--accesslog=true` dan `--log.level=INFO` ke `command:` service `traefik`.
**Trade-off**: log Traefik jadi jauh lebih berisik (tiap request tercatat, plus log operasional level INFO) dibanding default yang hanya mencatat error. Trade-off ini diterima karena Traefik adalah satu-satunya titik masuk semua request, tanpa access log dia jadi satu-satunya service tanpa visibilitas sama sekali, bertentangan dengan tujuan observability itu sendiri.

### Panel Network I/O per container di-drop, bukan grant `privileged: true` ke cAdvisor

**Context**: cAdvisor bisa memecah metrik network per container, tapi butuh `privileged: true` (akses penuh ke device/namespace host). Mount default (`docker.sock:ro`, `/sys:ro`, `/var/lib/docker:ro`) tidak cukup; percobaan tambahan `/:/rootfs:ro` juga tidak menolong. Tanpa `privileged`, metrik network yang tersedia cuma agregat host (`id: "/"`), bukan per container.
**Decision**: panel "Network I/O per container" tidak dibuat. `privileged: true` tidak digunakan.
**Trade-off**: satu panel USE (network) hilang dari dashboard, dicatat sebagai batasan terbuka di MONITORING.md §4. Sebagai gantinya, `cadvisor` tetap berjalan dengan akses read-only minimum yang sudah ada, tidak menambah attack surface baru demi satu panel observability yang tidak kritis.
