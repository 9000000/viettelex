#!/bin/bash
# Kiểm thử đầu-cuối bản RPM trên máy local (Docker/OrbStack), KHÔNG dùng khoá thật:
#   1. build-rpm.sh (build + %check + smoke cài thẳng .rpm)            [bỏ qua: --skip-build]
#   2. khoá GPG dùng một lần → dnf-repo.sh dựng + ký kho vào thư mục tạm (base file:///repo/rpm)
#   3. mỗi target, container sạch:
#      a. file .repo (gpgcheck=1, repo_gpgcheck=1) → dnf install viettelex → rpm -K, rpm -V,
#         Fcitx5/IBus thấy file; repomd.xml bị sửa ⇒ dnf phải từ chối
#      b. docs/install.sh --dry-run, cài thật, chạy lại (= cập nhật), --uninstall (kho + khoá sạch)
#
#   linux/packaging/test-rpm.sh [--target "fc44 el9"] [--arch aarch64] [--skip-build]
#
# Mặc định aarch64 (Mac Apple silicon: native). Không đẩy gì, không đụng ../viettelex-apt.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
TARGETS="fc44 el9"
ARCH=aarch64
BUILD=1
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGETS=$2; shift ;;
    --arch) ARCH=$2; shift ;;
    --skip-build) BUILD=0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$ARCH" in x86_64) PLAT=linux/amd64 ;; aarch64) PLAT=linux/arm64 ;; *) echo "arch?" >&2; exit 2 ;; esac
image_of() {
  case "$1" in fc43) echo fedora:43 ;; fc44) echo fedora:44 ;; el9) echo rockylinux/rockylinux:9 ;;
    el10) echo rockylinux/rockylinux:10 ;; *) return 1 ;; esac
}

if [ "$BUILD" = 1 ]; then
  "$HERE/build-rpm.sh" --target "$TARGETS" --arch "$ARCH"
fi

# GNUPGHOME ngắn: socket gpg-agent trên macOS giới hạn ~104 ký tự.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/vt-rpmtest.XXXXXX")
export GNUPGHOME
GNUPGHOME=$(mktemp -d /tmp/vtg.XXXXXX)
cleanup() { gpgconf --kill gpg-agent 2>/dev/null || true; rm -rf "$GNUPGHOME" "$WORK"; }
trap cleanup EXIT
gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
  --quick-gen-key "VietTelex Test Key <test@viettelex.invalid>" rsa3072 sign 1d
FPR=$(gpg --batch --with-colons --list-keys | awk -F: '/^fpr/{print $10; exit}')
echo "==> khoá thử $FPR"

mkdir -p "$WORK/dist"
for t in $TARGETS; do cp -R "$REPO/linux/dist/rpm/$t" "$WORK/dist/"; done
VT_RPM_BASE_URL=file:///repo/rpm VT_RPM_KEY=$FPR "$HERE/dnf-repo.sh" --dist "$WORK/dist" --out "$WORK/site"
# install.sh lấy khoá kho APT (binary) — ở đây chỉ cần cho đường pacman; RPM dùng RPM-GPG-KEY.
gpg --batch --export "$FPR" > "$WORK/site/viettelex-archive-keyring.gpg"

INNER='set -uo pipefail
fail=0; bad() { echo "FAIL: $*"; fail=1; }
. /etc/os-release
echo "### $PRETTY_NAME — kho file:// + gpgcheck"
case "$T" in fc*) repo=/repo/rpm/viettelex-fedora.repo ;; *) repo=/repo/rpm/viettelex-$T.repo ;; esac
cp "$repo" /etc/yum.repos.d/viettelex.repo
cat /etc/yum.repos.d/viettelex.repo
dnf -y -q install viettelex >/tmp/dnf.log 2>&1 || { tail -20 /tmp/dnf.log; bad "dnf install viettelex"; }
echo "cài: $(rpm -qa "viettelex*" "libviettelex*" | sort | tr "\n" " ")"
for p in $(rpm -qa "viettelex*" "libviettelex*"); do
  rpm -V "$p" || bad "rpm -V $p"
  rpm -q --qf "%{NAME}: %{SIGPGP:pgpsig}%{RSAHEADER:pgpsig}\n" "$p" | grep -qi "key id" || bad "$p chưa ký"
done
L=$(rpm -E %_libdir)
if rpm -q viettelex-ibus >/dev/null; then test -f /usr/share/ibus/component/viettelex.xml || bad "ibus component"; fi
if rpm -q viettelex-fcitx5 >/dev/null; then
  test -f "$L/fcitx5/viettelex.so" && test -f /usr/share/fcitx5/addon/viettelex.conf || bad "fcitx5 addon"
fi
printf "toi di hoc" | "$L/viettelex/viettelex-text-tool" addTones; echo
dnf -y -q remove "viettelex*" "libviettelex*" >/dev/null 2>&1 || bad "dnf remove"

echo "### repomd.xml bị sửa ⇒ dnf phải từ chối"
cp -a /repo /tmp/bad; sed -i "s#/repo/rpm#/tmp/bad/rpm#" /etc/yum.repos.d/viettelex.repo
for f in /tmp/bad/rpm/*/*/*/repodata/repomd.xml; do echo "<!-- x -->" >> "$f"; done
dnf clean all >/dev/null 2>&1
if dnf -y -q --refresh install viettelex-settings >/tmp/bad.log 2>&1; then bad "kho bị sửa vẫn cài được"; else echo "ok: từ chối ($(grep -io "signature\|gpg[^ ]*" /tmp/bad.log | head -1))"; fi
rm -f /etc/yum.repos.d/viettelex.repo; dnf clean all >/dev/null 2>&1

echo "### docs/install.sh --dry-run"
export VT_REPO_BASE=file:///repo VT_TEST_KEY_FPR=$FPR
bash /src/docs/install.sh --dry-run --yes > /tmp/dry.log 2>&1 || { cat /tmp/dry.log; bad "dry-run"; }
grep -E "^\s+\\$ |==>" /tmp/dry.log | head -20
test ! -e /etc/yum.repos.d/viettelex.repo || bad "dry-run đã ghi file"
echo "### docs/install.sh (cài thật)"
bash /src/docs/install.sh --yes > /tmp/inst.log 2>&1 || { tail -30 /tmp/inst.log; bad "install.sh"; }
grep -E "==>|Cập nhật về sau" /tmp/inst.log
rpm -q viettelex viettelex-settings libviettelex-core || bad "install.sh không cài đủ"
case "$T" in el*) rpm -q viettelex-ibus >/dev/null || bad "EL phải là IBus" ;; *) rpm -q viettelex-fcitx5 >/dev/null || bad "Fedora (không GNOME) mặc định Fcitx5" ;; esac
grep -q "gpgcheck=1" /etc/yum.repos.d/viettelex.repo && grep -q "repo_gpgcheck=1" /etc/yum.repos.d/viettelex.repo || bad "repo file"
bash /src/docs/install.sh --yes > /tmp/inst2.log 2>&1 || bad "chạy lại install.sh"
echo "### docs/install.sh --uninstall"
bash /src/docs/install.sh --uninstall --yes > /tmp/un.log 2>&1 || { tail -20 /tmp/un.log; bad "uninstall"; }
grep "==>" /tmp/un.log
rpm -qa "viettelex*" "libviettelex*" | grep . && bad "còn gói"
test ! -e /etc/yum.repos.d/viettelex.repo && test ! -e /etc/pki/rpm-gpg/RPM-GPG-KEY-viettelex || bad "còn kho/khoá"
rpm -q "gpg-pubkey-$(printf %s "$FPR" | tail -c 8 | tr A-F a-f)" >/dev/null 2>&1 && bad "còn khoá trong rpmdb"
[ $fail = 0 ] && echo "RPM TEST OK ($T)" || echo "RPM TEST FAIL ($T)"'

FAILS=0
for t in $TARGETS; do
  img=$(image_of "$t") || { echo "target lạ $t" >&2; exit 2; }
  echo "==> $t ($img, $ARCH)"
  docker run --rm --platform "$PLAT" -v "$WORK/site:/repo:ro" -v "$REPO:/src:ro" \
    -e "T=$t" -e "FPR=$FPR" "$img" bash -c "$INNER" | tee "$WORK/$t.log"
  grep -q "RPM TEST OK" "$WORK/$t.log" || FAILS=$((FAILS+1))
done
echo "RESULT FAILS=$FAILS"
[ "$FAILS" = 0 ]
