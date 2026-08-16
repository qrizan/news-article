#!/usr/bin/env bash
set -euo pipefail

# Commit tervalidasi tiap repo aplikasi, dicatat saat orkestrasi ini terakhir
# terbukti bekerja penuh: artikel dibuat lewat panel admin, tampil di situs
# publik beserta gambarnya. Kalau salah satu sibling repo maju melewati
# commit ini, build berikutnya bisa memakai kode yang belum pernah diverifikasi
# bersama commit di repo ini.
declare -A PINNED=(
  [laravel-swagger-roles]=536a134
  [react-tailwind-roles]=a4c5cb2
  [nextjs-tailwind-storybook]=4aa600d
)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail=0

for repo in "${!PINNED[@]}"; do
  sha="${PINNED[$repo]}"
  dir="$BASE_DIR/$repo"

  if [ ! -d "$dir/.git" ]; then
    echo "[FAIL] $repo tidak ditemukan di $dir (clone dulu: git clone git@github.com:qrizan/$repo.git $dir)"
    fail=1
    continue
  fi

  if [ -n "$(git -C "$dir" status --porcelain)" ]; then
    echo "[FAIL] $repo punya perubahan belum di-commit, checkout dilewati. Commit atau stash dulu, lalu ulangi."
    fail=1
    continue
  fi

  git -C "$dir" fetch --quiet origin

  if ! git -C "$dir" cat-file -e "$sha" 2>/dev/null; then
    echo "[FAIL] $repo tidak punya commit $sha setelah fetch"
    fail=1
    continue
  fi

  git -C "$dir" checkout --quiet "$sha"
  head="$(git -C "$dir" rev-parse --short HEAD)"

  if [ "$head" = "$sha" ]; then
    echo "[PASS] $repo -> $sha"
  else
    echo "[FAIL] $repo checkout ke $sha tapi HEAD sekarang $head"
    fail=1
  fi
done

if [ "$fail" -eq 0 ]; then
  echo
  echo "Semua repo sibling berhasil di-checkout ke commit yang tervalidasi."
fi

exit "$fail"
