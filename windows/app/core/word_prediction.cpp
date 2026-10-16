// word_prediction.cpp — see word_prediction.h. Names and order follow the Swift sources so a
// change there is easy to mirror here; every weight is the iOS/macOS one.
#include "word_prediction.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string_view>

#include <viettelex/add_tones.hpp>
#include <viettelex/text_tools.hpp>

namespace vtx::app::predict {

namespace {

// ---- Swift Character helpers on NFC code points (a combining mark left after NFC belongs
// to the letter before it: it is part of that Character, never counted on its own).
bool isNewline(char32_t c) {
    return c == '\n' || c == '\r' || c == 0x0B || c == 0x0C || c == 0x85 || c == 0x2028 || c == 0x2029;
}
bool isWordChar(char32_t c) { return text::isLetter(c) || text::isMark(c); }
bool isSpaceChar(char32_t c) { return c == U' ' || c == U'\t' || c == 0xA0 || isNewline(c); }
size_t glen(const std::u32string& s) {
    size_t n = 0;
    for (char32_t c : s)
        if (!text::isMark(c)) ++n;
    return n;
}
bool isUpperChar(char32_t c) { return text::isLetter(c) && text::lower(c) != std::u32string(1, c); }
std::u32string lowerS(const std::u32string& s) { return text::lower(s); }
std::u32string capitalizeFirst(const std::u32string& w) {
    if (w.empty()) return w;
    return text::upper(w[0]) + w.substr(1);
}
std::u32string u32(std::string_view s) { return text::fromUtf8(s.data(), s.size()); }
std::string u8(const std::u32string& s) { return text::toUtf8(s); }
bool endsWith(const std::u32string& s, const std::u32string& t) {
    return s.size() >= t.size() && s.compare(s.size() - t.size(), t.size(), t) == 0;
}

// ---- SuggestRank constants (SuggestionSupport.swift)
constexpr double kBigramWeight = 3.0;
constexpr double kBigramCap = 12.0;
constexpr double kNextFreqWeight = 10.0;
constexpr int kTriOnlyRow = 6;
constexpr int kPoolLimit = 24;

// SuggestionFill.pad(base: [], with:, need:) — dedupe by lowercase, keep order.
std::vector<std::u32string> pad(const std::vector<std::u32string>& cands, size_t need) {
    std::vector<std::u32string> out, seen;  // ≤ 3: a linear scan
    for (const auto& c : cands) {
        if (out.size() >= need) break;
        std::u32string l = lowerS(c);
        if (std::find(seen.begin(), seen.end(), l) != seen.end()) continue;
        seen.push_back(std::move(l));
        out.push_back(c);
    }
    return out;
}

std::vector<std::u32string> filterSensitive(const std::vector<std::u32string>& words) {
    std::vector<std::u32string> out;
    out.reserve(words.size());
    for (const auto& w : words)
        if (!isSensitive(w)) out.push_back(w);
    return out;
}

// ---- SeedData.unigrams (generated: one packed string, sorted by UTF-8 bytes)
#include "seed_unigrams.inc"

}  // namespace

// ================================================================ the logic

std::optional<Request> request(const std::u32string& beforeIn, const std::u32string& typedIn, bool english) {
    const std::u32string b = text::nfc(beforeIn);
    const std::u32string t = text::nfc(typedIn);
    std::u32string head;
    if (!t.empty()) {
        if (glen(t) < static_cast<size_t>(kMinTyped) || !endsWith(b, t)) return std::nullopt;
        if (!text::isLetter(t[0])) return std::nullopt;
        for (char32_t c : t)
            if (!isWordChar(c)) return std::nullopt;
        head = b.substr(0, b.size() - t.size());
        if (!head.empty() && !isSpaceChar(head.back())) return std::nullopt;
    } else {
        if (b.empty() || b.back() != U' ') return std::nullopt;
        head = b.substr(0, b.size() - 1);
        if (head.empty() || !isWordChar(head.back())) return std::nullopt;  // two spaces / after punctuation
    }
    // Up to 2 context words, back from the end, one space apart, letters only.
    std::vector<std::u32string> words;
    size_t end = head.size();  // rest = head[0, end)
    while (words.size() < 2) {
        if (!words.empty() || !t.empty()) {
            if (end == 0 || head[end - 1] != U' ') break;
            --end;
        }
        size_t i = end;
        while (i > 0 && isWordChar(head[i - 1])) --i;
        const std::u32string w = head.substr(i, end - i);
        if (w.empty() || glen(w) > 24 || text::isMark(w[0])) break;
        if (i > 0 && !isSpaceChar(head[i - 1])) break;  // "a.b" is not a word
        words.push_back(lowerS(w));
        end = i;
        if (end > 0 && isNewline(head[end - 1])) break;
    }
    if (t.empty() && words.empty()) return std::nullopt;
    Request r;
    r.typed = t;
    if (!words.empty()) r.prev = words[0];
    if (words.size() > 1) r.prev2 = words[1];
    r.english = english;
    return r;
}

bool wantsEnglish(const Request& r, int vietnameseHits) { return r.english || vietnameseHits == 0; }

bool wantsNextWord(const Request& r) { return r.typed.empty() && !r.english && r.prev && r.prev2; }

std::vector<std::u32string> completions(const std::vector<std::u32string>& ranked, const std::u32string& typed) {
    const size_t n = glen(typed);
    std::vector<std::u32string> out, seen;  // ≤ 3: a linear scan
    for (const auto& w : ranked) {
        if (glen(w) <= n) continue;
        std::u32string l = lowerS(w);
        if (std::find(seen.begin(), seen.end(), l) == seen.end()) {
            seen.push_back(std::move(l));
            out.push_back(w);
        }
        if (out.size() >= static_cast<size_t>(kRankDepth)) break;
    }
    return out;
}

bool muted(const std::u32string& typed, const std::u32string& declined) {
    if (declined.empty() || typed.empty()) return false;
    const std::u32string t = lowerS(typed), d = lowerS(declined);
    return t.compare(0, d.size(), d) == 0 && t.size() >= d.size();
}

// ================================================================ display helpers

namespace {
// DisplayCase.chains / .proper (iOS/Keyboard/DisplayCase.swift) — keep identical. Plain
// constant tables (no static-init code); a linear scan of ~100 entries per candidate.
struct Chain {
    const char* prev;
    const char* next;  // "|a|b|c|"
};
const Chain kChains[] = {
    {"hà", "|nội|nam|tĩnh|giang|"},
    {"đà", "|nẵng|lạt|"},
    {"nha", "|trang|"},
    {"phú", "|quốc|thọ|yên|"},
    {"sài", "|gòn|"},
    {"hồ", "|chí|"},
    {"chí", "|minh|"},
    {"việt", "|nam|"},
    {"cần", "|thơ|"},
    {"hải", "|phòng|dương|"},
    {"hạ", "|long|"},
    {"quy", "|nhơn|"},
    {"vũng", "|tàu|"},
    {"biên", "|hòa|"},
    {"bình", "|dương|định|thuận|"},
    {"thanh", "|hóa|"},
    {"hội", "|an|"},
    {"quảng", "|ninh|nam|ngãi|bình|trị|"},
    {"nghệ", "|an|"},
    {"lâm", "|đồng|"},
    {"đồng", "|nai|tháp|"},
    {"long", "|an|"},
    {"tây", "|ninh|"},
    {"new", "|york|"},
    {"san", "|francisco|"},
    {"hong", "|kong|"},
    {"nguyễn", "|văn|thị|đức|minh|ngọc|hữu|xuân|thùy|kim|hồng|quốc|đình|"},
    {"trần", "|văn|thị|đức|minh|ngọc|quốc|"},
    {"lê", "|văn|thị|đức|minh|ngọc|hữu|"},
    {"phạm", "|văn|thị|minh|ngọc|"},
    {"hoàng", "|văn|thị|minh|anh|"},
    {"vũ", "|văn|thị|minh|"},
    {"đặng", "|văn|thị|"},
    {"bùi", "|văn|thị|"},
    {"đỗ", "|văn|thị|"},
    {"ngô", "|văn|thị|"},
    {"dương", "|văn|thị|"},
    {"trịnh", "|văn|thị|xuân|"},
    {"văn", "|hùng|tuấn|dũng|sơn|nam|long|hải|minh|"},
    {"thị", "|hương|lan|thu|ngọc|hồng|phương|hà|linh|"},
};
const char* const kProper[][2] = {
    {"senprints", "SenPrints"}, {"printik", "Printik"}, {"apple", "Apple"},
    {"iphone", "iPhone"}, {"ipad", "iPad"}, {"macbook", "MacBook"}, {"samsung", "Samsung"}, {"google", "Google"},
    {"facebook", "Facebook"}, {"youtube", "YouTube"}, {"tiktok", "TikTok"}, {"zalo", "Zalo"}, {"shopee", "Shopee"},
    {"lazada", "Lazada"}, {"grab", "Grab"}, {"momo", "MoMo"}, {"vnpay", "VNPay"}, {"vietcombank", "Vietcombank"},
    {"techcombank", "Techcombank"}, {"viettel", "Viettel"}, {"vingroup", "Vingroup"}, {"vinfast", "VinFast"},
    {"vietjet", "Vietjet"}, {"fpt", "FPT"}, {"arsenal", "Arsenal"}, {"liverpool", "Liverpool"},
    {"chelsea", "Chelsea"}, {"manchester", "Manchester"}, {"bitcoin", "Bitcoin"}, {"ethereum", "Ethereum"},
    {"binance", "Binance"}, {"netflix", "Netflix"}, {"spotify", "Spotify"}, {"github", "GitHub"},
    {"claude", "Claude"}, {"chatgpt", "ChatGPT"}, {"tesla", "Tesla"}, {"openai", "OpenAI"},
    {"anthropic", "Anthropic"}, {"yahoo", "Yahoo"}, {"hotmail", "Hotmail"}, {"windows", "Windows"},
    {"macos", "macOS"}, {"ios", "iOS"}, {"android", "Android"}, {"linux", "Linux"}, {"chrome", "Chrome"},
    {"safari", "Safari"}, {"excel", "Excel"}, {"word", "Word"}, {"wifi", "WiFi"}, {"gmail", "Gmail"},
    {"outlook", "Outlook"}, {"singapore", "Singapore"}, {"dubai", "Dubai"}, {"london", "London"},
    {"tokyo", "Tokyo"}, {"sydney", "Sydney"}, {"canada", "Canada"}, {"houston", "Houston"}, {"seattle", "Seattle"},
    {"miami", "Miami"}, {"dallas", "Dallas"}, {"austin", "Austin"}, {"texas", "Texas"},
    {"california", "California"}, {"washington", "Washington"}, {"york", "York"}, {"francisco", "Francisco"},
    {"paris", "Paris"}, {"bangkok", "Bangkok"}, {"seoul", "Seoul"}, {"nguyễn", "Nguyễn"}, {"trịnh", "Trịnh"},
    {"đặng", "Đặng"}, {"bùi", "Bùi"},
};
}  // namespace

std::u32string displayCase(const std::u32string& w, const std::optional<std::u32string>& after) {
    const std::string ws = u8(w);
    if (after) {
        const std::string p = u8(lowerS(*after)), needle = "|" + ws + "|";
        for (const Chain& c : kChains)
            if (p == c.prev) {
                if (std::strstr(c.next, needle.c_str())) return capitalizeFirst(w);
                break;
            }
    }
    for (const auto& pr : kProper)
        if (ws == pr[0]) return u32(pr[1]);
    return w;
}

std::u32string suggestionCase(const std::u32string& w, const std::u32string& typed) {
    int letters = 0, upper = 0;
    bool firstUpper = false;
    for (char32_t c : typed) {
        if (!text::isLetter(c)) continue;
        if (isUpperChar(c)) {
            ++upper;
            if (letters == 0) firstUpper = true;
        }
        ++letters;
    }
    enum { AsIs, Capitalized, Upper } mode = AsIs;
    if (letters == 0) mode = AsIs;  // shift .off
    else if (letters >= 2 && upper == letters) mode = Upper;
    else mode = firstUpper ? Capitalized : AsIs;
    if (mode == AsIs || w.empty() || !text::isLetter(w[0])) return w;
    if (mode == Upper) return text::upper(w);
    for (char32_t c : w)
        if (isUpperChar(c)) return w;
    return capitalizeFirst(w);
}

bool isSensitive(const std::u32string& w) {
    static const char* const kSet[] = {
        "đcm", "đm", "dm", "dcm", "vcl", "vkl", "vl", "cl", "clgt", "cmnr", "cứt", "lồn", "cặc", "buồi",
        "đĩ", "điếm", "đụ", "địt", "tml", "sml", "dâm", "fuck", "shit", "bitch", "wtf",
    };
    const std::string l = u8(lowerS(w));
    for (const char* x : kSet)
        if (l == x) return true;
    return false;
}

int seedCount(const std::string& w) {
    int lo = 0, hi = kSeedCount;
    while (lo < hi) {
        const int mid = (lo + hi) / 2;
        const int c = std::strcmp(kSeedWords + kSeedOff[mid], w.c_str());
        if (c == 0) return kSeedN[mid];
        if (c < 0) lo = mid + 1;
        else hi = mid;
    }
    return 0;
}

// ================================================================ the model

Model::Model(const addtones::LanguageData& data) : data_(data), index_(data.lexicon) {}

std::vector<std::u32string> Model::words(const Top& t) const {
    std::vector<std::u32string> out;
    out.reserve(t.ids.size());
    for (int id : t.ids) out.push_back(u32(data_.lexicon.display(id)));
    return out;
}

// SuggestRank.topNext — insertion into arrays of `limit`, no sort.
bool Model::topNext(const std::u32string& prev, const std::optional<std::u32string>& prev2, int limit, Top& out) const {
    out = Top();
    const addtones::SyllableLM& lm = data_.lm;
    if (!lm.ok() || limit <= 0) return false;
    const int pid = index_.lexiconId(prev);
    if (pid < 0) return false;
    addtones::SyllableLM::Context ctx;
    bool haveCtx = false;
    if (prev2) {
        const int id2 = index_.lexiconId(*prev2);
        if (id2 >= 0) haveCtx = lm.context(id2, pid, ctx);
    }
    const bool tri = haveCtx && ctx.hasTrigram();
    std::vector<int> ids(static_cast<size_t>(limit), 0);
    std::vector<double> sc(static_cast<size_t>(limit), 0);
    int n = 0;
    const double fw = kNextFreqWeight / 255;
    auto push = [&](int id, float pmi) {
        const double s = static_cast<double>(pmi) + fw * static_cast<double>(data_.lexicon.freq(id));
        if (n == limit && s <= sc[static_cast<size_t>(n - 1)]) return;
        int j;
        if (n < limit) {
            j = n;
            ++n;
        } else {
            j = n - 1;
        }
        while (j > 0 && sc[static_cast<size_t>(j - 1)] < s) {
            sc[static_cast<size_t>(j)] = sc[static_cast<size_t>(j - 1)];
            ids[static_cast<size_t>(j)] = ids[static_cast<size_t>(j - 1)];
            --j;
        }
        sc[static_cast<size_t>(j)] = s;
        ids[static_cast<size_t>(j)] = id;
    };
    if (tri) {
        // a long enough trigram row alone; a short one: both rows merged (KN back-off)
        if (ctx.forEachTrigram(push) < kTriOnlyRow) {
            n = 0;
            ctx.forEachNext(push);
        }
    } else {
        const addtones::SyllableLM::Bigram row = lm.bigram(pid);
        if (row.size() <= 0) return false;
        row.forEach(push);
    }
    if (n <= 0) return false;
    out.ids.assign(ids.begin(), ids.begin() + n);
    out.trigram = tri;
    return true;
}

// The trigram branch of SuggestRank.nextFill(prev, prev2:, personal: []) only: no (prev2, prev)
// trigram row => nothing (WordPrediction.swift, no one-word bigram guess).
std::vector<std::u32string> Model::nextWords(const std::u32string& prev, const std::optional<std::u32string>& prev2) const {
    Top tri;
    if (!prev2 || !topNext(prev, prev2, 6, tri) || !tri.trigram) return {};
    return pad(filterSensitive(words(tri)), kRankDepth);
}

// EnglishLite.completions: words starting with `typed` (a–z, any case), frequency desc then
// file order, the typed word itself skipped, case following the typed word.
std::vector<std::u32string> Model::englishCompletions(const std::u32string& typed, int limit) const {
    std::vector<std::u32string> out;
    const std::u32string low = lowerS(typed);
    if (low.empty() || limit <= 0) return out;
    std::string w;
    for (char32_t c : low) {
        if (c < U'a' || c > U'z') return out;
        w.push_back(static_cast<char>(c));
    }
    const addtones::EnglishLexicon& en = data_.english;
    std::vector<std::pair<int, int>> hits;  // (freq, index)
    for (size_t i = en.lowerBound(w); i < en.size(); ++i) {
        const std::string_view e = en.word(i);
        if (e.size() < w.size() || e.compare(0, w.size(), w) != 0) break;
        if (e.size() != w.size()) hits.emplace_back(en.freq(i), static_cast<int>(i));
    }
    typo::sortByFreqThenId(hits);
    // SwipeEnglish.matchCase
    const bool firstUpper = !typed.empty() && isUpperChar(typed[0]);
    bool allUpper = glen(typed) > 1;
    for (char32_t c : typed) allUpper = allUpper && isUpperChar(c);
    for (size_t k = 0; k < hits.size() && k < static_cast<size_t>(limit); ++k) {
        std::u32string word = u32(en.word(static_cast<size_t>(hits[k].second)));
        if (firstUpper) word = allUpper ? text::upper(word) : capitalizeFirst(word);
        out.push_back(std::move(word));
    }
    return out;
}

std::vector<std::u32string> Model::candidates(const Request& r, const std::u32string& raw) const {
    std::vector<std::u32string> out;
    if (!data_.ok()) return out;
    if (r.typed.empty()) {
        if (!wantsNextWord(r) || index_.lexiconId(*r.prev) < 0) return out;
        for (const auto& w : nextWords(*r.prev, r.prev2)) out.push_back(displayCase(w, r.prev));
        return out;
    }
    const std::u32string& typed = r.typed;
    std::vector<typo::LexiconIndex::Match> pool;
    if (!r.english) pool = index_.matches(typed, kPoolLimit, u8(lowerS(typed)));
    if (!wantsEnglish(r, static_cast<int>(pool.size()))) {
        // SuggestRank.inlinePmi (explicit entries of vnlm.bin after (prev2, prev))
        std::vector<float> pmi;
        bool havePmi = false;
        if (r.prev && data_.lm.ok() && !pool.empty()) {
            const int id = index_.lexiconId(*r.prev);
            if (id >= 0) {
                const int id2 = r.prev2 ? index_.lexiconId(*r.prev2) : -1;
                addtones::SyllableLM::Context ctx;
                if (data_.lm.context(id2, id, ctx) && ctx.bigramSize() > 0) {
                    havePmi = true;
                    for (const auto& m : pool) pmi.push_back(ctx.explicitPmi(m.id));
                }
            }
        }
        // SuggestRank.rankInline (no personal context: damp 1, ctx empty)
        const size_t typedLen = glen(typed);
        std::vector<std::pair<size_t, double>> scored;
        std::vector<std::u32string> poolWords;
        for (size_t i = 0; i < pool.size(); ++i) {
            poolWords.push_back(u32(pool[i].word));
            double b = 0.0;
            if (havePmi && i < pmi.size() && pmi[i] > 0)
                b = std::min(kBigramCap, kBigramWeight * static_cast<double>(pmi[i])) * 1;
            const double s = std::log(static_cast<double>(pool[i].freq) + 1) +
                             2.5 * std::log(static_cast<double>(seedCount(std::string(pool[i].word))) + 1) + 0.0 +
                             (glen(poolWords.back()) == typedLen ? 1.5 : 0) + b;
            scored.emplace_back(i, s);
        }
        // score desc, ties in pool order (pool ≤ kPoolLimit: insertion sort, stable)
        for (size_t i = 1; i < scored.size(); ++i)
            for (size_t j = i; j > 0 && scored[j - 1].second < scored[j].second; --j) std::swap(scored[j - 1], scored[j]);
        std::vector<std::u32string> ranked;
        for (const auto& s : scored) ranked.push_back(poolWords[s.first]);
        for (const auto& w : completions(filterSensitive(ranked), typed))
            out.push_back(suggestionCase(displayCase(w, r.prev), typed));
        return out;
    }
    // English: the raw keys (a–z) — "this" may show as "thí" after Telex.
    const std::u32string key = raw.empty() ? typed : raw;
    const std::u32string src = glen(key) >= static_cast<size_t>(kMinTyped) ? key : typed;
    const std::vector<std::u32string> en = filterSensitive(englishCompletions(src, kPoolLimit));
    return completions(en, glen(typed) >= glen(src) ? typed : src);
}

}  // namespace vtx::app::predict
