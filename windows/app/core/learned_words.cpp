// learned_words.cpp — see learned_words.h. Mirrors iOS/Keyboard/UserLMTables.swift (tables,
// compact, codec) and App/Sources/LearnedModel.swift (record, nextWords, decay, prune) line by
// line, so a change there is easy to repeat here.
#include "learned_words.h"

#include <algorithm>
#include <cstring>

#include <viettelex/text_tools.hpp>

namespace vtx::app::learn {

namespace {

inline uint64_t pack(uint32_t id, uint32_t c) { return (static_cast<uint64_t>(id) << 32) | c; }
inline uint32_t nid(uint64_t e) { return static_cast<uint32_t>(e >> 32); }
inline int cnt(uint64_t e) { return static_cast<int>(static_cast<uint32_t>(e)); }
inline uint64_t ctxOf(int32_t p2, int32_t p1) { return pack(static_cast<uint32_t>(p2), static_cast<uint32_t>(p1)); }
inline uint32_t clampC(int64_t c) { return c <= 0 ? 0u : c >= 0xFFFFFFFFll ? 0xFFFFFFFFu : static_cast<uint32_t>(c); }

// Position of `id` in a sorted bucket (or where to insert it).
size_t search(const std::vector<uint64_t>& b, uint32_t id, bool& found) {
    size_t lo = 0, hi = b.size();
    while (lo < hi) {
        const size_t m = (lo + hi) >> 1;
        if (nid(b[m]) < id) lo = m + 1;
        else hi = m;
    }
    found = lo < b.size() && nid(b[lo]) == id;
    return lo;
}

// Adds (or sets); true if the entry is new.
bool addTo(std::vector<uint64_t>& b, int32_t n, int by) {
    const uint32_t id = static_cast<uint32_t>(n);
    bool f = false;
    const size_t at = search(b, id, f);
    if (f) {
        b[at] = pack(id, clampC(static_cast<int64_t>(cnt(b[at])) + by));
        return false;
    }
    b.insert(b.begin() + static_cast<std::ptrdiff_t>(at), pack(id, clampC(by)));
    return true;
}

bool isLetterCp(char32_t c) { return text::isLetter(c); }

}  // namespace

uint32_t crc32(const uint8_t* p, size_t n) {
    static uint32_t table[256];
    static bool init = false;
    if (!init) {
        for (uint32_t i = 0; i < 256; ++i) {
            uint32_t c = i;
            for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        init = true;
    }
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; ++i) c = table[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

bool learnable(const std::string& w) {
    const std::u32string u = text::fromUtf8(w);
    // Swift Character count: a combining mark belongs to the letter before it.
    size_t chars = 0;
    for (char32_t c : u)
        if (!text::isMark(c)) ++chars;
    if (u.empty() || chars > static_cast<size_t>(kMaxWordLength) || text::isMark(u[0])) return false;
    int run = 0;
    char32_t prev = 0;
    for (char32_t c : u) {
        if (text::isMark(c)) continue;
        if (!isLetterCp(c)) return false;
        run = c == prev ? run + 1 : 1;
        if (run >= 3) return false;
        prev = c;
    }
    return true;
}

std::string key(const std::string& w) { return text::toUtf8(text::lower(text::nfc(text::fromUtf8(w)))); }

// MARK: learned casing (UserLMTables.swift CaseTable)

CaseKind caseKind(const std::string& form) {
    const std::u32string u = text::fromUtf8(form);
    int letters = 0, upper = 0;
    size_t i = 0;
    while (i < u.size()) {  // one Swift Character = a code point + the marks after it
        size_t j = i + 1;
        while (j < u.size() && text::isMark(u[j])) ++j;
        const std::u32string ch = u.substr(i, j - i);
        ++letters;
        if (text::lower(ch) != ch) ++upper;
        i = j;
    }
    if (upper == 0) return CaseKind::Lower;
    if (letters < 2 || upper == letters) return CaseKind::Ignored;
    return CaseKind::Mixed;
}

namespace {
void saturate(CaseStat& s) {
    if (s.total <= kCaseMaxCount) return;
    s.hits = (s.hits + 1) / 2;
    s.total = (s.total + 1) / 2;
}
}  // namespace

bool CaseTable::observe(const std::string& form, const std::string& k, int priorCount) {
    switch (caseKind(form)) {
        case CaseKind::Ignored: return false;
        case CaseKind::Lower: {
            const auto it = stats_.find(k);
            if (it == stats_.end()) return false;
            ++it->second.total;
            saturate(it->second);
            return true;
        }
        case CaseKind::Mixed: break;
    }
    auto it = stats_.find(k);
    if (it == stats_.end()) {
        if (stats_.size() >= static_cast<size_t>(kCaseCap)) return false;
        it = stats_.emplace(k, CaseStat{form, 0, std::min(std::max(priorCount, 0), kCaseMaxCount)}).first;
    }
    CaseStat& s = it->second;
    ++s.total;
    if (s.form == form) ++s.hits;
    else if (s.hits > 0) --s.hits;
    else {
        s.form = form;
        s.hits = 1;
    }
    saturate(s);
    return true;
}

std::string CaseTable::preferred(const std::string& k) const {
    const auto it = stats_.find(k);
    if (it == stats_.end()) return std::string();
    const CaseStat& s = it->second;
    return s.hits >= kCaseMinHits && s.hits * 5 >= s.total * 4 ? s.form : std::string();
}

Model::Model(KnownFn isKnown, int64_t nowMs) : lastDecayMs_(nowMs), isKnown_(std::move(isKnown)) {}

int32_t Model::idOf(const std::string& w) const {
    const auto it = ids_.find(w);
    return it == ids_.end() ? -1 : it->second;
}

int32_t Model::intern(const std::string& w) {
    const auto it = ids_.find(w);
    if (it != ids_.end()) return it->second;
    const int32_t i = static_cast<int32_t>(words_.size());
    words_.push_back(w);
    ids_.emplace(w, i);
    uniC_.push_back(0);
    biB_.emplace_back();
    return i;
}

void Model::setUni(int32_t id, int c) {
    uint32_t& slot = uniC_[static_cast<size_t>(id)];
    const uint32_t old = slot, v = clampC(c < 0 ? 0 : c);
    if (old == 0 && v > 0) ++uniN_;
    else if (old > 0 && v == 0) --uniN_;
    uniTotal_ += static_cast<int64_t>(v) - static_cast<int64_t>(old);
    slot = v;
}

int Model::biCount(int32_t p, int32_t n) const {
    const auto& b = biB_[static_cast<size_t>(p)];
    bool f = false;
    const size_t at = search(b, static_cast<uint32_t>(n), f);
    return f ? cnt(b[at]) : 0;
}

void Model::addBi(int32_t p, int32_t n, int by) {
    if (addTo(biB_[static_cast<size_t>(p)], n, by)) ++biN_;
}

int Model::triSlotOf(uint64_t c) const {
    const auto it = triIdx_.find(c);
    return it == triIdx_.end() ? -1 : it->second;
}

int Model::triSlot(uint64_t c) {
    const int s = triSlotOf(c);
    if (s >= 0) return s;
    const int n = static_cast<int>(triB_.size());
    triIdx_.emplace(c, n);
    triCtx_.push_back(c);
    triB_.emplace_back();
    return n;
}

int Model::triCount(int slot, int32_t n) const {
    const auto& b = triB_[static_cast<size_t>(slot)];
    bool f = false;
    const size_t at = search(b, static_cast<uint32_t>(n), f);
    return f ? cnt(b[at]) : 0;
}

void Model::addTri(uint64_t c, int32_t n, int by) {
    const int s = triSlot(c);
    if (addTo(triB_[static_cast<size_t>(s)], n, by)) ++triN_;
}

// MARK: learning

void Model::record(const std::string& wordIn, const std::string& prev1In, const std::string& prev2In, int weight,
                   bool caseEvidence) {
    if (weight <= 0 || !learnable(wordIn)) return;
    const std::string w = key(wordIn);
    const int32_t wid = intern(w);
    if (caseEvidence) cases_.observe(text::toUtf8(text::nfc(text::fromUtf8(wordIn))), w, uni(wid));
    setUni(wid, uni(wid) + weight);
    if (!prev1In.empty() && learnable(prev1In)) {
        const std::string p1 = key(prev1In);
        const int32_t pid = intern(p1);
        addBi(pid, wid, weight);
        if (!prev2In.empty() && learnable(prev2In)) {
            const int32_t p2id = idOf(key(prev2In));
            if (p2id >= 0 && biCount(p2id, pid) >= 2) addTri(ctxOf(p2id, pid), wid, weight);
        }
    }
    pruneIfNeeded();
    ++changes_;
}

int Model::count(const std::string& w) const {
    int32_t id = idOf(w);
    if (id < 0) id = idOf(key(w));
    return id < 0 ? 0 : uni(id);
}

int Model::bigramCount(const std::string& prev, const std::string& w) const {
    const int32_t p = idOf(key(prev)), n = idOf(key(w));
    return p < 0 || n < 0 ? 0 : biCount(p, n);
}

int Model::trigramCount(const std::string& prev2, const std::string& prev, const std::string& w) const {
    const int32_t a = idOf(key(prev2)), b = idOf(key(prev)), n = idOf(key(w));
    if (a < 0 || b < 0 || n < 0) return 0;
    const int s = triSlotOf(ctxOf(a, b));
    return s < 0 ? 0 : triCount(s, n);
}

bool Model::suggestable(const std::string& w) const {
    bool known = false;
    const auto it = knownCache_.find(w);
    if (it != knownCache_.end()) {
        known = it->second;
    } else {
        if (knownCache_.size() > 4096) knownCache_.clear();
        known = isKnown_ && isKnown_(w);
        knownCache_.emplace(w, known);
    }
    if (known) return true;
    const int32_t id = idOf(w);
    return id >= 0 && uni(id) >= kUnknownSuggestThreshold;
}

std::vector<std::string> Model::nextWords(const std::string& prev1In, const std::string& prev2In,
                                          const std::vector<std::string>& seeds, int limit, int pairMin) const {
    const std::string p1 = key(prev1In);
    const int32_t pid = idOf(p1);
    static const std::vector<uint64_t> kEmpty;
    const std::vector<uint64_t>& biBucket = pid >= 0 ? biB_[static_cast<size_t>(pid)] : kEmpty;
    const std::vector<uint64_t>* triBucket = &kEmpty;
    if (pid >= 0 && !prev2In.empty()) {
        const int32_t p2id = idOf(key(prev2In));
        if (p2id >= 0) {
            const int s = triSlotOf(ctxOf(p2id, pid));
            if (s >= 0) triBucket = &triB_[static_cast<size_t>(s)];
        }
    }
    int64_t biTotal = 0, triTotal = 0;
    for (uint64_t e : biBucket) biTotal += cnt(e);
    for (uint64_t e : *triBucket) triTotal += cnt(e);
    const int64_t uniTotal = std::max<int64_t>(uniTotal_, 1);
    const double lamTri = static_cast<double>(triTotal) / (static_cast<double>(triTotal) + 2);
    const double lamBi = static_cast<double>(biTotal) / (static_cast<double>(biTotal) + 4);

    struct Cand {
        std::string w;
        int bc, tc;
    };
    std::vector<Cand> cands;
    cands.reserve(biBucket.size() + triBucket->size() + seeds.size());
    size_t i = 0, j = 0;
    while (i < biBucket.size() || j < triBucket->size()) {
        const uint32_t bn = i < biBucket.size() ? nid(biBucket[i]) : 0xFFFFFFFFu;
        const uint32_t tn = j < triBucket->size() ? nid((*triBucket)[j]) : 0xFFFFFFFFu;
        const uint32_t id = std::min(bn, tn);
        int bc = 0, tc = 0;
        if (bn == id) bc = cnt(biBucket[i++]);
        if (tn == id) tc = cnt((*triBucket)[j++]);
        cands.push_back(Cand{words_[id], bc, tc});
    }
    for (const auto& s : seeds) {
        bool have = false;
        for (const auto& c : cands)
            if (c.w == s) { have = true; break; }
        if (!have) cands.push_back(Cand{s, 0, 0});
    }
    struct Top {
        std::string w;
        double s;
    };
    std::vector<Top> top;
    for (const auto& c : cands) {
        int seed = -1;
        for (size_t k = 0; k < seeds.size(); ++k)
            if (seeds[k] == c.w) { seed = static_cast<int>(k); break; }
        if (seed < 0) {
            if (pairMin > 0 && c.bc < pairMin && c.tc < kLearnedPairMin) continue;
            if (!suggestable(c.w)) continue;
        }
        double pSeed = 0.0;
        if (seed >= 0) {
            pSeed = 1;
            for (int k = 0; k < seed; ++k) pSeed *= 0.5;
        }
        const double pTri = triTotal > 0 ? static_cast<double>(c.tc) / static_cast<double>(triTotal) : 0;
        const double pBi = biTotal > 0 ? static_cast<double>(c.bc) / static_cast<double>(biTotal) : 0;
        const int32_t cid = idOf(c.w);
        const double pUni = static_cast<double>(cid >= 0 ? uni(cid) : 0) / static_cast<double>(uniTotal);
        const double sc = lamTri * pTri + lamBi * pBi + 0.1 * pUni + (1 - lamBi) * 0.9 * pSeed;
        size_t at = top.size();
        while (at > 0 && (top[at - 1].s < sc || (top[at - 1].s == sc && top[at - 1].w > c.w))) --at;
        if (at < static_cast<size_t>(limit)) {
            top.insert(top.begin() + static_cast<std::ptrdiff_t>(at), Top{c.w, sc});
            if (top.size() > static_cast<size_t>(limit)) top.pop_back();
        }
    }
    std::vector<std::string> out;
    out.reserve(top.size());
    for (auto& t : top) out.push_back(std::move(t.w));
    return out;
}

// MARK: decay / prune / clear

void Model::decayIfDue(int64_t nowMs) {
    const int64_t weeks = (nowMs - lastDecayMs_) / (7ll * 86400 * 1000);
    if (weeks < 1) return;
    double f = 1.0;
    for (int64_t k = 0; k < std::min<int64_t>(weeks, 64); ++k) f *= 0.7;
    scale(true, true, true, f);
    lastDecayMs_ = nowMs;
    ++changes_;
}

void Model::pruneIfNeeded() {
    const bool u = uniN_ > kUniCap, b = biN_ > kBiCap, r = triN_ > kTriCap;
    if (!(u || b || r)) return;
    scale(u, b, r, 0.5);
}

// UserLMTables.mapCounts + compact.
void Model::scale(bool u, bool b, bool r, double f) {
    auto apply = [f](int c) { return static_cast<int>(static_cast<double>(c) * f); };
    if (u) {
        uniN_ = 0;
        uniTotal_ = 0;
        for (auto& c : uniC_) {
            if (c == 0) continue;
            const uint32_t v = clampC(std::max(apply(static_cast<int>(c)), 0));
            c = v;
            if (v > 0) {
                ++uniN_;
                uniTotal_ += v;
            }
        }
    }
    auto mapB = [&](std::vector<std::vector<uint64_t>>& bs) {
        int n = 0;
        for (auto& bk : bs) {
            if (bk.empty()) continue;
            std::vector<uint64_t> out;
            out.reserve(bk.size());
            for (uint64_t e : bk) {
                const int v = apply(cnt(e));
                if (v > 0) out.push_back(pack(nid(e), clampC(v)));
            }
            n += static_cast<int>(out.size());
            bk.swap(out);
        }
        return n;
    };
    if (b) biN_ = mapB(biB_);
    if (r) triN_ = mapB(triB_);
    compact();
    if (u) dropOrphanCases();
}

// A word gone from the unigrams (decay / prune) takes its casing with it.
void Model::dropOrphanCases() {
    auto& st = cases_.stats();
    for (auto it = st.begin(); it != st.end();) {
        const int32_t id = idOf(it->first);
        if (id < 0 || uni(id) <= 0) it = st.erase(it);
        else ++it;
    }
}

void Model::compact() {
    std::vector<bool> live(words_.size());
    for (size_t i = 0; i < uniC_.size(); ++i) live[i] = uniC_[i] > 0;
    for (size_t p = 0; p < biB_.size(); ++p) {
        if (biB_[p].empty()) continue;
        live[p] = true;
        for (uint64_t e : biB_[p]) live[nid(e)] = true;
    }
    size_t liveTri = 0;
    for (size_t s = 0; s < triB_.size(); ++s) {
        if (triB_[s].empty()) continue;
        ++liveTri;
        live[nid(triCtx_[s])] = true;
        live[static_cast<uint32_t>(triCtx_[s])] = true;
        for (uint64_t e : triB_[s]) live[nid(e)] = true;
    }
    size_t nLive = 0;
    for (bool l : live) nLive += l ? 1 : 0;
    if (nLive == words_.size() && liveTri == triB_.size()) return;
    std::vector<uint32_t> remap(words_.size(), 0xFFFFFFFFu);
    std::vector<std::string> nw;
    std::vector<uint32_t> nu;
    std::vector<std::vector<uint64_t>> nb;
    std::unordered_map<std::string, int32_t> nids;
    nw.reserve(nLive);
    nu.reserve(nLive);
    nb.reserve(nLive);
    nids.reserve(nLive);
    for (size_t i = 0; i < words_.size(); ++i) {
        if (!live[i]) continue;
        remap[i] = static_cast<uint32_t>(nw.size());
        nids.emplace(words_[i], static_cast<int32_t>(nw.size()));
        nw.push_back(words_[i]);
        nu.push_back(uniC_[i]);
    }
    auto re = [&](const std::vector<uint64_t>& b) {
        std::vector<uint64_t> o;
        o.reserve(b.size());
        for (uint64_t e : b) o.push_back(pack(remap[nid(e)], static_cast<uint32_t>(e)));
        return o;
    };
    for (size_t i = 0; i < words_.size(); ++i)
        if (live[i]) nb.push_back(biB_[i].empty() ? std::vector<uint64_t>() : re(biB_[i]));
    std::unordered_map<uint64_t, int32_t> tIdx;
    std::vector<uint64_t> tCtx;
    std::vector<std::vector<uint64_t>> tB;
    for (size_t s = 0; s < triB_.size(); ++s) {
        if (triB_[s].empty()) continue;
        const uint64_t c = pack(remap[nid(triCtx_[s])], remap[static_cast<uint32_t>(triCtx_[s])]);
        tIdx.emplace(c, static_cast<int32_t>(tCtx.size()));
        tCtx.push_back(c);
        tB.push_back(re(triB_[s]));
    }
    words_.swap(nw);
    ids_.swap(nids);
    uniC_.swap(nu);
    biB_.swap(nb);
    triIdx_.swap(tIdx);
    triCtx_.swap(tCtx);
    triB_.swap(tB);
}

void Model::clear(int64_t nowMs) {
    words_.clear();
    ids_.clear();
    uniC_.clear();
    biB_.clear();
    triIdx_.clear();
    triCtx_.clear();
    triB_.clear();
    uniN_ = biN_ = triN_ = 0;
    uniTotal_ = 0;
    cases_.clear();
    knownCache_.clear();
    lastDecayMs_ = nowMs;
    ++changes_;
}

size_t Model::memoryBytes() const {
    size_t n = sizeof(*this);
    for (const auto& w : words_) n += sizeof(std::string) + (w.size() > 15 ? w.capacity() + 1 : 0);
    n += ids_.size() * (sizeof(std::string) + sizeof(int32_t) + 2 * sizeof(void*)) + ids_.bucket_count() * sizeof(void*);
    for (const auto& w : ids_) n += w.first.size() > 15 ? w.first.capacity() + 1 : 0;
    n += uniC_.capacity() * sizeof(uint32_t);
    n += biB_.capacity() * sizeof(std::vector<uint64_t>);
    for (const auto& b : biB_) n += b.capacity() * sizeof(uint64_t);
    n += triIdx_.size() * (sizeof(uint64_t) + sizeof(int32_t) + 2 * sizeof(void*)) + triIdx_.bucket_count() * sizeof(void*);
    n += triCtx_.capacity() * sizeof(uint64_t) + triB_.capacity() * sizeof(std::vector<uint64_t>);
    for (const auto& b : triB_) n += b.capacity() * sizeof(uint64_t);
    for (const auto& c : cases_.stats())
        n += sizeof(CaseStat) + sizeof(std::string) + 2 * sizeof(void*) + (c.second.form.size() > 15 ? c.second.form.capacity() + 1 : 0);
    return n;
}

// MARK: VTL2 (UserLMCodec)
//   "VTL2" | u16 version=1 | u16 flags | i64 lastDecay (ms) | u32 nWords | nWords × (u16 len, UTF-8)
//   nWords × u32 uni | u32 nBi | nBi × (u32 prev, u32 n, n × (u32 next, u32 count))
//   u32 nTri | nTri × (u32 p2, u32 p1, u32 n, n × (u32 next, u32 count)) | u32 nManual (0 here)
//   [flags & 1] u32 nCase | nCase × (u32 word id, u16 len, UTF-8 form, u16 hits, u16 total), ids ascending
//   u32 CRC32 of everything before.

std::vector<uint8_t> Model::encode() const {
    std::vector<uint8_t> o;
    o.reserve(64 + words_.size() * 16);
    auto u16 = [&](uint16_t v) {
        o.push_back(static_cast<uint8_t>(v));
        o.push_back(static_cast<uint8_t>(v >> 8));
    };
    auto u32 = [&](uint32_t v) {
        for (int k = 0; k < 4; ++k) o.push_back(static_cast<uint8_t>(v >> (8 * k)));
    };
    // casing rows: only words in the table, by id
    struct CaseRow {
        uint32_t id;
        const CaseStat* s;
    };
    std::vector<CaseRow> caseRows;
    for (const auto& c : cases_.stats()) {
        const int32_t id = idOf(c.first);
        if (id >= 0 && c.second.total > 0) caseRows.push_back(CaseRow{static_cast<uint32_t>(id), &c.second});
    }
    std::sort(caseRows.begin(), caseRows.end(), [](const CaseRow& a, const CaseRow& b) { return a.id < b.id; });
    o.insert(o.end(), {'V', 'T', 'L', '2'});
    u16(1);
    u16(caseRows.empty() ? 0 : 1);
    const uint64_t ms = static_cast<uint64_t>(lastDecayMs_);
    u32(static_cast<uint32_t>(ms));
    u32(static_cast<uint32_t>(ms >> 32));
    u32(static_cast<uint32_t>(words_.size()));
    for (const auto& w : words_) {
        const size_t n = std::min<size_t>(w.size(), 0xFFFF);
        u16(static_cast<uint16_t>(n));
        o.insert(o.end(), w.begin(), w.begin() + static_cast<std::ptrdiff_t>(n));
    }
    for (uint32_t c : uniC_) u32(c);
    auto bucket = [&](const std::vector<uint64_t>& b) {
        u32(static_cast<uint32_t>(b.size()));
        for (uint64_t e : b) {
            u32(nid(e));
            u32(static_cast<uint32_t>(e));
        }
    };
    uint32_t nb = 0;
    for (const auto& b : biB_) nb += b.empty() ? 0 : 1;
    u32(nb);
    for (size_t p = 0; p < biB_.size(); ++p) {
        if (biB_[p].empty()) continue;
        u32(static_cast<uint32_t>(p));
        bucket(biB_[p]);
    }
    uint32_t nt = 0;
    for (const auto& b : triB_) nt += b.empty() ? 0 : 1;
    u32(nt);
    for (size_t s = 0; s < triB_.size(); ++s) {
        if (triB_[s].empty()) continue;
        u32(nid(triCtx_[s]));
        u32(static_cast<uint32_t>(triCtx_[s]));
        bucket(triB_[s]);
    }
    u32(0);  // manual words: none on the desktop
    if (!caseRows.empty()) {
        auto clamp16 = [](int v) { return static_cast<uint16_t>(v < 0 ? 0 : v > 0xFFFF ? 0xFFFF : v); };
        u32(static_cast<uint32_t>(caseRows.size()));
        for (const auto& r : caseRows) {
            u32(r.id);
            const std::string& f = r.s->form;
            const size_t n = std::min<size_t>(f.size(), 0xFFFF);
            u16(static_cast<uint16_t>(n));
            o.insert(o.end(), f.begin(), f.begin() + static_cast<std::ptrdiff_t>(n));
            u16(clamp16(r.s->hits));
            u16(clamp16(r.s->total));
        }
    }
    u32(crc32(o.data(), o.size()));
    return o;
}

std::unique_ptr<Model> Model::decode(const uint8_t* bytes, size_t size, KnownFn isKnown) {
    if (!bytes || size < 36 || std::memcmp(bytes, "VTL2", 4) != 0) return nullptr;
    const size_t body = size - 4;
    size_t pos = 4;
    bool ok = true;
    auto u16 = [&]() -> uint16_t {
        if (pos + 2 > body) { ok = false; return 0; }
        const uint16_t v = static_cast<uint16_t>(bytes[pos] | (bytes[pos + 1] << 8));
        pos += 2;
        return v;
    };
    auto u32 = [&]() -> uint32_t {
        if (pos + 4 > body) { ok = false; return 0; }
        const uint32_t v = static_cast<uint32_t>(bytes[pos]) | (static_cast<uint32_t>(bytes[pos + 1]) << 8) |
                           (static_cast<uint32_t>(bytes[pos + 2]) << 16) | (static_cast<uint32_t>(bytes[pos + 3]) << 24);
        pos += 4;
        return v;
    };
    const uint32_t stored = static_cast<uint32_t>(bytes[body]) | (static_cast<uint32_t>(bytes[body + 1]) << 8) |
                            (static_cast<uint32_t>(bytes[body + 2]) << 16) | (static_cast<uint32_t>(bytes[body + 3]) << 24);
    if (crc32(bytes, body) != stored) return nullptr;
    if (u16() != 1) return nullptr;
    const uint16_t flags = u16();
    const uint32_t lo = u32(), hi = u32();
    if (!ok) return nullptr;
    auto m = std::make_unique<Model>(std::move(isKnown), static_cast<int64_t>((static_cast<uint64_t>(hi) << 32) | lo));
    const uint32_t nw = u32();
    if (!ok || nw > body / 2) return nullptr;
    m->words_.reserve(nw);
    for (uint32_t i = 0; i < nw; ++i) {
        const uint16_t n = u16();
        if (!ok || pos + n > body) return nullptr;
        std::string w(reinterpret_cast<const char*>(bytes + pos), n);
        pos += n;
        if (!m->ids_.emplace(w, static_cast<int32_t>(i)).second) return nullptr;  // duplicate word
        m->words_.push_back(std::move(w));
    }
    m->uniC_.reserve(nw);
    for (uint32_t i = 0; i < nw; ++i) {
        const uint32_t c = u32();
        if (!ok) return nullptr;
        m->uniC_.push_back(c);
    }
    auto bucket = [&](std::vector<uint64_t>& b) -> bool {
        const uint32_t n = u32();
        if (!ok || n == 0 || n > (body - pos) / 8) return false;
        b.reserve(n);
        bool first = true;
        uint32_t last = 0;
        for (uint32_t k = 0; k < n; ++k) {
            const uint32_t id = u32(), c = u32();
            if (!ok || id >= nw || c == 0) return false;
            if (!first && id <= last) return false;
            first = false;
            last = id;
            b.push_back(pack(id, c));
        }
        return true;
    };
    m->biB_.assign(nw, std::vector<uint64_t>());
    const uint32_t nb = u32();
    if (!ok) return nullptr;
    for (uint32_t k = 0; k < nb; ++k) {
        const uint32_t p = u32();
        if (!ok || p >= nw || !m->biB_[p].empty() || !bucket(m->biB_[p])) return nullptr;
    }
    const uint32_t nt = u32();
    if (!ok || nt > body / 12) return nullptr;
    for (uint32_t k = 0; k < nt; ++k) {
        const uint32_t a = u32(), b = u32();
        if (!ok || a >= nw || b >= nw) return nullptr;
        std::vector<uint64_t> bk;
        if (!bucket(bk)) return nullptr;
        const uint64_t c = pack(a, b);
        if (!m->triIdx_.emplace(c, static_cast<int32_t>(m->triCtx_.size())).second) return nullptr;
        m->triCtx_.push_back(c);
        m->triB_.push_back(std::move(bk));
    }
    const uint32_t nm = u32();
    if (!ok || nm > body / 2) return nullptr;
    for (uint32_t k = 0; k < nm; ++k) {  // manual words (iOS): skipped on the desktop
        const uint16_t n = u16();
        if (!ok || pos + n > body) return nullptr;
        pos += n;
    }
    if (flags & 1) {  // learned casing
        const uint32_t nc = u32();
        if (!ok || nc > body / 10) return nullptr;
        bool first = true;
        uint32_t last = 0;
        for (uint32_t k = 0; k < nc; ++k) {
            const uint32_t id = u32();
            const uint16_t n = u16();
            if (!ok || id >= nw || pos + n > body) return nullptr;
            std::string f(reinterpret_cast<const char*>(bytes + pos), n);
            pos += n;
            const uint16_t h = u16(), t = u16();
            if (!ok || f.empty() || t == 0 || h > t) return nullptr;
            if (!first && id <= last) return nullptr;
            first = false;
            last = id;
            m->cases_.stats()[m->words_[id]] = CaseStat{std::move(f), h, t};
        }
    }
    if (pos != body) return nullptr;
    for (uint32_t c : m->uniC_)
        if (c > 0) {
            ++m->uniN_;
            m->uniTotal_ += c;
        }
    for (const auto& b : m->biB_) m->biN_ += static_cast<int>(b.size());
    for (const auto& b : m->triB_) m->triN_ += static_cast<int>(b.size());
    return m;
}

}  // namespace vtx::app::learn
