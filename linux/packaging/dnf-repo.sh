#!/bin/bash
# Dựng kho DNF/YUM (cho GitHub Pages, cạnh kho APT) từ linux/dist/rpm/<target>/*.rpm và ký
# bằng gpg của HOST — khoá bí mật không bao giờ vào container hay repo.
#
#   VT_RPM_KEY=<fingerprint> linux/packaging/dnf-repo.sh --out DIR [--dist DIR]
#                                                       [--download X.Y.Z] [--no-sign]
#
#   --out DIR         thư mục checkout viettelex-apt (kết quả ở DIR/rpm/, không đụng tới kho APT)
#   --dist DIR        mặc định linux/dist/rpm (kết quả build-rpm.sh / CI: <target>/*.rpm)
#   --download X.Y.Z  tải .rpm của GitHub Release linux-vX.Y.Z (gh release download) vào
#                     thư mục tạm rồi dùng thay --dist
#   --no-sign         dựng layout không ký (thử)
#
#   DIR/rpm/
#     RPM-GPG-KEY-viettelex                     khoá công khai (armored) — gpgkey= của file .repo
#     viettelex-fedora.repo  viettelex-el9.repo  viettelex-el10.repo
#     fedora/<NN>/{x86_64,aarch64}/*.rpm + repodata/ (repomd.xml + repomd.xml.asc)
#     el/<N>/{x86_64,aarch64}/…
#
# Ký hai lớp (dnf kiểm cả hai: gpgcheck=1 + repo_gpgcheck=1):
#   - từng .rpm: rpmsign chạy trong container rockylinux:9 (rpm 4.16 ⇒ chữ ký v4 mọi distro
#     đọc được) nhưng thao tác ký thật do gpg host làm: %__gpg trong container là một proxy
#     ghi dữ liệu cần ký ra thư mục chung và chờ chữ ký mà vòng lặp trên host tạo
#     (gpg --detach-sign). Không chuyển socket gpg-agent vào container (OrbStack/Docker
#     Desktop không chuyển tiếp được socket Unix của macOS).
#   - repodata/repomd.xml: chữ ký tách rời armored repomd.xml.asc, ký thẳng trên host
#     (giống InRelease của APT).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
DIST="$REPO/linux/dist/rpm"
OUT=""
SIGN=1
DOWNLOAD=""
BASE_URL=${VT_RPM_BASE_URL:-https://ptrinh.github.io/viettelex-apt/rpm}
IMAGE=${VT_RPM_TOOLS_IMAGE:-rockylinux/rockylinux:9}
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
[ -n "$OUT" ] || { echo "usage: VT_RPM_KEY=… $0 --out DIR [--dist DIR | --download X.Y.Z] [--no-sign]" >&2; exit 2; }
if [ "$SIGN" = 1 ] && [ -z "${VT_RPM_KEY:-}" ]; then
  echo "VT_RPM_KEY is not set (or pass --no-sign)" >&2; exit 2
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/vt-dnf.XXXXXX")
SIGNER_PID=""
cleanup() { [ -n "$SIGNER_PID" ] && kill "$SIGNER_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

if [ -n "$DOWNLOAD" ]; then
  # Release asset tên <gói>-<ver>-1.<dist>.<arch>.rpm ⇒ xếp lại theo target (fc44, el9…).
  gh release download "linux-v$DOWNLOAD" --repo ptrinh/viettelex --pattern '*.rpm' --dir "$WORK/dl"
  DIST="$WORK/dist"
  for f in "$WORK"/dl/*.rpm; do
    t=$(basename "$f" | sed -n 's/.*-[^-]*\.\(fc[0-9][0-9]*\|el[0-9][0-9]*\)\.[a-z0-9_]*\.rpm$/\1/p')
    [ -n "$t" ] || { echo "không nhận ra distro của $(basename "$f")" >&2; exit 1; }
    mkdir -p "$DIST/$t"; mv "$f" "$DIST/$t/"
  done
fi
TARGETS=$(cd "$DIST" && for d in */; do d=${d%/}; ls "$d"/*.rpm >/dev/null 2>&1 && echo "$d"; done)
[ -n "$TARGETS" ] || { echo "no .rpm under $DIST/<target>/" >&2; exit 1; }

dir_of() {  # fc44 → fedora/44, el9 → el/9
  case "$1" in fc*) echo "fedora/${1#fc}" ;; el*) echo "el/${1#el}" ;; *) echo "target lạ: $1" >&2; return 1 ;; esac
}

mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
R="$OUT/rpm"
rm -rf "$R/fedora" "$R/el"
mkdir -p "$R"
STAGE="$WORK/stage"
for t in $TARGETS; do
  d=$(dir_of "$t")
  for a in x86_64 aarch64; do
    ls "$DIST/$t"/*."$a".rpm >/dev/null 2>&1 || continue
    mkdir -p "$STAGE/$d/$a"
    cp "$DIST/$t"/*."$a".rpm "$DIST/$t"/*.noarch.rpm "$STAGE/$d/$a/"
  done
done

# ---- ký từng .rpm (rpmsign trong container, gpg trên host) ------------------------------
RPC="$WORK/rpc"; mkdir -p "$RPC"
cat > "$RPC/gpg-proxy" <<'PROXY'
#!/bin/bash
# %__gpg của rpm trong container: chuyển việc ký cho gpg trên host qua thư mục /rpc.
in=-; out=-
while [ $# -gt 0 ]; do
  case "$1" in
    -sbo|-o) out=$2; shift ;;
    --) in=${2:--}; shift ;;
  esac
  shift
done
id=$(date +%s%N)-$$
if [ "$in" = - ]; then cat > /rpc/req.$id.data; else cp "$in" /rpc/req.$id.data; fi
touch /rpc/req.$id.ready
for _ in $(seq 1 1200); do
  [ -f /rpc/req.$id.sig ] && break
  sleep 0.1
done
[ -f /rpc/req.$id.sig ] || { echo "gpg-proxy: host không ký (hết giờ)" >&2; exit 1; }
if [ "$out" = - ]; then cat /rpc/req.$id.sig; else cp /rpc/req.$id.sig "$out"; fi
rm -f /rpc/req.$id.*
PROXY
chmod +x "$RPC/gpg-proxy"

INNER='set -euo pipefail
dnf -y -q install rpm-sign createrepo_c gnupg2 >/dev/null
cd /stage
if [ "$SIGN" = 1 ]; then
  export GNUPGHOME=/root/.gnupg; mkdir -p -m 700 $GNUPGHOME
  gpg --batch -q --import /rpc/pub.asc
  rpm --import /rpc/pub.asc
  printf "%%_gpg_name %s\n%%__gpg /rpc/gpg-proxy\n%%_gpg_digest_algo sha256\n" "$KEY" > /root/.rpmmacros
  # GPG_TTY: rpmsign cảnh báo vì stdin không phải tty — vô hại.
  find . -name "*.rpm" -print0 | sort -z | xargs -0 rpmsign --addsign 2>&1 >/dev/null | { grep -v GPG_TTY || true; }
  # Mọi gói phải mang chữ ký hợp lệ của khoá này.
  bad=$(find . -name "*.rpm" -exec rpm -K {} + | grep -v "digests signatures OK" || true)
  [ -z "$bad" ] || { echo "$bad" >&2; exit 1; }
  echo "rpm -K: $(find . -name "*.rpm" | wc -l) gói đã ký"
fi
for r in $(find . -mindepth 3 -maxdepth 3 -type d | sort); do
  createrepo_c -q --general-compress-type=gz --checksum=sha256 "$r"
  echo "$r: $(ls "$r"/*.rpm | wc -l) rpm"
done
chown -R "$OWNER" /stage'

if [ "$SIGN" = 1 ]; then
  gpg --batch --yes --armor --export "$VT_RPM_KEY" > "$RPC/pub.asc"
  [ -s "$RPC/pub.asc" ] || { echo "public key export failed" >&2; exit 1; }
  # Vòng ký trên host: chạy tới khi container xong.
  (
    while [ ! -e "$RPC/done" ]; do
      for r in "$RPC"/req.*.ready; do
        [ -e "$r" ] || continue
        b=${r%.ready}
        gpg --batch --yes --quiet --local-user "$VT_RPM_KEY" --digest-algo SHA256 --no-armor \
            --detach-sign -o "$b.sig.tmp" "$b.data" && mv "$b.sig.tmp" "$b.sig"
        rm -f "$r"
      done
      sleep 0.1
    done
  ) &
  SIGNER_PID=$!
fi
docker run --rm -v "$STAGE:/stage" -v "$RPC:/rpc" -e "SIGN=$SIGN" -e "KEY=${VT_RPM_KEY:-}" \
  -e "OWNER=$(id -u):$(id -g)" "$IMAGE" bash -c "$INNER"
touch "$RPC/done"
[ -n "$SIGNER_PID" ] && wait "$SIGNER_PID" 2>/dev/null || true
SIGNER_PID=""

cp -R "$STAGE"/. "$R/"

# ---- repomd.xml.asc + khoá + file .repo (trên host) ------------------------------------
if [ "$SIGN" = 1 ]; then
  find "$R" -path '*/repodata/repomd.xml' | while read -r m; do
    gpg --batch --yes --local-user "$VT_RPM_KEY" --digest-algo SHA256 --armor --detach-sign -o "$m.asc" "$m"
  done
  cp "$RPC/pub.asc" "$R/RPM-GPG-KEY-viettelex"
  echo "signed with $VT_RPM_KEY"
fi
write_repo() {  # write_repo FILE NAME PATH
  cat > "$1" <<EOF
[viettelex]
name=$2
baseurl=$BASE_URL/$3/\$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=$BASE_URL/RPM-GPG-KEY-viettelex
metadata_expire=6h
EOF
}
# Fedora: $releasever = 43, 44…; EL: cố định theo bản chính (EL10 có thể báo $releasever 10.x).
write_repo "$R/viettelex-fedora.repo" 'VietTelex (Fedora $releasever)' 'fedora/$releasever'
for t in $TARGETS; do
  case "$t" in el*) write_repo "$R/viettelex-$t.repo" "VietTelex (Enterprise Linux ${t#el})" "el/${t#el}" ;; esac
done
: > "$OUT/.nojekyll"
echo "dnf repo ready: $R"
find "$R" -maxdepth 3 -type d | sort | sed "s#^$OUT/##"
