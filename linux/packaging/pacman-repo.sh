#!/bin/bash
# Dựng kho pacman [viettelex] (cho GitHub Pages, cạnh kho APT/DNF) từ linux/dist/arch/*.pkg.tar.zst
# và ký bằng gpg của HOST — khoá bí mật không bao giờ vào container hay repo.
#
#   VT_PACMAN_KEY=<fingerprint> linux/packaging/pacman-repo.sh --out DIR [--dist DIR]
#                                                             [--download X.Y.Z] [--no-sign]
#
#   --out DIR         thư mục checkout viettelex-apt (kết quả ở DIR/arch/<arch>/)
#   --dist DIR        mặc định linux/dist/arch (kết quả build-arch.sh / CI)
#   --download X.Y.Z  tải *.pkg.tar.zst của GitHub Release linux-vX.Y.Z (gh release download)
#
#   DIR/arch/{x86_64,aarch64}/
#     viettelex-<ver>-<rel>-<arch>.pkg.tar.zst + .sig     gói + chữ ký tách rời (binary)
#     viettelex.db / viettelex.files (+ .tar.gz) + .sig   cơ sở dữ liệu kho + chữ ký
#   DIR/viettelex-archive-keyring.gpg                     khoá công khai (chung với kho APT)
#
# Tương đương `repo-add --sign` nhưng tách bí mật khỏi container: ký .pkg.tar.zst trên host
# trước, repo-add (container archlinux, không khoá) nhúng chữ ký gói vào DB (%PGPSIG%), rồi
# ký DB trên host. viettelex.db / .files là BẢN SAO (không phải symlink như repo-add tạo) vì
# GitHub Pages không phục vụ symlink.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
DIST="$REPO/linux/dist/arch"
OUT=""
SIGN=1
DOWNLOAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift ;;
    --dist) DIST=$2; shift ;;
    --download) DOWNLOAD=$2; shift ;;
    --no-sign) SIGN=0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$OUT" ] || { echo "usage: VT_PACMAN_KEY=… $0 --out DIR [--dist DIR | --download X.Y.Z] [--no-sign]" >&2; exit 2; }
if [ "$SIGN" = 1 ] && [ -z "${VT_PACMAN_KEY:-}" ]; then
  echo "VT_PACMAN_KEY is not set (or pass --no-sign)" >&2; exit 2
fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vt-pacman.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if [ -n "$DOWNLOAD" ]; then
  gh release download "linux-v$DOWNLOAD" --repo ptrinh/viettelex --pattern '*.pkg.tar.zst' --dir "$WORK/dl"
  DIST="$WORK/dl"
fi
ls "$DIST"/*.pkg.tar.zst >/dev/null 2>&1 || { echo "no .pkg.tar.zst under $DIST" >&2; exit 1; }

mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
rm -rf "$OUT/arch"
ARCHES=""
for a in x86_64 aarch64; do
  ls "$DIST"/*-"$a".pkg.tar.zst >/dev/null 2>&1 || continue
  ARCHES="$ARCHES $a"
  mkdir -p "$WORK/arch/$a"
  cp "$DIST"/*-"$a".pkg.tar.zst "$WORK/arch/$a/"
  if [ "$SIGN" = 1 ]; then
    for p in "$WORK/arch/$a"/*.pkg.tar.zst; do
      gpg --batch --yes --local-user "$VT_PACMAN_KEY" --no-armor --detach-sign -o "$p.sig" "$p"
    done
  fi
done

# repo-add trong archlinux (amd64; Mac Apple silicon: Rosetta) — không cần khoá.
docker run --rm --platform linux/amd64 -v "$WORK/arch:/arch" -e "OWNER=$(id -u):$(id -g)" \
  -e "ARCHES=$ARCHES" archlinux:latest bash -c 'set -euo pipefail
  for a in $ARCHES; do
    cd /arch/$a
    repo-add -q viettelex.db.tar.gz ./*.pkg.tar.zst
    for n in db files; do rm -f viettelex.$n; cp viettelex.$n.tar.gz viettelex.$n; done
    echo "arch/$a: $(ls ./*.pkg.tar.zst | wc -l) gói"
  done
  chown -R "$OWNER" /arch'

if [ "$SIGN" = 1 ]; then
  for a in $ARCHES; do
    for n in db files; do
      f="$WORK/arch/$a/viettelex.$n.tar.gz"
      gpg --batch --yes --local-user "$VT_PACMAN_KEY" --no-armor --detach-sign -o "$f.sig" "$f"
      cp "$f.sig" "$WORK/arch/$a/viettelex.$n.sig"
    done
  done
  gpg --batch --yes --export "$VT_PACMAN_KEY" > "$OUT/viettelex-archive-keyring.gpg"
  [ -s "$OUT/viettelex-archive-keyring.gpg" ] || { echo "public key export failed" >&2; exit 1; }
  echo "signed with $VT_PACMAN_KEY"
fi
cp -R "$WORK/arch" "$OUT/arch"
: > "$OUT/.nojekyll"
echo "pacman repo ready: $OUT/arch"
ls -l "$OUT"/arch/*/
