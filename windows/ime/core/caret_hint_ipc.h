// caret_hint_ipc.h — the two caret hints that need VietTelex.exe's language data
// (caret_hints.h: typo fixes need vnlexicon/enlexicon, tones need Thêm dấu). The data
// (~2 MB) stays out of the TIP, exactly like Công cụ văn bản (text_tool_ipc.h):
//
//   TIP  --WM_COPYDATA(kCopyHintRequest: request, job, engine flags, text)-->  app
//          (sent with SMTO_ABORTIFHUNG, short timeout; the app only queues the job)
//   app  --WM_COPYDATA(kCopyHintReply: request, job, 0, result)-->  TIP window
//          (result "" = nothing to suggest). The TIP shows it only if no key was typed
//          since (request = the TIP's key generation) and the screen still matches.
//
// Typo: text = the raw keys of the word ("tpoi"), result = the fix ("tôi").
// Tones: text = the unaccented run from the screen ("toi di hoc "), result = Thêm dấu.
// Predict (gợi ý từ, app/core/word_prediction.h): text = packPredictText(before the caret,
//   word being typed, its raw keys), flags = kPredictEnglish when the previous word was
//   English; result = the top-ranked candidate ("" = none) — one suggestion, no list.
// Up the integrity ladder only via the WM_COPYDATA filter the app already opens.
#pragma once
#include <cstdint>
#include <string>
#include <vector>

namespace vtx {

constexpr uint32_t kCopyHintRequest = 0x56544831u;  // "VTH1" TIP -> app
constexpr uint32_t kCopyHintReply = 0x56544832u;    // "VTH2" app -> TIP
constexpr size_t kHintMaxLength = 400;              // UTF-16 units (tones window + slack)

enum class HintJob : uint32_t { Typo = 1, Tones = 2, Predict = 3 };
inline bool isValidHintJob(uint32_t v) { return v >= 1 && v <= 3; }

// ---- Predict job payload. U+001F never occurs in typed text (control character).
constexpr char16_t kPredictSep = 0x1F;
constexpr uint32_t kPredictEnglish = 1;

inline std::u16string packPredictText(const std::u16string& before, const std::u16string& typed,
                                      const std::u16string& raw) {
    std::u16string t;
    t.reserve(before.size() + typed.size() + raw.size() + 2);
    for (char16_t c : before) t.push_back(c == kPredictSep ? u' ' : c);
    t.push_back(kPredictSep);
    t += typed;
    t.push_back(kPredictSep);
    t += raw;
    return t;
}

// False unless exactly three fields.
inline bool unpackPredictText(const std::u16string& t, std::u16string& before, std::u16string& typed,
                              std::u16string& raw) {
    const size_t a = t.find(kPredictSep);
    if (a == std::u16string::npos) return false;
    const size_t b = t.find(kPredictSep, a + 1);
    if (b == std::u16string::npos || t.find(kPredictSep, b + 1) != std::u16string::npos) return false;
    before = t.substr(0, a);
    typed = t.substr(a + 1, b - a - 1);
    raw = t.substr(b + 1);
    return true;
}


struct HintMessage {
    uint32_t request = 0;
    uint32_t job = 0;
    uint32_t flags = 0;  // vtx_engine flags of the TIP (typo: compose like the typist)
    std::u16string text;
};

// request u32 | job u32 | flags u32 | UTF-16 text (no terminator), little-endian.
inline std::vector<uint8_t> packHintMessage(const HintMessage& m) {
    const size_t n = m.text.size() > kHintMaxLength ? kHintMaxLength : m.text.size();
    std::vector<uint8_t> b(12 + n * 2);
    const uint32_t head[3] = {m.request, m.job, m.flags};
    for (int k = 0; k < 3; ++k)
        for (int i = 0; i < 4; ++i) b[static_cast<size_t>(k * 4 + i)] = static_cast<uint8_t>(head[k] >> (8 * i));
    for (size_t i = 0; i < n; ++i) {
        b[12 + 2 * i] = static_cast<uint8_t>(m.text[i] & 0xFF);
        b[13 + 2 * i] = static_cast<uint8_t>(m.text[i] >> 8);
    }
    return b;
}

// False on a malformed payload (short, odd size, too long, unknown job).
inline bool unpackHintMessage(const void* data, size_t size, HintMessage& out) {
    if (!data || size < 12 || (size - 12) % 2 != 0 || (size - 12) / 2 > kHintMaxLength) return false;
    const auto* p = static_cast<const uint8_t*>(data);
    uint32_t head[3] = {0, 0, 0};
    for (int k = 0; k < 3; ++k)
        for (int i = 0; i < 4; ++i) head[k] |= static_cast<uint32_t>(p[k * 4 + i]) << (8 * i);
    if (!isValidHintJob(head[1])) return false;
    out.request = head[0];
    out.job = head[1];
    out.flags = head[2];
    out.text.resize((size - 12) / 2);
    for (size_t i = 0; i < out.text.size(); ++i)
        out.text[i] = static_cast<char16_t>(p[12 + 2 * i] | (p[13 + 2 * i] << 8));
    return true;
}

}  // namespace vtx
