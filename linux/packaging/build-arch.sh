#!/bin/bash
# Gói Arch Linux (.pkg.tar.zst) cho kho pacman [viettelex] / GitHub Release, đóng lại từ
# .deb noble đã build (linux/dist/noble/, cùng PKGBUILD với AUR viettelex-bin qua
# `aur/bump.py --local`). Chạy trên HOST có docker hoặc CI, sau build-all.sh --series noble.
#
#   linux/packaging/build-arch.sh [--debs linux/dist/noble] [--arch "x86_64 aarch64"] [--no-smoke]
#
# - makepkg (user thường) trong archlinux:latest (chỉ có ảnh amd64; Mac Apple silicon chạy qua
#   Rosetta của OrbStack).
# - aarch64: ảnh Arch Linux ARM không có trên Docker Hub chính thức và runner arm64 của GitHub
#   không chạy được archlinux:latest ⇒ build gói aarch64 TRÊN x86_64 bằng makepkg.conf có
#   CARCH=aarch64. Làm được vì PKGBUILD chỉ giải nén .deb arm64 + đổi đường dẫn — không biên
#   dịch, không strip (options=('!strip' '!debug')) — nên không cần toolchain aarch64.
# - smoke (x86_64): pacman -U gói vừa build, Fcitx5 thấy IM viettelex, IBus thấy engine.
# Kết quả: linux/dist/arch/viettelex-<ver>-<rel>-<arch>.pkg.tar.zst
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
DEBS="$REPO/linux/dist/noble"
ARCHES="x86_64 aarch64"
SMOKE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --debs) DEBS=$(cd "$2" && pwd); shift ;;
    --arch) ARCHES=$2; shift ;;
    --no-smoke) SMOKE=0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
OUT="$REPO/linux/dist/arch"
mkdir -p "$REPO/linux/dist"
[ -f "$REPO/linux/dist/.gitignore" ] || printf '*\n' > "$REPO/linux/dist/.gitignore"
rm -rf "$OUT"; mkdir -p "$OUT"
W="$REPO/linux/dist/.arch-work-$$"
rm -rf "$W"; mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
python3 "$HERE/aur/bump.py" --local "$DEBS" --out "$W/pkg"

INNER='set -euo pipefail
# Sandbox tải của pacman 7 cần seccomp/landlock — hỏng trong container amd64 giả lập (Rosetta).
sed -i "s/^#DisableSandboxSyscalls/DisableSandboxSyscalls/; s/^#DisableSandboxFilesystem/DisableSandboxFilesystem/" /etc/pacman.conf
pacman -Syu --noconfirm --needed base-devel >/tmp/pacman.log 2>&1 || { tail -20 /tmp/pacman.log; exit 9; }
useradd -m builder
cp -r /w/pkg /home/builder/pkg; chown -R builder: /home/builder/pkg
cd /home/builder/pkg
for a in $ARCHES; do
  sed "s/^CARCH=.*/CARCH=\"$a\"/; s/^CHOST=.*/CHOST=\"$a-pc-linux-gnu\"/" /etc/makepkg.conf > /tmp/makepkg-$a.conf
  # SOURCE_DATE_EPOCH: gói tái lập được. -C: xoá src/ của arch trước (package() lấy mọi *.deb trong srcdir).
  sudo -u builder env SOURCE_DATE_EPOCH="$SDE" PKGDEST=/home/builder/out makepkg --config /tmp/makepkg-$a.conf \
    --noconfirm --nodeps -f -C >/tmp/makepkg-$a.log 2>&1 || { tail -30 /tmp/makepkg-$a.log; exit 1; }
  grep -E "Validating|Passed|FAILED|Finished" /tmp/makepkg-$a.log | head -8
done
cp /home/builder/out/*.pkg.tar.zst /out/
chown -R "$OWNER" /out'
SDE=$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)
docker run --rm --platform linux/amd64 -v "$W:/w:ro" -v "$OUT:/out" -e "ARCHES=$ARCHES" -e "SDE=$SDE" \
  -e "OWNER=$(id -u):$(id -g)" archlinux:latest bash -c "$INNER"

if [ "$SMOKE" = 1 ] && ls "$OUT"/*-x86_64.pkg.tar.zst >/dev/null 2>&1; then
  echo "==> smoke x86_64 (pacman -U)"
  docker run --rm --platform linux/amd64 -v "$OUT:/pkgs:ro" archlinux:latest bash -c '
    set -uo pipefail
    sed -i "s/^#DisableSandboxSyscalls/DisableSandboxSyscalls/; s/^#DisableSandboxFilesystem/DisableSandboxFilesystem/" /etc/pacman.conf
    pacman -Syu --noconfirm --needed dbus python-gobject ibus >/tmp/p.log 2>&1 || { tail /tmp/p.log; exit 1; }
    pacman -U --noconfirm /pkgs/*-x86_64.pkg.tar.zst >/tmp/u.log 2>&1 || { tail /tmp/u.log; exit 1; }
    fail=0
    test -f /usr/lib/fcitx5/viettelex.so && test -f /usr/share/fcitx5/addon/viettelex.conf || { echo "FAIL fcitx5 files"; fail=1; }
    grep -q "<exec>/usr/lib/ibus/ibus-engine-viettelex" /usr/share/ibus/component/viettelex.xml || { echo "FAIL ibus xml"; fail=1; }
    grep -qx pacman /usr/share/viettelex-settings/install-method || { echo "FAIL install-method"; fail=1; }
    export HOME=/tmp/h; mkdir -p $HOME
    dbus-run-session -- bash -c "
      fcitx5 --disable=wayland,xim,x11 >/tmp/f.log 2>&1 & sleep 6
      python3 -c \"
from gi.repository import Gio
b = Gio.bus_get_sync(Gio.BusType.SESSION, None)
p = Gio.DBusProxy.new_sync(b, 0, None, \\\"org.fcitx.Fcitx5\\\", \\\"/controller\\\", \\\"org.fcitx.Fcitx.Controller1\\\", None)
ims = [i[0] for i in p.call_sync(\\\"AvailableInputMethods\\\", None, 0, 3000, None).unpack()[0]]
print(\\\"fcitx5:\\\", \\\"viettelex\\\" in ims)
assert \\\"viettelex\\\" in ims\" || exit 1
      ibus-daemon -x -r --panel=disable >/tmp/i.log 2>&1 & sleep 5
      ibus list-engine | grep -q \"viettelex -\" && echo \"ibus: True\"" 2>/dev/null || { echo "FAIL runtime"; fail=1; }
    [ $fail = 0 ] && echo "ARCH SMOKE OK"' | tee "$W/smoke.log"
  grep -q "ARCH SMOKE OK" "$W/smoke.log" || { echo "arch smoke failed" >&2; exit 1; }
fi
ls -l "$OUT"
