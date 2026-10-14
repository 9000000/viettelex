#!/usr/bin/env python3
"""Xuất dữ liệu GENERATED của bàn phím iOS sang assets Android (blob đọc tại chỗ).

Usage: export-ios-data.py <repo-root>
Đọc iOS/Keyboard/{EmojiSuggest,SeedData}.swift + Resources/vnlexicon.bin +
iOS/ios-mau-cau.yml, ghi android/app/src/main/assets/:
  vnlexicon.bin      — copy nguyên (layout VNL2, xem VNLexicon2.kt)
  emojisuggest.bin   — "EMS1" | count u32 | keyOff u16[count+1] | valOff u16[count+1]
                       | keyBlob | valBlob  (little-endian; offset tính trong từng blob)
  seed.tsv           — "u\tword\tweight" / "b\tprev\tnext\tweight" (chỉ parse khi seed)
  (emoji.bin — emoji + tìm kiếm + kaomoji — do Scripts/gen-emoji-data.py ghi thẳng cho
   cả iOS lẫn Android, không qua script này.)
  ios-mau-cau.yml    — copy
Chạy lại mỗi khi dữ liệu iOS đổi.
"""
import base64, re, shutil, struct, sys, os

root = sys.argv[1]
kb = os.path.join(root, "iOS/Keyboard")
out = os.path.join(root, "android/app/src/main/assets")
os.makedirs(out, exist_ok=True)

def unesc(t):
    return t.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')

# --- EmojiSuggest
src = open(os.path.join(kb, "EmojiSuggest.swift"), encoding="utf-8").read()
def blob(name):
    m = re.search(r'static let %s = bytes\(StaticString\("((?:[^"\\]|\\.)*)"' % name, src, re.S)
    return unesc(m.group(1)).encode("utf-8")
def offs(name):
    m = re.search(r'static let %s = offsets\("([^"]*)"\)' % name, src)
    o = [0]
    for n in base64.b64decode(m.group(1)): o.append(o[-1] + n)
    return o
kblob, vblob = blob("keyBlob"), blob("valBlob")
ko, vo = offs("keyOff"), offs("valOff")
assert ko[-1] == len(kblob) and vo[-1] == len(vblob)
count = len(ko) - 1
declared = int(re.search(r'private static let count = (\d+)', src).group(1))
assert count == declared, (count, declared)
with open(os.path.join(out, "emojisuggest.bin"), "wb") as f:
    f.write(b"EMS1" + struct.pack("<I", count))
    f.write(struct.pack("<%dH" % (count + 1), *ko))
    f.write(struct.pack("<%dH" % (count + 1), *vo))
    f.write(kblob); f.write(vblob)
print("emojisuggest", count)

# --- SeedData
src = open(os.path.join(kb, "SeedData.swift"), encoding="utf-8").read()
ub = re.search(r'static var unigrams: \[String: Int\] \{ \[(.*?)\] \}', src, re.S).group(1)
bb = re.search(r'static var bigrams: \[\(String, String, Int\)\] \{ \[(.*?)\] \}', src, re.S).group(1)
uni = re.findall(r'"((?:[^"\\]|\\.)*)":\s*(\d+)', ub)
bi = re.findall(r'\("((?:[^"\\]|\\.)*)",\s*"((?:[^"\\]|\\.)*)",\s*(\d+)\)', bb)
# Swift dictionary literal: khóa trùng → crash lúc chạy; kiểm tra.
assert len({w for w, _ in uni}) == len(uni), "seed unigram trùng khóa"
with open(os.path.join(out, "seed.tsv"), "w", encoding="utf-8") as f:
    for w, c in uni: f.write(f"u\t{unesc(w)}\t{c}\n")
    for a, b, c in bi: f.write(f"b\t{unesc(a)}\t{unesc(b)}\t{c}\n")
print("seed", len(uni), len(bi))

shutil.copy(os.path.join(kb, "Resources/vnlexicon.bin"), os.path.join(out, "vnlexicon.bin"))
shutil.copy(os.path.join(root, "iOS/ios-mau-cau.yml"), os.path.join(out, "ios-mau-cau.yml"))
print("ok")
