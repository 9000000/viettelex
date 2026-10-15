#!/bin/bash
# Kiểm thử kho pacman [viettelex] trên máy local (Docker/OrbStack, archlinux amd64), KHÔNG dùng
# khoá thật:
#   1. build-arch.sh (cần linux/dist/noble/*.deb)                          [bỏ qua: --skip-build]
#   2. khoá GPG dùng một lần → pacman-repo.sh ký + dựng kho vào thư mục tạm
#   3. container archlinux sạch:
#      a. cách thủ công trong ARCH.md: pacman-key --add/--lsign-key, mục [viettelex] với
#         SigLevel = Required DatabaseRequired, Server = file:///repo/arch/$arch, pacman -Sy
#         viettelex → file Fcitx5/IBus đúng chỗ; DB bị sửa ⇒ pacman phải từ chối
#      b. docs/install.sh --dry-run, cài thật, chạy lại, --uninstall (pacman.conf + khoá sạch)
#
#   linux/packaging/test-pacman-repo.sh [--skip-build]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
[ "${1:-}" = --skip-build ] || "$HERE/build-arch.sh" --arch "x86_64 aarch64" --no-smoke

WORK=$(mktemp -d "${TMPDIR:-/tmp}/vt-pactest.XXXXXX")
export GNUPGHOME
GNUPGHOME=$(mktemp -d /tmp/vtg.XXXXXX)
cleanup() { gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf "$GNUPGHOME" "$WORK"; }
trap cleanup EXIT
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-gen-key "VietTelex Test Key <test@viettelex.invalid>" rsa3072 sign 1d
FPR=$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr/{print $10; exit}')
echo "==> khoá thử $FPR"
VT_PACMAN_KEY=$FPR "$HERE/pacman-repo.sh" --out "$WORK/site"

INNER='set -uo pipefail
fail=0; bad() { echo "FAIL: $*"; fail=1; }
sed -i "s/^#DisableSandboxSyscalls/DisableSandboxSyscalls/; s/^#DisableSandboxFilesystem/DisableSandboxFilesystem/" /etc/pacman.conf
pacman -Syu --noconfirm --needed dbus python-gobject diffutils >/tmp/p.log 2>&1 || { tail /tmp/p.log; exit 1; }
cp /etc/pacman.conf /tmp/pacman.conf.orig
# Ảnh Docker archlinux bỏ khoá chủ cục bộ của pacman-key; máy Arch thật đã có từ lúc cài.
pacman-key --init >/dev/null 2>&1

echo "### thủ công (ARCH.md)"
pacman-key --add /repo/viettelex-archive-keyring.gpg >/dev/null 2>&1 || bad "pacman-key --add"
pacman-key --lsign-key "$FPR" >/dev/null 2>&1 || bad "pacman-key --lsign-key"
printf "\n[viettelex]\nSigLevel = Required DatabaseRequired\nServer = file:///repo/arch/\$arch\n" >> /etc/pacman.conf
pacman -Sy --noconfirm viettelex >/tmp/i.log 2>&1 || { tail -20 /tmp/i.log; bad "pacman -Sy viettelex"; }
pacman -Qi viettelex | grep -E "^(Name|Version|Architecture|Validated By)"
pacman -Qi viettelex | grep -q "Validated By.*Signature" || bad "gói không được kiểm chữ ký"
test -f /usr/lib/fcitx5/viettelex.so && test -f /usr/share/fcitx5/addon/viettelex.conf \
  && test -f /usr/share/fcitx5/inputmethod/viettelex.conf || bad "Fcitx5 addon"
grep -q "<exec>/usr/lib/ibus/ibus-engine-viettelex" /usr/share/ibus/component/viettelex.xml || bad "IBus component"
test -x /usr/lib/ibus/ibus-engine-viettelex || bad "IBus engine"
grep -qx pacman /usr/share/viettelex-settings/install-method || bad "install-method"
pacman -Rns --noconfirm viettelex >/dev/null 2>&1 || bad "pacman -R"

echo "### DB bị sửa ⇒ pacman phải từ chối"
cp -a /repo /tmp/bad
printf x >> /tmp/bad/arch/x86_64/viettelex.db
sed -i "s#file:///repo/arch#file:///tmp/bad/arch#" /etc/pacman.conf
if pacman -Sy --noconfirm viettelex >/tmp/bad.log 2>&1; then bad "DB bị sửa vẫn cài được"; else echo "ok: từ chối ($(grep -io "signature[^.]*" /tmp/bad.log | head -1))"; fi
cp /tmp/pacman.conf.orig /etc/pacman.conf

echo "### pacman -U một lần (không thêm kho; .sig cạnh gói, khoá đã lsign)"
pacman -U --noconfirm file:///repo/arch/x86_64/$(basename /repo/arch/x86_64/viettelex-*-x86_64.pkg.tar.zst) >/tmp/u.log 2>&1 \
  || { tail /tmp/u.log; bad "pacman -U"; }
pacman -Qi viettelex | grep -q "Validated By.*Signature" || bad "-U không kiểm chữ ký"
pacman -Rns --noconfirm viettelex >/dev/null 2>&1
pacman-key --delete "$FPR" >/dev/null 2>&1

echo "### docs/install.sh --dry-run"
export VT_REPO_BASE=file:///repo VT_TEST_KEY_FPR=$FPR
bash /src/docs/install.sh --dry-run --yes >/tmp/dry.log 2>&1 || { cat /tmp/dry.log; bad "dry-run"; }
grep -E "\\$ |==>" /tmp/dry.log
cmp -s /etc/pacman.conf /tmp/pacman.conf.orig || bad "dry-run đã sửa pacman.conf"
echo "### docs/install.sh (cài thật, Fcitx5)"
bash /src/docs/install.sh --yes >/tmp/inst.log 2>&1 || { tail -30 /tmp/inst.log; bad "install.sh"; }
grep -E "==>|Cập nhật về sau" /tmp/inst.log
pacman -Q viettelex fcitx5 || bad "install.sh không cài đủ"
[ "$(grep -c "^\[viettelex\]" /etc/pacman.conf)" = 1 ] || bad "pacman.conf"
bash /src/docs/install.sh --yes >/tmp/inst2.log 2>&1 || { tail /tmp/inst2.log; bad "chạy lại install.sh"; }
[ "$(grep -c "^\[viettelex\]" /etc/pacman.conf)" = 1 ] || bad "chạy lại thêm trùng [viettelex]"
echo "### docs/install.sh --uninstall"
bash /src/docs/install.sh --uninstall --yes >/tmp/un.log 2>&1 || { tail -20 /tmp/un.log; bad "uninstall"; }
grep "==>" /tmp/un.log
pacman -Q viettelex >/dev/null 2>&1 && bad "còn gói"
grep -q "^\[viettelex\]" /etc/pacman.conf && bad "còn [viettelex] trong pacman.conf"
diff <(grep -v "^$" /tmp/pacman.conf.orig) <(grep -v "^$" /etc/pacman.conf) || bad "pacman.conf khác bản gốc"
pacman-key --list-keys "$FPR" >/dev/null 2>&1 && bad "còn khoá"
[ $fail = 0 ] && echo "PACMAN TEST OK" || echo "PACMAN TEST FAIL"'

docker run --rm --platform linux/amd64 -v "$WORK/site:/repo:ro" -v "$REPO:/src:ro" -e "FPR=$FPR" \
  archlinux:latest bash -c "$INNER" | tee "$WORK/log"
grep -q "PACMAN TEST OK" "$WORK/log"
