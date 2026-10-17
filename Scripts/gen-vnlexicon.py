#!/usr/bin/env python3
"""gen-vnlexicon.py — sinh vnlexicon.bin (VNL2) + bảng firstCharTop của VNLexicon2.swift/.kt.

Nguồn:
  1. syllables.txt — 7.184 âm tiết tiếng Việt của hieuthi (đã xếp theo tần suất
     corpus báo chí): https://gist.github.com/hieuthi/1f5d80fca871f3642f61f7e3de883f3a
     (raw revision 7d729de429c52d5ae5cc45d726c38e5a66e1d58e, sha256 5fc95005…c888a7).
  2. Tần suất (một trong hai):
     --freq vi_50k.txt  — hermitdave/FrequencyWords content/2016/vi/vi_50k.txt (commit
        b4618471a851365c64a5f81a6bf3990fdc72ab00, sha256 abc4c237…3b4eeb; OpenSubtitles 2016 —
        KHÔNG phải bản 2018) — bản dùng tới 10/2026. Kiểm 18/10/2026: lệnh dưới với hai file
        này tái tạo vnlexicon.bin cũ (150.700 B) TRÙNG TỪNG BYTE, và --patch-sources không đổi
        bảng firstCharTop.
     --counts counts.tsv — "âm_tiết<TAB>số_đếm" (số đếm có trọng số, có thể là số thực) từ
        `gen-syllable-lm.py unigram` trên corpus trộn (Wikimedia + Tatoeba + OpenSubtitles v2024
        + FineWeb-2, cùng trọng số với vnlm.bin) — bản dùng từ 18/10/2026 (giai đoạn 2).

Tần suất 0–255 = max(1, int(255·ln(c)/ln(max c))); âm tiết không có số đếm (hoặc c ≤ 1)
lấy theo hạng hieuthi: max(1, int(60·(1 − rank/n))). Với --counts, số đếm được nhân
`--scale` trước (xem docs/DATA-SOURCES.md mục vnlexicon).

vnlexicon.bin (little-endian): 0 "VNL2" | 4 version u32=1 | 8 count u32 | 12 sectionCount u32=6 |
16 6 × (offset u32, length u32) — offset tính từ đầu file; section đặt liền nhau, mỗi section
bắt đầu ở bội của 4 (đệm 0): folded (ASCII), display (UTF-8), attr (1 byte/ký tự folded =
quality<<3|tone), offsets (count+1 × u32 vào folded/attr), dispOffsets (count+1 × u32),
freqs (count × u8). Entries sort theo (folded, 255−freq, display) ⇒ id = vị trí.

Usage:
  python3 Scripts/gen-vnlexicon.py syllables.txt --freq vi_50k.txt --out vnlexicon.bin
  python3 Scripts/gen-vnlexicon.py syllables.txt --counts counts.tsv --out vnlexicon.bin \
      [--patch-sources]      # ghi lại firstCharTop trong iOS/Keyboard/VNLexicon2.swift + Android VNLexicon2.kt
  python3 Scripts/gen-vnlexicon.py syllables.txt --freq vi_50k.txt --swift out.swift   # định dạng cũ (base64)
"""
import argparse, base64, math, os, re, struct, sys, unicodedata

QUALITY = {}  # char -> (base, quality)
TONE = {}     # combining tone -> tone id
for b, hat, horn in [("a","â","ă"), ("e","ê",None), ("o","ô","ơ"), ("u",None,"ư")]:
    QUALITY[b] = (b, 0)
    if hat: QUALITY[hat] = (b, 1)
    if horn: QUALITY[horn] = (b, 2)
QUALITY["đ"] = ("d", 3)
TONES = {"́": 1, "̀": 2, "̉": 3, "̃": 4, "̣": 5}

def decompose_char(ch):
    """→ (base_ascii, quality, tone) hoặc None nếu không phải chữ Việt/Latin."""
    d = unicodedata.normalize("NFD", ch)
    base_q, tone = d[0], 0
    quality = 0
    rest = d[1:]
    for c in rest:
        if c in TONES: tone = TONES[c]
        elif c == "̂": quality = 1          # circumflex
        elif c in ("̛", "̆"): quality = 2  # horn / breve
    if base_q in QUALITY and quality == 0:
        base, quality = QUALITY[base_q][0], QUALITY[base_q][1]
    else:
        base = QUALITY.get(base_q, (base_q, 0))[0]
    if ch == "đ": base, quality = "d", 3
    if not ("a" <= base <= "z"): return None
    return base, quality, tone

# Kiểu dấu CŨ (hòa, thủy — convention của VietTelex, engine modern=false):
# nguồn hieuthi dùng kiểu mới (toà, thuý) → chuyển về cũ. Riêng sau 'q' thì
# u là glide của 'qu' nên tone ở nguyên âm sau (quỳ giữ nguyên).
_OLD_STYLE = {
    "oà":"òa","oá":"óa","oả":"ỏa","oã":"õa","oạ":"ọa",
    "oè":"òe","oé":"óe","oẻ":"ỏe","oẽ":"õe","oẹ":"ọe",
    "uỳ":"ùy","uý":"úy","uỷ":"ủy","uỹ":"ũy","uỵ":"ụy",
}
def to_old_style(w):
    # chỉ âm tiết MỞ (cặp nguyên âm ở cuối từ): hòa/thủy; có coda giữ nguyên
    # (toàn, thuyền — hai kiểu giống nhau). Sau 'q' thì u là glide → giữ (quý).
    if len(w) >= 2:
        pair = w[-2:]
        if pair in _OLD_STYLE and not (pair[0] == "u" and len(w) >= 3 and w[-3] == "q"):
            return w[:-2] + _OLD_STYLE[pair]
    return w

def load_syllables(path):
    syllables, seen = [], set()
    for line in open(path, encoding="utf-8"):
        w = to_old_style(unicodedata.normalize("NFC", line.strip().lower()))
        if w and w not in seen:
            seen.add(w); syllables.append(w)
    return syllables

def load_freq50k(path):
    counts = {}
    for line in open(path, encoding="utf-8"):
        parts = line.split()
        if len(parts) == 2:
            w = to_old_style(unicodedata.normalize("NFC", parts[0].lower()))
            counts[w] = max(counts.get(w, 0), int(parts[1]))
    return counts

def load_counts(path):
    counts = {}
    for line in open(path, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2 and parts[0]:
            w = to_old_style(unicodedata.normalize("NFC", parts[0].lower()))
            counts[w] = counts.get(w, 0) + float(parts[1])
    return counts

def build_entries(syllables, counts):
    """[(folded, 255−f, display, attrs, f)] đã sort — id = chỉ số."""
    maxlog = math.log(max(counts.values()))
    entries = []
    for rank, w in enumerate(syllables):
        c = counts.get(w)
        if c and c > 1: f = max(1, int(255 * math.log(c) / maxlog))
        elif c: f = 1   # c == 1 (ln = 0) — như bản cũ: max(1, 0)
        else: f = max(1, int(60 * (1 - rank / len(syllables))))
        dec = [decompose_char(ch) for ch in w]
        if any(d is None for d in dec): continue
        folded = "".join(d[0] for d in dec)
        attrs = bytes((d[1] << 3 | d[2]) for d in dec)
        entries.append((folded, 255 - f, w, attrs, f))   # sort key: folded, freq desc
    entries.sort()
    return entries

def blobs(entries):
    folded_blob, attr_blob, disp_blob = bytearray(), bytearray(), bytearray()
    offsets, disp_offsets, freqs = [0], [0], []
    for folded, _, w, attrs, f in entries:
        folded_blob += folded.encode()
        attr_blob += attrs
        disp_blob += w.encode("utf-8")
        offsets.append(len(folded_blob))
        disp_offsets.append(len(disp_blob))
        freqs.append(f)
    return folded_blob, disp_blob, attr_blob, offsets, disp_offsets, freqs

def first_char_top(entries):
    """bucket top-32 theo ký tự folded đầu (hot path prefix 1 phím)."""
    buckets = {}
    for i, (folded, _, w, attrs, f) in enumerate(entries):
        buckets.setdefault(folded[0], []).append((f, i))
    top = {}
    for ch, lst in buckets.items():
        lst.sort(reverse=True)
        top[ch] = [i for _, i in lst[:32]]
    return top

def write_vnl2(entries, out_path):
    folded, disp, attr, offs, doffs, freqs = blobs(entries)
    sections = [bytes(folded), bytes(disp), bytes(attr),
                struct.pack("<%dI" % len(offs), *offs),
                struct.pack("<%dI" % len(doffs), *doffs), bytes(freqs)]
    hdr_len = 16 + 8 * len(sections)
    body, table, pos = bytearray(), [], hdr_len
    for s in sections:
        pad = (-pos) % 4
        body += b"\0" * pad; pos += pad
        table.append((pos, len(s)))
        body += s; pos += len(s)
    out = bytearray(b"VNL2" + struct.pack("<III", 1, len(entries), len(sections)))
    for off, ln in table: out += struct.pack("<II", off, ln)
    out += body
    open(out_path, "wb").write(out)
    return len(out)

def patch_sources(top, root):
    """Ghi lại bảng firstCharTop trong VNLexicon2.swift (iOS) và VNLexicon2.kt (Android)."""
    sw = os.path.join(root, "iOS/Keyboard/VNLexicon2.swift")
    kt = os.path.join(root, "android/keyboard/src/main/kotlin/com/viettelex/keyboard/VNLexicon2.kt")
    s = open(sw, encoding="utf-8").read()
    body = "\n".join(f'        "{ch}": [{", ".join(map(str, top[ch]))}],' for ch in sorted(top))
    s2 = re.sub(r"(static let firstCharTop: \[Character: \[Int\]\] = \[\n)(.*?)(\n    \])",
                lambda m: m.group(1) + body + m.group(3), s, flags=re.S)
    assert s2 != s or body in s, "firstCharTop (Swift) không tìm thấy"
    open(sw, "w", encoding="utf-8").write(s2)
    k = open(kt, encoding="utf-8").read()
    body = "\n".join(f"        '{ch}' to intArrayOf({', '.join(map(str, top[ch]))})," for ch in sorted(top))
    k2 = re.sub(r"(val firstCharTop: Map<Char, IntArray> = mapOf\(\n)(.*?)(\s*\)\n\})",
                lambda m: m.group(1) + body + "\n    )\n}", k, flags=re.S)
    assert k2 != k or body in k, "firstCharTop (Kotlin) không tìm thấy"
    open(kt, "w", encoding="utf-8").write(k2)

def write_swift_legacy(entries, out_path):
    folded_blob, disp_blob, attr_blob, offsets, disp_offsets, freqs = blobs(entries)
    top = first_char_top(entries)
    def b64(data): return base64.b64encode(bytes(data)).decode()
    def u32le(vals): return b64(struct.pack("<%dI" % len(vals), *vals))
    top_lines = []
    for ch in sorted(top):
        ids = ", ".join(str(i) for i in top[ch])
        top_lines.append(f'        "{ch}": [{ids}],')
    swift = f'''// VNLexicon2.swift — GENERATED bởi Scripts/gen-vnlexicon.py. KHÔNG sửa tay.
// {len(entries)} âm tiết tiếng Việt (hieuthi 7184 + tần suất OpenSubtitles),
// sort theo foldedKey rồi tần suất giảm dần. attr mỗi ký tự = quality<<3|tone
// (quality: 0 none, 1 â/ê/ô, 2 ơ/ư/ă, 3 đ; tone: 0 ngang 1 sắc 2 huyền 3 hỏi
// 4 ngã 5 nặng). Blob nằm trong binary — zero cold-start.
import Foundation

enum VNLexicon2Data {{
    static let count = {len(entries)}
    static let foldedBlob = Array("{folded_blob.decode()}".utf8)
    static let displayBlob = Array("{disp_blob.decode()}".utf8)
    static let attrBlob: [UInt8] = Array(Data(base64Encoded: "{b64(attr_blob)}")!)
    static let offsetsRaw = "{u32le(offsets)}"
    static let dispOffsetsRaw = "{u32le(disp_offsets)}"
    static let freqRaw = "{b64(freqs)}"
    static let firstCharTop: [Character: [Int]] = [
{chr(10).join(top_lines)}
    ]
}}
'''
    open(out_path, "w", encoding="utf-8").write(swift)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("syllables")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--freq", help="vi_50k.txt (hermitdave)")
    g.add_argument("--counts", help="âm_tiết<TAB>số đếm (corpus trộn)")
    ap.add_argument("--scale", type=float, default=1.0, help="nhân số đếm --counts trước khi lấy ln")
    ap.add_argument("--out", help="vnlexicon.bin")
    ap.add_argument("--swift", help="định dạng Swift base64 cũ (lịch sử)")
    ap.add_argument("--patch-sources", action="store_true",
                    help="ghi lại firstCharTop trong VNLexicon2.swift / VNLexicon2.kt")
    ap.add_argument("--dump", help="ghi id<TAB>folded<TAB>display<TAB>freq")
    a = ap.parse_args()
    syllables = load_syllables(a.syllables)
    if a.freq:
        counts = load_freq50k(a.freq)
    else:
        counts = {w: c * a.scale for w, c in load_counts(a.counts).items()}
    entries = build_entries(syllables, counts)
    if a.out:
        n = write_vnl2(entries, a.out)
        print(f"{a.out}: {n} B, {len(entries)} âm tiết", file=sys.stderr)
    if a.swift:
        write_swift_legacy(entries, a.swift)
    if a.patch_sources:
        patch_sources(first_char_top(entries),
                      os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if a.dump:
        with open(a.dump, "w", encoding="utf-8") as fo:
            for i, (folded, _, w, attrs, f) in enumerate(entries):
                fo.write(f"{i}\t{folded}\t{w}\t{f}\n")

if __name__ == "__main__":
    main()
