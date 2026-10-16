// auto_text.cpp — see auto_text.h. Rules ported 1:1 from macOS SystemAutoText.swift /
// WordPrediction.swift (PredictionLogic); Swift Character predicates are approximated on code
// points for the scripts a Vietnamese IME produces (precomposed text; a trailing combining mark
// counts with its base letter).
#include "viettelex/auto_text.h"

#include "viettelex/app.h"
#include "viettelex/caret_hints.h"

#include <set>
#include <vector>

namespace viettelex {
namespace autotext {

namespace {

std::vector<uint32_t> decode(const std::string &s) {
    std::vector<uint32_t> out;
    for (size_t i = 0; i < s.size();) {
        unsigned char b = static_cast<unsigned char>(s[i]);
        size_t n = b < 0x80 ? 1 : (b >> 5) == 6 ? 2 : (b >> 4) == 14 ? 3 : (b >> 3) == 30 ? 4 : 0;
        if (n == 0 || i + n > s.size()) {
            out.push_back(0xfffd);
            ++i;
            continue;
        }
        uint32_t cp = n == 1 ? b : n == 2 ? (b & 0x1f) : n == 3 ? (b & 0x0f) : (b & 0x07);
        for (size_t k = 1; k < n; ++k) cp = (cp << 6) | (static_cast<unsigned char>(s[i + k]) & 0x3f);
        out.push_back(cp);
        i += n;
    }
    return out;
}

bool isCombining(uint32_t c) { return (c >= 0x300 && c <= 0x36f) || (c >= 0x1dc0 && c <= 0x1dff); }

// Grapheme-ish view: combining marks folded into their base character.
std::vector<uint32_t> chars(const std::string &s) {
    std::vector<uint32_t> out;
    for (uint32_t c : decode(s)) {
        if (isCombining(c) && !out.empty()) continue;
        out.push_back(c);
    }
    return out;
}

// Character.isLetter for Latin (incl. Vietnamese), Greek, Cyrillic, CJK, Hangul.
bool isLetter(uint32_t c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == 0xaa || c == 0xb5 || c == 0xba ||
           (c >= 0xc0 && c <= 0x24f && c != 0xd7 && c != 0xf7) || (c >= 0x370 && c <= 0x3ff && c != 0x37e) ||
           (c >= 0x400 && c <= 0x52f) || (c >= 0x1e00 && c <= 0x1fff) || (c >= 0x3040 && c <= 0x30ff) ||
           (c >= 0x3400 && c <= 0x9fff) || (c >= 0xac00 && c <= 0xd7a3);
}
bool isNumber(uint32_t c) {
    return (c >= '0' && c <= '9') || c == 0xb2 || c == 0xb3 || c == 0xb9 || (c >= 0xbc && c <= 0xbe) ||
           (c >= 0x2070 && c <= 0x2079) || (c >= 0x2080 && c <= 0x2089) || (c >= 0xff10 && c <= 0xff19);
}
bool isNewline(uint32_t c) {
    return c == '\n' || c == '\r' || c == 0x0b || c == 0x0c || c == 0x85 || c == 0x2028 || c == 0x2029;
}
bool isWhitespace(uint32_t c) {
    return c == ' ' || c == '\t' || isNewline(c) || c == 0xa0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200a) ||
           c == 0x202f || c == 0x205f || c == 0x3000;
}
bool isUpper(uint32_t c) {
    if (c >= 'A' && c <= 'Z') return true;
    std::string s;
    // hints::lower knows Vietnamese capitals (Ă Đ Ơ Ư Ạ…)
    if (c < 0x80) return false;
    if (c < 0x800) { s += char(0xc0 | (c >> 6)); s += char(0x80 | (c & 0x3f)); }
    else { s += char(0xe0 | (c >> 12)); s += char(0x80 | ((c >> 6) & 0x3f)); s += char(0x80 | (c & 0x3f)); }
    return hints::lower(s) != s;
}

std::string encode(const std::vector<uint32_t> &v, size_t from, size_t to) {
    std::string o;
    for (size_t i = from; i < to; ++i) {
        uint32_t cp = v[i];
        if (cp < 0x80) o += char(cp);
        else if (cp < 0x800) { o += char(0xc0 | (cp >> 6)); o += char(0x80 | (cp & 0x3f)); }
        else if (cp < 0x10000) {
            o += char(0xe0 | (cp >> 12)); o += char(0x80 | ((cp >> 6) & 0x3f)); o += char(0x80 | (cp & 0x3f));
        } else {
            o += char(0xf0 | (cp >> 18)); o += char(0x80 | ((cp >> 12) & 0x3f));
            o += char(0x80 | ((cp >> 6) & 0x3f)); o += char(0x80 | (cp & 0x3f));
        }
    }
    return o;
}

uint32_t firstCp(const std::string &s) {
    auto v = decode(s);
    return v.empty() ? 0 : v[0];
}

}  // namespace

Quotes quotesFor(const std::string &style) {
    if (style == "low9") return {"„", "“", "‚", "‘"};
    if (style == "guillemets") return {"«", "»", "‹", "›"};
    return {"“", "”", "‘", "’"};
}

bool isCodeEditorApp(const std::string &appId) {
    // SystemAutoText.excludedApps (Xcode, VS Code + forks, Zed, Sublime, Nova, BBEdit,
    // TextMate, Android Studio, JetBrains) — Linux ids (.desktop / WM_CLASS / Flatpak).
    static const std::set<std::string> names = {
        "code", "code-oss", "code-insiders", "vscode", "vscodium", "codium", "cursor", "windsurf", "kiro",
        "trae", "void", "pearai", "positron", "antigravity", "zed", "zeditor", "zed-preview", "dev.zed.zed",
        "sublime_text", "sublime-text", "sublime_merge", "android-studio", "studio", "idea", "gnome-builder",
        "builder", "kate", "kdevelop", "qtcreator", "geany", "lapce", "neovide", "gvim", "emacs", "lite-xl",
        "pulsar", "atom", "netbeans", "eclipse", "com.visualstudio.code", "com.vscodium.codium",
    };
    std::string id = normalizeAppId(appId);
    if (id.empty()) return false;
    if (names.count(id)) return true;
    size_t dot = id.rfind('.');
    if (dot != std::string::npos && names.count(id.substr(dot + 1))) return true;
    return id.rfind("jetbrains-", 0) == 0;
}

bool appAllowed(const std::string &appId) { return !isTerminalApp(appId) && !isCodeEditorApp(appId); }

bool periodQualifies(uint32_t c) {
    switch (c) {
    case ')': case ']': case '}': case '"': case '\'': case 0x201d: case 0x2019: case 0xbb: case 0x203a:
        return true;
    default:
        return isLetter(c) || isNumber(c);
    }
}

bool doubleSpacePeriod(const std::string &before, int64_t gapMs, bool isRepeat, uint32_t *prev) {
    if (isRepeat || gapMs < 0 || gapMs > kDoubleSpaceWindowMs) return false;
    auto v = chars(before);
    if (v.size() < 2 || v.back() != ' ') return false;
    uint32_t p = v[v.size() - 2];
    if (!periodQualifies(p)) return false;
    if (prev) *prev = p;
    return true;
}

std::string smartQuote(uint32_t typed, uint32_t prev, bool hasPrev, const Quotes &q) {
    bool dbl;
    if (typed == '"') dbl = true;
    else if (typed == '\'') dbl = false;
    else return std::string();
    bool open = true;
    if (hasPrev) {
        static const std::set<uint32_t> openers = {'(', '[', '{', '<', 0x201c, 0x2018, 0xab, 0x2039, 0x2014, 0x2013, '/'};
        open = isWhitespace(prev) || openers.count(prev) ||
               (dbl ? prev == firstCp(q.openSingle) : prev == firstCp(q.openDouble));
    }
    return dbl ? (open ? q.openDouble : q.closeDouble) : (open ? q.openSingle : q.closeSingle);
}

DashEdit dash(const std::string &before, bool lastWasOurEmDash) {
    auto v = chars(before);
    if (lastWasOurEmDash && !v.empty() && v.back() == 0x2014) return DashEdit::Restore;
    if (v.empty() || v.back() != '-') return DashEdit::None;
    if (v.size() >= 2) {
        uint32_t p = v[v.size() - 2];
        if (p == '-' || p == '<' || p == '!' || p == 0x2014) return DashEdit::None;
    }
    return DashEdit::EmDash;
}

CapContext capitalization(const std::string *before, bool atTextStart) {
    if (atTextStart) return CapContext::Capitalize;
    if (!before) return CapContext::Unknown;
    auto s = chars(*before);
    if (!s.empty() && isNewline(s.back())) return CapContext::Capitalize;  // new paragraph
    if (s.empty() || !(s.back() == ' ' || s.back() == '\t'))
        return s.empty() ? CapContext::Unknown : CapContext::Keep;  // mid-word / after a symbol
    size_t n = s.size();
    while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t')) --n;
    if (n == 0) return CapContext::Unknown;  // only whitespace known
    if (isNewline(s[n - 1])) return CapContext::Capitalize;
    static const std::set<uint32_t> closers = {')', ']', '"', '\'', 0x201d, 0x2019, 0xbb, 0x203a};
    while (n > 0 && closers.count(s[n - 1])) --n;
    if (n == 0) return CapContext::Keep;
    uint32_t end = s[n - 1];
    if (!(end == '.' || end == '!' || end == '?')) return CapContext::Keep;
    if (end != '.') return CapContext::Capitalize;
    --n;
    if (n > 0 && s[n - 1] == '.') return CapContext::Keep;  // "..." — not surely the end
    // The word right before the dot (leading brackets / quotes dropped).
    size_t b = n;
    while (b > 0 && !isWhitespace(s[b - 1])) --b;
    static const std::set<uint32_t> openers = {'(', '[', '{', '"', '\'', 0x201c, 0x2018, 0xab};
    while (b < n && openers.count(s[b])) ++b;
    if (b == n) return CapContext::Capitalize;
    std::string token = encode(s, b, n);
    static const std::set<std::string> abbreviations = {
        "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "etc", "e.g", "i.e", "cf",
        "approx", "no", "fig", "inc", "ltd", "co", "corp", "dept", "est", "a.m", "p.m",
        "tp", "ths", "ts", "pgs", "gs", "bs", "ks", "lg", "q", "p", "tx", "đ/c",
    };
    if (abbreviations.count(hints::lower(token))) return CapContext::Keep;
    // email, URL, domain, "U.S." — not surely the end of a sentence.
    if (token.find_first_of("@/.") != std::string::npos) return CapContext::Keep;
    // A one-letter initial ("J. Smith").
    if (n - b == 1 && isUpper(s[b])) return CapContext::Keep;
    return CapContext::Capitalize;
}

uint32_t capitalized(uint32_t ch) { return ch >= 'a' && ch <= 'z' ? ch - 32 : ch; }

bool predictionMuted(const std::string &typed, const std::string &declined) {
    if (declined.empty() || typed.empty()) return false;
    std::string t = hints::lower(typed), d = hints::lower(declined);
    return t.compare(0, d.size(), d) == 0;
}

bool completionWorthAsking(const std::string &typed) {
    auto v = chars(typed);
    if (int(v.size()) < kPredictMinTyped) return false;
    for (uint32_t c : v)
        if (!isLetter(c)) return false;
    return true;
}

bool nextWordWorthAsking(const std::string &before) {
    auto v = chars(before);
    return v.size() >= 2 && v.back() == ' ' && isLetter(v[v.size() - 2]);
}

}  // namespace autotext
}  // namespace viettelex
