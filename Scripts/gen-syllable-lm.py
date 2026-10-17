#!/usr/bin/env python3
"""gen-syllable-lm.py — sinh MÔ HÌNH NGÔN NGỮ ÂM TIẾT TRIGRAM tĩnh (vnlm.bin) cho gõ vuốt, thanh
gợi ý gõ chạm và Thêm dấu: Kneser-Ney nội suy bậc 3, cắt tỉa + lượng tử codebook, nén Elias–Fano,
mmap đọc tại chỗ.
Chỉ python3 stdlib, trừ `count-np` (numpy — chạy trong container). (Thay cả vnbigram.bin +
Scripts/gen-syllable-bigram.py cũ từ 28/09/2026 — hàm tách nguồn/âm tiết/tập giữ lại của script
đó chuyển nguyên văn vào đây.)

Nguồn + giấy phép + ghi công: docs/DATA-SOURCES.md (Wikipedia/Wikisource/Wikivoyage/
Wikibooks/Wikiquote tiếng Việt — CC BY-SA 4.0; Tatoeba — CC BY 2.0 FR; từ 18/10/2026 thêm
OpenSubtitles (OPUS v2024) + lát diễn đàn FineWeb-2 (ODC-By) qua Scripts/lm-chat-prep.py →
`ids` / `count-np --share` — lệnh đầy đủ: docs/DATA-SOURCES.md mục "Nguồn hội thoại"). Bản dưới
là đường cũ (chỉ Wikimedia + Tatoeba; `ids` + `count-np` không --share cho file y hệt `count`).
Dữ liệu thô KHÔNG commit; tải về thư mục tạm rồi chạy:

  B=https://dumps.wikimedia.org/other/cirrussearch/20251229
  curl -O https://downloads.tatoeba.org/exports/per_language/vie/vie_sentences.tsv.bz2
  for w in viwikisource viwikivoyage viwikibooks viwikiquote; do
    curl -o $w.json.gz $B/$w-20251229-cirrussearch-content.json.gz; done
  # Wikipedia: chỉ 600 MB nén đầu (bài cũ, id thấp — ít bài bot sơ khai)
  curl -r 0-599999999 -o viwiki-part.json.gz $B/viwiki-20251229-cirrussearch-content.json.gz

  python3 Scripts/gen-syllable-lm.py count --lexicon iOS/Keyboard/Resources/vnlexicon.bin \\
      --cache /tmp/lm/ngrams.pkl --test-out /tmp/lm/test.txt --dev-out /tmp/lm/dev.txt \\
      /tmp/bg/*.gz /tmp/bg/*.bz2                                    # ~3 phút, ~4,5 GB RAM
  python3 Scripts/gen-syllable-lm.py build --lexicon iOS/Keyboard/Resources/vnlexicon.bin \\
      --cache /tmp/lm/ngrams.pkl --out iOS/Keyboard/Resources/vnlm.bin \\
      --parity iOS/KeyboardTests/Fixtures/vnlm-parity.txt \\
      --chains iOS/KeyboardTests/Fixtures/bigram-heldout.txt           # ~30 giây, tự kiểm
  cp iOS/Keyboard/Resources/vnlm.bin android/app/src/main/assets/
  # fixture đo độ chính xác (câu kiểm thử đã tách âm tiết)
  python3 Scripts/gen-syllable-lm.py chains --lexicon iOS/Keyboard/Resources/vnlexicon.bin \\
      --input /tmp/lm/test.txt --out iOS/KeyboardTests/Fixtures/bigram-heldout.txt

Tách âm tiết: NFC, chữ thường, kiểu dấu CŨ như vnlexicon (hòa, thủy); chỉ giữ âm tiết có
trong vnlexicon. Chuỗi n-gram đứt ở MỌI thứ không phải khoảng trắng giữa hai âm tiết (dấu
câu, số, từ ngoại lai, ký hiệu). Câu có blake2b(câu) % 20 == 0 bị GIỮ LẠI (không đếm) làm tập
kiểm thử, == 1 làm tập dev (chỉnh trọng số) — `--test-out` / `--dev-out` ghi các câu Tatoeba
giữ lại.

Mô hình (đo & chọn trên tập dev, xem docs/DATA-SOURCES.md mục vnlm.bin):
  - Đếm có trọng số nguồn (Tatoeba ×30 — văn hội thoại, xem WEIGHTS).
  - KN nội suy, chiết khấu tuyệt đối D = 0.75 mọi bậc:
      P1(c)     = (N1+(•c) + 0.5) / (N1+(••) + 0.5·V)                 (continuation)
      P2(c|b)   = max(c(bc) − D, 0)/c(b) + D·N1+(b•)/c(b) · P1(c)
      P3(c|a,b) = max(c(abc) − D, 0)/c(ab) + D·N1+(ab•)/c(ab) · P2(c|b)
    (c(·) có trọng số, N1+ đếm thô; trigram chỉ giữ khi đếm thô ≥ 2.)
  - Giá trị lưu s = ln(P(c|ngữ cảnh) / P1(c)) (nat) — "c hay theo sau ngữ cảnh hơn bình
    thường bao nhiêu"; âm = ít gặp hơn. Không cần lưu P1: decoder đã có tần suất riêng.
  - Thiếu mục: bigram → s = ln γ2(b), γ2(b) = D·N1+(b•)/c(b); dòng trigram có mà thiếu c
    → s = ln γ3(ab) + s2(b, c); không có dòng trigram (ab) → s2(b, c).
  - Cắt tỉa kiểu "weighted difference" (Seymore & Rosenfeld 1996) trên ĐIỂM decoder thật
    sự dùng: bỏ mục khi c_trọng_số · |clip(β·s) − clip(β·s_lùi)| < ngưỡng (β = 0.15,
    clip [−1, 1] — hằng số của SwipeTyping). Ngưỡng bigram 10, trigram 20.
  - Lượng tử i8 = round(s·16), bão hoà ±127 (±7.9 nat — vượt vùng clip của decoder), rồi
    CODEBOOK phi tuyến (v3): k-means 1-D tối ưu (quy hoạch động, trọng số √đếm) với tâm là
    số nguyên i8 — bigram 64 mức (lưu i8 thô), trigram 16 mức + γ3 16 mức (lưu mã 4 bit).
    Hai lượt: khớp codebook trên mô hình chưa lượng tử, rồi dựng lại và cắt tỉa trên CHÍNH
    điểm đã lượng tử. Ngữ cảnh trigram (a, b) phải có mục bigram (a, b) tường minh (v3 đánh
    chỉ số ngữ cảnh theo mục bigram) — 0,3 % ngữ cảnh mồ côi bị bỏ (đo: không đổi gì).
  - uniAdj(c) = q(ln(P1(c)·N / c(c))): cộng vào s2(b, c) ⇒ PMI ln(P2(c|b) / P(c)) theo tần suất
    thật — thanh gợi ý + Thêm dấu dùng (thay vnbigram.bin; khớp PMI cũ ±0.08 nat trên cặp chung).

vnlm.bin v3 (little-endian; mọi mảng đọc tại chỗ, không giải mã vào heap):
   0  "VNM1"
   4  version u32 = 3
   8  count u32          — số âm tiết vnlexicon (id theo THỨ TỰ vnlexicon.bin)
  12  lexHash u32        — FNV-1a 32 của vnlexicon.bin (reader từ chối nếu lệch)
  16  qPerNat u32 = 16   — mọi điểm là i8 / 16 nat
  20  biEntries u32 (nb)   24 triContexts u32 (nk)   28 triEntries u32 (nt)
  32  u8: triL, 8 (bit điểm bigram = i8 thô), bits3, bitsG3, biSel, triSel; u16 0
  40  payloadHash u32    — FNV-1a của byte [128, hết) (test kiểm; reader không quét lúc nạp)
  44  0
  48  offset u32 × 19    — đầu 18 phần dưới đây (theo thứ tự) + kết thúc (= cỡ file)
 128  các phần, mỗi phần pad 0 tới bội 8 rồi thêm 8 byte 0 (đọc u64 vắt biên không tràn;
      reader kiểm cỡ từng phần = đúng như tính từ header):
      g2 i8[count]          — q(ln γ2(b))
      adj i8[count]         — uniAdj: q(ln(P1(c)·N / c(c)))
      cb3 i8[2^bits3], cbg i8[2^bitsG3] — codebook trigram / γ3
      biRow u32[count+1]    — mục bigram của dòng b: [biRow[b], biRow[b+1]) (n_b = hiệu)
      biZero u32[count+1]   — số bit 0 của high trước dòng b (Z_b = count >> L_b + 1, 0 nếu rỗng)
      biLowOff u32[count+1] — bit đầu phần thấp của dòng b trong biLow
      biLow                 — Elias–Fano THEO DÒNG: L_b = ⌊log2(count/n_b)⌋ bit thấp mỗi id c
      biHigh u64[]          — dòng b bắt đầu ở bit biRow[b] + biZero[b]; mục i của dòng (id c)
                              đặt bit (c >> L_b) + i sau đầu dòng; xô h kết thúc ở số 0 thứ h
      biSel u32[]           — vị trí số 0 thứ t·2^biSel (select0 ~1 từ 64 bit: dòng nào cũng
                              có bit 1 ≈ bit 0 nên không dòng dày nào làm quét dài)
      biScore i8[nb]        — điểm s2 (64 mức)
      hasTri bit[nb]        — mục bigram (a, b) có dòng trigram; ngữ cảnh k = rank(j)
      triRank u32[nb/64+1]  — số cờ trước mỗi từ 64 bit
      g3 bitsG3-bit[nk]     — mã γ3 của ngữ cảnh k
      triLow / triHigh / triSel — Elias–Fano TOÀN CỤC của khoá k·count + c (L = triL,
                              số 0 = (nk·count >> L) + 1, mẫu select0 mỗi 2^triSel số 0)
      triScore bits3-bit[nt] — mã điểm trigram
    Khoá bigram (cho checksum) = b·count + c. Dòng ≤ 8 mục quét tuần tự từ đầu dòng; dài
    hơn: select0(biZero[b] + h − 1) mở xô h = c >> L_b (0–2 mục). Checksum mô hình (fixture
    vnlm-parity.txt) = FNV-1a trên (khoá u32, điểm i8, cờ u8) mọi mục bigram, γ3 mọi ngữ
    cảnh, (khoá u32, điểm i8) mọi mục trigram — script tính từ dict, Swift/Kotlin duyệt file.
"""
import argparse, array, bz2, collections, hashlib, importlib.util, json, math, os, pickle, re
import struct, sys, unicodedata, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
HOLDOUT_MOD = 20

D = 0.75
Q = 16
VERSION = 3
BITS2, BITS3, BITSG = 6, 4, 4                # mức codebook 2^bits: bigram (lưu i8 thô), trigram, γ3 (lưu mã)
BI_SEL = 6                                     # mẫu select0 bigram mỗi 64 số 0
TRI_SEL = 8                                    # trigram mỗi 256 (chỉ dùng lúc dựng Context)
BETA, CLIP_LO, CLIP_HI = 0.15, -1.0, 1.0      # = SwipeTyping.lmWeight / lmFloor / lmCap
BR = 0xFFFF
M13 = 0x1FFF

# ---- vnlexicon.bin -------------------------------------------------------------

def load_lexicon(path):
    blob = open(path, "rb").read()
    assert blob[:4] == b"VNL2"
    count, nsec = struct.unpack_from("<II", blob, 8)
    secs = [struct.unpack_from("<II", blob, 16 + i * 8) for i in range(nsec)]
    disp_base = secs[1][0]
    doff_base, _ = secs[4]
    doffs = struct.unpack_from("<%dI" % (count + 1), blob, doff_base)
    words = []
    for i in range(count):
        lo = 0 if i == 0 else doffs[i]
        words.append(blob[disp_base + lo: disp_base + doffs[i + 1]].decode("utf-8"))
    return words, fnv1a(blob)

def fnv1a(data):
    h = 0x811C9DC5
    for b in data:
        h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF
    return h

def _old_style():
    spec = importlib.util.spec_from_file_location("genvnlex", os.path.join(HERE, "gen-vnlexicon.py"))
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m.to_old_style

# ---- nguồn --------------------------------------------------------------------

def gz_lines(path):
    """Đọc gzip theo dòng, chịu được file bị cắt (tải một phần)."""
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    buf = b""
    with open(path, "rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk: break
            try:
                buf += d.decompress(chunk)
            except zlib.error:
                break
            *lines, buf = buf.split(b"\n")
            yield from lines

def cirrus_texts(path):
    for line in gz_lines(path):
        if not line.startswith(b'{"'): continue
        if line.startswith(b'{"index"'): continue
        try: doc = json.loads(line)
        except ValueError: continue
        t = doc.get("text")
        if t: yield t

def tatoeba_texts(path):
    with bz2.open(path, "rt", encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 3: yield parts[2]

def source_of(path):
    b = os.path.basename(path)
    if b.startswith("vie_sentences"): return "tatoeba", tatoeba_texts(path)
    return b.split(".")[0].split("-")[0], cirrus_texts(path)

# Trọng số nguồn: văn hội thoại (Tatoeba) nhỏ nhưng đúng văn phong bàn phím.
# Chọn trên tập dev (Tatoeba giữ lại): ×30 cho top-1 +1.5 điểm so với ×8; ×80 chỉ
# thêm +0.6 mà lệch văn phong Tatoeba (câu dịch) — giữ ×30.
WEIGHTS = {"tatoeba": 30, "viwikisource": 1, "viwikiquote": 2, "viwikivoyage": 1,
           "viwikibooks": 1, "viwiki": 1}

SENT_SPLIT = re.compile(r"(?<=[.!?…])\s+|\n+")
TOKEN = re.compile(r"[^\W\d_]+|\S", re.UNICODE)

def sentences(text):
    for s in SENT_SPLIT.split(text):
        s = s.strip()
        if s: yield s

def held_out(sentence):
    """0 = tập kiểm thử, 1 = tập dev (chỉnh tham số), None = dùng để đếm."""
    h = hashlib.blake2b(sentence.encode("utf-8"), digest_size=4).digest()
    r = int.from_bytes(h, "little") % HOLDOUT_MOD
    return r if r < 2 else None

# ---- đếm ----------------------------------------------------------------------

def id_stream(path, tid, held=(None, None)):
    """Nguồn → mảng id âm tiết, BR ở chỗ đứt chuỗi. Câu giữ lại bị bỏ (Tatoeba: ghi ra
    held[0] = tập kiểm thử / held[1] = tập dev nếu có)."""
    name, texts = source_of(path)
    buf = array.array("H")
    for text in texts:
        text = unicodedata.normalize("NFC", text)
        for s in sentences(text):
            low = s.lower()
            h = held_out(low)
            if h is not None:
                if name == "tatoeba" and held[h]: held[h].write(s + "\n")
                continue
            last_br = True
            for m in TOKEN.finditer(low):
                i = tid(m.group())
                if i < 0:
                    if not last_br: buf.append(BR); last_br = True
                    continue
                buf.append(i); last_br = False
            if not last_br: buf.append(BR)
    return name, buf

def cmd_count(a):
    words, _ = load_lexicon(a.lexicon)
    assert len(words) <= M13, "id phải vừa 13 bit"
    wid = {w: i for i, w in enumerate(words)}
    old = _old_style()
    cache = {}
    def tid(t):
        r = cache.get(t)
        if r is None:
            r = wid.get(old(t), -1)
            if len(cache) < 2_000_000: cache[t] = r
        return r
    uni = collections.Counter(); bi = collections.Counter(); tri = collections.Counter()
    bi_raw = collections.Counter(); tri_raw = collections.Counter()
    CH = 4_000_000
    held = tuple(open(f, "w", encoding="utf-8") if f else None for f in (a.test_out, a.dev_out))
    for path in a.inputs:
        name, ids = id_stream(path, tid, held)
        w = WEIGHTS.get(name, 1)
        L = len(ids)
        for s in range(0, L, CH):
            seg = ids[s: min(L, s + CH + 2)]
            e = min(CH, len(seg))
            u = collections.Counter(x for x in seg[:e] if x != BR)
            b = collections.Counter(x << 13 | y for x, y in zip(seg[:e], seg[1:e + 1])
                                    if x != BR and y != BR)
            t = collections.Counter(x << 26 | y << 13 | z for x, y, z in
                                    zip(seg[:e], seg[1:e + 1], seg[2:e + 2])
                                    if x != BR and y != BR and z != BR)
            bi_raw.update(b); tri_raw.update(t)
            if w != 1:
                for c in (u, b, t):
                    for k in c: c[k] *= w
            uni.update(u); bi.update(b); tri.update(t)
        print(f"{name}: {L} token (×{w}), {len(bi)} bigram, {len(tri)} trigram khác nhau",
              file=sys.stderr, flush=True)
    for f in held:
        if f: f.close()
    cont1 = collections.Counter(k & M13 for k in bi_raw)
    fol1 = collections.Counter(k >> 13 for k in bi_raw)
    fol2 = collections.Counter(k >> 13 for k in tri_raw)
    keep = {k for k, r in tri_raw.items() if r >= 2}
    with open(a.cache, "wb") as f:
        pickle.dump({"count": len(words), "uni": dict(uni), "bi": dict(bi), "bi_raw": dict(bi_raw),
                     "tri": {k: tri[k] for k in keep}, "tri_raw": {k: tri_raw[k] for k in keep},
                     "cont1": dict(cont1), "fol1": dict(fol1), "fol2": dict(fol2)}, f, protocol=4)

# ---- đếm bằng numpy (nguồn lớn: hội thoại, 18/10/2026) ----------------------------------

def cmd_ids(a):
    """Nguồn cũ (dump Wikimedia / Tatoeba) → luồng id .ids (u16, BR = đứt chuỗi) — tách y hệt
    `count` (id_stream). Câu giữ lại Tatoeba ghi ra --test-out / --dev-out như `count`."""
    words, _ = load_lexicon(a.lexicon)
    wid = {w: i for i, w in enumerate(words)}
    old = _old_style()
    cache = {}
    def tid(t):
        r = cache.get(t)
        if r is None:
            r = wid.get(old(t), -1)
            if len(cache) < 2_000_000: cache[t] = r
        return r
    held = tuple(open(f, "w", encoding="utf-8") if f else None for f in (a.test_out, a.dev_out))
    os.makedirs(a.out_dir, exist_ok=True)
    for path in a.inputs:
        name, ids = id_stream(path, tid, held)
        with open(os.path.join(a.out_dir, name + ".ids"), "wb") as f: ids.tofile(f)
        print(f"{name}: {len(ids)} id", file=sys.stderr, flush=True)
    for f in held:
        if f: f.close()

def np_source_counts(path, np, chunk=40_000_000):
    """Một luồng .ids → (uni, bi, tri): mỗi cái (khoá tăng dần int64, đếm thô int64). Khoá như
    `count`: bigram b<<13|c, trigram a<<26|b<<13|c. Đếm theo khúc (gối 2 id) rồi gộp."""
    ids = np.fromfile(path, dtype="<u2")
    parts = ([], [], [])
    def uniq(k):
        u, c = np.unique(k, return_counts=True)
        return u, c.astype(np.int64)
    L = len(ids)
    for s in range(0, L, chunk):
        seg = ids[s: min(L, s + chunk + 2)].astype(np.int64)
        e = min(chunk, len(seg))
        x = seg[:e]; ok = x != BR
        parts[0].append(uniq(x[ok]))
        y = seg[1:e + 1]; n2 = len(y)
        m2 = ok[:n2] & (y != BR)
        parts[1].append(uniq((x[:n2][m2] << 13) | y[m2]))
        z = seg[2:e + 2]; n3 = len(z)
        m3 = ok[:n3] & (y[:n3] != BR) & (z != BR)
        parts[2].append(uniq((x[:n3][m3] << 26) | (y[:n3][m3] << 13) | z[m3]))
    def merge(ps):
        if len(ps) == 1: return ps[0]
        k = np.concatenate([p[0] for p in ps]); c = np.concatenate([p[1] for p in ps])
        u, inv = np.unique(k, return_inverse=True)
        return u, np.bincount(inv, weights=c, minlength=len(u)).astype(np.int64)
    return tuple(merge(p) for p in parts)

def apply_shares(wts, mass, shares):
    """--share: nguồn k chiếm đúng phần p của TỔNG khối lượng có trọng số; tổng giữ bằng khối
    lượng của các nguồn không --share (sửa `wts` tại chỗ)."""
    if shares:
        base = [k for k in mass if k not in shares]
        M = sum(wts[k] * mass[k] for k in base)            # tổng khối lượng giữ như không có nguồn mới
        rest = 1.0 - sum(shares.values())
        for k in base: wts[k] = wts[k] * rest
        for k, p in shares.items(): wts[k] = p * M / mass[k]
    for k in mass:
        print(f"  {k}: ×{wts[k]:.6g} → {wts[k] * mass[k] / 1e6:.2f} tr (khối lượng có trọng số)", file=sys.stderr)

def weights_from_args(names, a):
    wts = {name: WEIGHTS.get(name, 1) for name in names}
    for spec in a.weight or []:
        k, v = spec.split("="); wts[k] = float(v)
    shares = {}
    for spec in a.share or []:
        k, v = spec.split("="); shares[k] = float(v)
    return wts, shares

def cmd_unigram(a):
    """Số đếm UNIGRAM có trọng số (cùng --weight/--share như count-np) → TSV "âm_tiết<TAB>số đếm"
    cho Scripts/gen-vnlexicon.py --counts (tần suất vnlexicon.bin từ corpus trộn, giai đoạn 2
    18/10/2026). Đếm mọi id trong luồng (kể cả âm tiết đứng một mình giữa hai chỗ đứt)."""
    import numpy as np
    words, _ = load_lexicon(a.lexicon)
    n = len(words)
    names = [os.path.basename(p).split(".")[0] for p in a.inputs]
    per = {}
    for name, path in zip(names, a.inputs):
        ids = np.fromfile(path, dtype="<u2")
        per[name] = np.bincount(ids[ids != BR], minlength=n)[:n].astype(np.float64)
    mass = {k: float(v.sum()) for k, v in per.items()}
    wts, shares = weights_from_args(names, a)
    apply_shares(wts, mass, shares)
    tot = sum(per[k] * wts[k] for k in per)
    with open(a.out, "w", encoding="utf-8") as f:
        for i in np.argsort(-tot, kind="stable"):
            f.write(f"{words[i]}\t{tot[i]:.3f}\n")
    if a.per_source:
        with open(a.per_source, "w", encoding="utf-8") as f:
            f.write("syllable\t" + "\t".join(per) + "\n")
            for i in range(n):
                f.write(words[i] + "\t" + "\t".join(str(int(per[k][i])) for k in per) + "\n")
    print(f"unigram: {n} âm tiết, tổng {tot.sum() / 1e6:.2f} tr → {a.out}", file=sys.stderr)
    if a.bigram_out:                       # cặp có trọng số ≥ --bigram-min (seed SeedData, gen-seed-data.py)
        ks, ws = [], []
        for name, path in zip(names, a.inputs):
            cache = path + ".npz"
            if os.path.exists(cache) and os.path.getmtime(cache) >= os.path.getmtime(path):
                z = np.load(cache); u2, c2 = z["u2"], z["c2"]
            else:
                (u1, c1), (u2, c2), (u3, c3) = np_source_counts(path, np)
                np.savez(cache, u1=u1, c1=c1, u2=u2, c2=c2, u3=u3, c3=c3)
            ks.append(u2); ws.append(c2.astype(np.float64) * wts[name])
        u, inv = np.unique(np.concatenate(ks), return_inverse=True)
        w = np.bincount(inv, weights=np.concatenate(ws), minlength=len(u))
        keep = w >= a.bigram_min
        u, w = u[keep], w[keep]
        order = np.argsort(-w, kind="stable")
        with open(a.bigram_out, "w", encoding="utf-8") as f:
            for j in order:
                k = int(u[j]); f.write(f"{words[k >> 13]} {words[k & M13]}\t{w[j]:.3f}\n")
        print(f"bigram: {len(u)} cặp ≥ {a.bigram_min} → {a.bigram_out}", file=sys.stderr)

def cmd_remap(a):
    """Đổi id trong các luồng .ids từ vnlexicon cũ sang vnlexicon mới (cùng tập âm tiết, khác thứ
    tự id vì tần suất đổi) — tương đương chạy lại `ids`/lm-chat-prep với lexicon mới (tách âm
    tiết không phụ thuộc tần suất). Ghi OUT_DIR/<tên file gốc>."""
    import numpy as np
    old, _ = load_lexicon(a.old)
    new, _ = load_lexicon(a.new)
    assert sorted(old) == sorted(new), "hai vnlexicon phải cùng tập âm tiết"
    pos = {w: i for i, w in enumerate(new)}
    lut = np.full(1 << 16, BR, dtype=np.uint16)
    for i, w in enumerate(old): lut[i] = pos[w]
    os.makedirs(a.out_dir, exist_ok=True)
    for path in a.inputs:
        ids = np.fromfile(path, dtype="<u2")
        out = lut[ids]
        assert ((ids == BR) == (out == BR)).all()
        out.astype("<u2").tofile(os.path.join(a.out_dir, os.path.basename(path)))
        print(f"{path}: {len(ids)} id", file=sys.stderr)

def cmd_count_np(a):
    """Như `count` nhưng từ các luồng .ids, đếm bằng numpy (chạy trong container — nguồn hội
    thoại hàng trăm triệu âm tiết vượt sức Counter của python). Trọng số:
      --weight tên=w      hệ số như WEIGHTS (mặc định WEIGHTS, 1 nếu không có);
      --share tên=p       nguồn này chiếm đúng phần p của TỔNG khối lượng có trọng số; các nguồn
                          còn lại chia phần 1 − Σp theo tỉ lệ hệ số của chúng; tổng khối lượng
                          giữ bằng của các nguồn không --share (⇒ ngưỡng cắt tỉa giữ nghĩa).
    Cache chỉ giữ mục CÓ THỂ qua cắt tỉa (đếm có trọng số ≥ --pre2 / --pre3; build kiểm ngưỡng
    ≥ 2× các mức này) + thống kê KN tính trên TOÀN BỘ (N1+, số bigram khác nhau `nbt`).
    Không --share và trọng số mặc định ⇒ cùng cache với `count` (build ra file y hệt từng byte)."""
    import numpy as np
    words, _ = load_lexicon(a.lexicon)
    n = len(words)
    srcs = []
    for spec in a.inputs:
        path = spec
        name = os.path.basename(path).split(".")[0]
        srcs.append((name, path))
    wts, shares = weights_from_args([name for name, _ in srcs], a)
    counts = {}
    for name, path in srcs:
        cache = path + ".npz"
        if os.path.exists(cache) and os.path.getmtime(cache) >= os.path.getmtime(path):
            z = np.load(cache)
            counts[name] = ((z["u1"], z["c1"]), (z["u2"], z["c2"]), (z["u3"], z["c3"]))
        else:
            counts[name] = np_source_counts(path, np)
            (u1, c1), (u2, c2), (u3, c3) = counts[name]
            np.savez(cache, u1=u1, c1=c1, u2=u2, c2=c2, u3=u3, c3=c3)
        print(f"{name}: {int(counts[name][0][1].sum())} âm tiết, {len(counts[name][1][0])} bigram, "
              f"{len(counts[name][2][0])} trigram khác nhau", file=sys.stderr, flush=True)
    mass = {k: float(counts[k][0][1].sum()) for k in counts}
    apply_shares(wts, mass, shares)
    def combine(i):
        ks = np.concatenate([counts[k][i][0] for k in counts])
        raw = np.concatenate([counts[k][i][1] for k in counts])
        wc = np.concatenate([counts[k][i][1].astype(np.float64) * wts[k] for k in counts])
        u, inv = np.unique(ks, return_inverse=True)
        return u, np.bincount(inv, weights=raw, minlength=len(u)).astype(np.int64), \
            np.bincount(inv, weights=wc, minlength=len(u))
    u1, _, w1 = combine(0)
    u2, r2, w2 = combine(1)
    u3, r3, w3 = combine(2)
    del counts
    M13_ = np.int64(M13)
    cont1 = np.bincount(u2 & M13_, minlength=n)
    fol1 = np.bincount(u2 >> 13, minlength=n)
    ab3, fol2c = np.unique(u3 >> 13, return_counts=True)
    keep3 = (r3 >= 2) & (w3 >= a.pre3)
    keep2 = (w2 >= a.pre2)
    def as_int(v): return int(v) if float(v).is_integer() else float(v)
    def d(keys, vals, conv): return {int(k): conv(v) for k, v in zip(keys.tolist(), vals.tolist())}
    wint = all(float(w).is_integer() for w in wts.values())
    cv = (lambda v: int(round(v))) if wint else float
    out = {"count": n,
           "uni": d(u1, w1, cv),
           "bi": d(u2[keep2], w2[keep2], cv), "bi_raw": d(u2[keep2], r2[keep2], int),
           "tri": d(u3[keep3], w3[keep3], cv), "tri_raw": d(u3[keep3], r3[keep3], int),
           "cont1": {int(k): int(v) for k, v in enumerate(cont1.tolist()) if v},
           "fol1": {int(k): int(v) for k, v in enumerate(fol1.tolist()) if v},
           "fol2": d(ab3, fol2c, int),
           "nbt": int(len(u2)), "pre2": a.pre2, "pre3": a.pre3,
           "weights": {k: float(v) for k, v in wts.items()}, "mass": mass}
    with open(a.cache, "wb") as f: pickle.dump(out, f, protocol=4)
    print(f"cache: {len(out['bi'])} bigram, {len(out['tri'])} trigram (ứng viên), nbt {out['nbt']} → {a.cache}",
          file=sys.stderr)

# ---- mô hình ------------------------------------------------------------------

class KN:
    def __init__(self, c):
        self.__dict__.update(c)
        self.nbt = float(c.get("nbt", len(self.bi_raw)))

    def p1(self, c):
        return (self.cont1.get(c, 0) + 0.5) / (self.nbt + 0.5 * self.count)

    def p2(self, b, c):
        cb = self.uni.get(b, 0); f = self.fol1.get(b, 0)
        if cb == 0 or f == 0: return self.p1(c)
        return max(self.bi.get(b << 13 | c, 0.0) - D, 0) / cb + D * f / cb * self.p1(c)

    def p3(self, a, b, c):
        ab = a << 13 | b
        cab = self.bi.get(ab, 0.0); f = self.fol2.get(ab, 0)
        if cab == 0 or f == 0: return self.p2(b, c)
        return max(self.tri.get(ab << 13 | c, 0.0) - D, 0) / cab + D * f / cab * self.p2(b, c)

def qz(s): return max(-127, min(127, round(s * Q)))
def clip(s): return max(CLIP_LO, min(CLIP_HI, BETA * s))

# ---- codebook (lượng tử phi tuyến) ------------------------------------------------

def fit_codebook(hist, k):
    """hist: giá trị i8 → trọng số. K-means 1-D TỐI ƯU (quy hoạch động) với tâm NGUYÊN (bội
    1/16 nat — giải mã ra đúng một giá trị i8, parity dễ kiểm). Trả ≤ k tâm tăng dần."""
    xs = sorted(hist)
    if len(xs) <= k: return xs
    n = len(xs)
    P = [0.0]; PX = [0.0]; PXX = [0.0]
    for x in xs:
        w = hist[x]
        P.append(P[-1] + w); PX.append(PX[-1] + w * x); PXX.append(PXX[-1] + w * x * x)
    memo = {}
    def cost(i, j):                                   # cụm xs[i:j] → (sai số, tâm nguyên)
        r = memo.get((i, j))
        if r is None:
            W, S, SS = P[j] - P[i], PX[j] - PX[i], PXX[j] - PXX[i]
            mu = S / W
            r = min((SS - 2 * c * S + c * c * W, c) for c in (math.floor(mu), math.ceil(mu)))
            memo[(i, j)] = r
        return r
    INF = float("inf")
    dp = [[INF] * (n + 1) for _ in range(k + 1)]; bk = [[0] * (n + 1) for _ in range(k + 1)]
    dp[0][0] = 0.0
    for q in range(1, k + 1):
        for j in range(1, n + 1):
            best, arg = INF, 0
            for i in range(q - 1, j):
                if dp[q - 1][i] == INF: continue
                v = dp[q - 1][i] + cost(i, j)[0]
                if v < best: best, arg = v, i
            dp[q][j], bk[q][j] = best, arg
    cents, j = [], n
    for q in range(k, 0, -1):
        i = bk[q][j]; cents.append(cost(i, j)[1]); j = i
    return sorted(set(cents))

def nearest_map(cb):
    """i8 → tâm gần nhất (hoà ⇒ tâm nhỏ hơn)."""
    return {v: min(cb, key=lambda c: (abs(c - v), c)) for v in range(-127, 128)}

# ---- dựng mô hình ------------------------------------------------------------------

def _build(m, th2, th3, q2=None, q3=None, qg=None, mc2=2):
    """Một lượt: tính điểm (đã lượng tử theo codebook nếu có) rồi cắt tỉa trên CHÍNH điểm
    lưu. Trả g2, bi, g3, tri + trọng số (đếm) từng mục để khớp codebook."""
    g2 = {}
    for b, f in m.fol1.items():
        cb = m.uni.get(b, 0)
        if cb > 0 and f > 0: g2[b] = qz(math.log(D * f / cb))
    bi = {}; w2 = {}
    for k, r in m.bi_raw.items():
        if r < mc2: continue
        b, c = k >> 13, k & M13
        if b not in g2: continue
        q = qz(math.log(m.p2(b, c) / m.p1(c)))
        if q2: q = q2[q]
        if m.bi[k] * abs(clip(q / Q) - clip(g2[b] / Q)) >= th2: bi[k] = q; w2[k] = m.bi[k]
    def s2(b, c):
        q = bi.get(b << 13 | c)
        return (q if q is not None else g2.get(b, 0)) / Q
    tri = {}; g3 = {}; w3 = {}; wg = {}
    for k in m.tri_raw:
        ab = k >> 13; a, b, c = ab >> 13, ab & M13, k & M13
        cab = m.bi.get(ab, 0.0); f = m.fol2.get(ab, 0)
        if cab <= 0 or f == 0: continue
        g = g3.get(ab)
        if g is None:
            g = qz(math.log(D * f / cab))
            if qg: g = qg[g]
            g3[ab] = g; wg[ab] = cab
        q = qz(math.log(m.p3(a, b, c) / m.p1(c)))
        if q3: q = q3[q]
        if m.tri[k] * abs(clip(q / Q) - clip(g / Q + s2(b, c))) >= th3: tri[k] = q; w3[k] = m.tri[k]
    # dòng trigram phải treo vào một mục bigram (a, b) tường minh (v3 đánh chỉ số ngữ cảnh
    # theo mục bigram): ~0,3 % ngữ cảnh mồ côi (bigram bị cắt tỉa) ⇒ bỏ (đo: không đổi gì)
    rows = {k >> 13 for k in tri if (k >> 13) in bi}
    tri = {k: v for k, v in tri.items() if (k >> 13) in rows}
    g3 = {k: v for k, v in g3.items() if k in rows}
    return g2, bi, g3, tri, w2, w3, wg

def build_model(m, th2, th3, bits2=BITS2, bits3=BITS3, bitsg=BITSG):
    """Hai lượt: (1) không lượng tử → khớp codebook trên mục giữ lại (trọng số √đếm);
    (2) dựng lại với điểm đã lượng tử (cắt tỉa theo giá trị thật sự lưu). Tất định."""
    g2, bi, g3, tri, w2, w3, wg = _build(m, th2, th3)
    def hist(d, w):
        h = collections.defaultdict(float)
        for k in sorted(d): h[d[k]] += math.sqrt(w[k])
        return h
    cb2 = fit_codebook(hist(bi, w2), 1 << bits2)
    cb3 = fit_codebook(hist(tri, w3), 1 << bits3)
    cbg = fit_codebook(hist(g3, wg), 1 << bitsg)
    g2, bi, g3, tri, *_ = _build(m, th2, th3, nearest_map(cb2), nearest_map(cb3), nearest_map(cbg))
    return g2, bi, g3, tri, (cb2, cb3, cbg)

def uni_adj(m):
    """q(ln(P1(c)·N / c(c))) — cộng vào s2 ⇒ PMI ln(P2(c|b) / P(c)) theo unigram thật."""
    n = float(sum(m.uni.values()))
    return {c: qz(math.log(m.p1(c) * n / u)) for c, u in m.uni.items() if u > 0}

# ---- v3: Elias–Fano + bit-pack ----------------------------------------------------

SECTIONS = ("g2", "adj", "cb3", "cbg", "biRow", "biZero", "biLowOff", "biLow", "biHigh", "biSel",
            "biScore", "hasTri", "triRank", "g3", "triLow", "triHigh", "triSel", "triScore")
HEADER = 128

def ef_low_bits(n, u):
    """L = ⌊log2(u/n)⌋ (0 nếu n = 0 hoặc u < n)."""
    return (u // n).bit_length() - 1 if n and u >= n else 0

def pack_bits(values, width):
    out = bytearray(); acc = 0; na = 0
    if width == 0: return bytes()
    for v in values:
        acc |= v << na; na += width
        while na >= 8: out.append(acc & 0xFF); acc >>= 8; na -= 8
    if na: out.append(acc & 0xFF)
    return bytes(out)

def ef_encode(keys, u):
    """Elias–Fano TOÀN CỤC (trigram): keys tăng ngặt < u → (L, low, high, sel). high: bit
    (key>>L) + i; số bit 0 = (u>>L)+1 (mọi xô có số 0 kết thúc); sel[t] = vị trí số 0 thứ
    t·2^TRI_SEL."""
    n = len(keys)
    L = ef_low_bits(n, u)
    mask = (1 << L) - 1
    low = pack_bits((k & mask for k in keys), L)
    zeros = (u >> L) + 1
    H = n + zeros
    high = bytearray((H + 7) // 8)
    prev = -1
    for i, k in enumerate(keys):
        assert k > prev and k < u; prev = k
        p = (k >> L) + i
        high[p >> 3] |= 1 << (p & 7)
    sel, z = select_samples(high, H, TRI_SEL)
    assert z == zeros
    return L, low, bytes(high), sel

def select_samples(high, H, shift):
    """sel[t] = vị trí số 0 thứ t·2^shift trong H bit đầu của `high`; trả (byte, số số 0)."""
    sel = []; z = 0
    for p in range(H):
        if not (high[p >> 3] >> (p & 7)) & 1:
            if z & ((1 << shift) - 1) == 0: sel.append(p)
            z += 1
    return struct.pack("<%dI" % len(sel), *sel), z

def ef_rows(rows, u):
    """Elias–Fano THEO DÒNG (dòng b: id tăng dần < u): mỗi dòng L_b = ⌊log2(u/n_b)⌋ riêng,
    Z_b = (u >> L_b) + 1 số 0 (dòng rỗng: 0); bit high của cả bảng nối liền — dòng b bắt đầu ở
    bit row[b] + zero[b]. Mật độ bit 1 / bit 0 của mọi dòng ~ 1 ⇒ select0 theo mẫu luôn quét
    ngắn (EF toàn cục sẽ dày đặc ở dòng lớn như "của", "và")."""
    row = [0]; zero = [0]; lowoff = [0]
    for ids in rows:
        n = len(ids); L = ef_low_bits(n, u)
        row.append(row[-1] + n); zero.append(zero[-1] + ((u >> L) + 1 if n else 0))
        lowoff.append(lowoff[-1] + n * L)
    H = row[-1] + zero[-1]
    high = bytearray((H + 7) // 8)
    lows = []
    for b, ids in enumerate(rows):
        n = len(ids); L = ef_low_bits(n, u); start = row[b] + zero[b]; prev = -1
        for i, c in enumerate(ids):
            assert prev < c < u; prev = c
            p = start + (c >> L) + i
            high[p >> 3] |= 1 << (p & 7)
            lows.append((c & ((1 << L) - 1), L))
    acc = 0; na = 0; low = bytearray()
    for v, L in lows:
        acc |= v << na; na += L
        while na >= 8: low.append(acc & 0xFF); acc >>= 8; na -= 8
    if na: low.append(acc & 0xFF)
    sel, z = select_samples(high, H, BI_SEL)
    assert z == zero[-1]
    return (struct.pack("<%dI" % len(row), *row), struct.pack("<%dI" % len(zero), *zero),
            struct.pack("<%dI" % len(lowoff), *lowoff), bytes(low), bytes(high), sel)

def pad_section(b):
    """Bội 8 + 8 byte 0: đọc u64 vắt qua ranh giới luôn nằm trong file."""
    return b + b"\0" * (-len(b) % 8 + 8)

def serialize(count, lex_hash, g2, bi, g3, tri, adj, cbs):
    _, cb3, cbg = cbs                               # codebook bigram không lưu (điểm i8 thô)
    b3, bg = BITS3, BITSG
    def code_of(cb, width):
        assert len(cb) <= 1 << width
        return {v: i for i, v in enumerate(cb)}, cb + [cb[-1]] * ((1 << width) - len(cb))
    c3, t3 = code_of(cb3, b3); cg, tg = code_of(cbg, bg)
    bkeys = sorted(bi)                              # (b<<13|c), cùng thứ tự với b·count + c
    bidx = {k: j for j, k in enumerate(bkeys)}
    ctx = sorted(g3, key=lambda ab: bidx[ab])       # ngữ cảnh k ↔ mục bigram thứ rank(j)
    kidx = {ab: i for i, ab in enumerate(ctx)}
    tkeys = sorted(tri, key=lambda t: (kidx[t >> 13], t & M13))
    nb, nk, nt = len(bkeys), len(ctx), len(tkeys)
    rows = [[] for _ in range(count)]
    for k in bkeys: rows[k >> 13].append(k & M13)
    brow, bzero, blowoff, blow, bhigh, bsel = ef_rows(rows, count)
    tL, tlow, thigh, tsel = ef_encode([kidx[t >> 13] * count + (t & M13) for t in tkeys], nk * count)
    has = bytearray((nb + 7) // 8)
    for ab in ctx:
        j = bidx[ab]; has[j >> 3] |= 1 << (j & 7)
    rank = []; r = 0                                 # số cờ trước mỗi từ 64 bit (rank = 1 đọc + popcount)
    for t in range((nb >> 6) + 1):
        rank.append(r)
        r += sum(bin(x).count("1") for x in has[t * 8: t * 8 + 8])
    sec = {
        "g2": struct.pack("<%db" % count, *(g2.get(i, 0) for i in range(count))),
        "adj": struct.pack("<%db" % count, *(adj.get(i, 0) for i in range(count))),
        "cb3": struct.pack("<%db" % len(t3), *t3),
        "cbg": struct.pack("<%db" % len(tg), *tg),
        "biRow": brow, "biZero": bzero, "biLowOff": blowoff,
        "biLow": blow, "biHigh": bhigh, "biSel": bsel,
        # điểm bigram: giá trị i8 THÔ (đã lượng tử về 2^BITS2 mức) — tra ngẫu nhiên nhiều nhất:
        # 1 byte đọc thẳng thay mã 6 bit + codebook (+83 KB, độ trễ JVM/iOS, docs/DATA-SOURCES.md)
        "biScore": struct.pack("<%db" % nb, *(bi[k] for k in bkeys)),
        "hasTri": bytes(has), "triRank": struct.pack("<%dI" % len(rank), *rank),
        "g3": pack_bits((cg[g3[ab]] for ab in ctx), bg),
        "triLow": tlow, "triHigh": thigh, "triSel": tsel,
        "triScore": pack_bits((c3[tri[t]] for t in tkeys), b3),
    }
    body = bytearray(); offs = []
    for name in SECTIONS:
        offs.append(HEADER + len(body)); body += pad_section(sec[name])
    offs.append(HEADER + len(body))
    head = b"VNM1" + struct.pack("<7I", VERSION, count, lex_hash, Q, nb, nk, nt)
    head += struct.pack("<6BH", tL, 8, b3, bg, BI_SEL, TRI_SEL, 0)
    head += struct.pack("<I", fnv1a(body))
    head += struct.pack("<I", 0)
    head += struct.pack("<%dI" % len(offs), *offs)
    head += b"\0" * (HEADER - len(head))
    assert len(head) == HEADER
    return bytes(head) + bytes(body)

def model_checksum(count, g2, bi, g3, tri):
    """FNV-1a trên toàn bộ mô hình theo thứ tự giải mã (reader Swift/Kotlin tính y hệt khi
    duyệt hết file): mỗi mục bigram (key u32, điểm i8, cờ trigram u8); γ3 mỗi ngữ cảnh (i8);
    mỗi mục trigram (key u32, điểm i8). key bigram = b·count + c, trigram = k·count + c."""
    h = 0x811C9DC5
    def mix(bs):
        nonlocal h
        for x in bs: h = ((h ^ x) * 0x01000193) & 0xFFFFFFFF
    bkeys = sorted(bi); bidx = {k: j for j, k in enumerate(bkeys)}
    ctx = sorted(g3, key=lambda ab: bidx[ab]); kidx = {ab: i for i, ab in enumerate(ctx)}
    for k in bkeys:
        mix(struct.pack("<Ibb", (k >> 13) * count + (k & M13), bi[k], 1 if k in g3 else 0))
    for ab in ctx: mix(struct.pack("<b", g3[ab]))
    for t in sorted(tri, key=lambda t: (kidx[t >> 13], t & M13)):
        mix(struct.pack("<Ib", kidx[t >> 13] * count + (t & M13), tri[t]))
    return h

class RefLM:
    """Tham chiếu ngữ nghĩa (từ dict, không qua byte) — sinh fixture parity."""
    def __init__(self, count, g2, bi, g3, tri, adj):
        self.count, self.g2, self.bi, self.g3, self.tri, self.adj = count, g2, bi, g3, tri, adj
        self.rows = collections.Counter(k >> 13 for k in bi)
    def score(self, p2, p1, w):                       # đơn vị q (1/16 nat)
        if not (0 <= p1 < self.count) or not (0 <= w < self.count): return 0
        ab = p2 << 13 | p1 if 0 <= p2 < self.count else None
        if ab is not None and ab in self.g3:
            t = self.tri.get(ab << 13 | w)
            if t is not None: return t
        q = self.bi.get(p1 << 13 | w)
        s2 = q if q is not None else self.g2.get(p1, 0)
        return (self.g3[ab] + s2) if ab is not None and ab in self.g3 else s2
    def pmi(self, p, w):
        if not (0 <= p < self.count) or self.rows[p] == 0 or not (0 <= w < self.count): return 0
        q = self.bi.get(p << 13 | w)
        return (q if q is not None else self.g2.get(p, 0)) + self.adj.get(w, 0)
    def explicit(self, p, w):
        if not (0 <= p < self.count) or not (0 <= w < self.count): return 0
        q = self.bi.get(p << 13 | w)
        return q + self.adj.get(w, 0) if q is not None else 0
    def size(self, p):
        return self.rows[p] if 0 <= p < self.count else 0

class V3:
    """Reader v3 bằng Python — CÙNG thuật toán với SyllableLM.swift/.kt (select0 theo mẫu,
    xô Elias–Fano, rank cờ trigram). Tự kiểm sau khi sinh (build) + làm đặc tả."""
    def __init__(self, blob):
        assert blob[:4] == b"VNM1"
        (self.version, self.count, self.lex_hash, self.q, self.nb, self.nk, self.nt) = struct.unpack_from("<7I", blob, 4)
        assert self.version == VERSION
        self.tL, self.b2, self.b3, self.bg, self.bsel, self.tsel, _ = struct.unpack_from("<6BH", blob, 32)
        self.payload_hash, = struct.unpack_from("<I", blob, 40)
        offs = struct.unpack_from("<%dI" % (len(SECTIONS) + 1), blob, 48)
        self.sec = {n: offs[i] for i, n in enumerate(SECTIONS)}
        assert offs[-1] == len(blob)
        self.b = blob
    def u64(self, sec, wi): return struct.unpack_from("<Q", self.b, self.sec[sec] + wi * 8)[0]
    def bits(self, sec, pos, width):
        if width == 0: return 0
        wi, sh = pos >> 6, pos & 63
        v = self.u64(sec, wi) >> sh
        if sh + width > 64: v |= self.u64(sec, wi + 1) << (64 - sh)
        return v & ((1 << width) - 1)
    def i8(self, sec, i): return struct.unpack_from("<b", self.b, self.sec[sec] + i)[0]
    def u32(self, sec, i): return struct.unpack_from("<I", self.b, self.sec[sec] + i * 4)[0]
    def bit(self, sec, p): return (self.b[self.sec[sec] + (p >> 3)] >> (p & 7)) & 1
    # --- Elias–Fano ---
    def select0(self, pre, shift, r):
        """Vị trí số 0 thứ r (từ 0) trong mảng high của `pre` (mẫu mỗi 2^shift số 0)."""
        hi = pre + "High"
        t = r >> shift
        p = self.u32(pre + "Sel", t)
        k = r - (t << shift)
        if k == 0: return p
        pos = p + 1
        wi = pos >> 6
        w = ~self.u64(hi, wi) & ((1 << 64) - 1) & ~((1 << (pos & 63)) - 1)
        while True:
            c = bin(w).count("1")
            if c >= k:
                for _ in range(k - 1): w &= w - 1
                return wi * 64 + ((w & -w).bit_length() - 1)
            k -= c; wi += 1
            w = ~self.u64(hi, wi) & ((1 << 64) - 1)
    def run_len(self, hi, pos):
        n = 0
        while self.bit(hi, pos): n += 1; pos += 1
        return n
    # trigram: EF toàn cục, khoá k·count + c
    def tri_bucket(self, h):
        if h == 0: return 0, 0
        z = self.select0("tri", self.tsel, h - 1)
        return z + 1, z + 1 - h
    def tri_lower_bound(self, x):
        L = self.tL; h = x >> L; t = x & ((1 << L) - 1)
        pos, idx = self.tri_bucket(h)
        while self.bit("triHigh", pos) and self.bits("triLow", idx * L, L) < t: pos += 1; idx += 1
        return idx, pos
    def tri_find(self, x):
        L = self.tL
        pos, idx = self.tri_bucket(x >> L)
        for m in range(idx, idx + self.run_len("triHigh", pos)):
            if self.bits("triLow", m * L, L) == x & ((1 << L) - 1): return m
        return -1
    # bigram: EF theo dòng
    def bi_row(self, b):
        lo, hi = self.u32("biRow", b), self.u32("biRow", b + 1)
        L = ef_low_bits(hi - lo, self.count)
        return lo, hi, L, self.u32("biZero", b), self.u32("biLowOff", b)
    def bi_find(self, b, c):
        lo, hi, L, z0, lowoff = self.bi_row(b)
        if lo == hi: return -1
        h = c >> L
        if h == 0: pos, idx = lo + z0, lo
        else:
            z = z0 + h - 1
            pos = self.select0("bi", self.bsel, z) + 1; idx = pos - (z + 1)
        for m in range(idx, idx + self.run_len("biHigh", pos)):
            if self.bits("biLow", lowoff + (m - lo) * L, L) == c & ((1 << L) - 1): return m
        return -1
    def bi_scan(self, b):
        lo, hi, L, z0, lowoff = self.bi_row(b)
        pos = lo + z0; out = []
        for m in range(lo, hi):
            while not self.bit("biHigh", pos): pos += 1
            out.append((m, ((pos - (lo + z0) - (m - lo)) << L) | self.bits("biLow", lowoff + (m - lo) * L, L)))
            pos += 1
        return out
    # --- mô hình ---
    def q2(self, j): return self.i8("biScore", j)
    def q3(self, t): return self.i8("cb3", self.bits("triScore", t * self.b3, self.b3))
    def qg(self, k): return self.i8("cbg", self.bits("g3", k * self.bg, self.bg))
    def rank(self, j):
        r = self.u32("triRank", j >> 6)
        for x in range((j >> 6) * 64, j): r += self.bit("hasTri", x)
        return r
    def score(self, p2, p1, w):
        C = self.count
        if not (0 <= p1 < C) or not (0 <= w < C): return 0
        k = -1
        if 0 <= p2 < C:
            j = self.bi_find(p2, p1)
            if j >= 0 and self.bit("hasTri", j): k = self.rank(j)
        if k >= 0:
            t = self.tri_find(k * C + w)
            if t >= 0: return self.q3(t)
        j = self.bi_find(p1, w)
        s2 = self.q2(j) if j >= 0 else self.i8("g2", p1)
        return self.qg(k) + s2 if k >= 0 else s2
    def pmi(self, p, w):
        C = self.count
        if not (0 <= p < C) or not (0 <= w < C) or self.size(p) == 0: return 0
        j = self.bi_find(p, w)
        return (self.q2(j) if j >= 0 else self.i8("g2", p)) + self.i8("adj", w)
    def explicit(self, p, w):
        C = self.count
        if not (0 <= p < C) or not (0 <= w < C): return 0
        j = self.bi_find(p, w)
        return self.q2(j) + self.i8("adj", w) if j >= 0 else 0
    def size(self, p):
        if not (0 <= p < self.count): return 0
        return self.u32("biRow", p + 1) - self.u32("biRow", p)
    def checksum(self):
        h = 0x811C9DC5
        def mix(bs):
            nonlocal h
            for x in bs: h = ((h ^ x) * 0x01000193) & 0xFFFFFFFF
        for b in range(self.count):
            for j, c in self.bi_scan(b):
                mix(struct.pack("<Ibb", b * self.count + c, self.q2(j), self.bit("hasTri", j)))
        for k in range(self.nk): mix(struct.pack("<b", self.qg(k)))
        pos = 0; L = self.tL
        for t in range(self.nt):
            while not self.bit("triHigh", pos): pos += 1
            mix(struct.pack("<Ib", ((pos - t) << L) | self.bits("triLow", t * L, L), self.q3(t)))
            pos += 1
        # dòng trigram định vị bằng lower_bound phải khớp thứ tự
        for k in range(0, self.nk, 997):
            idx, _ = self.tri_lower_bound(k * self.count)
            assert idx < self.nt
        return h

def verify(blob, ref, checksum, queries):
    """Tự kiểm: payload hash, checksum duyệt toàn bộ, mọi truy vấn parity (reader Python v3 ≡
    tham chiếu dict)."""
    r = V3(blob)
    assert r.payload_hash == fnv1a(blob[HEADER:]), "payload hash"
    assert r.checksum() == checksum, "checksum duyệt toàn bộ"
    for p2, p1, w in queries:
        assert r.score(p2, p1, w) == ref.score(p2, p1, w), ("score", p2, p1, w)
        assert r.pmi(p1, w) == ref.pmi(p1, w), ("pmi", p1, w)
        assert r.explicit(p1, w) == ref.explicit(p1, w), ("explicit", p1, w)
        assert r.size(p1) == ref.size(p1), ("size", p1)

def parity_queries(words, chains_path):
    """Truy vấn parity (tất định): bộ ba liên tiếp của 120 chuỗi kiểm thử đầu + 200 bộ ngẫu
    nhiên (seed cố định) + ca biên (−1, count)."""
    import random
    wid = {w: i for i, w in enumerate(words)}
    rnd = random.Random(20260928)
    n = len(words)
    qs = []
    if chains_path:
        chains = [l.split() for l in open(chains_path, encoding="utf-8") if l.strip() and not l.startswith("#")]
        for ch in chains[:120]:
            ids = [wid[w] for w in ch]
            for i in range(1, len(ids)):
                qs.append((ids[i - 2] if i >= 2 else -1, ids[i - 1], ids[i]))
    for _ in range(200):
        qs.append((rnd.randrange(-1, n), rnd.randrange(0, n), rnd.randrange(0, n)))
    qs += [(-1, -1, 5), (-1, n, 5), (3, 5, n), (-1, 0, 0), (n - 1, n - 1, n - 1), (0, n - 1, 0)]
    return qs

def cmd_build(a):
    words, lex_hash = load_lexicon(a.lexicon)
    with open(a.cache, "rb") as f: c = pickle.load(f)
    assert c["count"] == len(words), "cache dựng từ lexicon khác"
    assert a.th2 >= 2 * c.get("pre2", 0) and a.th3 >= 2 * c.get("pre3", 0), "ngưỡng < 2× mức lọc trước của cache"
    m = KN(c)
    g2, bi, g3, tri, cbs = build_model(m, a.th2, a.th3)
    adj = uni_adj(m)
    n = len(words)
    blob = serialize(n, lex_hash, g2, bi, g3, tri, adj, cbs)
    ref = RefLM(n, g2, bi, g3, tri, adj)
    checksum = model_checksum(n, g2, bi, g3, tri)
    qs = parity_queries(words, a.chains)
    verify(blob, ref, checksum, qs)
    open(a.out, "wb").write(blob)
    print(f"{len(bi)} bigram, {len(g3)} ngữ cảnh trigram, {len(tri)} trigram, codebook "
          f"{cbs[0]} / {cbs[1]} / {cbs[2]}, {len(blob)} byte (đã tự kiểm) → {a.out}", file=sys.stderr)
    if a.parity: write_parity(a.parity, ref, qs, checksum, fnv1a(blob), n)

def write_parity(path, ref, qs, checksum, filehash, n):
    """Fixture parity Swift ≡ Kotlin ≡ script: truy vấn (id) → điểm ×16 (số nguyên — mọi điểm
    lưu là bội 1/16 nat) + checksum duyệt toàn bộ mô hình + hash cả file."""
    out = [f"# vnlm-parity v3 — sinh bởi Scripts/gen-syllable-lm.py build --parity (cùng lần sinh "
           f"vnlm.bin). Dòng: S p2 p1 w q (score·16) | P p w q (pmi·16) | E p w q (explicit·16) | "
           f"N p size. CHECKSUM = FNV-1a duyệt toàn bộ mô hình; FILE = FNV-1a cả file.",
           f"CHECKSUM {checksum}", f"FILE {filehash}"]
    for p2, p1, w in qs:
        out.append(f"S {p2} {p1} {w} {ref.score(p2, p1, w)}")
        out.append(f"P {p1} {w} {ref.pmi(p1, w)}")
        out.append(f"E {p1} {w} {ref.explicit(p1, w)}")
    for p in sorted({q[1] for q in qs[:200]}) + [-1, n]:
        out.append(f"N {p} {ref.size(p)}")
    open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"{len(out)} dòng parity → {path}", file=sys.stderr)

def cmd_chains(a):
    """Câu giữ lại → chuỗi âm tiết liên tiếp (mỗi dòng một chuỗi ≥ 2 âm tiết) — fixture
    đo độ chính xác gõ vuốt (tách âm tiết y như lúc đếm, reader khỏi phải tách lại)."""
    words, _ = load_lexicon(a.lexicon)
    wid = set(words)
    old = _old_style()
    out = [f"# bigram-heldout v1 — câu Tatoeba (CC BY 2.0 FR, https://tatoeba.org) GIỮ LẠI khỏi "
           f"dữ liệu dựng vnlm.bin (hash % 20 == 0). Sinh bởi Scripts/gen-syllable-lm.py chains. "
           f"Mỗi dòng: chuỗi âm tiết liên tiếp trong vnlexicon."]
    n = 0
    for line in open(a.input, encoding="utf-8"):
        chain = []
        for m in TOKEN.finditer(unicodedata.normalize("NFC", line.strip()).lower()):
            t = old(m.group())
            if t in wid: chain.append(t); continue
            if len(chain) >= 2: out.append(" ".join(chain))
            chain = []
        if len(chain) >= 2: out.append(" ".join(chain))
        n += 1
        if a.limit and n >= a.limit: break
    open(a.out, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"{len(out) - 1} chuỗi từ {n} câu → {a.out}", file=sys.stderr)

def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("count")
    p.add_argument("--lexicon", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--test-out")
    p.add_argument("--dev-out")
    p.add_argument("inputs", nargs="+")
    p = sp.add_parser("build")
    p.add_argument("--lexicon", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--th2", type=float, default=10)
    p.add_argument("--th3", type=float, default=20)
    p.add_argument("--parity", help="ghi fixture parity (vnlm-parity.txt)")
    p.add_argument("--chains", help="chuỗi kiểm thử cho truy vấn parity (bigram-heldout.txt)")
    p = sp.add_parser("ids")
    p.add_argument("--lexicon", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--test-out")
    p.add_argument("--dev-out")
    p.add_argument("inputs", nargs="+")
    p = sp.add_parser("count-np")
    p.add_argument("--lexicon", required=True)
    p.add_argument("--cache", required=True)
    p.add_argument("--weight", action="append", help="tên=hệ số")
    p.add_argument("--share", action="append", help="tên=phần khối lượng (0–1)")
    p.add_argument("--pre2", type=float, default=2.0)
    p.add_argument("--pre3", type=float, default=4.0)
    p.add_argument("inputs", nargs="+", help="luồng .ids (tên nguồn = tên file trước dấu chấm)")
    p = sp.add_parser("unigram")
    p.add_argument("--lexicon", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--per-source", help="TSV số đếm thô từng nguồn")
    p.add_argument("--bigram-out", help="TSV \"a b<TAB>số đếm có trọng số\" (cặp ≥ --bigram-min)")
    p.add_argument("--bigram-min", type=float, default=50.0)
    p.add_argument("--weight", action="append", help="tên=hệ số")
    p.add_argument("--share", action="append", help="tên=phần khối lượng (0–1)")
    p.add_argument("inputs", nargs="+", help="luồng .ids")
    p = sp.add_parser("remap")
    p.add_argument("--old", required=True, help="vnlexicon.bin đã dùng sinh luồng .ids")
    p.add_argument("--new", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("inputs", nargs="+")
    p = sp.add_parser("chains")
    p.add_argument("--lexicon", required=True)
    p.add_argument("--input", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--limit", type=int, default=0)
    a = ap.parse_args()
    {"count": cmd_count, "build": cmd_build, "chains": cmd_chains, "ids": cmd_ids,
     "count-np": cmd_count_np, "unigram": cmd_unigram, "remap": cmd_remap}[a.cmd](a)

if __name__ == "__main__":
    main()
