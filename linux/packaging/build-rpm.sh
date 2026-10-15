#!/bin/sh
# Build .rpm cho Fedora / Enterprise Linux bằng Docker/OrbStack, rồi cài thử trong container
# sạch. Chạy trên HOST (macOS/Linux có docker) hoặc CI (.github/workflows/linux-release.yml).
#
#   linux/packaging/build-rpm.sh [--target "fc43 fc44 el9 el10"] [--arch "x86_64 aarch64"]
#                                [--swift-dir DIR] [--swift-only] [--no-smoke]
#
# Hai bước:
#   1. Engine Swift (libtelexcore.so + viettelex-text-tool) trong ảnh Swift chính thức
#      swift:rhel-ubi9 (VT_SWIFT_TAG=6.4 ⇒ swift:6.4-rhel-ubi9): glibc 2.34 = mức thấp nhất
#      của các distro ⇒ một bản cho mọi target cùng arch. Kết quả: linux/dist/rpm/.swift/<arch>/.
#      --swift-dir DIR dùng engine có sẵn (DIR/<arch>/…, CI tải từ job trước) — bỏ bước 1;
#      --swift-only chỉ làm bước 1.
#   2. rpmbuild trong đúng distro (frontend C++ link Fcitx5/IBus của distro đó; %check chạy
#      ctest + test app cài đặt + desktop/AppStream validate), rồi dnf install trong container
#      sạch (rpm/smoke-install.sh).
# Kết quả: linux/dist/rpm/<target>/*.rpm (gói noarch lấy từ arch build đầu tiên).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
DIST="$REPO/linux/dist/rpm"
TARGETS="fc43 fc44 el9 el10"
ARCHES="x86_64 aarch64"
SWIFT_DIR=""
SWIFT_ONLY=0
SMOKE=1
while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGETS=$2; shift ;;
    --arch) ARCHES=$2; shift ;;
    --swift-dir) SWIFT_DIR=$(cd "$2" && pwd); shift ;;
    --swift-only) SWIFT_ONLY=1 ;;
    --no-smoke) SMOKE=0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
# Thêm target: một dòng ở đây + matrix trong linux-release.yml + dnf-repo.sh (REPO_FILES) +
# docs/install.sh (RPM_TARGETS).
image_of() {
  case "$1" in
    fc43) echo fedora:43 ;; fc44) echo fedora:44 ;;
    el9) echo rockylinux/rockylinux:9 ;; el10) echo rockylinux/rockylinux:10 ;;
    *) echo "unknown target: $1 (thêm vào image_of trong build-rpm.sh)" >&2; return 1 ;;
  esac
}
platform_of() { case "$1" in x86_64) echo linux/amd64 ;; aarch64) echo linux/arm64 ;; *) echo "unknown arch $1" >&2; return 1 ;; esac; }
for t in $TARGETS; do image_of "$t" >/dev/null || exit 2; done
for a in $ARCHES; do platform_of "$a" >/dev/null || exit 2; done
SWIFT_IMAGE="swift:${VT_SWIFT_TAG:+$VT_SWIFT_TAG-}rhel-ubi9"

mkdir -p "$DIST" "$REPO/linux/dist"
[ -f "$REPO/linux/dist/.gitignore" ] || printf '*\n' > "$REPO/linux/dist/.gitignore"
# Chủ quyền: container chạy root ⇒ trả /out về user host khi thoát (CI Linux).
OWNER="$(id -u):$(id -g)"

# ---- 1. engine Swift -------------------------------------------------------------------
if [ -z "$SWIFT_DIR" ]; then
  SWIFT_DIR="$DIST/.swift"
  for a in $ARCHES; do
    rm -rf "${SWIFT_DIR:?}/$a"; out="$SWIFT_DIR/$a"; mkdir -p "$out"
    echo "==> swift engine $a ($SWIFT_IMAGE)"
    docker run --rm --platform "$(platform_of "$a")" -v "$REPO:/src:ro" -v "$out:/out" "$SWIFT_IMAGE" \
      sh -c "trap 'chown -R $OWNER /out' EXIT; bash /src/linux/packaging/rpm/build-swift.sh --out /out"
  done
fi
[ "$SWIFT_ONLY" = 1 ] && { ls -l "$SWIFT_DIR"/*/; exit 0; }

# ---- 2. rpmbuild theo distro -------------------------------------------------------------
for t in $TARGETS; do
  rm -rf "${DIST:?}/${t:?}"; mkdir -p "$DIST/$t"
  for a in $ARCHES; do
    test -f "$SWIFT_DIR/$a/libtelexcore.so" || { echo "thiếu engine $SWIFT_DIR/$a" >&2; exit 1; }
    out="$DIST/.work/$t-$a-$$"; mkdir -p "$out"
    echo "==> rpmbuild $t/$a ($(image_of "$t"))"
    docker run --rm --platform "$(platform_of "$a")" -v "$REPO:/src:ro" -v "$SWIFT_DIR/$a:/swift:ro" \
      -v "$out:/out" "$(image_of "$t")" sh -c \
      "trap 'chown -R $OWNER /out' EXIT; bash /src/linux/packaging/rpm/build-in-container.sh --out /out --swift-dir /swift"
    for f in "$out"/rpms/*.rpm; do
      b=$(basename "$f")
      case "$b" in
        *.src.rpm) continue ;;   # SRPM không phát hành (nguồn = repo GitHub)
        *.noarch.rpm) [ -e "$DIST/$t/$b" ] && continue ;;
      esac
      cp "$f" "$DIST/$t/"
    done
    rm -rf "$out"
  done
done

if [ "$SMOKE" = 1 ]; then
  for t in $TARGETS; do
    for a in $ARCHES; do
      tmp="$DIST/.work/smoke-$t-$a"; rm -rf "$tmp"; mkdir -p "$tmp"
      cp "$DIST/$t"/*."$a".rpm "$DIST/$t"/*.noarch.rpm "$tmp/"
      echo "==> smoke $t/$a"
      docker run --rm --platform "$(platform_of "$a")" -v "$tmp:/rpms:ro" \
        -v "$HERE/rpm/smoke-install.sh:/smoke.sh:ro" "$(image_of "$t")" bash /smoke.sh \
        | tee "$tmp/log"
      grep -q "SMOKE OK" "$tmp/log" || { echo "smoke failed: $t/$a" >&2; exit 1; }
      rm -rf "$tmp"
    done
  done
fi
ls -l "$DIST"/*/
rm -rf "$DIST/.work"
