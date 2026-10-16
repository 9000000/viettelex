// caret_hints_tests — the pure logic of the caret hints (caret_hints.h), mirroring macOS
// AppTests/CaretSuggestionsTests.swift + CaretHintTests.swift + MathHintTests.swift and the
// shared fixtures math-results.txt / number-chips.txt (same results as iOS/Android/macOS).
// The typo-fix lexicon part (and its precision eval) lives in the app tests (typo_fix.h).
#include <cstdio>
#include <fstream>
#include <sstream>

#include "caret_hint_ipc.h"
#include "caret_hints.h"
#include "fake_document.h"
#include "session.h"
#include "settings.h"
#include "test.h"

using namespace vtx;
using namespace vtx::hints;

namespace {

std::u32string U(const char* s) { return toU32(utf8ToUtf16(s)); }
std::string S(const std::u32string& s) { return utf16ToUtf8(toU16(s)); }
std::string S(const std::u16string& s) { return utf16ToUtf8(s); }
std::string S(const std::optional<std::u32string>& s) { return s ? S(*s) : std::string("-"); }

std::vector<std::string> fixtureLines(const char* name) {
    std::vector<std::string> out;
    std::ifstream f(std::string(VTX_FIXTURES) + "/" + name);
    std::string line;
    while (std::getline(f, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        out.push_back(line);
    }
    return out;
}

std::vector<std::string> split(const std::string& s) {
    std::vector<std::string> p;
    size_t a = 0;
    while (true) {
        size_t b = s.find('|', a);
        p.push_back(s.substr(a, b == std::string::npos ? std::string::npos : b - a));
        if (b == std::string::npos) break;
        a = b + 1;
    }
    return p;
}

std::string unmark(std::string s) {  // "␣" = one space in the fixtures
    const std::string mark = "\xE2\x90\xA3";
    for (size_t i; (i = s.find(mark)) != std::string::npos;) s.replace(i, mark.size(), " ");
    return s;
}

bool englishForTest(const std::u32string& w) { return opensEnglishRun(w); }

const LocalTime kNow{2026, 9, 28, 21, 35};  // 28/09/2026 21:35 (a Monday)

}  // namespace

// ---------------------------------------------------------------- shared fixtures

TEST(hints_math_results_fixture) {
    const auto lines = fixtureLines("math-results.txt");
    CHECK(lines.size() > 80);
    int n = 0;
    for (const std::string& l : lines) {
        const auto p = split(l);
        if (p.size() != 3) continue;
        const std::u32string in = U(unmark(p[1]).c_str());
        const std::string got = p[0] == "eval" ? S(mathResult(in)) : S(mathChip(in));
        if (got != p[2]) std::printf("  math %s|%s: got [%s] want [%s]\n", p[0].c_str(), p[1].c_str(), got.c_str(), p[2].c_str());
        CHECK_EQ(got, p[2]);
        ++n;
    }
    CHECK(n > 80);
}

TEST(hints_number_chips_fixture) {
    const auto lines = fixtureLines("number-chips.txt");
    CHECK(lines.size() > 100);
    for (const std::string& l : lines) {
        const auto p = split(l);
        if (p[0] == "spell" || p[0] == "spellLe") {
            CHECK_EQ(S(spellNumber(U(p[1].c_str()), p[0] == "spellLe")), p[2]);
        } else if (p[0] == "chip") {
            const auto c = numberChip(U(unmark(p[1]).c_str()));
            if (p.size() == 3) {
                if (c) std::printf("  chip %s: unexpected [%s]\n", p[1].c_str(), S(c->display).c_str());
                CHECK(!c);
            } else {
                CHECK(c.has_value());
                if (!c) continue;
                CHECK_EQ(S(c->display), unmark(p[2]));
                CHECK_EQ(S(c->replace), unmark(p[3]));
                CHECK_EQ(S(c->insert), unmark(p[4]));
            }
        }
    }
}

// ---------------------------------------------------------------- math / money (CaretHintTests)

TEST(hints_math_label_and_chip) {
    CHECK_EQ(S(mathLabel(U("36"))), std::string("= 36"));
    CHECK_EQ(S(mathChip(U("125 x (4 + 5.5) ="))), std::string("1187.5"));
    CHECK_EQ(S(mathChip(U("200+10%="))), std::string("220"));
    CHECK(!mathChip(U("12*3")));
}

TEST(hints_money_chip_only_money_formats) {
    auto a = moneyChip(U("giá 1tr2 "));
    CHECK(a.has_value());
    if (a) {
        CHECK(a->kind == Kind::Number);
        CHECK_EQ(S(a->display), std::string("1.200.000 ₫"));
        CHECK_EQ(S(a->replace), std::string("1tr2 "));
        CHECK_EQ(S(a->insert), std::string("1.200.000 ₫ "));
    }
    CHECK(moneyChip(U("nợ 2 tỷ ")).has_value());
    CHECK(moneyChip(U("50k ")).has_value());
    CHECK(!moneyChip(U("giá 1250000 ")));   // words, not money: not on Windows/macOS
    CHECK(!moneyChip(U("giá 1tr2")));       // needs the space just typed
    CHECK(!moneyChip(U("giá 1.250.000đ ")));
    CHECK(isMoneyFormat(U("-50.000 ₫")) && !isMoneyFormat(U("năm")));
}

// ---------------------------------------------------------------- keys (only Tab; Enter for math)

TEST(hints_key_actions) {
    for (Kind k : {Kind::Typo, Kind::Tones, Kind::Date, Kind::Number}) {
        CHECK(action(k, kVkTab, true) == KeyAction::Accept);
        CHECK(action(k, kVkReturn, true) == KeyAction::DismissPass);
        CHECK(action(k, kVkEscape, true) == KeyAction::DismissConsume);
        CHECK(action(k, 0x20, true) == KeyAction::DismissPass);
        CHECK(action(k, '1', true) == KeyAction::DismissPass);  // digits never pick
    }
    CHECK(action(Kind::Math, kVkReturn, true) == KeyAction::Accept);
    CHECK(action(Kind::Math, kVkTab, false) == KeyAction::DismissPass);    // Shift+Tab etc.
    CHECK(action(Kind::Math, kVkEscape, false) == KeyAction::DismissPass);
}

// ---------------------------------------------------------------- 3. typo gate (CaretSuggestionsTests)

TEST(hints_typo_gate_only_invalid_letter_words_at_boundary) {
    CHECK(typoWorthChecking(U' ', U("tpoi"), U("tpoi")));
    CHECK(typoWorthChecking(U',', U("tpoi"), U("tpoi")));
    CHECK(!typoWorthChecking(U'.', U("tpoi"), U("tpoi")));   // domains, times
    CHECK(!typoWorthChecking(U'\'', U("tpoi"), U("tpoi")));
    CHECK(!typoWorthChecking(U'\n', U("tpoi"), U("tpoi")));  // Enter may have sent it
    CHECK(!typoWorthChecking(U' ', U("tooi"), U("tôi")));    // valid syllable
    CHECK(!typoWorthChecking(U' ', U("kp"), U("kp")));       // too short
    CHECK(!typoWorthChecking(U' ', U("tp1i"), U("tp1i")));   // digit
    CHECK(!typoWorthChecking(U' ', U("tpoi"), U("(tpoi")));  // glued symbol
}

TEST(hints_typo_suggestion_keeps_boundary_and_case) {
    auto t = typoSuggestion(U("anh tpoi,"), U("tpoi"), U',', U("tpoi"), U("tôi"));
    CHECK(t.has_value());
    if (t) CHECK(*t == (Suggestion{Kind::Typo, u"tôi", u"tpoi,", u"tôi,", {}}));
    CHECK(!typoSuggestion(U("anh xtpoi "), U("tpoi"), U' ', U("tpoi"), U("tôi")));
    CHECK(!typoSuggestion(U("anh tpoi"), U("tpoi"), U' ', U("tpoi"), U("tôi")));
    CHECK(typoSuggestion(U("Xong. Tpoi "), U("Tpoi"), U' ', U("Tpoi"), U("Tôi")).has_value());
    CHECK(typoSuggestion(U("Tpoi "), U("Tpoi"), U' ', U("Tpoi"), U("Tôi")).has_value());
    CHECK(!typoSuggestion(U("gặp Tpoi "), U("Tpoi"), U' ', U("Tpoi"), U("Tôi")));  // a name mid-sentence
    CHECK(!typoSuggestion(U("anh tpoi "), U("tpoi"), U' ', U("tpoi"), U("tpoi")));  // no change
}

TEST(hints_rejected_words_case_insensitive_and_capped) {
    Rejected r(3);
    CHECK(r.add(U("Tpoi")));
    CHECK(!r.add(U("tpoi")));
    CHECK(r.contains(U("TPOI")));
    r.add(U("a1"));
    r.add(U("a2"));
    r.add(U("a3"));
    CHECK(!r.contains(U("tpoi")));  // oldest dropped
    CHECK(r.size() == 3);
}

// ---------------------------------------------------------------- 4. tones

namespace {
std::vector<ToneTrigger> feed(ToneTracker& t, const char* text) {
    // Key stream: each boundary reports the chunk committed right before it.
    std::vector<ToneTrigger> out;
    std::u32string chunk;
    for (char32_t ch : U(text)) {
        if (isLetter(ch) || isDigit(ch)) {
            chunk.push_back(ch);
            continue;
        }
        out.push_back(t.feed(chunk, ch));
        if (isWhitespace(ch)) chunk.clear();
        else chunk.push_back(ch);
    }
    return out;
}
using TT = ToneTrigger;
}  // namespace

TEST(hints_tone_tracker_triggers) {
    ToneTracker t;
    CHECK(feed(t, "toi di hoc ") == (std::vector<TT>{TT::None, TT::None, TT::Pause}));
    CHECK(feed(t, "hom nay ") == (std::vector<TT>{TT::Pause, TT::Pause}));
    t.reset();
    CHECK(feed(t, "toi di hoc.") == (std::vector<TT>{TT::None, TT::None, TT::SentenceEnd}));
    CHECK(feed(t, " roi ") == (std::vector<TT>{TT::None, TT::None}));  // new sentence
    t.reset();
    CHECK(feed(t, "toi, di hoc ") == (std::vector<TT>{TT::None, TT::None, TT::None, TT::Pause}));
    t.reset();
    CHECK(feed(t, "tôi di hoc ") == (std::vector<TT>{TT::None, TT::None, TT::None}));  // accented
    t.reset();
    CHECK(feed(t, "the cat is ") == (std::vector<TT>{TT::None, TT::None, TT::None}));  // English
    t.reset();
    CHECK(feed(t, "toi di\nhoc ") == (std::vector<TT>{TT::None, TT::None, TT::None}));  // newline
    t.reset();
    CHECK(feed(t, "a b ") == (std::vector<TT>{TT::None, TT::None}));
}

TEST(hints_tone_run_from_screen) {
    CHECK_EQ(S(toneRun(U("toi di hoc "))), std::string("toi di hoc "));
    CHECK_EQ(S(toneRun(U("Chiều nào toi di hoc hom nay "))), std::string("toi di hoc hom nay "));
    CHECK_EQ(S(toneRun(U("Xong. toi di hoc."))), std::string("toi di hoc."));
    CHECK_EQ(S(toneRun(U("xin chao ban. toi di hoc "))), std::string("toi di hoc "));  // not the previous sentence
    CHECK_EQ(S(toneRun(U("dong 1\ntoi di hoc "))), std::string("toi di hoc "));
    CHECK(!toneRun(U("toi di ")));
    CHECK(!toneRun(U("tôi đi học ")));
    CHECK(!toneRun(U("open the file ")));
}

TEST(hints_tone_suggestion) {
    const std::u32string run = U("toi di hoc ");
    auto s = toneSuggestion(run, U("tôi đi học "));
    CHECK(s.has_value());
    if (s) CHECK(*s == (Suggestion{Kind::Tones, u"tôi đi học", u"toi di hoc ", u"tôi đi học ", {}}));
    CHECK(!toneSuggestion(run, run));         // unchanged
    CHECK(!toneSuggestion(run, U("tôi")));    // length differs
    std::u32string longRun, longOut;
    for (int i = 0; i < 20; ++i) {
        longRun += U("toi di ");
        longOut += U("tôi đi ");
    }
    auto l = toneSuggestion(longRun, longOut);
    CHECK(l && toU32(l->display).size() == 60 && l->display[0] == u'…');
}

TEST(hints_unaccented_syllables) {
    CHECK(isUnaccentedSyllable(U("hoc")));    // stop rime: only sắc/nặng
    CHECK(isUnaccentedSyllable(U("Toi,")));
    CHECK(isUnaccentedSyllable(U("TOI")));
    CHECK(!isUnaccentedSyllable(U("tOi")));
    CHECK(!isUnaccentedSyllable(U("the")));
    CHECK(!isUnaccentedSyllable(U("tôi")));
    CHECK(!isUnaccentedSyllable(U("xyzw")));
}

// ---------------------------------------------------------------- 5. date / time

TEST(hints_date_detect) {
    auto en = &englishForTest;
    CHECK(detectDate(U' ', U("hôm"), U("nay"), en) == Phrase::Today);
    CHECK(detectDate(U' ', U("Hôm"), U("qua"), en) == Phrase::Yesterday);
    CHECK(detectDate(U' ', U("ngày"), U("mai"), en) == Phrase::Tomorrow);
    CHECK(detectDate(U' ', U("bây"), U("giờ"), en) == Phrase::Now);
    CHECK(detectDate(U' ', U("you"), U("tomorrow"), en) == Phrase::Tomorrow);
    CHECK(detectDate(U' ', U("right"), U("now"), en) == Phrase::Now);
    CHECK(!detectDate(U' ', U(""), U("now"), en));        // no English context
    CHECK(!detectDate(U' ', U("gặp"), U("today"), en));
    CHECK(!detectDate(U',', U("hôm"), U("nay"), en));     // space only
    CHECK(!detectDate(U' ', U("hom"), U("nay"), en));     // unaccented
    CHECK(!detectDate(U' ', U("hôm"), U("sau"), en));
}

TEST(hints_date_format) {
    CHECK_EQ(S(formatDate(Phrase::Today, kNow)), std::string("28/09/2026"));
    CHECK_EQ(S(formatDate(Phrase::Tomorrow, kNow)), std::string("29/09/2026"));
    CHECK_EQ(S(formatDate(Phrase::Yesterday, kNow)), std::string("27/09/2026"));
    CHECK_EQ(S(formatDate(Phrase::Now, kNow)), std::string("21:35"));
    CHECK_EQ(S(formatDate(Phrase::Tomorrow, LocalTime{2026, 12, 31, 8, 5})), std::string("01/01/2027"));
    CHECK_EQ(S(formatDate(Phrase::Yesterday, LocalTime{2028, 3, 1, 8, 5})), std::string("29/02/2028"));
    CHECK_EQ(S(formatDate(Phrase::Now, LocalTime{2028, 3, 1, 8, 5})), std::string("08:05"));
}

TEST(hints_date_suggestion_replaces_phrase) {
    auto a = dateSuggestion(U("Hẹn hôm nay "), U("hôm"), U("nay"), Phrase::Today, kNow);
    CHECK(a && *a == (Suggestion{Kind::Date, u"28/09/2026", u"hôm nay ", u"28/09/2026 ", {}}));
    auto b = dateSuggestion(U("bây giờ "), U("bây"), U("giờ"), Phrase::Now, kNow);
    CHECK(b && b->insert == u"21:35 ");
    auto c = dateSuggestion(U("see you tomorrow "), U("you"), U("tomorrow"), Phrase::Tomorrow, kNow);
    CHECK(c && c->replace == u"tomorrow ");
    CHECK(!dateSuggestion(U("xhôm nay "), U("hôm"), U("nay"), Phrase::Today, kNow));  // not standing alone
    CHECK(!dateSuggestion(U("hôm nay"), U("hôm"), U("nay"), Phrase::Today, kNow));    // screen differs
}

TEST(hints_last_runs_from_screen) {
    std::u32string p, r;
    CHECK(lastRuns(U("Hẹn hôm nay "), p, r) && S(p) == "hôm" && S(r) == "nay");
    CHECK(lastRuns(U("nay "), p, r) && p.empty() && S(r) == "nay");
    CHECK(!lastRuns(U("hôm nay"), p, r));
    CHECK(!lastRuns(U("hôm nay  "), p, r));
}

// ---------------------------------------------------------------- key stream -> trigger

namespace {
Trigger typeInto(HintTracker& t, const char* keys, const Enabled& en, const Commit& atLast = {}) {
    Trigger last;
    const std::u32string k = U(keys);
    for (size_t i = 0; i < k.size(); ++i) last = t.onChar(k[i], i + 1 == k.size() ? atLast : Commit{}, en);
    return last;
}
}  // namespace

TEST(hints_tracker_triggers) {
    Enabled en;
    en.tones = true;
    HintTracker t;
    CHECK(typeInto(t, "12*3=", en).kind == TriggerKind::Math);
    t.reset();
    CHECK(typeInto(t, "gia 1tr2 ", en).kind == TriggerKind::Number);
    t.reset();
    CHECK(typeInto(t, "no 2 tyr ", en).kind == TriggerKind::Number);  // unit after the number
    t.reset();
    CHECK(typeInto(t, "hen hoom nay ", en).kind == TriggerKind::Date);
    t.reset();
    CHECK(typeInto(t, "see you tomorrow ", en).kind == TriggerKind::Date);
    t.reset();
    Trigger ty = typeInto(t, "anh tpoi ", en, Commit{U("tpoi"), U("tpoi")});
    CHECK(ty.kind == TriggerKind::Typo && S(ty.raw) == "tpoi" && ty.boundary == U' ');
    t.reset();
    Trigger p = typeInto(t, "toi di hoc ", en);
    CHECK(p.kind == TriggerKind::Tones && p.delayMs == kTonePauseMs);
    t.reset();
    Trigger se = typeInto(t, "toi di hoc.", en);
    CHECK(se.kind == TriggerKind::Tones && se.delayMs < 100);
    t.reset();
    CHECK(typeInto(t, "xin chao ", en).kind == TriggerKind::None);
}

TEST(hints_tracker_respects_switches) {
    Enabled off;
    off.math = off.number = off.typo = off.tones = off.date = false;
    CHECK(!off.any());
    HintTracker t;
    CHECK(typeInto(t, "12*3=", off).kind == TriggerKind::None);
    CHECK(typeInto(t, "50k ", off).kind == TriggerKind::None);
    CHECK(typeInto(t, "hoom nay ", off).kind == TriggerKind::None);
    CHECK(typeInto(t, "toi di hoc.", off).kind == TriggerKind::None);
    Enabled def;  // defaults: tones OFF
    CHECK(!def.tones && def.math && def.number && def.typo && def.date);
    t.reset();
    CHECK(typeInto(t, "toi di hoc.", def).kind == TriggerKind::None);
}

TEST(hints_tracker_backspace) {
    Enabled en;
    HintTracker t;
    typeInto(t, "50", en);
    t.onBackspace();
    t.onBackspace();
    CHECK(t.chunk().empty());
    CHECK(typeInto(t, "k ", en).kind == TriggerKind::None);  // the digits are gone
}

TEST(hints_worth_checking_filters) {
    CHECK(numberWorthChecking(U("1tr2"), U("")));
    CHECK(numberWorthChecking(U("tyr"), U("2")));
    CHECK(!numberWorthChecking(U("nha"), U("anh")));
    CHECK(dateWorthReading(U("hoom"), U("nay")));
    CHECK(dateWorthReading(U("ngayf"), U("mai")));
    CHECK(dateWorthReading(U("baay"), U("giowf")));
    CHECK(dateWorthReading(U("you"), U("Tomorrow")));
    CHECK(!dateWorthReading(U(""), U("now")));
    CHECK(!dateWorthReading(U("xin"), U("chao")));
}

// ---------------------------------------------------------------- the session reports the commit

TEST(hints_session_reports_committed_word) {
    for (OutputMode m : {OutputMode::Composition, OutputMode::InPlace}) {
        Settings st;
        TypingSession s;
        s.setOutputMode(m);
        SessionOptions o;
        o.engineFlags = st.engineFlags();
        o.autoRestore = st.autoRestore;
        o.shortcuts = &st.shortcuts;
        s.configure(o);
        test::FakeDocument doc;
        auto key = [&](char c) {
            KeyInput k;
            k.kind = KeyKind::Char;
            k.ch = static_cast<unsigned char>(c);
            const bool eaten = s.wantsKey(k) && s.handleKey(k, doc);
            if (!eaten) doc.appInsert(static_cast<char16_t>(c));
        };
        for (char c : std::string("tooi tpoi")) key(c);
        CHECK(s.lastCommitRaw().empty());
        key(' ');
        CHECK_EQ(S(s.lastCommitRaw()), std::string("tpoi"));
        CHECK_EQ(S(s.lastCommitText()), std::string("tpoi"));
        key('x');
        CHECK(s.lastCommitRaw().empty());
        for (char c : std::string("in,")) key(c);
        CHECK_EQ(S(s.lastCommitRaw()), std::string("xin"));
        CHECK(utf16ToUtf8(doc.text).rfind("tôi tpoi xin,", 0) == 0);
    }
}

// ---------------------------------------------------------------- where to show

TEST(hints_caret_rect_plausibility) {
    const Rect screen{0, 0, 1920, 1080};
    CHECK(plausibleCaret(Rect{100, 200, 101, 220}, screen));
    CHECK(plausibleCaret(Rect{100, 200, 100, 220}, screen));    // zero width
    CHECK(!plausibleCaret(Rect{0, 0, 0, 0}, screen));           // nothing
    CHECK(!plausibleCaret(Rect{100, 200, 900, 240}, screen));   // the whole field
    CHECK(!plausibleCaret(Rect{100, 200, 101, 800}, screen));   // absurd height
    CHECK(!plausibleCaret(Rect{3000, 200, 3001, 220}, screen)); // off screen
    CHECK(plausibleCaret(Rect{100, 200, 101, 260}, screen, 192));  // 200% scale
}

TEST(hints_popup_below_or_above_caret) {
    const Rect work{0, 0, 1920, 1040};
    long x = 0, y = 0;
    popupOrigin(Rect{100, 200, 101, 220}, 120, 30, work, x, y);
    CHECK(x == 100 && y == 224);                         // below, left edge at the caret
    popupOrigin(Rect{100, 1010, 101, 1030}, 120, 30, work, x, y);
    CHECK(x == 100 && y == 1010 - 4 - 30);               // flipped above near the bottom
    popupOrigin(Rect{1900, 200, 1901, 220}, 120, 30, work, x, y);
    CHECK(x == 1920 - 6 - 120);                          // kept inside the work area
    popupOrigin(Rect{-50, 200, -49, 220}, 120, 30, work, x, y);
    CHECK(x == 6);
}

// ---------------------------------------------------------------- IPC + settings

TEST(hints_ipc_roundtrip_and_rejects_garbage) {
    HintMessage m;
    m.request = 0x12345678;
    m.job = static_cast<uint32_t>(HintJob::Tones);
    m.flags = 0x707;
    m.text = u"toi di hoc ";
    const auto b = packHintMessage(m);
    HintMessage r;
    CHECK(unpackHintMessage(b.data(), b.size(), r));
    CHECK(r.request == m.request && r.job == m.job && r.flags == m.flags && r.text == m.text);
    CHECK(!unpackHintMessage(b.data(), b.size() - 1, r));   // odd
    CHECK(!unpackHintMessage(b.data(), 8, r));              // short
    std::vector<uint8_t> bad = b;
    bad[4] = 9;                                             // unknown job
    CHECK(!unpackHintMessage(bad.data(), bad.size(), r));
    HintMessage big;
    big.job = 1;
    big.text.assign(kHintMaxLength + 50, u'a');
    const auto bb = packHintMessage(big);                    // truncated to the cap
    CHECK(unpackHintMessage(bb.data(), bb.size(), r) && r.text.size() == kHintMaxLength);
}

TEST(hints_settings_defaults_and_snapshot) {
    Settings s;
    CHECK(s.mathResults && s.numberChips && s.typoHints && s.dateHints);
    CHECK(!s.toneHints);  // macOS: tones default OFF
    s.mathResults = false;
    s.toneHints = true;
    s.dateHints = false;
    const auto b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(!r.mathResults && r.numberChips && r.typoHints && r.toneHints && !r.dateHints);
    CHECK(r == s);
    // A snapshot from an older app (16 bools) leaves the new switches at their defaults.
    std::vector<uint8_t> old = serialize(Settings{});
    old[6] = 16;
    old[7] = 0;
    Settings o;
    CHECK(deserialize(old.data(), old.size(), o));
    CHECK(o.mathResults && !o.toneHints);
}

// ---------------------------------------------------------------- 6. word prediction (TIP side)

TEST(predict_keys_never_accept_on_enter_or_arrows) {
    CHECK(action(Kind::Predict, kVkTab, true) == KeyAction::Accept);
    CHECK(action(Kind::Predict, kVkReturn, true) == KeyAction::DismissPass);  // Enter never picks
    CHECK(action(Kind::Predict, 0x28 /* VK_DOWN */, true) == KeyAction::DismissPass);
    CHECK(action(Kind::Predict, 0x26 /* VK_UP */, true) == KeyAction::DismissPass);
    CHECK(action(Kind::Predict, kVkEscape, true) == KeyAction::DismissConsume);
    CHECK(action(Kind::Predict, kVkTab, false) == KeyAction::DismissPass);  // Shift+Tab etc.
}

TEST(predict_suggestion_from_candidates) {
    auto s = predictSuggestion(U"xin chào bạn đư", U"đư", {u"được", u"đường", u"đưa"});
    CHECK(s.has_value());
    if (s) {
        CHECK(s->kind == Kind::Predict);
        CHECK(s->display == u"được" && s->replace == u"đư" && s->insert == u"được ");
        CHECK(s->alternates == (std::vector<std::u16string>{u"đường", u"đưa"}));
        CHECK(chooseCandidate(*s, 0).insert == u"được ");
        CHECK(chooseCandidate(*s, 2).insert == u"đưa ");
        CHECK(chooseCandidate(*s, 9).insert == u"được ");  // out of range: the first
        CHECK(chooseCandidate(*s, 1).alternates.empty());
    }
    // the screen changed / the word is glued to something: nothing
    CHECK(!predictSuggestion(U"xin chào bạn đươ", U"đư", {u"được"}));
    CHECK(!predictSuggestion(U"abc.đư", U"đư", {u"được"}));
    CHECK(!predictSuggestion(U"đư", U"đư", {}));
    // next word: right after "word "
    auto n = predictSuggestion(U"cảm ", U"", {u"ơn", u"thấy"});
    CHECK(n && n->replace.empty() && n->insert == u"ơn " && n->alternates.size() == 1);
    CHECK(!predictSuggestion(U"xong. ", U"", {u"ơn"}));
    CHECK(!predictSuggestion(U"cảm", U"", {u"ơn"}));
    // at most 3 shown
    auto m = predictSuggestion(U"a ", U"", {u"1", u"2", u"3", u"4"});
    CHECK(m && m->alternates.size() == 2);
}

TEST(predict_still_valid_before_replacing) {
    auto s = predictSuggestion(U"tôi đư", U"đư", {u"được"});
    CHECK(s && hintStillValid(*s, U"tôi đư"));
    CHECK(s && !hintStillValid(*s, U"tôi đưa"));
    auto n = predictSuggestion(U"cảm ", U"", {u"ơn"});
    CHECK(n && hintStillValid(*n, U"cảm "));
    CHECK(n && !hintStillValid(*n, U"cảm  "));
    CHECK(n && !hintStillValid(*n, U"cảm"));
}

TEST(predict_muting_and_apps) {
    CHECK(predictMuted(U"đươ", U"đư"));
    CHECK(predictMuted(U"ĐƯ", U"đư"));
    CHECK(!predictMuted(U"đa", U"đư"));
    CHECK(!predictMuted(U"", U"đư"));
    CHECK(!predictMuted(U"đư", U""));
    CHECK(predictionAllowedForApp("notepad.exe"));
    CHECK(predictionAllowedForApp("winword.exe"));
    CHECK(predictionAllowedForApp("chrome.exe"));
    CHECK(!predictionAllowedForApp("code.exe"));  // code editors: Tab indents
    CHECK(!predictionAllowedForApp("devenv.exe"));
    CHECK(!predictionAllowedForApp("idea64.exe"));
    CHECK(!predictionAllowedForApp("windowsterminal.exe"));  // terminals (built-in Direct rule)
    CHECK(!predictionAllowedForApp("conhost.exe"));
}

TEST(predict_ipc_payload) {
    std::u16string b, t, r;
    CHECK(unpackPredictText(packPredictText(u"tôi đư", u"đư", u"dduw"), b, t, r));
    CHECK(b == u"tôi đư" && t == u"đư" && r == u"dduw");
    CHECK(unpackPredictText(packPredictText(u"cảm ", u"", u""), b, t, r) && t.empty() && r.empty());
    HintMessage m;
    m.request = 3;
    m.job = static_cast<uint32_t>(HintJob::Predict);
    m.flags = kPredictEnglish;
    m.text = packPredictText(u"my keyb", u"keyb", u"keyb");
    std::vector<uint8_t> bytes = packHintMessage(m);
    HintMessage back;
    CHECK(unpackHintMessage(bytes.data(), bytes.size(), back));
    CHECK(back.job == 3 && back.flags == kPredictEnglish && back.text == m.text);
    CHECK(splitCandidates(joinCandidates({u"a", u"b", u"c", u"d"})).size() == 3);
}

TEST(predict_snapshot_mirror_bit) {
    size_t n = 0;
    const BoolKey* keys = boolKeys(&n);
    CHECK(n >= 25 && n <= 32);
    CHECK_EQ(std::string(keys[24].name), std::string("systemTextPrediction"));  // appended, never reordered
    CHECK(isSystemMirror(keys[24]));
    for (size_t i = 0; i < 24; ++i) CHECK(!isSystemMirror(keys[i]));
    Settings d;
    CHECK(!d.systemTextPrediction);  // Windows default: off
    Settings s;
    s.systemTextPrediction = true;
    std::vector<uint8_t> b = serialize(s);
    Settings r;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(r.systemTextPrediction);
    b[6] = 24;  // a snapshot from before the bit: off
    b[7] = 0;
    CHECK(deserialize(b.data(), b.size(), r));
    CHECK(!r.systemTextPrediction);
}
