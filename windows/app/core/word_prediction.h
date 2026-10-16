// word_prediction.h — GỢI Ý TỪ (word prediction) for Windows: a C++ port of macOS
// App/Sources/WordPrediction.swift (PredictionLogic + PredictionModel) and the shared iOS
// ranking it uses (iOS/Keyboard/SuggestionSupport.swift SuggestRank.rankInline / inlinePmi /
// nextFill / topNext, VNSuggest.swift, SyllableLM.swift Context, DisplayCase.swift,
// SensitiveWords.swift, SeedData.swift unigrams, CaretSuggestions.swift EnglishLite).
// Same data files (vnlexicon.bin, vnlm.bin, enlexicon.bin — already embedded in
// VietTelex.exe for Thêm dấu), same weights, same results: the golden fixture
// app/tests/fixtures/word-prediction.tsv is generated FROM the Swift code
// (app/tools/gen_prediction_golden.sh) and app_tests checks every line.
//
//   a) completion of the word being typed ("tôi đư" -> đừng / được / đưa; English when the
//      context is English or no Vietnamese syllable matches: "keyb" -> keyboards …);
//   b) next word right after a space ("cảm " -> ơn / thấy / hứng).
//
// Runs in VietTelex.exe only (like typo fixes and tones, caret_hint_ipc.h): the TIP sends
// the text before the caret + the word being typed; nothing of this is linked into the TIP.
// Gate: the Windows setting "Show text suggestions when typing on the physical keyboard"
// (Settings → Time & language → Typing) — `kHwkbPredictionKey` / `kHwkbPredictionValue`.
// No VietTelex toggle. The model loads on the first request (setting on), never before.
#pragma once
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "typo_fix.h"

namespace vtx { namespace addtones { struct LanguageData; } }

namespace vtx::app::predict {

// ---------------------------------------------------------------- the Windows setting
// HKCU\Software\Microsoft\Input\Settings, REG_DWORD EnableHwkbTextPrediction: 1 = on,
// 0 = off. Absent (never toggled) = Windows' default, OFF. Not documented by Microsoft;
// the name is the one the Settings toggle writes (community references, see README).
constexpr const wchar_t* kHwkbPredictionKey = L"Software\\Microsoft\\Input\\Settings";
constexpr const wchar_t* kHwkbPredictionValue = L"EnableHwkbTextPrediction";
constexpr bool kHwkbPredictionDefault = false;
// `present` = the value exists as a DWORD.
inline bool resolveHwkbPrediction(bool present, uint32_t value) {
    return present ? value != 0 : kHwkbPredictionDefault;
}

// ---------------------------------------------------------------- PredictionLogic
constexpr int kIdleDelayMs = 300;  // pause before reading the screen (typing on = nothing)
constexpr int kMaxCandidates = 3;
constexpr int kMinTyped = 2;       // completion only from 2 typed letters
constexpr int kWindow = 64;        // UTF-16 units read before the caret

struct Request {
    std::u32string typed;               // word being typed ("" = next word)
    std::optional<std::u32string> prev; // 1–2 words before, same sentence, lowercase
    std::optional<std::u32string> prev2;
    bool english = false;               // engine: the previous word was English
    bool operator==(const Request& o) const {
        return typed == o.typed && prev == o.prev && prev2 == o.prev2 && english == o.english;
    }
};

// PredictionLogic.request: `before` = text before the caret (ends at the caret), `typed` =
// the word being composed. nullopt = nothing to suggest.
std::optional<Request> request(const std::u32string& before, const std::u32string& typed, bool english);
bool wantsEnglish(const Request& r, int vietnameseHits);
// Ranked words -> at most kMaxCandidates real completions (longer than typed), no dupes.
std::vector<std::u32string> completions(const std::vector<std::u32string>& ranked, const std::u32string& typed);
// Esc on a completion: no suggestion while the typed word still starts with the declined one.
bool muted(const std::u32string& typed, const std::u32string& declined);

// ---------------------------------------------------------------- display helpers
// DisplayCase.apply (proper nouns, name chains "hà" -> "Nội").
std::u32string displayCase(const std::u32string& w, const std::optional<std::u32string>& after);
// SuggestionCase.display(w, shift: .off, typed:).
std::u32string suggestionCase(const std::u32string& w, const std::u32string& typed);
bool isSensitive(const std::u32string& w);  // SensitiveWords.set (lowercased)
// SeedData.unigrams count (0 if absent).
int seedCount(const std::string& utf8Lower);

// ---------------------------------------------------------------- PredictionModel
class Model {
public:
    explicit Model(const addtones::LanguageData& data);
    // Candidates (case adjusted) for `r`; `raw` = raw keys of the word being typed.
    std::vector<std::u32string> candidates(const Request& r, const std::u32string& raw) const;

    // Exposed for tests: SuggestRank.nextFill(prev, prev2, personal: [], …) and
    // VNSuggest-pool ranking (rankInline + inlinePmi + sensitive filter).
    std::vector<std::u32string> nextWords(const std::u32string& prev, const std::optional<std::u32string>& prev2) const;
    std::vector<std::u32string> englishCompletions(const std::u32string& typed, int limit) const;

private:
    struct Top {
        std::vector<int> ids;
        bool trigram = false;
    };
    bool topNext(const std::u32string& prev, const std::optional<std::u32string>& prev2, int limit, Top& out) const;
    std::vector<std::u32string> words(const Top& t) const;

    const addtones::LanguageData& data_;
    typo::LexiconIndex index_;
};

}  // namespace vtx::app::predict
