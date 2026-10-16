// word_prediction_tests — gợi ý từ (word_prediction.h) against the macOS implementation:
// the golden fixture fixtures/word-prediction.tsv is produced by the Swift code itself
// (app/tools/gen_prediction_golden.sh), plus the macOS WordPredictionTests cases that are
// pure logic (request shape, completions, muting), the Windows setting, the IPC answer and
// timing / memory numbers (printed as "PREDICT ...").
#include <chrono>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <vector>

#include <viettelex/add_tones.hpp>
#include <viettelex/text_tools.hpp>

#include "caret_hint_ipc.h"
#include "test.h"
#include "typo_fix.h"
#include "word_prediction.h"

#if defined(__APPLE__)
#include <malloc/malloc.h>
#endif

using namespace vtx;
using namespace vtx::app;

namespace {

std::vector<uint8_t> readFile(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

struct Data {
    std::vector<uint8_t> vl, el, lm;
    addtones::LanguageData d;
    bool ok = false;
    Data() {
        vl = readFile(VTX_KB_RESOURCES "/vnlexicon.bin");
        el = readFile(VTX_KB_RESOURCES "/enlexicon.bin");
        lm = readFile(VTX_KB_RESOURCES "/vnlm.bin");
        ok = d.load(vl.data(), vl.size(), el.data(), el.size(), lm.data(), lm.size());
    }
};
const Data& data() {
    static const Data d;
    return d;
}

std::u32string U(const std::string& s) { return text::fromUtf8(s); }
std::string S(const std::u32string& s) { return text::toUtf8(s); }
std::string S(const std::optional<std::u32string>& s) { return s ? S(*s) : std::string("-"); }

std::string join(const std::vector<std::u32string>& v) {
    std::string out;
    for (size_t i = 0; i < v.size(); ++i) out += (i ? "|" : "") + S(v[i]);
    return out;
}

const predict::Model& model() {
    static const predict::Model m(data().d);
    return m;
}

std::string cands(const std::string& before, const std::string& typed = "", const std::string& raw = "",
                  bool english = false) {
    auto r = predict::request(U(before), U(typed), english);
    return r ? join(model().candidates(*r, U(raw))) : std::string();
}

std::vector<std::string> split(const std::string& s, char sep) {
    std::vector<std::string> out;
    size_t a = 0;
    while (true) {
        const size_t b = s.find(sep, a);
        out.push_back(s.substr(a, b == std::string::npos ? std::string::npos : b - a));
        if (b == std::string::npos) break;
        a = b + 1;
    }
    return out;
}

std::string unescapeNl(std::string s) {
    for (size_t p; (p = s.find("\\n")) != std::string::npos;) s.replace(p, 2, "\n");
    return s;
}

#if defined(__APPLE__)
// Heap bytes in use (all malloc zones): what the model adds on top of the data files,
// which VietTelex.exe reads in place from its image-mapped resources.
long long footprint() {
    malloc_statistics_t st = {};
    malloc_zone_statistics(nullptr, &st);
    return static_cast<long long>(st.size_in_use);
}
#else
long long footprint() { return 0; }
#endif

}  // namespace

// ---------------------------------------------------------------- the Windows setting

TEST(prediction_setting_resolution) {
    CHECK(!predict::resolveHwkbPrediction(false, 0));  // never toggled: Windows default OFF
    CHECK(!predict::resolveHwkbPrediction(false, 1));
    CHECK(predict::resolveHwkbPrediction(true, 1));
    CHECK(!predict::resolveHwkbPrediction(true, 0));
    CHECK(predict::resolveHwkbPrediction(true, 2));
    CHECK(std::wstring(predict::kHwkbPredictionKey) == L"Software\\Microsoft\\Input\\Settings");
    CHECK(std::wstring(predict::kHwkbPredictionValue) == L"EnableHwkbTextPrediction");
}

// ---------------------------------------------------------------- PredictionLogic (macOS WordPredictionTests)

TEST(prediction_request_while_composing) {
    auto r = predict::request(U("xin chào bạn đư"), U("đư"), false);
    CHECK(r.has_value());
    if (r) {
        CHECK_EQ(S(r->typed), std::string("đư"));
        CHECK_EQ(S(r->prev), std::string("bạn"));
        CHECK_EQ(S(r->prev2), std::string("chào"));
    }
    r = predict::request(U("đư"), U("đư"), false);
    CHECK(r && !r->prev && !r->prev2);
    CHECK(!predict::request(U("abc.đư"), U("đư"), false));   // not standing alone
    CHECK(!predict::request(U("chào đ"), U("đ"), false));     // 1 letter: nothing
    CHECK(!predict::request(U("chào đư"), U("đươ"), false));  // screen differs
    CHECK(!predict::request(U("a1"), U("a1"), false));
    // NFD on screen, NFC typed (some hosts): same request
    CHECK(predict::request(text::nfd(U("tôi đư")), U("đư"), false).has_value());
}

TEST(prediction_request_next_word) {
    auto r = predict::request(U("cảm "), U(""), false);
    CHECK(r && S(r->prev) == "cảm" && !r->prev2);
    r = predict::request(U("Tôi Đang "), U(""), false);
    CHECK(r && S(r->prev) == "đang" && S(r->prev2) == "tôi");
    r = predict::request(U("xin chào, bạn "), U(""), false);
    CHECK(r && S(r->prev) == "bạn" && !r->prev2);  // the comma cuts the context
    r = predict::request(U("dòng một\nđi "), U(""), false);
    CHECK(r && !r->prev2);
    CHECK(!predict::request(U("hai  "), U(""), false));
    CHECK(!predict::request(U("xong. "), U(""), false));
    CHECK(!predict::request(U(" "), U(""), false));
    CHECK(!predict::request(U(""), U(""), false));
    CHECK(!predict::request(U("a.b "), U(""), false));
}

TEST(prediction_completions_and_muting) {
    const std::vector<std::u32string> ranked = {U("đư"), U("được"), U("Được"), U("đường"), U("đưa"), U("đứng")};
    CHECK_EQ(join(predict::completions(ranked, U("đư"))), std::string("được|đường|đưa"));
    CHECK(predict::muted(U("đươ"), U("đư")));
    CHECK(predict::muted(U("Đư"), U("đư")));
    CHECK(!predict::muted(U("đa"), U("đư")));
    CHECK(!predict::muted(U(""), U("đư")));
    CHECK(!predict::muted(U("đư"), U("")));
    CHECK(!predict::muted(U("đ"), U("đư")));
}

TEST(prediction_display_case) {
    CHECK_EQ(S(predict::displayCase(U("nội"), U("hà"))), std::string("Nội"));
    CHECK_EQ(S(predict::displayCase(U("nội"), std::nullopt)), std::string("nội"));
    CHECK_EQ(S(predict::displayCase(U("iphone"), std::nullopt)), std::string("iPhone"));
    CHECK_EQ(S(predict::suggestionCase(U("được"), U("Đư"))), std::string("Được"));
    CHECK_EQ(S(predict::suggestionCase(U("người"), U("NG"))), std::string("NGƯỜI"));
    CHECK_EQ(S(predict::suggestionCase(U("iPhone"), U("Ip"))), std::string("iPhone"));
    CHECK_EQ(S(predict::suggestionCase(U("được"), U("đư"))), std::string("được"));
}

// ---------------------------------------------------------------- ranking = macOS

TEST(prediction_golden_matches_macos) {
    CHECK(data().ok);
    std::ifstream f(VTX_APP_FIXTURES "/word-prediction.tsv");
    CHECK(f.good());
    std::string line;
    int n = 0, bad = 0;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        const auto c = split(line, '\t');
        if (c.size() != 5) {
            std::printf("  bad fixture line: %s\n", line.c_str());
            ++bad;
            continue;
        }
        ++n;
        const std::string got = cands(unescapeNl(c[0]), c[1], c[2], c[3] == "1");
        if (got != c[4]) {
            std::printf("  golden '%s' typed '%s': got [%s] want [%s]\n", c[0].c_str(), c[1].c_str(), got.c_str(),
                        c[4].c_str());
            ++bad;
        }
    }
    CHECK(n >= 60);
    CHECK_EQ(bad, 0);
}

TEST(prediction_macos_assertions) {
    // AppTests/WordPredictionTests.swift, the data-dependent assertions.
    CHECK(!cands("cảm ơn ").empty());  // two context words with a trigram row
    CHECK(!cands("xin chào ").empty());
    CHECK(split(cands("hôm nay "), '|').size() <= static_cast<size_t>(predict::kRankDepth));
    CHECK_EQ(cands("hello world ", "", "", true), std::string());  // English: no next-word data
    CHECK_EQ(cands("zzqx zzqy "), std::string());
    for (const auto& w : split(cands("thành phố hồ "), '|')) CHECK(w != "chí");  // "Chí" after "hồ"
    CHECK(split(cands("thành phố hồ "), '|')[0] == "Chí");
    CHECK(cands("tôi đư", "đư", "dduw").find("được") != std::string::npos);
    CHECK(split(cands("xin ch", "ch", "ch"), '|')[0] == "chào");
    CHECK_EQ(cands("cảm ơ", "ơ", "ow"), std::string());
    CHECK(cands("my keyb", "keyb", "keyb").find("keyboard") != std::string::npos);
    CHECK(cands("this is beca", "beca", "beca", true).find("because") != std::string::npos);
    for (const auto& w : split(cands("thí", "thí", "this", true), '|'))
        CHECK(w.rfind("this", 0) == 0 && w.size() > 4);
    for (const char* t : {"đị", "đi", "fu", "sh", "vc"})
        for (const auto& w : split(cands(t, t, t), '|')) CHECK(w.empty() || !predict::isSensitive(U(w)));
}

// Phil 16/10/2026: "Tên " -> "gọi" was a one-word bigram guess. Next word only with two
// context words AND a trigram row for that pair — no bigram fallback.
TEST(prediction_next_word_needs_two_word_trigram) {
    CHECK_EQ(cands("Tên "), std::string());
    CHECK_EQ(cands("cảm "), std::string());
    CHECK_EQ(cands("xin "), std::string());
    CHECK_EQ(cands("xong, tên "), std::string());  // the comma cuts the context
    CHECK_EQ(cands("zzqx tên "), std::string());    // a pair without a trigram row
    CHECK(!cands("cảm ơn ").empty());
    predict::Request r;
    r.prev = U("tên");
    CHECK(!predict::wantsNextWord(r));
    r.prev2 = U("họ");
    CHECK(predict::wantsNextWord(r));
    r.english = true;
    CHECK(!predict::wantsNextWord(r));
    CHECK(model().nextWords(U("tên"), std::nullopt).empty());
}

TEST(prediction_seed_matches_swift) {
    // seed_unigrams.inc is generated from SeedData.swift: spot-check it is not stale.
    std::ifstream f(VTX_KB_RESOURCES "/../SeedData.swift");
    std::stringstream ss;
    ss << f.rdbuf();
    const std::string sw = ss.str();
    const size_t a = sw.find("static var unigrams"), b = sw.find("] }", a);
    CHECK(a != std::string::npos && b != std::string::npos);
    int n = 0, bad = 0;
    for (size_t p = sw.find('"', a); p != std::string::npos && p < b; p = sw.find('"', p)) {
        const size_t q = sw.find('"', p + 1);
        const std::string w = sw.substr(p + 1, q - p - 1);
        const size_t colon = sw.find(':', q);
        const int c = std::atoi(sw.c_str() + colon + 1);
        if (predict::seedCount(w) != c) ++bad;
        ++n;
        p = sw.find_first_of(",]", colon);
    }
    CHECK(n > 800);
    CHECK_EQ(bad, 0);
    CHECK_EQ(predict::seedCount("zzzz"), 0);
}

// ---------------------------------------------------------------- the app's answer to the TIP

TEST(prediction_ipc_answer) {
    CHECK(data().ok);
    HintJobs jobs(&data().d);
    CHECK(!jobs.predictionLoaded());  // nothing built before the first Predict job
    HintMessage m;
    m.request = 7;
    m.job = static_cast<uint32_t>(HintJob::Predict);
    m.text = packPredictText(u"xin ch", u"ch", u"ch");
    std::vector<uint8_t> b = packHintMessage(m);
    HintMessage back;
    CHECK(unpackHintMessage(b.data(), b.size(), back));
    const std::u16string a = jobs.answer(back);
    CHECK(jobs.predictionLoaded());
    CHECK(a == u"chào");  // one suggestion: the top-ranked word only
    m.text = packPredictText(u"cảm ", u"", u"");
    CHECK(jobs.answer(m).empty());  // one context word: no next-word guess
    m.text = packPredictText(u"thành phố hồ ", u"", u"");
    CHECK(jobs.answer(m) == u"Chí");
    m.flags = kPredictEnglish;  // English context: no next-word data
    CHECK(jobs.answer(m).empty());
    m.flags = 0;
    m.text = u"no separators";
    CHECK(jobs.answer(m).empty());
    std::u16string be, ty, raw;
    CHECK(unpackPredictText(packPredictText(u"a\x1f b", u"x", u"y"), be, ty, raw));
    CHECK(be == u"a  b" && ty == u"x" && raw == u"y");
    CHECK(!unpackPredictText(u"a\x1f" u"b", be, ty, raw));
}

// ---------------------------------------------------------------- numbers

TEST(prediction_perf_and_memory) {
    CHECK(data().ok);
    // The language data itself (shared with typo fixes / Thêm dấu, often loaded already):
    // the files are read in place; only the readers' indexes are heap.
    const long long d0 = footprint();
    {
        addtones::LanguageData fresh;
        CHECK(fresh.load(data().vl.data(), data().vl.size(), data().el.data(), data().el.size(), data().lm.data(),
                         data().lm.size()));
        std::printf("PREDICT MEM language data indexes (shared with typo/tones) %+.1f KB\n", (footprint() - d0) / 1024.0);
    }
    const long long m0 = footprint();
    predict::Model m(data().d);
    const long long m1 = footprint();
    struct Q {
        const char *before, *typed, *raw;
    };
    const Q qs[] = {{"cảm ơn ", "", ""},     {"xin chào ", "", ""},     {"tôi đang ", "", ""}, {"hôm nay ", "", ""},
                    {"đi học ", "", ""},     {"không có ", "", ""},     {"anh ấy ", "", ""},   {"chúng ta ", "", ""},
                    {"nhà của ", "", ""},    {"tôi và ", "", ""},           {"tôi đư", "đư", "dduw"}, {"xin ch", "ch", "ch"},
                    {"ng", "ng", "ng"},      {"anh th", "th", "th"},    {"my keyb", "keyb", "keyb"},
                    {"khô", "khô", "khoo"}};
    std::vector<predict::Request> reqs;
    std::vector<std::u32string> raws;
    for (const Q& q : qs) {
        if (auto r = predict::request(U(q.before), U(q.typed), false)) {
            reqs.push_back(*r);
            raws.push_back(U(q.raw));
        }
    }
    for (size_t i = 0; i < reqs.size(); ++i) m.candidates(reqs[i], raws[i]);  // warm
    const long long m2 = footprint();
    const int rounds = 50;
    double worst = 0;
    const auto t0 = std::chrono::steady_clock::now();
    for (int k = 0; k < rounds; ++k) {
        for (size_t i = 0; i < reqs.size(); ++i) {
            const auto a = std::chrono::steady_clock::now();
            m.candidates(reqs[i], raws[i]);
            const double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - a).count();
            if (us > worst) worst = us;
        }
    }
    const double avg = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count() /
                       (rounds * static_cast<double>(reqs.size()));
    std::printf("PREDICT per-request avg %.0f us, worst %.0f us (%d requests)\n", avg, worst,
                rounds * static_cast<int>(reqs.size()));
    std::printf("PREDICT MEM model build %+.1f KB, first queries %+.1f KB (heap in use; data files excluded)\n",
                (m1 - m0) / 1024.0, (m2 - m1) / 1024.0);
    CHECK(avg < 3000);
}
