// test_auto_text — "văn bản tự động" (auto_text.h + Session): the pure rules ported from macOS
// (AppTests/SystemAutoTextTests.swift golden cases: double-space period, smart quotes, dashes,
// sentence capitals; WordPredictionTests: Esc mute, the helper protocol), and the Session
// wiring per display mode (Preedit / Surrounding / Direct, proven vs blind surrounding,
// password / English / terminals / code editors), all four switches OFF by default. The
// ranking itself (Swift, shared with iOS/macOS) is checked by ctest caret_suggest
// (viettelex-text-tool --self-test); here the real helper answers "predict" end to end when
// VIETTELEX_TEXT_TOOL is set.

#include "viettelex/auto_text.h"
#include "viettelex/caret_hints.h"
#include "viettelex/keys.h"
#include "viettelex/session.h"
#include "viettelex/settings.h"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace viettelex;
using namespace viettelex::autotext;
using Kind = CaretSuggestion::Kind;

static int g_fail = 0, g_pass = 0;
#define CHECK_EQ(a, b)                                                                         \
    do {                                                                                       \
        auto _a = (a);                                                                         \
        auto _b = (b);                                                                         \
        if (_a == _b) ++g_pass;                                                                \
        else {                                                                                 \
            ++g_fail;                                                                          \
            std::fprintf(stderr, "%s:%d: CHECK_EQ(%s, %s) failed\n", __FILE__, __LINE__, #a, #b); \
        }                                                                                      \
    } while (0)
#define CHECK(x) CHECK_EQ(bool(x), true)

namespace {

const uint32_t kRdq = 0x201d, kRsq = 0x2019;

std::string u8(uint32_t cp) {
    std::string o;
    if (cp < 0x80) o += char(cp);
    else if (cp < 0x800) { o += char(0xc0 | (cp >> 6)); o += char(0x80 | (cp & 0x3f)); }
    else { o += char(0xe0 | (cp >> 12)); o += char(0x80 | ((cp >> 6) & 0x3f)); o += char(0x80 | (cp & 0x3f)); }
    return o;
}

void popChars(std::string &s, int n) {
    while (n-- > 0 && !s.empty()) {
        size_t i = s.size() - 1;
        while (i > 0 && (static_cast<unsigned char>(s[i]) & 0xc0) == 0x80) --i;
        s.resize(i);
    }
}

struct Mock : InputContext {
    std::string doc, pre, shown, aux;
    std::vector<std::string> cands;
    bool surrounding = true, selection = false;
    int hides = 0;
    void setPreedit(const std::string &s, bool) override { pre = s; }
    void commit(const std::string &s) override { doc += s; }
    void deleteBeforeCursor(int n) override { popChars(doc, n); }
    bool textBeforeCursor(std::string &out) override {
        if (!surrounding) return false;
        out = doc;
        return true;
    }
    bool hasSelection() override { return selection; }
    void showHint(const std::string &l) override { shown = l; }
    void showCandidates(const std::vector<std::string> &w, const std::string &a) override {
        cands = w;
        aux = a;
    }
    void hideHint() override {
        shown.clear();
        cands.clear();
        aux.clear();
        ++hides;
    }
    // Direct mode (terminal): forwarded keys land in the document.
    void directReplace(int bs, const std::string &s) override {
        popChars(doc, bs);
        doc += s;
    }
};

int64_t g_now = 1000000;

// Press (and release unless `hold`). Returns whether the IM consumed the key; otherwise does
// what the app would (ASCII only).
bool press(Session &s, Mock &m, uint32_t keysym, uint32_t unicode, bool release = true) {
    KeyEvent ev;
    ev.keysym = keysym;
    ev.unicode = unicode;
    bool consumed = s.processKey(ev, m);
    if (release) {
        ev.release = true;
        s.processKey(ev, m);
    }
    if (consumed) return true;
    if (keysym == ks::BackSpace) popChars(m.doc, 1);
    else if (keysym == ks::Return) m.doc += "\n";
    else if (keysym == ks::Tab) m.doc += "\t";
    else if (unicode >= 0x20 && unicode < 0x7f) m.doc += char(unicode);
    return false;
}

// '<' BackSpace, '\n' Return, '\t' Tab, '~' Escape; 10 ms between keys.
void type(Session &s, Mock &m, const std::string &keys) {
    for (char c : keys) {
        g_now += 10;
        switch (c) {
        case '<': press(s, m, ks::BackSpace, 0); break;
        case '\n': press(s, m, ks::Return, '\r'); break;
        case '\t': press(s, m, ks::Tab, '\t'); break;
        case '~': press(s, m, ks::Escape, 0x1b); break;
        default: press(s, m, uint32_t((unsigned char)c), uint32_t((unsigned char)c));
        }
    }
}

struct Rig {
    Session s;
    Mock m;
    std::vector<HintRequest> reqs;
    Rig(Settings st, DisplayMode mode = DisplayMode::Preedit, bool edits = true, bool sink = true) {
        s.setClockForTesting([] { return g_now; });
        s.applySettings(st);
        s.setDisplayMode(mode, m);
        s.setSurroundingEdits(edits);
        if (sink) s.setHintSink([this](const HintRequest &r) { reqs.push_back(r); });
    }
    std::string last() const { return reqs.empty() ? std::string() : reqs.back().line; }
    void answer(const CaretSuggestion &c) { s.deliverHint(reqs.back().gen, c, m); }
};

Settings with(bool period, bool cap, bool smart, bool predict) {
    Settings s;
    s.mathResults = s.numberChips = s.typoHints = s.dateHints = false;
    s.doubleSpacePeriod = period;
    s.autoCapitalize = cap;
    s.smartPunctuation = smart;
    s.wordPrediction = predict;
    return s;
}

std::string req(std::vector<std::string> f) { return hints::request(f); }

CaretSuggestion P(std::string d, std::string r, std::vector<std::string> alt = {}) {
    CaretSuggestion c;
    c.kind = Kind::Predict;
    c.display = d;
    c.replace = std::move(r);
    c.insert = d + " ";
    c.alternates = std::move(alt);
    return c;
}

// MARK: - pure rules (SystemAutoTextTests)

void testSettings() {
    Settings d;
    CHECK(!d.doubleSpacePeriod && !d.autoCapitalize && !d.smartPunctuation && !d.wordPrediction);  // all OFF
    CHECK_EQ(d.quoteStyle, std::string("curly"));
    Settings p = parseConfig("[general]\ndouble_space_period = true\nauto_capitalize = true\n"
                             "smart_punctuation = true\nword_prediction = true\nquote_style = \"guillemets\"\n");
    CHECK(p.doubleSpacePeriod && p.autoCapitalize && p.smartPunctuation && p.wordPrediction);
    CHECK_EQ(p.quoteStyle, std::string("guillemets"));
    CHECK_EQ(parseConfig("[general]\nquote_style = \"fancy\"\n").quoteStyle, std::string("curly"));
    CHECK(!parseConfig("[general]\nword_prediction = \"yes\"\n").wordPrediction);  // wrong type → default
    Settings rt = parseConfig(serializeConfig(p));
    CHECK(rt.doubleSpacePeriod && rt.autoCapitalize && rt.smartPunctuation && rt.wordPrediction);
    CHECK_EQ(rt.quoteStyle, std::string("guillemets"));
    CHECK(quotesFor("curly") == (Quotes{"“", "”", "‘", "’"}));
    CHECK(quotesFor("low9") == (Quotes{"„", "“", "‚", "‘"}));
    CHECK(quotesFor("guillemets") == (Quotes{"«", "»", "‹", "›"}));
}

void testExcludedApps() {
    for (const char *id : {"gnome-terminal-server", "org.gnome.Ptyxis", "konsole", "kitty", "code", "codium",
                           "cursor", "dev.zed.Zed", "sublime_text", "jetbrains-idea", "jetbrains-pycharm-ce",
                           "org.kde.kate", "com.visualstudio.code"})
        CHECK_EQ(appAllowed(id), false);
    for (const char *id : {"org.gnome.TextEditor", "gedit", "firefox", "google-chrome", "libreoffice-writer",
                           "thunderbird", "slack", "default", ""})
        CHECK_EQ(appAllowed(id), true);
}

void testDoubleSpaceRule() {
    uint32_t p = 0;
    CHECK(doubleSpacePeriod("xin chào ", 200, false, &p));
    CHECK_EQ(p, uint32_t('o'));
    CHECK(doubleSpacePeriod("việt ", 200, false, &p));
    CHECK_EQ(p, uint32_t('t'));
    CHECK(doubleSpacePeriod("năm 2026 ", 200, false, &p));
    CHECK_EQ(p, uint32_t('6'));
    CHECK(doubleSpacePeriod("(xem trên) ", 200, false, &p));
    CHECK_EQ(p, uint32_t(')'));
    CHECK(doubleSpacePeriod("“hay” ", 200, false, &p));
    CHECK_EQ(p, kRdq);
    CHECK(doubleSpacePeriod("Việt\xcc\x81 ", 200, false));  // NFD mark folded into its letter
    for (const char *b : {"hết. ", "hết, ", "hết! ", "hết? ", "hết: ", "hết; ", "a - ", "hết.  ", " ", ""})
        CHECK_EQ(doubleSpacePeriod(b, 100, false), false);
    CHECK_EQ(doubleSpacePeriod("chào", 100, false), false);  // no first space
    CHECK(doubleSpacePeriod("a ", kDoubleSpaceWindowMs, false));
    CHECK_EQ(doubleSpacePeriod("a ", kDoubleSpaceWindowMs + 1, false), false);
    CHECK_EQ(doubleSpacePeriod("a ", 30, true), false);  // held space
    CHECK_EQ(kDoubleSpaceWindowMs, int64_t(1100));
    CHECK_EQ(doubleSpacePeriod("chào. ", 100, false), false);  // after the replacement: no again
}

void testSmartQuoteRule() {
    Quotes q = quotesFor("curly");
    CHECK_EQ(smartQuote('"', 0, false, q), std::string("“"));  // start of the text
    CHECK_EQ(smartQuote('"', ' ', true, q), std::string("“"));
    CHECK_EQ(smartQuote('"', '(', true, q), std::string("“"));
    CHECK_EQ(smartQuote('"', '\n', true, q), std::string("“"));
    CHECK_EQ(smartQuote('"', 'o', true, q), std::string("”"));
    CHECK_EQ(smartQuote('"', '.', true, q), std::string("”"));
    CHECK_EQ(smartQuote('\'', 'n', true, q), std::string("’"));  // don't → don’t
    CHECK_EQ(smartQuote('\'', ' ', true, q), std::string("‘"));
    CHECK_EQ(smartQuote('\'', 0x201c, true, q), std::string("‘"));  // “‘lồng’”
    CHECK_EQ(smartQuote('"', 0x2018, true, q), std::string("“"));
    CHECK_EQ(smartQuote('"', 0x2014, true, q), std::string("“"));  // after an em dash
    CHECK_EQ(smartQuote('"', 0x1ec7, true, q), std::string("”"));  // after "ệ"
    CHECK(smartQuote('-', ' ', true, q).empty());
    Quotes g = quotesFor("guillemets");
    CHECK_EQ(smartQuote('"', ' ', true, g), std::string("«"));
    CHECK_EQ(smartQuote('"', 'a', true, g), std::string("»"));
    CHECK_EQ(smartQuote('\'', 0xab, true, g), std::string("‹"));  // inside « » opens
}

void testDashRule() {
    CHECK(dash("a-", false) == DashEdit::EmDash);
    CHECK(dash("a -", false) == DashEdit::EmDash);
    CHECK(dash("-", false) == DashEdit::EmDash);
    CHECK(dash("a", false) == DashEdit::None);
    CHECK(dash("a--", false) == DashEdit::None);  // already 3+ dashes
    CHECK(dash("<!-", false) == DashEdit::None);  // HTML comment
    CHECK(dash("a—", true) == DashEdit::Restore);  // "---" kept literally
    CHECK(dash("a—", false) == DashEdit::None);   // an existing "—" + "-"
}

void testCapitalizationRule() {
    auto cap = [](const char *b) {
        std::string s(b);
        return capitalization(&s, false);
    };
    CHECK(cap("Xong rồi. ") == CapContext::Capitalize);
    CHECK(cap("Thật sao? ") == CapContext::Capitalize);
    CHECK(cap("Hay quá! ") == CapContext::Capitalize);
    CHECK(cap("Anh nói “đi thôi.” ") == CapContext::Capitalize);
    CHECK(cap("dòng một\n") == CapContext::Capitalize);
    CHECK(cap("dòng một\n  ") == CapContext::Capitalize);
    CHECK(capitalization(nullptr, true) == CapContext::Capitalize);
    CHECK(cap("1. ") == CapContext::Capitalize);
    for (const char *b : {"xin ", "xin, ", "xin", "e.g. ", "Mr. ", "x etc. ", "ở TP. ", "gửi a@b.vn. ",
                          "xem viettelex.com. ", "J. ", "thế... ", "Đ/c ", "gặp Đ/c. "})
        CHECK(cap(b) == CapContext::Keep);
    CHECK(capitalization(nullptr, false) == CapContext::Unknown);
    CHECK(cap("") == CapContext::Unknown);
    CHECK(cap("  ") == CapContext::Unknown);
    CHECK_EQ(capitalized('d'), uint32_t('D'));
    CHECK_EQ(capitalized('D'), uint32_t('D'));
    CHECK_EQ(capitalized('1'), uint32_t('1'));
    CHECK_EQ(capitalized('['), uint32_t('['));
}

void testPredictionGates() {
    CHECK(predictionMuted("đươ", "đư"));
    CHECK(predictionMuted("Đư", "đư"));
    CHECK(!predictionMuted("đa", "đư"));
    CHECK(!predictionMuted("", "đư"));
    CHECK(!predictionMuted("đư", ""));
    CHECK(completionWorthAsking("đư"));
    CHECK(!completionWorthAsking("đ"));
    CHECK(!completionWorthAsking("a1"));
    CHECK(nextWordWorthAsking("cảm "));
    CHECK(!nextWordWorthAsking("hai  "));
    CHECK(!nextWordWorthAsking("xong. "));
    CHECK(!nextWordWorthAsking(" "));
    CHECK_EQ(kPredictIdleMs, 300);
    // Protocol: predict answers carry up to two alternates; replace may be empty (next word).
    CaretSuggestion c;
    CHECK(hints::parseAnswer("predict\tđược\tđư\tđược \tđường\tđưa", c));
    CHECK(c == P("được", "đư", {"đường", "đưa"}));
    CHECK(hints::parseAnswer("predict\tơn\t\tơn ", c));
    CHECK(c == P("ơn", ""));
    CHECK(!hints::parseAnswer("predict\ta\tb\ta \tc\td\te", c));
    CHECK(!hints::parseAnswer("typo\ttôi\ttpoi \ttôi \tx", c));
    CHECK(!hints::parseAnswer("typo\ttôi\t\ttôi ", c));
    CHECK(hints::keyAction(Kind::Predict, ks::Tab, 0) == hints::KeyAction::Accept);
    CHECK(hints::keyAction(Kind::Predict, ks::Return, 0) == hints::KeyAction::DismissPass);  // never Enter
    CHECK(hints::keyAction(Kind::Predict, '1', 0) == hints::KeyAction::DismissPass);  // digits are digits
    CHECK(hints::keyAction(Kind::Predict, ks::Escape, 0) == hints::KeyAction::DismissConsume);
    CHECK(hints::keyAction(Kind::Predict, ks::Tab, VT_MOD_SHIFT) == hints::KeyAction::DismissPass);
}

// MARK: - Session: dấu chấm khi gõ hai dấu cách

void space(Rig &r, int gapMs, bool release = true) {
    g_now += gapMs;
    press(r.s, r.m, ' ', ' ', release);
}

void testDoubleSpaceSession() {
    for (DisplayMode mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Rig r(with(true, false, false, false), mode);
        type(r.s, r.m, "xin chaof");
        space(r, 100);
        space(r, 200);
        CHECK_EQ(r.m.doc, std::string("xin chào. "));
        space(r, 200);  // a third space is just a space
        CHECK_EQ(r.m.doc, std::string("xin chào.  "));
    }
    // Too slow / held / after punctuation / off / not here.
    Rig slow(with(true, false, false, false));
    type(slow.s, slow.m, "chaof");
    space(slow, 10);
    space(slow, 1200);
    CHECK_EQ(slow.m.doc, std::string("chào  "));
    Rig held(with(true, false, false, false));
    type(held.s, held.m, "chaof");
    space(held, 10, false);
    space(held, 30, false);  // autorepeat: no release in between
    CHECK_EQ(held.m.doc, std::string("chào  "));
    Rig punct(with(true, false, false, false));
    type(punct.s, punct.m, "het,");
    space(punct, 10);
    space(punct, 100);
    CHECK_EQ(punct.m.doc, std::string("het,  "));
    Rig off(with(false, false, false, false));
    type(off.s, off.m, "chaof  ");
    CHECK_EQ(off.m.doc, std::string("chào  "));
    Rig code(with(true, false, false, false));
    code.s.setAutoTextAllowed(false);
    type(code.s, code.m, "x  ");
    CHECK_EQ(code.m.doc, std::string("x  "));
    // Chrome / Firefox (surrounding not proven, forced preedit): cannot replace committed text.
    Rig blind(with(true, false, false, false), DisplayMode::Preedit, false);
    type(blind.s, blind.m, "chaof  ");
    CHECK_EQ(blind.m.doc, std::string("chào  "));
    // The screen changed under us (app autocompleted): plain space.
    Rig moved(with(true, false, false, false));
    type(moved.s, moved.m, "chaof");
    space(moved, 10);
    moved.m.doc = "chàoX ";
    space(moved, 100);
    CHECK_EQ(moved.m.doc, std::string("chàoX  "));
    // Terminal (Direct): never.
    Rig term(with(true, false, false, false), DisplayMode::Direct, false);
    type(term.s, term.m, "ls  ");
    CHECK_EQ(term.m.doc, std::string("ls  "));
    // ⌫ right after deletes the inserted space, never re-opens the word.
    Rig bs(with(true, false, false, false));
    type(bs.s, bs.m, "chaof  <");
    CHECK_EQ(bs.m.doc, std::string("chào."));
}

// MARK: - viết hoa đầu câu

void testCapitalizeSession() {
    Rig r(with(false, true, false, false));
    r.m.doc = "Xong rồi. ";
    type(r.s, r.m, "dduwowcj ");
    CHECK_EQ(r.m.doc, std::string("Xong rồi. Được "));  // Telex still composes
    type(r.s, r.m, "vieejt nam. ddi\nhoc ");
    CHECK_EQ(r.m.doc, std::string("Xong rồi. Được việt nam. Đi\nHoc "));
    // Abbreviations / initials / "..." / mid-sentence: no capital.
    Rig k(with(false, true, false, false));
    k.m.doc = "Mr. ";
    type(k.s, k.m, "smith ");
    CHECK_EQ(k.m.doc, std::string("Mr. smith "));
    // ⌫ the auto capital: the next first letter stays lowercase (user declined).
    Rig d(with(false, true, false, false));
    d.m.doc = "Xong. ";
    type(d.s, d.m, "i");
    CHECK_EQ(d.m.pre, std::string("I"));
    type(d.s, d.m, "<iphone ");
    CHECK_EQ(d.m.doc, std::string("Xong. iphone "));
    // Start of the field: only multi-line fields (Fcitx5 Multiline).
    Rig one(with(false, true, false, false));
    type(one.s, one.m, "google ");
    CHECK_EQ(one.m.doc, std::string("google "));
    Rig multi(with(false, true, false, false));
    multi.s.setMultiline(true);
    type(multi.s, multi.m, "chaof ");
    CHECK_EQ(multi.m.doc, std::string("Chào "));
    // Surrounding (word typed in place).
    Rig sur(with(false, true, false, false), DisplayMode::Surrounding);
    sur.m.doc = "Hay quá! ";
    type(sur.s, sur.m, "vieejt");
    CHECK_EQ(sur.m.doc, std::string("Hay quá! Việt"));
    // Blind field (Chrome): nothing known before the first word; then the keys tell.
    Rig blind(with(false, true, false, false), DisplayMode::Preedit, false);
    blind.m.doc = "Xong. ";
    type(blind.s, blind.m, "xong. dduwowcj ");
    CHECK_EQ(blind.m.doc, std::string("Xong. xong. Được "));
    // Off, code editor, English mode, password: never.
    Rig off(with(false, false, false, false));
    off.m.doc = "Xong. ";
    type(off.s, off.m, "abc ");
    CHECK_EQ(off.m.doc, std::string("Xong. abc "));
    Rig code(with(false, true, false, false));
    code.s.setAutoTextAllowed(false);
    code.m.doc = "x. ";
    type(code.s, code.m, "abc ");
    CHECK_EQ(code.m.doc, std::string("x. abc "));
    Rig en(with(false, true, false, false));
    en.s.setVietnamese(false, en.m);
    en.m.doc = "x. ";
    type(en.s, en.m, "abc ");
    CHECK_EQ(en.m.doc, std::string("x. abc "));
    Rig pw(with(false, true, false, false));
    pw.s.setPassthrough(true, pw.m);
    pw.m.doc = "x. ";
    type(pw.s, pw.m, "abc ");
    CHECK_EQ(pw.m.doc, std::string("x. abc "));
    // Shift already: nothing to do; VNI digits untouched.
    Settings vni = with(false, true, false, false);
    vni.vni = true;
    Rig v(vni);
    v.m.doc = "Xong. ";
    type(v.s, v.m, "d9u7o7c5 ");
    CHECK_EQ(v.m.doc, std::string("Xong. Được "));
}

// MARK: - ngoặc kép cong + gạch dài

void testSmartPunctuationSession() {
    Rig r(with(false, false, true, false));
    type(r.s, r.m, "\"xin chaof\" don't 'a'");
    CHECK_EQ(r.m.doc, std::string("“xin chào” don’t ‘a’"));
    CHECK(r.m.pre.empty());
    // Blind field: the very first quote is unknown → left straight; after typed text it is known.
    Rig blind(with(false, false, true, false), DisplayMode::Preedit, false);
    type(blind.s, blind.m, "\"a \"b\"");
    CHECK_EQ(blind.m.doc, std::string("\"a “b”"));
    // Quote style.
    Settings g = with(false, false, true, false);
    g.quoteStyle = "low9";
    Rig low(g);
    type(low.s, low.m, "\"vieejt\"");
    CHECK_EQ(low.m.doc, std::string("„việt“"));
    // Dashes (surrounding proven): "--" → "—", one more "-" → "---", "<!--" kept.
    for (DisplayMode mode : {DisplayMode::Preedit, DisplayMode::Surrounding}) {
        Rig d(with(false, false, true, false), mode);
        type(d.s, d.m, "a--b");
        CHECK_EQ(d.m.doc + d.m.pre, std::string("a—b"));
        type(d.s, d.m, " ---");
        CHECK_EQ(d.m.doc, std::string("a—b ---"));
        type(d.s, d.m, "- x!--");
        CHECK_EQ(d.m.doc, std::string("a—b ---- x!--"));
    }
    // ⌫ after "—": the em dash goes (one character).
    Rig b(with(false, false, true, false));
    type(b.s, b.m, "x--<");
    CHECK_EQ(b.m.doc, std::string("x"));
    // Blind field: "--" stays (cannot replace committed text).
    Rig bd(with(false, false, true, false), DisplayMode::Preedit, false);
    type(bd.s, bd.m, "a--");
    CHECK_EQ(bd.m.doc, std::string("a--"));
    // Terminal / code editor / off.
    Rig t(with(false, false, true, false), DisplayMode::Direct, false);
    type(t.s, t.m, "echo \"x\" --help");
    CHECK_EQ(t.m.doc, std::string("echo \"x\" --help"));
    Rig c(with(false, false, true, false));
    c.s.setAutoTextAllowed(false);
    type(c.s, c.m, "\"x\" --");
    CHECK_EQ(c.m.doc, std::string("\"x\" --"));
    Rig off(with(false, false, false, false));
    type(off.s, off.m, "\"x\" --");
    CHECK_EQ(off.m.doc, std::string("\"x\" --"));
    // ⌫ right after a curly quote never re-opens the word before it.
    Rig q(with(false, false, true, false));
    type(q.s, q.m, "vieejt\"<");
    CHECK_EQ(q.m.doc, std::string("việt"));
}

// MARK: - gợi ý từ

void testPredictionSession() {
    // Completion while composing (Preedit: the word is the composition).
    Rig r(with(false, false, false, true));
    type(r.s, r.m, "tooi dduw");
    CHECK_EQ(r.last(), req({"predict", "tôi đư", "đư", "dduw", "0"}));
    CHECK_EQ(r.reqs.back().delayMs, kPredictIdleMs);
    r.answer(P("được", "đư", {"đường", "đưa"}));
    CHECK(r.s.hint() != nullptr);
    CHECK(r.m.cands == (std::vector<std::string>{"được", "đường", "đưa"}));
    CHECK_EQ(r.m.aux, std::string("Tab"));
    CHECK(press(r.s, r.m, ks::Tab, '\t'));
    CHECK_EQ(r.m.doc, std::string("tôi được "));
    CHECK(r.m.pre.empty());
    CHECK(r.m.cands.empty());
    CHECK_EQ(r.last(), req({"predict", "tôi được ", "", "", "0"}));  // next word offered
    // Next word: Tab inserts it.
    r.answer(P("không", ""));
    CHECK(press(r.s, r.m, ks::Tab, '\t'));
    CHECK_EQ(r.m.doc, std::string("tôi được không "));

    // Click on an alternate (Fcitx5 CandidateWord::select / IBus candidate_clicked).
    Rig c(with(false, false, false, true), DisplayMode::Surrounding);
    type(c.s, c.m, "dduw");
    c.answer(P("được", "đư", {"đường", "đưa"}));
    CHECK(c.s.chooseHint(1, c.m));
    CHECK_EQ(c.m.doc, std::string("đường "));
    CHECK(!c.s.chooseHint(0, c.m));  // nothing shown any more

    // Any other key dismisses and goes on; digits are typed, never select.
    Rig k(with(false, false, false, true));
    type(k.s, k.m, "dduw");
    k.answer(P("được", "đư", {"đường"}));
    type(k.s, k.m, "1");
    CHECK_EQ(k.m.doc, std::string("đư1"));
    CHECK(!k.s.hint());
    CHECK(k.m.cands.empty());

    // Esc: hidden, not offered again while the word starts with what was declined.
    Rig e(with(false, false, false, true));
    type(e.s, e.m, "dduw");
    e.answer(P("được", "đư"));
    CHECK(press(e.s, e.m, ks::Escape, 0x1b));
    size_t n = e.reqs.size();
    type(e.s, e.m, "ow");
    CHECK_EQ(e.reqs.size(), n);
    type(e.s, e.m, " ddu");  // next word: offered again
    CHECK_EQ(e.last(), req({"predict", "đươ đu", "đu", "ddu", "0"}));

    // Typing on before the answer: stale (generation moved on).
    Rig g(with(false, false, false, true));
    type(g.s, g.m, "dduw");
    uint64_t gen = g.reqs.back().gen;
    type(g.s, g.m, "o");
    g.s.deliverHint(gen, P("được", "đư"), g.m);
    CHECK(!g.s.hint());
    // The word changed under the answer: not shown.
    Rig w(with(false, false, false, true));
    type(w.s, w.m, "dduw");
    w.answer(P("đang", "đa"));
    CHECK(!w.s.hint());

    // Other caret suggestions win: the next word is only a fallback of the typo request.
    Settings both = with(false, false, false, true);
    both.typoHints = true;
    Rig o(both);
    type(o.s, o.m, "anh tpoi ");
    CHECK_EQ(o.last(), req({"typo", "anh tpoi ", "tpoi", " ", "tpoi", "1010000110"}));
    CHECK_EQ(o.reqs.back().fallback, req({"predict", "anh tpoi ", "", "", "0"}));
    CHECK_EQ(o.reqs.back().fallbackDelayMs, kPredictIdleMs);
    CaretSuggestion typo;
    typo.kind = Kind::Typo;
    typo.display = "tôi";
    typo.replace = "tpoi ";
    typo.insert = "tôi ";
    o.answer(typo);
    o.s.deliverHint(o.reqs.back().gen, P("ơi", ""), o.m);  // late prediction: ignored
    CHECK(o.s.hint() && o.s.hint()->kind == Kind::Typo);
    // …and replace a prediction already shown.
    Rig o2(both);
    type(o2.s, o2.m, "camr ");
    o2.answer(P("ơn", ""));
    CHECK(!o2.m.cands.empty());
    CaretSuggestion date;
    date.kind = Kind::Date;
    date.display = "x";
    date.replace = "cảm ";
    date.insert = "x ";
    o2.answer(date);
    CHECK(o2.s.hint()->kind == Kind::Date);
    CHECK(o2.m.cands.empty());
    CHECK(!o2.m.shown.empty());

    // Blind field (Chrome): completion in the preedit; the text before what was typed since the
    // focus is unknown and NOT marked for prediction (the first word is taken to stand alone).
    Rig b(with(false, false, false, true), DisplayMode::Preedit, false);
    type(b.s, b.m, "camr ");
    CHECK_EQ(b.last(), req({"predict", "cảm ", "", "", "0"}));
    type(b.s, b.m, "xin ch");
    CHECK_EQ(b.last(), req({"predict", "cảm xin ch", "ch", "ch", "0"}));
    CHECK_EQ(b.s.typedBefore(), std::string("\xef\xbf\xbc") + "cảm xin ");  // other hints: still marked
    // English context: the engine's previous-word flag goes along.
    Rig en(with(false, false, false, true));
    type(en.s, en.m, "you beca");
    CHECK_EQ(en.last(), req({"predict", "you beca", "beca", "beca", "1"}));

    // Off / no helper / terminal / code editor / password / English mode / distrusted.
    Rig off(with(false, false, false, false));
    type(off.s, off.m, "tooi dduw cam ");
    CHECK(off.reqs.empty());
    CHECK_EQ(off.s.typedBefore(), std::string("\xef\xbf\xbc"));  // nothing tracked at all
    Rig term(with(false, false, false, true), DisplayMode::Direct, false);
    type(term.s, term.m, "git commit ");
    CHECK(term.reqs.empty());
    Rig code(with(false, false, false, true));
    code.s.setAutoTextAllowed(false);
    type(code.s, code.m, "return valu");
    CHECK(code.reqs.empty());
    Rig pw(with(false, false, false, true));
    pw.s.setPassthrough(true, pw.m);
    type(pw.s, pw.m, "secret word");
    CHECK(pw.reqs.empty());
    Rig eng(with(false, false, false, true));
    eng.s.setVietnamese(false, eng.m);
    type(eng.s, eng.m, "hello wor");
    CHECK(eng.reqs.empty());
    Rig sur(with(false, false, false, true), DisplayMode::Surrounding, false);
    type(sur.s, sur.m, "dduw");
    CHECK(sur.reqs.empty());  // Surrounding without edits: cannot replace the word on screen
}

// MARK: - real helper (viettelex-text-tool --serve)

void testHelperEndToEnd() {
    const char *tool = std::getenv("VIETTELEX_TEXT_TOOL");
    if (!tool || !*tool) {
        std::printf("(skip helper: VIETTELEX_TEXT_TOOL unset)\n");
        return;
    }
    std::mutex mu;
    std::deque<std::function<void()>> mainQueue;
    HintService svc([&](std::function<void()> f) {
        std::lock_guard<std::mutex> l(mu);
        mainQueue.push_back(std::move(f));
    });
    std::string ans;
    CHECK(svc.query(req({"predict", "cảm ", "", "", "0"}), ans));
    CHECK_EQ(ans.rfind("predict\tơn\t\tơn ", 0), size_t(0));
    CHECK(svc.query(req({"predict", "tôi đư", "đư", "dduw", "0"}), ans));
    CaretSuggestion c;
    CHECK(hints::parseAnswer(ans, c));
    CHECK(c.kind == Kind::Predict && c.replace == "đư");
    bool hasDuoc = false;
    for (auto &w : c.candidates()) hasDuoc |= w == "được";
    CHECK(hasDuoc);
    CHECK(svc.query(req({"predict", "abc.đư", "đư", "dduw", "0"}), ans));
    CHECK_EQ(ans, std::string("-"));

    auto drain = [&](int ms) {
        auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
        while (std::chrono::steady_clock::now() < until) {
            std::function<void()> f;
            {
                std::lock_guard<std::mutex> l(mu);
                if (!mainQueue.empty()) {
                    f = std::move(mainQueue.front());
                    mainQueue.pop_front();
                }
            }
            if (f) f();
            else std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    };
    // Session → HintService (300 ms idle) → helper → candidates → Tab.
    Session s;
    Mock m;
    s.applySettings(with(false, false, false, true));
    s.setSurroundingEdits(true);
    s.setHintSink([&](const HintRequest &r) {
        uint64_t gen = r.gen;
        svc.submit(r, [&, gen](bool ok, const CaretSuggestion &cs) {
            if (ok) s.deliverHint(gen, cs, m);
        });
    });
    type(s, m, "camr ");
    drain(150);
    CHECK(!s.hint());  // still inside the 300 ms pause
    drain(1500);
    CHECK(s.hint() != nullptr);
    CHECK(!m.cands.empty() && m.cands[0] == "ơn");
    CHECK(press(s, m, ks::Tab, '\t'));
    CHECK_EQ(m.doc, std::string("cảm ơn "));
    // The typo request falls back to the prediction when there is no typo fix.
    std::atomic<int> got{0};
    CaretSuggestion fb;
    auto gen = std::make_shared<std::atomic<uint64_t>>(7);
    HintRequest r;
    r.line = req({"number", "hello "});  // no answer
    r.fallback = req({"predict", "xin ", "", "", "0"});
    r.fallbackDelayMs = 100;
    r.gen = 7;
    r.liveGen = gen;
    svc.submit(r, [&](bool, const CaretSuggestion &cs) {
        fb = cs;
        ++got;
    });
    drain(1500);
    CHECK_EQ(got.load(), 1);
    CHECK(fb.kind == Kind::Predict);
}

}  // namespace

int main() {
    testSettings();
    testExcludedApps();
    testDoubleSpaceRule();
    testSmartQuoteRule();
    testDashRule();
    testCapitalizationRule();
    testPredictionGates();
    testDoubleSpaceSession();
    testCapitalizeSession();
    testSmartPunctuationSession();
    testPredictionSession();
    testHelperEndToEnd();
    std::printf("auto text tests: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
