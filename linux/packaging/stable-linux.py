#!/usr/bin/env python3
"""Ghi mục "linux" vào docs/stable.json + file SHA256SUMS cho GitHub Release Linux.

    linux/packaging/stable-linux.py [--dist linux/dist] [--notes "…"] [--sums OUT]

Đọc mọi .deb trong <dist>/<series>/ (kết quả build-all.sh), .rpm trong <dist>/rpm/<target>/
(build-rpm.sh) và .pkg.tar.zst trong <dist>/arch/ (build-arch.sh), lấy phiên bản từ
linux/settings/viettelex_settings/__init__.py, tính SHA256 theo TÊN ASSET trên GitHub
(GitHub đổi "~" thành "."), rồi cập nhật docs/stable.json — chỉ khoá "linux", giữ nguyên
khoá gốc (macOS) và "windows". App cài đặt Linux chỉ đọc mục này (xem updater.py).
stable.json chỉ mang SHA256 của .deb (cập nhật một chạm + AUR bump.py); .rpm / .pkg.tar.zst
chỉ vào SHA256SUMS (attestation CI ký theo file này) — dnf/pacman tự kiểm chữ ký kho.
"""
import argparse
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
GH = "https://github.com/ptrinh/viettelex/releases"


def version():
    p = os.path.join(REPO, "linux", "settings", "viettelex_settings", "__init__.py")
    m = re.search(r'^VERSION = "([^"]+)"', open(p, encoding="utf-8").read(), re.M)
    return m.group(1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dist", default=os.path.join(REPO, "linux", "dist"))
    ap.add_argument("--notes", default=None)
    ap.add_argument("--sums", default=None, help="ghi SHA256SUMS (mặc định <dist>/SHA256SUMS)")
    ap.add_argument("--stable", default=os.path.join(REPO, "docs", "stable.json"))
    a = ap.parse_args()

    ver = version()
    sums, series = {}, set()
    for s in sorted(os.listdir(a.dist)):
        d = os.path.join(a.dist, s)
        if not os.path.isdir(d) or s.startswith("."):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith(".deb"):
                continue
            asset = f.replace("~", ".")
            if not re.search(r"_%s\.%s1_(amd64|arm64|all)\.deb$" % (re.escape(ver), s), asset):
                sys.exit("bỏ qua? %s không khớp phiên bản %s~%s1" % (f, ver, s))
            h = hashlib.sha256(open(os.path.join(d, f), "rb").read()).hexdigest()
            sums[asset] = h
            series.add(s)
    if not sums:
        sys.exit("không có .deb trong %s/<series>/" % a.dist)

    # .rpm (<dist>/rpm/<target>/) + .pkg.tar.zst (<dist>/arch/): tên asset giữ nguyên.
    others = {}
    rpm_re = re.compile(r"-%s-\d+\.(fc\d+|el\d+)\.(x86_64|aarch64|noarch)\.rpm$" % re.escape(ver))
    for root, _dirs, files in os.walk(os.path.join(a.dist, "rpm")):
        if os.path.basename(root).startswith("."):
            continue
        for f in sorted(files):
            if f.endswith(".rpm"):
                if f.endswith(".src.rpm") or not rpm_re.search(f):
                    sys.exit("bỏ qua? %s không khớp phiên bản %s" % (f, ver))
                others[f] = os.path.join(root, f)
    archdir = os.path.join(a.dist, "arch")
    if os.path.isdir(archdir):
        for f in sorted(os.listdir(archdir)):
            if f.endswith(".pkg.tar.zst"):
                if not re.search(r"-%s-\d+-(x86_64|aarch64)\.pkg\.tar\.zst$" % re.escape(ver), f):
                    sys.exit("bỏ qua? %s không khớp phiên bản %s" % (f, ver))
                others[f] = os.path.join(archdir, f)

    with open(a.stable, encoding="utf-8") as f:
        info = json.load(f)
    old = info.get("linux") if isinstance(info.get("linux"), dict) else {}
    info["linux"] = {
        "version": ver,
        "url": "%s/tag/linux-v%s" % (GH, ver),
        "download": "%s/download/linux-v%s/" % (GH, ver),
        "series": sorted(series),
        "sha256": dict(sorted(sums.items())),
    }
    notes = a.notes if a.notes is not None else old.get("notes")
    if notes:
        info["linux"]["notes"] = notes
    with open(a.stable, "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=2)
        f.write("\n")

    allsums = dict(sums)
    for name, path in others.items():
        if name in allsums:
            sys.exit("trùng tên asset: %s" % name)
        allsums[name] = hashlib.sha256(open(path, "rb").read()).hexdigest()
    out = a.sums or os.path.join(a.dist, "SHA256SUMS")
    with open(out, "w") as f:
        for name, h in sorted(allsums.items()):
            f.write("%s  %s\n" % (h, name))
    print("stable.json linux → %s (%d .deb); SHA256SUMS → %s (%d file, + %d rpm/pacman)"
          % (ver, len(sums), out, len(allsums), len(others)))


if __name__ == "__main__":
    main()
