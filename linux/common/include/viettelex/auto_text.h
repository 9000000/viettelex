// auto_text.h — "văn bản tự động" (port macOS App/Sources/SystemAutoText.swift +
// the pure parts of App/Sources/WordPrediction.swift, 16/10/2026):
//   • dấu chấm khi gõ hai dấu cách ("chào␣␣" → "chào. "),
//   • tự viết hoa đầu câu (the first letter goes into the engine uppercase: "dduwowcj" → "Được"),
//   • ngoặc kép cong + gạch dài (" ' → “ ” ‘ ’, "--" → "—", another "-" → "---"),
//   • gợi ý từ (word prediction): only the cheap gates live here — ranking runs in
//     `viettelex-text-tool --serve` ("predict", engine-capi/Sources/TextToolCLI/Predict.swift).
// macOS follows its own Text Input settings; Linux has no OS-wide equivalent, so each one is a
// VietTelex switch ([general] double_space_period / auto_capitalize / smart_punctuation /
// word_prediction, SETTINGS.md §8b), all OFF by default.
//
// Pure functions on UTF-8 text / code points — the Session (session.cpp) decides when to call
// them from the typed tail it already keeps for caret suggestions, and does the edits.
#pragma once

#include <cstdint>
#include <string>

namespace viettelex {
namespace autotext {

// NSUserQuotesArray order: open double, close double, open single, close single.
struct Quotes {
    std::string openDouble, closeDouble, openSingle, closeSingle;
    bool operator==(const Quotes &o) const {
        return openDouble == o.openDouble && closeDouble == o.closeDouble && openSingle == o.openSingle &&
               closeSingle == o.closeSingle;
    }
};
// [general] quote_style: "curly" (default) “ ” ‘ ’, "low9" „ “ ‚ ‘, "guillemets" « » ‹ ›.
Quotes quotesFor(const std::string &style);

// Apps where none of this runs: terminals (isTerminalApp) and code editors / IDEs ("--flag",
// '"' in code, a capital at line start are syntax there) — SystemAutoText.excludedApps.
bool appAllowed(const std::string &appId);
bool isCodeEditorApp(const std::string &appId);

// MARK: dấu chấm khi gõ hai dấu cách
// AOSP LatinIME config_double_space_period_timeout (macOS: same 1.1 s).
constexpr int64_t kDoubleSpaceWindowMs = 1100;
// Letter, digit, or a closing bracket / quote ("(xem trên)␣␣" → "(xem trên). ").
bool periodQualifies(uint32_t c);
// Second space: `before` = the text before the caret (it already ends with the first space),
// `gapMs` = since the first space, `isRepeat` = the key is held (autorepeat). True = replace
// that space with ". " (and swallow this one); `prev` gets the character before the space.
bool doubleSpacePeriod(const std::string &before, int64_t gapMs, bool isRepeat, uint32_t *prev = nullptr);

// MARK: ngoặc kép cong
// `typed` = '"' or '\''; `prev` = the character before the caret, `hasPrev` = false at the
// start of the text. "" when `typed` is not a quote key.
std::string smartQuote(uint32_t typed, uint32_t prev, bool hasPrev, const Quotes &q);

// MARK: gạch dài
enum class DashEdit { None, EmDash, Restore };
// Key "-": `before` = the text before the caret. "--" → "—" (the "-" before goes, this key is
// swallowed); a "—" WE just made + "-" → "---". Not after "<!" (HTML comment) nor on a run of
// 3+ dashes.
DashEdit dash(const std::string &before, bool lastWasOurEmDash);

// MARK: viết hoa đầu câu
enum class CapContext { Capitalize, Keep, Unknown };
// First letter of a new word: `before` = text right before the caret (nullptr = unknown),
// `atTextStart` = the caret is at the very start of the field (callers pass it only for
// multi-line fields — a username / search box is not capitalised).
CapContext capitalization(const std::string *before, bool atTextStart);
// ASCII lowercase letter → uppercase; anything else unchanged.
uint32_t capitalized(uint32_t ch);

// MARK: gợi ý từ (PredictionLogic, WordPrediction.swift)
constexpr int kPredictIdleMs = 300;   // PredictionLogic.idleDelay
constexpr int kPredictMinTyped = 2;   // PredictionLogic.minTyped
// Esc on a completion: do not offer again while the word still starts with what was
// declined (until the next word). Case-insensitive.
bool predictionMuted(const std::string &typed, const std::string &declined);
// Cheap gate before asking the helper for a completion: the word being composed has at least
// kPredictMinTyped characters, all letters.
bool completionWorthAsking(const std::string &typed);
// …for the next word: `before` ends with exactly one space right after a letter.
bool nextWordWorthAsking(const std::string &before);

}  // namespace autotext
}  // namespace viettelex
