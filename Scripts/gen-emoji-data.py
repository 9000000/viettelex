#!/usr/bin/env python3
"""Sinh dữ liệu bàn phím emoji (iOS + Android) từ dữ liệu Unicode chính thức.

Usage:
  gen-emoji-data.py [--emoji-test F] [--cldr-vi F] [--cldr-vi-derived F]
                    [--cldr-en F] [--cldr-en-derived F]
Không đưa đường dẫn → tự tải về ~/.cache/viettelex-emoji/ (chỉ python3 stdlib):
  emoji-test.txt   https://unicode.org/Public/17.0.0/emoji/emoji-test.txt
  vi.xml           CLDR release-48 common/annotations/vi.xml
  vi-derived.xml   CLDR release-48 common/annotationsDerived/vi.xml
  en.xml           CLDR release-48 common/annotations/en.xml
  en-derived.xml   CLDR release-48 common/annotationsDerived/en.xml
(giấy phép Unicode — xem docs/DATA-SOURCES.md). Nguồn từ khoá tiếng Việt thứ hai là
blob gợi ý emoji sẵn có android/app/src/main/assets/emojisuggest.bin (EMS1).

Ghi (hai file GIỐNG HỆT nhau, KHÔNG sửa tay):
  iOS/Keyboard/Resources/emoji.bin
  android/app/src/main/assets/emoji.bin

Chọn emoji: fully-qualified trong emoji-test.txt, phiên bản ≤ MAX_VERSION, bỏ nhóm
Component và mọi chuỗi mang tông da (1F3FB–1F3FF: popup giữ lâu tự sinh). Mỗi emoji
lưu phiên bản (E x.y) để runtime chỉ kiểm glyph những emoji mới hơn mức OS chắc chắn
hỗ trợ (iOS: CoreText; Android: Paint.hasGlyph) — emoji máy không vẽ được thì ẩn.

Layout emoji.bin (little-endian), header "VTE1" | u32 sectionCount, rồi
sectionCount × (tag[4], u32 offset, u32 length) — offset tính từ đầu file:
  EMOJ  u32 n | u32 off[n+1] | utf8           — bảng emoji, id = chỉ số
  EVER  u8 ver[n]                              — phiên bản ×10 (E0.6 → 6, E17.0 → 170)
  ECAT  u32 k | k × (u32 nameOff, u32 nameLen, u32 start, u32 count) | utf8 tên
        (id liền nhau theo thứ tự category)
  SKEY  u32 m | u32 foldOff[m+1] | u32 origOff[m+1] | u32 idOff[m+1]
        | fold utf8 | orig utf8 | u16 ids   — khoá tìm kiếm, sort theo fold
  SKEN  u32 m | u16 foldOff[m+1] | u16 idOff[m+1] | fold utf8 | u16 ids
                                               — khoá TIẾNG ANH (CLDR en), sort theo fold
        (gọn hơn SKEY: không có orig vì khoá tiếng Anh không dấu; offset u16);
        id mỗi khoá xếp theo độ sát (tên tts == khoá > khoá là cụm từ trong tts > còn
        lại; rồi tts ngắn trước). Đã LỌC nhiễu tiếng Việt: bỏ khoá một từ < 3 chữ,
        trùng âm tiết tiếng Việt không dấu (vnlexicon) hoặc là tiền tố của âm tiết đó.
        Dùng cho ô tìm emoji (sau mọi hạng tiếng Việt) và gợi ý khi gõ (khớp nguyên khoá).
  FLG2  u32 n | n × 2B mã ISO 3166 IN HOA (sort) | u16 id[n]
        — gõ đúng "JP" (in hoa) → 🇯🇵; chữ thường không tra (65 mã trùng âm tiết Việt).
  KAOM  u32 g | g × (u32 nameOff, u32 nameLen, u32 start, u32 count)
        | u32 itemCount | u32 itemOff[itemCount+1] | utf8 tên+item
fold = chữ thường, bỏ dấu tiếng Việt (NFD bỏ U+0300–036F, đ→d), dấu câu → space,
gộp space — runtime fold câu tìm theo ĐÚNG luật này (EmojiSearch.fold).
"""
import argparse, os, re, struct, sys, unicodedata, urllib.request
import xml.etree.ElementTree as ET

MAX_VERSION = 17.0
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CACHE = os.path.expanduser("~/.cache/viettelex-emoji")
URLS = {
    "emoji-test.txt": "https://unicode.org/Public/17.0.0/emoji/emoji-test.txt",
    "vi.xml": "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotations/vi.xml",
    "vi-derived.xml": "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotationsDerived/vi.xml",
    "en.xml": "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotations/en.xml",
    "en-derived.xml": "https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/annotationsDerived/en.xml",
}

GROUP_TO_CAT = {
    "Smileys & Emotion": "smileys", "People & Body": "smileys",
    "Animals & Nature": "animals", "Food & Drink": "food",
    "Activities": "activity", "Travel & Places": "travel",
    "Objects": "objects", "Symbols": "symbols", "Flags": "flags",
}
CAT_ORDER = ["smileys", "animals", "food", "activity", "travel", "objects", "symbols", "flags"]

# Kaomoji / ký tự đặc biệt: nội dung biên soạn tay (không phải dữ liệu Unicode).
KAOMOJI = [
    ("vui", ["^_^", "^^", "(^▽^)", "(◕‿◕)", "(≧▽≦)", "(*^▽^*)", "(｡◕‿◕｡)", "٩(◕‿◕)۶",
             "(✿◠‿◠)", "o(^▽^)o", "(•‿•)", "(⌒‿⌒)", "＼(^▽^)／", "(￣▽￣)", "ヽ(・∀・)ﾉ",
             "(ﾉ◕ヮ◕)ﾉ*:･ﾟ✧", "\\(^o^)/", "(^_−)☆", "ᕕ( ᐛ )ᕗ", "(¬‿¬)", "¯\\_(ツ)_/¯",
             "(☞ﾟヮﾟ)☞", "(•̀ᴗ•́)و", "( ͡° ͜ʖ ͡°)"]),
    ("buồn", ["(T_T)", "(;_;)", "(╥﹏╥)", "(ಥ﹏ಥ)", "(｡•́︿•̀｡)", "(´；ω；`)", "(ノ_<。)",
              "｡ﾟ(ﾟ´Д｀ﾟ)ﾟ｡", "(｡╯︵╰｡)", "(-_-)", "(._.)", "(´･_･`)", "(︶︹︺)", "orz",
              "(>_<)", "(ಠ_ಠ)", "(¬_¬)", "(╯°□°)╯︵ ┻━┻", "┬─┬ノ( º _ ºノ)", "(ง'̀-'́)ง"]),
    ("yêu", ["<3", "♥‿♥", "(♥ω♥*)", "(｡♥‿♥｡)", "(づ｡◕‿‿◕｡)づ", "(っ´▽`)っ♥", "♡(ˆ⌣ˆԅ)",
             "(*˘︶˘*).｡.:*♡", "(´∀｀)♡", "( ˘ ³˘)♥", "(づ￣ ³￣)づ", "(✿ ♥‿♥)", "(◍•ᴗ•◍)♡",
             "(ɔˆ ³(ˆ⌣ˆc)", "(っ˘з(˘⌣˘ )", "♡＾▽＾♡"]),
    ("động vật", ["ʕ•ᴥ•ʔ", "ʕ·ᴥ·ʔ", "ʕ￫ᴥ￩ʔ", "(=^･ω･^=)", "(=①ω①=)", "ฅ^•ﻌ•^ฅ", "(ᵔᴥᵔ)",
                  "U・ᴥ・U", "∪･ω･∪", "(・⊝・)", "(•ө•)", "><(((('>", "<°)))><", "(\\_/)",
                  "(='.'=)", "(V) (;,,;) (V)", "~>°)~~~", "(:3 」∠)"]),
    ("ký hiệu", ["₫", "°", "→", "←", "↑", "↓", "↔", "⇒", "✓", "✗", "★", "☆", "♥", "♡",
                 "“”", "‘’", "«»", "…", "•", "·", "–", "—", "±", "×", "÷", "≈", "≠", "≤",
                 "≥", "∞", "‰", "€", "£", "¥", "$", "©", "®", "™", "§", "¶", "№", "½", "¼",
                 "¾", "²", "³", "♪", "♫", "☀", "☁", "☂", "☎", "✉", "✂", "☐", "☑", "※", "†"]),
]


def fetch(name, path):
    if path:
        return open(path, encoding="utf-8").read()
    os.makedirs(CACHE, exist_ok=True)
    p = os.path.join(CACHE, name)
    if not os.path.exists(p):
        print(f"tải {URLS[name]}")
        data = urllib.request.urlopen(URLS[name], timeout=60).read()
        open(p, "wb").write(data)
    return open(p, encoding="utf-8").read()


def fold(s):
    s = unicodedata.normalize("NFD", s.lower().replace("đ", "d"))
    s = "".join(c for c in s if not (0x300 <= ord(c) <= 0x36F))
    return clean(s)


def clean(s):
    """Chữ thường, NFC, dấu câu → space, gộp space."""
    s = unicodedata.normalize("NFC", s.lower())
    s = "".join(c if (c.isalnum() or c == " ") else " " for c in s)
    return " ".join(s.split())


def parse_emoji_test(text):
    emoji, versions, cats = [], {}, {c: [] for c in CAT_ORDER}
    unq = set()           # mọi dạng (kể cả unqualified) — để chèn FE0E cho ký hiệu kaomoji
    group = None
    version_line = re.search(r"^# Version: ([\d.]+)", text, re.M).group(1)
    for line in text.splitlines():
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            continue
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^([0-9A-F ]+?)\s*;\s*([\w-]+)\s*#\s*\S+\s+E([\d.]+)\s", line)
        if not m:
            continue
        cps = [int(x, 16) for x in m.group(1).split()]
        s = "".join(map(chr, cps))
        unq.add(s)
        if m.group(2) != "fully-qualified" or group == "Component":
            continue
        ver = float(m.group(3))
        if ver > MAX_VERSION:
            continue
        if any(0x1F3FB <= c <= 0x1F3FF for c in cps):
            continue
        cats[GROUP_TO_CAT[group]].append(s)
        versions[s] = ver
    # 🇻🇳 đầu nhóm cờ (như bàn phím cũ)
    vn = "\U0001F1FB\U0001F1F3"
    cats["flags"].remove(vn)
    cats["flags"].insert(0, vn)
    for c in CAT_ORDER:
        emoji.extend(cats[c])
    return version_line, emoji, versions, cats, unq


def strip_vs(s):
    return s.replace("\uFE0F", "").replace("\uFE0E", "")


def parse_cldr(text):
    out = []   # (emoji, [phrase…])
    root = ET.fromstring(text.encode("utf-8"))
    for a in root.iter("annotation"):
        cp = a.get("cp")
        phrases = [p.strip() for p in (a.text or "").split("|")] if a.get("type") != "tts" else [a.text or ""]
        out.append((cp, [p for p in phrases if p.strip()]))
    return out


def parse_cldr_typed(text):
    """→ [(emoji, is_tts, [phrase…])] — giữ phân biệt tên (tts) với từ khoá."""
    out = []
    root = ET.fromstring(text.encode("utf-8"))
    for a in root.iter("annotation"):
        tts = a.get("type") == "tts"
        phrases = [a.text or ""] if tts else [p.strip() for p in (a.text or "").split("|")]
        out.append((a.get("cp"), tts, [p for p in phrases if p.strip()]))
    return out


def read_vn_syllables(path):
    """Âm tiết tiếng Việt đã fold (không dấu) từ vnlexicon.bin (VNL2, xem VNLexicon2.kt)."""
    b = open(path, "rb").read()
    assert b[:4] == b"VNL2"
    n = struct.unpack_from("<I", b, 8)[0]
    fo = struct.unpack_from("<I", b, 16)[0]
    oo = struct.unpack_from("<I", b, 16 + 3 * 8)[0]
    offs = struct.unpack_from("<%dI" % (n + 1), b, oo)
    return {b[fo + offs[i]:fo + offs[i + 1]].decode() for i in range(n)}


def is_flag_pair(e):
    return len(e) == 2 and all(0x1F1E6 <= ord(c) <= 0x1F1FF for c in e)


def read_emojisuggest(path):
    b = open(path, "rb").read()
    assert b[:4] == b"EMS1"
    n = struct.unpack_from("<I", b, 4)[0]
    ko = struct.unpack_from("<%dH" % (n + 1), b, 8)
    vo = struct.unpack_from("<%dH" % (n + 1), b, 8 + 2 * (n + 1))
    kb = 8 + 4 * (n + 1)
    vb = kb + ko[-1]
    return [(b[kb + ko[i]:kb + ko[i + 1]].decode(), b[vb + vo[i]:vb + vo[i + 1]].decode().split(" "))
            for i in range(n)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--emoji-test")
    ap.add_argument("--cldr-vi")
    ap.add_argument("--cldr-vi-derived")
    ap.add_argument("--cldr-en")
    ap.add_argument("--cldr-en-derived")
    a = ap.parse_args()

    uver, emoji, versions, cats, unq = parse_emoji_test(fetch("emoji-test.txt", a.emoji_test))
    assert len(set(emoji)) == len(emoji), "emoji trùng"
    ident = {e: i for i, e in enumerate(emoji)}
    by_stripped = {}
    for e in emoji:
        by_stripped.setdefault(strip_vs(e), e)

    def resolve(e):
        if e in ident:
            return ident[e]
        f = by_stripped.get(strip_vs(e))
        return ident[f] if f else None

    # --- khoá tìm kiếm: EmojiSuggest (biên soạn, đứng trước) + CLDR vi
    keys = {}   # orig(clean) -> [ids]

    def add(phrase, e):
        i = resolve(e)
        if i is None:
            return
        k = clean(phrase)
        if not k:
            return
        lst = keys.setdefault(k, [])
        if i not in lst:
            lst.append(i)

    es = read_emojisuggest(os.path.join(ROOT, "android/app/src/main/assets/emojisuggest.bin"))
    for k, vs in es:
        for v in vs:
            add(k, v)
    for name, p in (("vi.xml", a.cldr_vi), ("vi-derived.xml", a.cldr_vi_derived)):
        for cp, phrases in parse_cldr(fetch(name, p)):
            for ph in phrases:
                add(ph, cp)
    items = sorted(keys.items(), key=lambda kv: (fold(kv[0]).encode(), kv[0].encode()))

    # --- khoá tiếng Anh (CLDR en) — section riêng, SKEY tiếng Việt giữ nguyên từng byte.
    syl = read_vn_syllables(os.path.join(ROOT, "iOS/Keyboard/Resources/vnlexicon.bin"))
    syl_prefix = {s[:j] for s in syl for j in range(1, len(s))}
    tts = {}        # id -> tên tts đã fold
    flagname = {}   # id -> tên nước đã clean ("flag: Japan" → "japan")
    en_raw = []     # (phrase, id)
    dropped = {"short": 0, "syllable": 0, "prefix": 0}
    for name, p in (("en.xml", a.cldr_en), ("en-derived.xml", a.cldr_en_derived)):
        for cp, is_tts, phrases in parse_cldr_typed(fetch(name, p)):
            i = resolve(cp)
            if i is None:
                continue
            for ph in phrases:
                if is_tts:
                    tts[i] = fold(ph)
                    if ph.lower().startswith("flag:"):
                        flagname[i] = fold(ph.split(":", 1)[1])
                        en_raw.append((ph.split(":", 1)[1], i))
                en_raw.append((ph, i))
    en_keys = {}    # fold -> [ids]
    for ph, i in en_raw:
        f = fold(ph)
        if not f:
            continue
        words = f.split(" ")
        if len(words) == 1:
            why = "short" if len(f) < 3 else "syllable" if f in syl else "prefix" if f in syl_prefix else None
        else:   # cụm mà mọi từ đều là âm tiết Việt ("the end"…) — gõ tiếng Việt không dấu dễ trùng
            why = "phrase" if all(w in syl for w in words) else None
        if why:
            dropped[why] = dropped.get(why, 0) + 1
            continue
        lst = en_keys.setdefault(f, [])
        if i not in lst:
            lst.append(i)

    def closeness(k, i):
        t = tts.get(i, "")
        if flagname.get(i) == k or t == k:
            return 0
        return 1 if f" {k} " in f" {t} " else 2

    for k, lst in en_keys.items():
        lst.sort(key=lambda i: (closeness(k, i), len(tts.get(i, "")), i))
    en_items = sorted(en_keys.items(), key=lambda kv: kv[0].encode())

    flags = sorted((cp_code, ident[e]) for e in emoji if is_flag_pair(e)
                   for cp_code in ["".join(chr(ord(c) - 0x1F1E6 + 65) for c in e)])
    # "UK" không phải mã ISO nhưng là cách viết tắt phổ biến của 🇬🇧 (GB).
    flags = sorted(flags + [("UK", dict(flags)["GB"])])

    # --- nhị phân
    sections = []

    def u32s(xs):
        return struct.pack("<%dI" % len(xs), *xs)

    def offsets(blobs):
        o = [0]
        for b in blobs:
            o.append(o[-1] + len(b))
        return o

    eb = [e.encode() for e in emoji]
    sections.append((b"EMOJ", u32s([len(eb)]) + u32s(offsets(eb)) + b"".join(eb)))
    sections.append((b"EVER", bytes(int(round(versions[e] * 10)) for e in emoji)))

    names = b""
    table = b""
    start = 0
    for c in CAT_ORDER:
        nb = c.encode()
        table += u32s([len(names), len(nb), start, len(cats[c])])
        names += nb
        start += len(cats[c])
    sections.append((b"ECAT", u32s([len(CAT_ORDER)]) + table + names))

    def skey(its):
        fb = [fold(k).encode() for k, _ in its]
        ob = [k.encode() for k, _ in its]
        ids = [i for _, lst in its for i in lst]
        io = [0]
        for _, lst in its:
            io.append(io[-1] + len(lst))
        assert max(ids) < 65536
        return (u32s([len(its)]) + u32s(offsets(fb)) + u32s(offsets(ob)) + u32s(io)
                + b"".join(fb) + b"".join(ob) + struct.pack("<%dH" % len(ids), *ids))

    sections.append((b"SKEY", skey(items)))
    efb = [k.encode() for k, _ in en_items]
    eids = [i for _, lst in en_items for i in lst]
    eio = [0]
    for _, lst in en_items:
        eio.append(eio[-1] + len(lst))
    efo = offsets(efb)
    assert efo[-1] < 65536 and eio[-1] < 65536, "SKEN vượt u16 — cần offset u32"
    assert len({f for f in efb}) == len(efb), "SKEN trùng fold"

    def u16s(xs):
        return struct.pack("<%dH" % len(xs), *xs)
    sections.append((b"SKEN", u32s([len(en_items)]) + u16s(efo) + u16s(eio) + b"".join(efb) + u16s(eids)))
    assert all(len(c) == 2 and c.isupper() for c, _ in flags)
    sections.append((b"FLG2", u32s([len(flags)]) + "".join(c for c, _ in flags).encode()
                     + struct.pack("<%dH" % len(flags), *[i for _, i in flags])))

    # Ký hiệu kaomoji mà Unicode cũng coi là emoji (♥ ☀ ☎ ✂…) → thêm FE0E để hiện dạng chữ.
    groups, kitems, knames = [], [], b""
    for name, lst in KAOMOJI:
        assert len(set(lst)) == len(lst), f"kaomoji trùng trong {name}"
        fixed = [s + "\uFE0E" if (len(s) == 1 and s in unq) else s for s in lst]
        nb = name.encode()
        groups.append((len(knames), len(nb), len(kitems), len(fixed)))
        knames += nb
        kitems += fixed
    kb = [s.encode() for s in kitems]
    head = u32s([len(groups)]) + b"".join(u32s(list(g)) for g in groups)
    sections.append((b"KAOM", head + u32s([len(kb)]) + u32s(offsets(kb)) + knames + b"".join(kb)))

    # header + section table
    hdr_len = 8 + 12 * len(sections)
    body, table, pos = b"", b"", hdr_len
    for tag, payload in sections:
        while pos % 4:
            body += b"\0"; pos += 1
        table += tag + struct.pack("<II", pos, len(payload))
        body += payload
        pos += len(payload)
    data = b"VTE1" + struct.pack("<I", len(sections)) + table + body

    for rel in ("iOS/Keyboard/Resources/emoji.bin", "android/app/src/main/assets/emoji.bin"):
        p = os.path.join(ROOT, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "wb").write(data)
    newer = {v: sum(1 for e in emoji if versions[e] == v) for v in sorted(set(versions.values())) if v >= 15.0}
    print(f"Emoji {uver}: {len(emoji)} emoji ({', '.join(f'{c}={len(cats[c])}' for c in CAT_ORDER)})")
    print(f"mới: {newer}")
    print(f"khoá tìm: {len(items)}  tiếng Anh: {len(en_items)} (bỏ {dropped})  cờ ISO: {len(flags)}"
          f"  kaomoji: {len(kitems)}  → emoji.bin {len(data)} B")


if __name__ == "__main__":
    main()
