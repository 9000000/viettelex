# VietTelex trên Arch Linux / VietTelex on Arch Linux

Kho pacman `[viettelex]`: `https://ptrinh.github.io/viettelex-apt/arch/$arch` (x86_64, aarch64),
gói và cơ sở dữ liệu kho đều ký bằng khoá `43ADE236BCC43900B8F146B4F57C885055149990` (cùng khoá
với kho APT/DNF). Một gói `viettelex` gồm engine, addon Fcitx5, engine IBus, công cụ văn bản và app
cài đặt — đóng lại từ các .deb Ubuntu 24.04 chính thức (cùng PKGBUILD với AUR `viettelex-bin`).
Dùng được cho Arch và bản dựa trên Arch: Manjaro, EndeavourOS, CachyOS, Garuda, Arch Linux ARM.

Gói AUR `viettelex-bin` sẽ có sau — AUR đang tạm đóng đăng ký tài khoản mới. / *The AUR package
`viettelex-bin` comes later; AUR account registration is closed for now.*

## Tiếng Việt — cài đặt

**Một lệnh** (thêm kho + khoá, cài, chạy lại = cập nhật; `--ibus`, `--uninstall`, `--dry-run`):

```sh
curl -fsSL https://viettelex.com/install.sh | bash
```

**Thủ công:**

```sh
# 1. Khoá ký (kiểm vân tay: 43AD E236 BCC4 3900 B8F1  46B4 F57C 8850 5514 9990)
curl -fsSLO https://ptrinh.github.io/viettelex-apt/viettelex-archive-keyring.gpg
sudo pacman-key --add viettelex-archive-keyring.gpg
#    (hoặc: sudo pacman-key --recv-keys 43ADE236BCC43900B8F146B4F57C885055149990 — nếu keyserver có)
sudo pacman-key --lsign-key 43ADE236BCC43900B8F146B4F57C885055149990

# 2. Thêm vào cuối /etc/pacman.conf
[viettelex]
SigLevel = Required DatabaseRequired
Server = https://ptrinh.github.io/viettelex-apt/arch/$arch

# 3. Cài
sudo pacman -Sy viettelex          # Fcitx5 (đã là phụ thuộc) — thêm fcitx5-gtk fcitx5-qt fcitx5-configtool
                                   # IBus (GNOME): sudo pacman -S ibus
```

**Cài một lần, không thêm kho** (vẫn cần bước 1 để pacman kiểm chữ ký `.sig` cạnh gói; cách này
không tự cập nhật):

```sh
sudo pacman -U https://ptrinh.github.io/viettelex-apt/arch/x86_64/viettelex-<phiên bản>-1-x86_64.pkg.tar.zst
```

(File `.pkg.tar.zst` cũng có trên [GitHub Releases](https://github.com/ptrinh/viettelex/releases);
tải về rồi `sudo pacman -U ./viettelex-*.pkg.tar.zst`, kiểm bằng `sha256sum -c SHA256SUMS --ignore-missing`.)

**Sau khi cài:** mở **VietTelex** (hoặc `viettelex-settings --onboarding`). Fcitx5: đặt Fcitx5 làm
bộ gõ (KDE: Cài đặt hệ thống → Bàn phím → Bàn phím ảo → Fcitx 5; GNOME: nút *Dùng Fcitx5* trong app),
đăng nhập lại, thêm "Vietnamese (VietTelex)". IBus: `ibus restart`, Cài đặt → Bàn phím → Nguồn nhập.

**Cập nhật:** `sudo pacman -Syu` — app cài đặt cũng báo như vậy (không có nút cập nhật một chạm trên
Arch). **Gỡ:** `curl -fsSL https://viettelex.com/install.sh | bash -s -- --uninstall`, hoặc
`sudo pacman -Rns viettelex`, xoá mục `[viettelex]` khỏi `/etc/pacman.conf`,
`sudo pacman-key --delete 43ADE236BCC43900B8F146B4F57C885055149990`.

## English — install

Run the one-line installer above, or by hand: add the key with `pacman-key --add
viettelex-archive-keyring.gpg` (or `--recv-keys 43ADE236BCC43900B8F146B4F57C885055149990`), then
`pacman-key --lsign-key 43ADE236BCC43900B8F146B4F57C885055149990`; append the `[viettelex]` section
above (`SigLevel = Required DatabaseRequired`, `Server = …/arch/$arch`) to `/etc/pacman.conf`; then
`sudo pacman -Sy viettelex`. For a one-off install without the repository, `sudo pacman -U` the
package URL from the repository (its `.sig` sits next to it) after importing the key. Updates:
`sudo pacman -Syu`; the settings app says so instead of offering a one-click update.

---

## Dành cho người phát hành / For maintainers

```sh
linux/packaging/build-arch.sh                 # từ linux/dist/noble/*.deb → linux/dist/arch/*.pkg.tar.zst
linux/packaging/test-pacman-repo.sh           # khoá thử: kho file://, SigLevel Required, install.sh, gỡ
VT_PACMAN_KEY=43ADE236BCC43900B8F146B4F57C885055149990 linux/packaging/pacman-repo.sh --out ../viettelex-apt
#   (hoặc --download $V: lấy .pkg.tar.zst từ GitHub Release) → ../viettelex-apt/arch/{x86_64,aarch64}/
```

- **CI** (`linux-release.yml`, job `arch`): sau khi có .deb noble, `aur/bump.py --local` sinh PKGBUILD
  dùng .deb cục bộ (sha256 tính từ chính file — không cần stable.json/Release có trước), `makepkg`
  trong `archlinux:latest`. Ảnh này chỉ có amd64 (Arch Linux ARM không có ảnh Docker chính thức,
  runner arm64 không chạy được ảnh amd64) ⇒ gói **aarch64 đóng trên x86_64** với `CARCH=aarch64`:
  PKGBUILD chỉ giải nén .deb arm64 + đổi đường dẫn, không biên dịch, không strip. Gói gắn vào
  GitHub Release + SHA256SUMS + attestation như .deb.
- **Ký** (`pacman-repo.sh`): giống `repo-add --sign` nhưng khoá không vào container — ký từng gói
  (`.sig`) bằng gpg host, `repo-add` trong container (nhúng chữ ký gói vào DB), rồi ký
  `viettelex.db` / `viettelex.files` trên host. DB là bản sao, không phải symlink (GitHub Pages).
- Tên gói trong kho là `viettelex` (provides/conflicts `viettelex-bin`); AUR vẫn là `viettelex-bin`.
  Cả hai ghi `install-method` = `pacman` để app báo "cập nhật bằng pacman -Syu".
