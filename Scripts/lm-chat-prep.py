#!/usr/bin/env python3
"""lm-chat-prep.py — làm sạch NGUỒN HỘI THOẠI (OpenSubtitles, FineWeb-2) thành luồng id âm tiết
cho Scripts/gen-syllable-lm.py (count-np). Giai đoạn 1 dựng lại vnlm.bin (18/10/2026), xem
docs/DATA-SOURCES.md mục "Nguồn hội thoại".

Cần python3 + pyarrow (chỉ chế độ fineweb) — chạy trong container dùng một lần, KHÔNG cài lên
máy. Dữ liệu thô không commit; FineWeb đọc thẳng qua HTTP Range (không tải cả shard).

  lm-chat-prep.py opus    --out DIR/opus     vi.txt.gz
  lm-chat-prep.py fineweb --out DIR/fineweb  --max-syllables 200e6  URL_SHARD...

Đầu ra: OUT.ids (u16 little-endian, 0xFFFF = đứt chuỗi — y như id_stream của gen-syllable-lm),
OUT.test.txt / OUT.dev.txt (mẫu câu GIỮ LẠI đã làm sạch: blake2b % 20 == 0 / 1, như tập Tatoeba),
OUT.stats.json (số câu bỏ theo từng bộ lọc).

Đường xử lý (mỗi câu): NFC → (OpenSubtitles: bỏ rác "N" của xuống dòng \\N) → bỏ URL/email/
@mention/#hashtag (thành chỗ đứt chuỗi) → tách câu ở . ! ? … và xuống dòng → chữ thường →
GIỮ LẠI theo blake2b(câu thô) như gen-syllable-lm (không bao giờ đếm câu kiểm thử/dev Tatoeba
trùng chữ) → kéo dài "điiii" → "đi" → chuẩn hoá teencode (ViSoLex, đã lọc — teencode_map) →
kiểu dấu cũ → id vnlexicon. Bỏ câu khi: < 2 âm tiết Việt; có từ chỉ hợp lệ khi KHÔNG dấu
(khong, duoc — gõ không dấu); tỉ lệ âm tiết có dấu thấp; > 50 % từ không phải âm tiết Việt
(tiếng Anh…); số điện thoại / ≥ 2 từ khoá quảng cáo; lặp từ; có từ tục/tình dục (VULGAR —
nguồn hội thoại bỏ CẢ CÂU, không chỉ n-gram). Trùng lặp: câu (dạng đã chuẩn hoá) ≥ 5 âm tiết
chỉ đếm một lần (lọc Bloom 2^32 bit, tất định); câu ngắn hơn tối đa SHORT_CAP lần mỗi nguồn
("cảm ơn", "được rồi" vẫn giữ được tần suất tương đối).
"""
import argparse, array, collections, hashlib, importlib.util, io, json, multiprocessing, os, re
import sys, time, unicodedata, urllib.request, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("genlm", os.path.join(HERE, "gen-syllable-lm.py"))
G = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(G)

BR = G.BR
SHORT_LEN = 5          # câu < 5 âm tiết: giới hạn số lần thay vì khử trùng tuyệt đối
SHORT_CAP = 8
BLOOM_BITS = 32
SAMPLE_MOD = 40        # ghi 1/40 câu giữ lại ra file mẫu (tập kiểm thử/dev hội thoại)

# Từ tục / tình dục: SensitiveWords (iOS/Keyboard/SensitiveWords.swift) + vài từ tình dục thô
# hay gặp trên mạng. Nguồn hội thoại: câu có một từ trong đây bị BỎ (n-gram của chúng chỉ còn
# từ Wikipedia/Tatoeba như trước). Cụm hai âm tiết: VULGAR_PAIRS.
VULGAR = {"đcm", "đm", "dm", "dcm", "vcl", "vkl", "vl", "cl", "clgt", "cmnr", "cứt", "lồn", "cặc",
          "buồi", "đĩ", "điếm", "đụ", "địt", "tml", "sml", "dâm", "fuck", "shit", "bitch", "wtf",
          "chịch", "xoạc", "nứng", "đéo", "loz", "lìn", "cmn", "đmm", "sex", "porn", "dick",
          "pussy", "cock", "cak", "kặc"}
VULGAR_PAIRS = {("làm", "tình")}

URL_RE = re.compile(r"(?:https?://|www\.)\S+|\S+@\S+\.\w+|(?<!\w)[@#][\w.]+|\b\S+\.(?:com|vn|net|org|info|io|me)\b\S*",
                    re.I)
PHONE_RE = re.compile(r"(?:\+?84|\b0)(?:[\s.\-]?\d){8,10}\b")
SPAM_WORDS = ("liên hệ", "hotline", "zalo", "inbox", "khuyến mãi", "mua ngay", "đặt hàng", "giá chỉ",
              "giá tốt", "giao hàng", "ship cod", "sđt", "đt:", "tư vấn miễn phí", "chiết khấu", "website",
              "đăng ký ngay", "click", "download", "tải về")
SENT_RE = re.compile(r"(?<=[.!?…])\s+|\n+|(?<=[!?]{2})|\s[-–—]\s")
ELONG_RE = re.compile(r"(.)\1{2,}")

def fold(w):
    d = unicodedata.normalize("NFD", w.replace("đ", "d").replace("Đ", "D"))
    return unicodedata.normalize("NFC", "".join(c for c in d if not unicodedata.combining(c)))

# ---- teencode (ViSoLex) -------------------------------------------------------------

# teencode là âm tiết hợp lệ trong vnlexicon nhưng gần như chỉ dùng thay một từ chuẩn
# (khum = không…): chỉ những khoá này được thay dù có trong vnlexicon.
TEENCODE_IN_LEXICON = {"khum": "không", "thui": "thôi", "nhìu": "nhiều", "lun": "luôn", "bít": "biết",
                       "iu": "yêu", "kon": "con", "pé": "bé", "dui": "vui", "hum": "hôm", "hem": "không",
                       "ík": "ít", "wá": "quá", "dzui": "vui", "nhứt": "nhất", "cũg": "cũng"}

def subseq(a, b):
    it = iter(b)
    return all(ch in it for ch in a)

def teencode_map(path, lex, old):
    """ViSoLex dictionary.json (MIT, github.com/HaDung2002/visolex) → {khoá: [âm tiết chuẩn]}.
    Chỉ giữ: khoá KHÔNG phải âm tiết vnlexicon (trừ TEENCODE_IN_LEXICON), một đáp án duy nhất,
    mọi âm tiết đáp án có trong vnlexicon, không phải chỉ là dạng không dấu của đáp án (khong
    → không là gõ không dấu, bộ lọc câu xử lý), khoá ⊂ dạng không dấu của đáp án sau khi thay
    f→ph, j→gi, z→d, w→qu… (loại nhiễu kiểu nsfw → nữa). Đáp án có từ tục ⇒ khoá vào VULGAR."""
    d = json.load(open(path, encoding="utf-8"))
    out, vulgar, stats = {}, set(), collections.Counter()
    def norm_out(o): return [old(t) for t in unicodedata.normalize("NFC", o.lower()).split()]
    for k, v in d.items():
        key = unicodedata.normalize("NFC", k.lower()).strip()
        if " " in key or not key: stats["key-space"] += 1; continue
        outs = {tuple(norm_out(o)) for o in v.get("normalized", [])}
        if any(set(o) & VULGAR or any(p in VULGAR_PAIRS for p in zip(o, o[1:])) for o in outs):
            if old(key) not in lex: vulgar.add(key)
            stats["vulgar"] += 1; continue
        if len(outs) != 1: stats["ambiguous"] += 1; continue
        o = list(outs.pop())
        if not o or not all(t in lex for t in o): stats["bad-output"] += 1; continue
        if old(key) in lex: stats["key-in-lexicon"] += 1; continue
        f = fold(key)
        if f == key and f == fold("".join(o)): stats["unaccented"] += 1; continue
        f2 = f.replace("dz", "d").replace("f", "ph").replace("j", "gi").replace("z", "d").replace("w", "qu")
        tgt = fold("".join(o))
        if not (subseq(f2, tgt) or subseq(f, tgt) or (len(f) >= 3 and sum(c in tgt for c in f) >= len(f) - 1)):
            stats["not-similar"] += 1; continue
        out[key] = o; stats["kept"] += 1
    for k, v in TEENCODE_IN_LEXICON.items():
        out[k] = [old(t) for t in v.split()]
    return out, vulgar, stats

# ---- xử lý câu (chạy trong worker) ------------------------------------------------------

W = {}

def init_worker(lexicon, visolex, mode):
    words, _ = G.load_lexicon(lexicon)
    old = G._old_style()
    lex = set(words)
    tmap, tvulgar, _ = teencode_map(visolex, lex, old)
    W.update(wid={w: i for i, w in enumerate(words)}, lex=lex, old=old, tmap=tmap,
             vulgar=VULGAR | tvulgar, folded={fold(w) for w in words}, mode=mode, cache={})

def norm_token(t):
    """Một từ (chữ thường) → (danh sách âm tiết chuẩn hoá, loại): 'vi' | 'unacc' | 'other'."""
    c = W["cache"].get(t)
    if c is not None: return c
    lex, old, tmap = W["lex"], W["old"], W["tmap"]
    r = None
    o = old(t)
    if o in tmap and (o not in lex or o in TEENCODE_IN_LEXICON): r = (tmap[o], "vi")
    elif o in lex: r = ([o], "vi")
    else:
        if ELONG_RE.search(t):                         # kéo dài: điiii → đi, ơiii → ơi
            for rep in (r"\1", r"\1\1"):
                s = old(ELONG_RE.sub(rep, t))
                if s in tmap: r = (tmap[s], "vi"); break
                if s in lex: r = ([s], "vi"); break
        if r is None:
            if t.isascii() and t in W["folded"]: r = ([], "unacc")
            else: r = ([], "other")
    if len(W["cache"]) < 500_000: W["cache"][t] = r
    return r

def has_dia(s): return not s.isascii()

def process_sentence(s):
    """Câu (chữ thường) → (lý do bỏ | None, danh sách id có BR, số âm tiết Việt)."""
    toks = G.TOKEN.findall(s)
    ids = []; nw = nvi = ndia = nother = 0
    last_br = True; prev = None; run = 0; maxrun = 0
    syls = []
    vulgar = W["vulgar"]; wid = W["wid"]
    for t in toks:
        if t in vulgar: return "vulgar", None, 0
        if not t[0].isalpha():
            if not last_br: ids.append(BR); last_br = True
            continue
        nw += 1
        out, kind = norm_token(t)
        if kind == "unacc": return "unaccented", None, 0
        if kind == "other":
            nother += 1
            if not last_br: ids.append(BR); last_br = True
            continue
        for x in out:
            if x in vulgar: return "vulgar", None, 0
            nvi += 1
            if has_dia(x): ndia += 1
            ids.append(wid[x]); last_br = False; syls.append(x)
            run = run + 1 if x == prev else 1; prev = x; maxrun = max(maxrun, run)
    if nvi < 2: return "short", None, 0
    if nother * 2 > nw: return "english", None, 0
    if nvi >= 5 and ndia < 0.3 * nvi: return "low-diacritics", None, 0
    if nvi >= 3 and ndia == 0: return "low-diacritics", None, 0
    if maxrun >= 4: return "repeat", None, 0
    if nvi >= 8 and len(set(syls)) < 0.35 * nvi: return "repeat", None, 0
    for a, b in zip(syls, syls[1:]):
        if (a, b) in VULGAR_PAIRS: return "vulgar", None, 0
    if not last_br: ids.append(BR)
    return None, ids, nvi

def fix_opus_n(text):
    """\\N (xuống dòng phụ đề) bị dính thành 'Nvà', 'biếtN', 'NNghỉ' ⇒ tách ra (đứt câu)."""
    lex, old = W["lex"], W["old"]
    def rep(m):
        w = m.group(0)
        lw = w.lower()
        if old(lw) in lex: return w
        if w[0] == "N" and len(w) > 1 and (old(lw[1:]) in lex or w[1].isupper()):
            return "\n" + w[1:]
        if w[-1] == "N" and len(w) > 1 and old(lw[:-1]) in lex:
            return w[:-1] + "\n"
        return w
    return re.sub(r"[^\W\d_]+", rep, text)

def process_doc(text):
    """Văn bản → danh sách (câu thô chữ thường, mã giữ lại, lý do, ids, nvi)."""
    mode = W["mode"]
    text = unicodedata.normalize("NFC", text)
    if mode == "opus": text = fix_opus_n(text)
    text = URL_RE.sub(" | ", text)
    res = []
    for s in SENT_RE.split(text):
        s = s.strip(" -–—\t\"'“”")
        if not s: continue
        low = s.lower()
        h = G.held_out(low)
        if PHONE_RE.search(low) or sum(w in low for w in SPAM_WORDS) >= 2:
            res.append((low, h, "spam", None, 0)); continue
        why, ids, nvi = process_sentence(low)
        res.append((low, h, why, ids, nvi))
    return res

def work_batch(batch):
    """Lô văn bản (opus: chuỗi; fineweb: (text, url, dump) — chọn trang ngay trong worker)."""
    out = []
    for t in batch:
        if isinstance(t, tuple):
            text, url, dump = t
            why = fineweb_select(text, url, dump, W["folded"])
            out.append((why, process_doc(text) if why else []))
        else:
            out.append((None, process_doc(t)))
    return out

# ---- nguồn -------------------------------------------------------------------------------

def opus_batches(path, n=2000):
    """vi.txt.gz: mỗi dòng một câu phụ đề; gom theo lô."""
    b = []
    for line in G.gz_lines(path):
        b.append(line.decode("utf-8", "replace"))
        if len(b) >= n: yield b; b = []
    if b: yield b

class HTTPRangeFile(io.RawIOBase):
    """File parquet đọc qua HTTP Range (pyarrow chỉ đọc footer + các cột cần)."""
    def __init__(self, url, block=1 << 20):
        self.url, self.block, self.pos, self.fetched = url, block, 0, 0
        with urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=60) as r:
            self.size = int(r.headers["Content-Length"])
        self.cache_start, self.cache = -1, b""
    def seekable(self): return True
    def readable(self): return True
    def tell(self): return self.pos
    def seek(self, off, whence=0):
        self.pos = off if whence == 0 else (self.pos + off if whence == 1 else self.size + off)
        return self.pos
    def _get(self, a, b):
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={a}-{b - 1}"})
        for i in range(8):
            try:
                with urllib.request.urlopen(req, timeout=180) as r: d = r.read()
                if len(d) == b - a: self.fetched += len(d); return d
            except Exception as e:
                print("  thử lại", a, e, file=sys.stderr)
            time.sleep(3 + 5 * i)
        raise IOError("không tải được đoạn %d-%d" % (a, b))
    def read(self, n=-1):
        if n < 0: n = self.size - self.pos
        n = min(n, self.size - self.pos)
        if n <= 0: return b""
        s = self.pos
        if self.cache_start <= s and s + n <= self.cache_start + len(self.cache):
            o = s - self.cache_start; d = self.cache[o:o + n]
        elif n >= self.block:
            d = self._get(s, s + n)
        else:
            e = min(self.size, s + max(n, self.block))
            self.cache = self._get(s, e); self.cache_start = s; d = self.cache[:n]
        self.pos += len(d); return d
    def readinto(self, b):
        d = self.read(len(b)); b[:len(d)] = d; return len(d)

FORUM_URL = re.compile(r"forum|4rum|diendan|dien-dan|/threads?/|showthread|showpost|viewtopic|/topic|/t-\d|"
                       r"[/.-]t\d+|/f\d+/|/hoi-?dap|/hoidap|hoi-va-dap|/questions?/|answers\.|comment|binh-?luan|"
                       r"tam-?su|confession|chuyen-tro|/archive/index\.php|webtretho|voz\.vn|tinhte\.vn|otofun|"
                       r"lamchame|5giay|vn-zoom|vozforums|kenhsinhvien|hocmai\.vn/forum|tinhte|danketoan|"
                       r"spiderum|tiki\.vn/hoi-dap|zingnews\.vn/.*binh-luan|reddit\.com/r/vietnam", re.I)
CHAT_MARK = re.compile(r"(?<![^\W\d_])(?:mình|bạn|nhé|nha|ạ|ơi|nhỉ|à|hả|ha|nè|đấy|vậy|thế|luôn|chứ|"
                       r"mà|nhưng|tớ|cậu|em|anh|chị|mọi người|hihi|haha|ừ|ừm|dạ|vâng|ok)(?![^\W\d_])", re.I)
NEWS_DOMAIN = re.compile(r"vnexpress|dantri|tuoitre|thanhnien|vietnamnet|zingnews|news\.zing|nld\.com|"
                         r"laodong|baomoi|24h\.com|kenh14|cafef|cafebiz|vov\.vn|vtc\.vn|\.gov\.vn|tienphong|"
                         r"nhandan|qdnd|plo\.vn|vietbao|soha\.vn|wikipedia|rfa\.org|voatiengviet|bbc\.", re.I)

EXCLUDE_URL = re.compile(r"truyen|tieu-?thuyet|novel|ebook|wattpad|nguoi-?lon|18\+|sex|porn|casino|kubet|"
                         r"w88|fun88|nha-?cai|xoso|xo-so|soi-?keo|lo-?de|ca-?cuoc|bong-?da|game-?bai|tai-?xiu|"
                         r"/tag/|/tags/|/search|/category/|login|register", re.I)
SLUG_TOKEN = re.compile(r"[a-z]+")

def domain_of(u):
    return re.sub(r"^https?://(www\.)?", "", u).split("/")[0].lower()

def vi_slug(u, folded):
    """Đường dẫn kiểu slug tiếng Việt không dấu (…/cach-chon-may-giat-cho-gia-dinh) — trang
    dịch máy/spam nước ngoài thường giữ slug tiếng Anh."""
    path = u.split("/", 3)[-1].lower() if u.count("/") >= 3 else ""
    toks = SLUG_TOKEN.findall(path)
    if len(toks) < 3: return False
    return sum(t in folded for t in toks) >= 0.6 * len(toks)

def fineweb_select(text, url, dump, folded):
    """Chọn trang kiểu diễn đàn/bình luận/hỏi đáp/tâm sự: theo URL, hoặc mật độ từ hội thoại
    + slug tiếng Việt + tên miền không phải báo/truyện/cá cược."""
    try:
        if int(dump[8:12]) < 2018: return None             # CC-MAIN-YYYY-WW: chỉ dump ≥ 2018
    except ValueError:
        return None
    if NEWS_DOMAIN.search(url) or EXCLUDE_URL.search(url): return None
    if FORUM_URL.search(url): return "url"
    n = max(1, len(text) // 5)                                # ~ số âm tiết
    if len(CHAT_MARK.findall(text)) >= 0.07 * n and (domain_of(url).endswith(".vn") or vi_slug(url, folded)):
        return "chat"
    return None

def fineweb_batches(urls, stats, max_rg_per_shard, rg_step):
    import pyarrow.parquet as pq
    for url in urls:
        f = HTTPRangeFile(url)
        pf = pq.ParquetFile(f)
        n = pf.metadata.num_row_groups
        taken = 0
        for rg in range(0, n, rg_step):
            if taken >= max_rg_per_shard: break
            meta = pf.metadata.row_group(rg)
            starts = [(c.dictionary_page_offset or c.data_page_offset, c.total_compressed_size)
                      for c in (meta.column(i) for i in range(meta.num_columns))]
            lo = min(o for o, _ in starts); hi = max(o + n for o, n in starts)
            lo = max(0, lo)
            f.cache = f._get(lo, min(f.size, hi)); f.cache_start = lo        # cả row group, một lần tải
            t = pf.read_row_group(rg, columns=["text", "url", "dump"])
            texts, us, dumps = (t.column(c).to_pylist() for c in ("text", "url", "dump"))
            batch = [(domain_of(u), (x, u, dmp)) for x, u, dmp in zip(texts, us, dumps)]
            stats["docs"] += len(batch)
            taken += 1
            stats["row-groups"] += 1
            yield batch
        stats["bytes-fetched"] += f.fetched
        print(f"{url}: {taken} row group, {f.fetched / 1e6:.0f} MB", file=sys.stderr, flush=True)

# ---- main --------------------------------------------------------------------------------

class Bloom:
    def __init__(self, bits):
        self.m = (1 << bits) - 1; self.b = bytearray(1 << (bits - 3))
    def add(self, digest):
        """True nếu ĐÃ có (có thể dương tính giả ~1e-5), rồi thêm."""
        x = int.from_bytes(digest, "little"); m = self.m; b = self.b
        seen = True
        for k in range(4):
            p = (x >> (k * 32)) & m
            if not (b[p >> 3] >> (p & 7)) & 1: seen = False; b[p >> 3] |= 1 << (p & 7)
        return seen

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["opus", "fineweb"])
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("--out", required=True)
    ap.add_argument("--lexicon", default=os.path.join(HERE, "..", "iOS/Keyboard/Resources/vnlexicon.bin"))
    ap.add_argument("--visolex", required=True)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--max-syllables", type=float, default=0)
    ap.add_argument("--domain-cap", type=float, default=0.03, help="fineweb: tối đa phần âm tiết của 1 tên miền")
    ap.add_argument("--max-rg-per-shard", type=int, default=10 ** 9)
    ap.add_argument("--rg-step", type=int, default=1)
    a = ap.parse_args()

    stats = collections.Counter()
    words, _ = G.load_lexicon(a.lexicon)
    _, tv, tstats = teencode_map(a.visolex, set(words), G._old_style())
    stats.update({"teencode-" + k: v for k, v in tstats.items()})
    bloom = Bloom(BLOOM_BITS); short = collections.Counter()
    dom_syl = collections.Counter()
    out = open(a.out + ".ids", "wb")
    held = [open(a.out + ".test.txt", "w", encoding="utf-8"), open(a.out + ".dev.txt", "w", encoding="utf-8")]
    held_seen = set()
    def chains(ids):
        """ids câu giữ lại → các chuỗi ≥ 2 âm tiết (định dạng bigram-heldout.txt)."""
        cur = []
        for x in ids + [BR]:
            if x == BR:
                if len(cur) >= 2: yield " ".join(cur)
                cur = []
            else: cur.append(words[x])
    total = 0
    if a.mode == "opus":
        batches = (list(zip([None] * len(b), b)) for b in opus_batches(a.inputs[0]))
    else:
        batches = fineweb_batches(a.inputs, stats, a.max_rg_per_shard, a.rg_step)
    t0 = t_start = time.time()
    with multiprocessing.Pool(a.workers, init_worker, (a.lexicon, a.visolex, a.mode)) as pool:
        for b, res in zip_batches(pool, batches):
            buf = array.array("H")
            for (dom, _), (sel, sents) in zip(b, res):
                if sel: stats["docs-" + sel] += 1
                for low, h, why, ids, nvi in sents:
                    stats["sent"] += 1
                    if why: stats["drop-" + why] += 1; continue
                    if h is not None:
                        stats["held-%d" % h] += 1
                        dig = hashlib.blake2b(array.array("H", ids).tobytes(), digest_size=8).digest()
                        if int.from_bytes(dig, "big") % SAMPLE_MOD == 0 and dig not in held_seen:
                            held_seen.add(dig)
                            for ch in chains(ids): held[h].write(ch + "\n")
                        continue
                    if a.max_syllables and dom is not None and dom_syl[dom] > a.domain_cap * a.max_syllables:
                        stats["drop-domain-cap"] += 1; continue
                    norm = array.array("H", ids).tobytes()
                    dig = hashlib.blake2b(norm, digest_size=16).digest()
                    if nvi < SHORT_LEN:
                        k8 = int.from_bytes(dig[:8], "little")
                        if short[k8] >= SHORT_CAP: stats["dup-short"] += 1; continue
                        short[k8] += 1
                    elif bloom.add(dig):
                        stats["dup"] += 1; continue
                    buf.extend(ids); total += nvi; stats["kept"] += 1
                    if dom is not None: dom_syl[dom] += nvi
            out.write(buf.tobytes())
            if time.time() - t0 > 60:
                t0 = time.time()
                print(f"  {total / 1e6:.1f} tr âm tiết, {stats['sent'] / 1e6:.1f} tr câu, giữ {stats['kept']}",
                      file=sys.stderr, flush=True)
            if a.max_syllables and total >= a.max_syllables: break
    out.close()
    for f in held: f.close()
    stats["syllables"] = total
    stats["seconds"] = round(time.time() - t_start)
    stats["domains"] = len(dom_syl)
    stats["top-domains"] = dom_syl.most_common(30)
    json.dump(stats, open(a.out + ".stats.json", "w"), ensure_ascii=False, indent=1)
    print(json.dumps({k: v for k, v in stats.items() if k != "top-domains"}, ensure_ascii=False), file=sys.stderr)

def zip_batches(pool, batches):
    """Giữ thứ tự (tất định): imap trên lô văn bản, trả (lô, kết quả)."""
    pending = collections.deque()
    it = iter(batches)
    def texts(b): return [t for _, t in b]
    done = False
    while True:
        while not done and len(pending) < 16:
            try: b = next(it)
            except StopIteration: done = True; break
            pending.append((b, pool.apply_async(work_batch, (texts(b),))))
        if not pending: return
        b, r = pending.popleft()
        yield b, r.get()

if __name__ == "__main__":
    main()
