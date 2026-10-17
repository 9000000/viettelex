// word_prediction_tests — gợi ý từ (word_prediction.h) against the macOS implementation:
// the golden fixture fixtures/word-prediction.tsv is produced by the Swift code itself
// (app/tools/gen_prediction_golden.sh), plus the macOS WordPredictionTests cases that are
// pure logic (request shape, completions, muting), the Windows setting, the IPC answer and
// timing / memory numbers (printed as "PREDICT ...").
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <sstream>
#include <vector>

#include <viettelex/add_tones.hpp>
#include <viettelex/text_tools.hpp>

#include "caret_hint_ipc.h"
#include "caret_hints.h"
#include "test.h"
#include "typo_fix.h"
#include "learned_words.h"
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
                  bool english = false, bool filter = true, const learn::Model* learned = nullptr) {
    auto r = predict::request(U(before), U(typed), english);
    return r ? join(model().candidates(*r, U(raw), filter, learned)) : std::string();
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

// The golden `learn` column: each sentence learned word by word, the 2 previous words of the
// same sentence as context (= LearnTracker over single spaces; gen_prediction_golden.sh).
std::unique_ptr<learn::Model> learnedFrom(const std::string& spec) {
    auto m = std::make_unique<learn::Model>([](const std::string& w) { return model().knownWord(w); },
                                            1760000000000ll);
    for (const auto& part : split(spec, '|')) {
        std::string sentence = part;
        int times = 1;
        const size_t star = sentence.rfind('*');
        if (star != std::string::npos) {
            times = std::atoi(sentence.c_str() + star + 1);
            sentence.resize(star);
        }
        const auto words = split(sentence, ' ');
        for (int t = 0; t < times; ++t)
            for (size_t i = 0; i < words.size(); ++i)
                m->record(words[i], i >= 1 ? words[i - 1] : std::string(), i >= 2 ? words[i - 2] : std::string());
    }
    return m;
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
        // before \t typed \t raw \t english \t filter ("Lọc từ nhạy cảm") \t learn ("Học từ bạn
        // gõ": sentences typed, "|" between, "*N" = N times) \t candidates
        if (c.size() != 7) {
            std::printf("  bad fixture line: %s\n", line.c_str());
            ++bad;
            continue;
        }
        ++n;
        std::unique_ptr<learn::Model> lm;
        if (!c[5].empty()) lm = learnedFrom(c[5]);
        const std::string got = cands(unescapeNl(c[0]), c[1], c[2], c[3] == "1", c[4] != "0", lm.get());
        if (got != c[6]) {
            std::printf("  golden '%s' typed '%s' learn '%s': got [%s] want [%s]\n", c[0].c_str(), c[1].c_str(),
                        c[5].c_str(), got.c_str(), c[6].c_str());
            ++bad;
        }
    }
    CHECK(n >= 140);
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

// Phil 16/10/2026: "Tên " -> "gọi" was a one-word bigram guess. The static LM needs two
// context words AND a trigram row; one context word only through an iOS seed pair.
TEST(prediction_next_word_needs_two_word_trigram_or_seed) {
    CHECK_EQ(cands("Tên "), std::string());
    CHECK(split(cands("cảm "), '|')[0] == "ơn");
    CHECK(split(cands("xin "), '|')[0] == "lỗi");
    CHECK(split(cands("zzqx cảm "), '|')[0] == "ơn");   // no trigram row: the seed
    CHECK(split(cands("nguyễn "), '|')[0] == "Văn");
    CHECK(split(cands("good ", "", "", true), '|')[0] == "morning");
    CHECK_EQ(cands("anh ", "", "", true), std::string());  // English context: English seed only
    CHECK_EQ(cands("xong, tên "), std::string());  // the comma cuts the context
    CHECK_EQ(cands("zzqx tên "), std::string());    // a pair without a trigram row, no seed
    CHECK(!cands("cảm ơn ").empty());
    CHECK(split(cands("vãi "), '|')[0] == "cả");
    CHECK(split(cands("vãi ", "", "", false, false), '|')[0] == "lồn");  // filter off = iOS off
    CHECK_EQ(cands("ngon "), std::string());
    predict::Request r;
    r.prev = U("tên");
    CHECK(predict::wantsSeedNext(r));
    CHECK(!predict::wantsNextWord(r));
    r.prev2 = U("họ");
    CHECK(predict::wantsNextWord(r));
    r.english = true;
    CHECK(!predict::wantsNextWord(r));
    CHECK(model().nextWords(U("tên"), std::nullopt).empty());
}

// English in a Vietnamese context (prefersEnglish) + the space after an accepted prediction.
TEST(prediction_english_override_and_accept_space) {
    CHECK(split(cands("tôi gặp pé", "pé", "pers"), '|')[0] == "person");
    CHECK(split(cands("ưởn", "ưởn", "wron"), '|')[0] == "wrong");
    for (const char* t : {"toi", "duoc", "cam", "thin", "chan", "thanh"})
        CHECK(cands(std::string("anh ") + t, t, t).find("thank") == std::string::npos);
    CHECK(!predict::prefersEnglish(U("toi"), U("toi"), {}, -1, 255));          // < 4 keys
    CHECK(!predict::prefersEnglish(U("thin"), U("thin"), {{U("thỉnh"), 126}}, -1, 196));  // margin 70 < 80
    CHECK(predict::prefersEnglish(U("pers"), U("pé"), {{U("pết"), 8}}, -1, 168));
    CHECK(!predict::prefersEnglish(U("chan"), U("chan"), {{U("chán"), 150}}, -1, 255));    // a common syllable
    CHECK(S(hints::acceptSpaceReplacement(U'.')) == ". ");
    CHECK(S(hints::acceptSpaceReplacement(U')')) == ") ");
    CHECK(S(hints::acceptSpaceReplacement(U'/')) == "/");
    CHECK(hints::acceptSpaceReplacement(U'"').empty() && hints::acceptSpaceReplacement(U'a').empty());
}

TEST(prediction_seed_next_matches_swift) {
    // seed_next.inc and App/Sources/SeedNextData.swift come from Scripts/gen-seed-next.sh:
    // every Swift row must read back the same.
    std::ifstream f(VTX_KB_RESOURCES "/../../../App/Sources/SeedNextData.swift");
    CHECK(f.good());
    std::string line;
    bool in = false;
    int n = 0, bad = 0;
    while (std::getline(f, line)) {
        if (line.find("static let packed") != std::string::npos) { in = true; continue; }
        if (!in) continue;
        if (line.find("\"\"\"") != std::string::npos) break;
        const std::string row = line.substr(4);
        const auto w = split(row, ' ');
        std::vector<std::string> want(w.begin() + 1, w.end());
        std::string got;
        for (const auto& x : predict::seedNext(U(w[0]))) got += (got.empty() ? "" : "|") + S(x);
        std::string exp;
        for (const auto& x : want) exp += (exp.empty() ? "" : "|") + x;
        if (got != exp) {
            std::printf("  seed next '%s': got [%s] want [%s]\n", w[0].c_str(), got.c_str(), exp.c_str());
            ++bad;
        }
        ++n;
    }
    CHECK(n > 200);
    CHECK_EQ(bad, 0);
    CHECK(predict::seedNext(U("zzqx")).empty());
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
    CHECK(jobs.answer(m) == u"ơn");  // one context word: the iOS seed pair
    m.text = packPredictText(u"Tên ", u"", u"");
    CHECK(jobs.answer(m).empty());  // no seed: no one-word guess
    m.text = packPredictText(u"vãi ", u"", u"");
    CHECK(jobs.answer(m) == u"cả");  // "Lọc từ nhạy cảm" on (default)
    jobs.setFilterSensitive(false);
    CHECK(jobs.answer(m) == u"lồn");
    jobs.setFilterSensitive(true);
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

// ---------------------------------------------------------------- Học từ bạn gõ (learned_words.h)
// Same cases as macOS AppTests/LearnedWordsTests + Linux --self-test.

namespace {
std::unique_ptr<learn::Model> fresh() {
    return std::make_unique<learn::Model>([](const std::string& w) { return model().knownWord(w); }, 1760000000000ll);
}
void typeIn(learn::Model& m, const std::string& sentence, int times = 1) {
    const auto words = split(sentence, ' ');
    for (int t = 0; t < times; ++t)
        for (size_t i = 0; i < words.size(); ++i)
            m.record(words[i], i >= 1 ? words[i - 1] : std::string(), i >= 2 ? words[i - 2] : std::string());
}
}  // namespace

TEST(learned_record_semantics_match_ios) {
    auto m = fresh();
    typeIn(*m, "cảm ơn bạn");
    CHECK_EQ(m->count("ơn"), 1);
    CHECK_EQ(m->bigramCount("cảm", "ơn"), 1);
    CHECK_EQ(m->trigramCount("cảm", "ơn", "bạn"), 0);  // the pair (p2, p1) must be ≥ 2 first
    typeIn(*m, "cảm ơn bạn", 2);
    CHECK_EQ(m->trigramCount("cảm", "ơn", "bạn"), 2);
    CHECK_EQ(m->count("Bạn"), 3);  // keys are lowercase
    CHECK(learn::learnable("cơm") && learn::learnable("Phúc") && learn::learnable("heey"));
    CHECK(!learn::learnable("heeey") && !learn::learnable("a1") && !learn::learnable(""));
    CHECK(learn::learnable("abcdefghijkl") && !learn::learnable("abcdefghijklm") && !learn::learnable("e-mail"));
}

TEST(learned_ranking) {
    CHECK(data().ok);
    auto m = fresh();
    typeIn(*m, "ăn cơm", 3);
    CHECK_EQ(std::string(split(cands("ăn ", "", "", false, true, m.get()), '|')[0]), std::string("cơm"));
    auto t = fresh();
    typeIn(*t, "tên tôi");
    CHECK_EQ(cands("Tên ", "", "", false, true, t.get()), std::string());  // once: not yet
    typeIn(*t, "tên tôi");
    CHECK_EQ(cands("Tên ", "", "", false, true, t.get()), std::string("tôi"));
    auto c = fresh();
    typeIn(*c, "cảm ơn anh", 3);
    CHECK_EQ(std::string(split(cands("cảm ơn ", "", "", false, true, c.get()), '|')[0]), std::string("anh"));
    auto x = fresh();
    typeIn(*x, "thằng cặc", 4);
    CHECK_EQ(x->count("cặc"), 4);  // stored…
    CHECK(cands("thằng ", "", "", false, true, x.get()).find("cặc") == std::string::npos);  // …filtered
    CHECK_EQ(std::string(split(cands("thằng ", "", "", false, false, x.get()), '|')[0]), std::string("cặc"));
    auto u = fresh();
    typeIn(*u, "gặp xyzk", 2);
    CHECK(cands("gặp ", "", "", false, true, u.get()).find("xyzk") == std::string::npos);
    typeIn(*u, "gặp xyzk");
    CHECK(cands("gặp ", "", "", false, true, u.get()).find("xyzk") != std::string::npos);
    // An empty model = the plain seed ranking.
    auto e = fresh();
    for (const char* b : {"cảm ", "xin ", "ăn ", "cảm ơn ", "tên "}) CHECK_EQ(cands(b, "", "", false, true, e.get()), cands(b));
    CHECK_EQ(cands("tôi hi", "hi", "hi", false, true, e.get()), cands("tôi hi", "hi", "hi"));
}

TEST(learned_file_matches_swift) {
    // learned-words.bin = Swift LearnedModel after this spec (gen_prediction_golden.sh).
    const std::vector<uint8_t> bin = readFile(VTX_APP_FIXTURES "/learned-words.bin");
    CHECK(bin.size() > 36);
    auto m = fresh();
    for (const char* part : {"cảm ơn anh*3", "tên tôi là phúc*2", "ăn cơm*4", "heeey you*2", "gặp xyzk*3"}) {
        std::string s = part;
        const size_t star = s.rfind('*');
        const int times = std::atoi(s.c_str() + star + 1);
        s.resize(star);
        typeIn(*m, s, times);
    }
    CHECK(m->encode() == bin);  // byte for byte
    auto back = learn::Model::decode(bin.data(), bin.size());
    CHECK(back != nullptr);
    if (back) {
        CHECK_EQ(back->count("cơm"), 4);
        CHECK_EQ(back->trigramCount("cảm", "ơn", "anh"), 2);
        CHECK_EQ(back->wordCount(), m->wordCount());
        CHECK(back->lastDecayMs() == 1760000000000ll);
        CHECK(back->encode() == bin);
    }
}

TEST(learned_file_corruption_recovers) {
    auto m = fresh();
    typeIn(*m, "ăn cơm", 3);
    std::vector<uint8_t> b = m->encode();
    CHECK(learn::Model::decode(b.data(), b.size()) != nullptr);
    std::vector<uint8_t> flipped = b;
    flipped[flipped.size() / 2] ^= 0xFF;
    CHECK(learn::Model::decode(flipped.data(), flipped.size()) == nullptr);  // CRC
    CHECK(learn::Model::decode(b.data(), 20) == nullptr);                    // truncated
    CHECK(learn::Model::decode(nullptr, 0) == nullptr);
    const std::string junk = "garbage garbage garbage garbage garbage";
    CHECK(learn::Model::decode(reinterpret_cast<const uint8_t*>(junk.data()), junk.size()) == nullptr);
    // The empty store the Linux settings app writes for "Xoá từ đã học" (config.py).
    // 56544c32 0100 0000 + 24 zero bytes (lastDecay, counts) + CRC 3a3b26a4
    uint8_t empty[36] = {0x56, 0x54, 0x4c, 0x32, 1, 0};
    empty[32] = 0x3a;
    empty[33] = 0x3b;
    empty[34] = 0x26;
    empty[35] = 0xa4;
    auto e = learn::Model::decode(empty, sizeof empty);
    CHECK(e != nullptr && e->empty());
}

TEST(learned_prune_decay_clear) {
    auto m = fresh();
    for (int i = 0; i <= learn::kUniCap; ++i) {
        std::string w = "x";
        for (int v = i, k = 0; k < 3; ++k, v /= 26) w.push_back(static_cast<char>('a' + v % 26));
        m->record(w);
    }
    CHECK(m->wordCount() <= learn::kUniCap);  // halved: count 1 → 0
    learn::Model d(nullptr, 0);
    for (int i = 0; i < 10; ++i) d.record("cơm", "ăn");
    d.decayIfDue(6ll * 86400 * 1000);
    CHECK_EQ(d.count("cơm"), 10);
    d.decayIfDue(14ll * 86400 * 1000 + 1);
    CHECK_EQ(d.count("cơm"), 4);  // 10 × 0.7² = 4.9 → 4
    CHECK_EQ(d.bigramCount("ăn", "cơm"), 4);
    d.clear(0);
    CHECK(d.empty() && d.count("cơm") == 0 && d.changes() > 0);
}

TEST(learned_perf_and_memory) {
    // A full model (the caps: 3000 words, 6000 pairs, 3000 triples) — RAM, file size, record cost.
    std::vector<std::string> words;
    for (int i = 0; i < 5000; ++i) {
        std::string w = "w";
        for (int v = i, k = 0; k < 3; ++k, v /= 26) w.push_back(static_cast<char>('a' + v % 26));
        words.push_back(w);
    }
    const long long f0 = footprint();
    auto m = std::make_unique<learn::Model>(nullptr, 0);
    // Zipf-like text over 5000 distinct words, 8-word sentences (a heavy user: fills the caps).
    uint32_t seed = 12345;
    auto pick = [&]() {
        seed = seed * 1664525u + 1013904223u;
        const double u = (seed >> 8) / 16777216.0;
        return words[static_cast<size_t>(5000 * u * u * u) % 5000];
    };
    const auto t0 = std::chrono::steady_clock::now();
    const int n = 60000;
    std::string p1, p2;
    for (int i = 0; i < n; ++i) {
        if (i % 8 == 0) p1.clear(), p2.clear();
        const std::string w = pick();
        m->record(w, p1, p2);
        p2 = p1;
        p1 = w;
    }
    const double us = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count() / n;
    const long long f1 = footprint();
    const auto bin = m->encode();
    std::printf("LEARN record %.2f us/word; model %d words / %d pairs / %d triples; heap %+.1f KB (est %.1f KB); "
                "file %.1f KB\n",
                us, m->wordCount(), m->pairCount(), m->tripleCount(), (f1 - f0) / 1024.0, m->memoryBytes() / 1024.0,
                bin.size() / 1024.0);
    CHECK(us < 50);
    CHECK(m->wordCount() <= learn::kUniCap && m->pairCount() <= learn::kBiCap && m->tripleCount() <= learn::kTriCap);
    const auto t1 = std::chrono::steady_clock::now();
    for (int i = 0; i < 200; ++i) (void)m->nextWords(words[i % 2900], words[(i + 1) % 2800], {}, 6);
    std::printf("LEARN nextWords %.2f us\n",
                std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t1).count() / 200);
}

// ---------------------------------------------------------------- learned casing (10/2026)
// = iOS KeyboardTests/LearnedCaseTests.swift (CaseTable in UserLMTables.swift).

namespace {
// Records like the app's onLearnWork: evidence = predict::casingEvidence(word, prev1).
void typeCased(learn::Model& m, const std::string& word, const std::string& prev, int times = 1) {
    for (int t = 0; t < times; ++t) m.record(word, prev, std::string(), 1, predict::casingEvidence(U(word), U(prev)));
}
}  // namespace

TEST(learned_case_thresholds) {
    auto m = fresh();
    typeCased(*m, "SenPrints", "ty", 2);
    CHECK(m->learnedCase("senprints").empty());  // 2: not yet
    typeCased(*m, "SenPrints", "ở");
    CHECK_EQ(m->learnedCase("senprints"), std::string("SenPrints"));
    typeCased(*m, "Văn", "anh", 3);
    CHECK_EQ(m->learnedCase("văn"), std::string("Văn"));
    // sentence start (no prev) / Caps Lock / one letter / name chain: never learned
    auto s = fresh();
    typeCased(*s, "Văn", "", 6);
    typeCased(*s, "SENPRINTS", "ở", 5);
    typeCased(*s, "VĂN", "anh", 5);
    typeCased(*s, "A", "điểm", 5);
    typeCased(*s, "Nam", "Việt", 6);
    CHECK(s->cases().empty());
    CHECK(!predict::casingEvidence(U("Nam"), U("việt")) && predict::casingEvidence(U("Nam"), U("anh")));
    CHECK(!predict::casingEvidence(U("Văn"), U("")));
    // ambiguous word: lowercase history wins; consistency needed (≥ 80%)
    auto a = fresh();
    typeCased(*a, "văn", "bài", 20);
    typeCased(*a, "Văn", "anh", 3);
    CHECK(a->learnedCase("văn").empty());
    auto n = fresh();
    typeCased(*n, "Văn", "anh", 4);
    typeCased(*n, "văn", "bài");
    CHECK_EQ(n->learnedCase("văn"), std::string("Văn"));  // 4/5
    typeCased(*n, "văn", "bài");
    CHECK(n->learnedCase("văn").empty());  // 4/6
    // competing capital forms cancel
    auto c = fresh();
    typeCased(*c, "SenPrints", "ở", 3);
    typeCased(*c, "Senprints", "ở", 2);
    CHECK(c->learnedCase("senprints").empty());
    // no evidence flag: table untouched
    auto z = fresh();
    for (int i = 0; i < 5; ++i) z->record("SenPrints", "ở");
    CHECK(z->cases().empty());
    // saturation keeps the ratio
    learn::CaseTable t;
    for (int i = 0; i < 600; ++i) t.observe("VietTelex", "viettelex", 0);
    const learn::CaseStat* st = t.find("viettelex");
    CHECK(st && st->total <= learn::kCaseMaxCount && st->hits == st->total);
    CHECK(learn::caseKind("iPhone") == learn::CaseKind::Mixed && learn::caseKind("Đà") == learn::CaseKind::Mixed);
    CHECK(learn::caseKind("ĐÀ") == learn::CaseKind::Ignored && learn::caseKind("đà") == learn::CaseKind::Lower);
}

TEST(learned_case_persistence_and_clear) {
    auto m = fresh();
    typeCased(*m, "SenPrints", "ở", 3);
    typeCased(*m, "Văn", "anh", 2);
    const std::vector<uint8_t> b = m->encode();
    CHECK_EQ(static_cast<int>(b[6]), 1);  // flags bit 0
    auto r = learn::Model::decode(b.data(), b.size());
    CHECK(r != nullptr);
    if (r) {
        CHECK_EQ(r->learnedCase("senprints"), std::string("SenPrints"));
        CHECK(r->learnedCase("văn").empty());
        const learn::CaseStat* v = r->cases().find("văn");
        CHECK(v && *v == (learn::CaseStat{"Văn", 2, 2}));
        CHECK(r->encode() == b);
        typeCased(*r, "Văn", "anh");
        CHECK_EQ(r->learnedCase("văn"), std::string("Văn"));
    }
    // decay to zero drops the casing; clear drops everything
    learn::Model d(nullptr, 0);
    typeCased(d, "Văn", "anh", 3);
    d.decayIfDue(52ll * 7 * 86400 * 1000);
    CHECK(d.count("văn") == 0 && d.cases().empty());
    typeCased(*m, "Văn", "anh");
    m->clear(0);
    CHECK(m->cases().empty() && m->learnedCase("senprints").empty());
    // hits > total / total 0 / flag off with data => rejected (CRC fixed up)
    auto patched = [](std::vector<uint8_t> v, size_t at, uint8_t val) {
        v.resize(v.size() - 4);
        v[at] = val;
        const uint32_t c = learn::crc32(v.data(), v.size());
        for (int k = 0; k < 4; ++k) v.push_back(static_cast<uint8_t>(c >> (8 * k)));
        return v;
    };
    const size_t n = b.size() - 4;
    const auto bad1 = patched(b, n - 4, 9);  // hits of the last row > total
    CHECK(learn::Model::decode(bad1.data(), bad1.size()) == nullptr);
    const auto bad2 = patched(patched(b, n - 2, 0), n - 1, 0);  // total 0
    CHECK(learn::Model::decode(bad2.data(), bad2.size()) == nullptr);
    const auto bad3 = patched(b, 6, 0);  // flag off, section still there
    CHECK(learn::Model::decode(bad3.data(), bad3.size()) == nullptr);
}

TEST(learned_case_cross_platform_fixture) {
    // Shared with iOS / Android (python-built): senprints (3,3), văn (1,21).
    const std::vector<uint8_t> bin = readFile(VTX_KB_RESOURCES "/../../KeyboardTests/Fixtures/userlm-vtl2-case.bin");
    CHECK(bin.size() > 36);
    auto m = learn::Model::decode(bin.data(), bin.size());
    CHECK(m != nullptr);
    if (m) {
        CHECK_EQ(m->count("văn"), 21);
        CHECK(m->cases().size() == 2);
        CHECK_EQ(m->learnedCase("senprints"), std::string("SenPrints"));
        CHECK(m->learnedCase("văn").empty());
        CHECK(m->encode() == bin);  // byte for byte = the Swift encoder
    }
    // The old fixture has no casing: flags 0 (learned_file_matches_swift keeps it byte-identical).
    const std::vector<uint8_t> old = readFile(VTX_APP_FIXTURES "/learned-words.bin");
    CHECK(old.size() > 8 && old[6] == 0 && old[7] == 0);
}

TEST(learned_case_in_predictions) {
    CHECK(data().ok);
    learn::Model m([](const std::string& w) { return model().knownWord(w); }, 1760000000000ll);
    CHECK(predict::resolveCase(U("văn"), std::nullopt, &m) == U("văn"));
    typeCased(m, "Văn", "anh", 3);
    CHECK(predict::resolveCase(U("văn"), std::nullopt, &m) == U("Văn"));
    CHECK(predict::resolveCase(U("văn"), std::nullopt, nullptr) == U("văn"));
    CHECK(predict::resolveCase(U("iphone"), std::nullopt, &m) == U("iPhone"));  // DisplayCase
    CHECK(predict::resolveCase(U("nam"), U("việt"), &m) == U("Nam"));          // chain
    CHECK(predict::resolveCase(U("VietTelex"), std::nullopt, &m) == U("VietTelex"));
    // next word after a learned pair, and completion of the word being typed: learned casing
    const std::string next = cands("anh ", "", "", false, true, &m);
    CHECK(next.find("Văn") != std::string::npos && next.find("văn") == std::string::npos);
    const std::string comp = cands("anh vă", "vă", "vaw", false, true, &m);
    CHECK(comp.find("Văn") != std::string::npos);
}
