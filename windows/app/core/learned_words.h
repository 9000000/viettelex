// learned_words.h — "Học từ bạn gõ" for Windows word prediction: a C++ port of
// App/Sources/LearnedModel.swift (macOS + Linux), which itself runs the iOS UserLangModel tables
// (iOS/Keyboard/UserLMTables.swift — UserLMTables + the "VTL2" file format UserLMCodec). Same
// numbers, same order, same bytes on disk: the golden fixture app/tests/fixtures/word-prediction.tsv
// (column `learn`) and learned-words.bin are generated from the Swift code.
//
//   • record: unigram += w, bigram (prev1 → word) += w, trigram (prev2, prev1 → word) += w only
//     once the pair (prev2, prev1) has been seen ≥ 2 times. w = 1 typed, 2 an accepted prediction.
//   • learnable: letters only, ≤ 12 characters, no run of ≥ 3 equal characters.
//   • caps uni 3000 / bi 6000 / tri 3000: over ⇒ every count of that table halved, then compact.
//   • decay: every ≥ 7 days all counts × 0.7^weeks (one global timestamp, applied at load).
//   • learning vs suggesting: a word outside vnlexicon needs count ≥ 3 to be suggested.
//   • next words: λ_tri·P_tri + λ_bi·P_bi + 0.1·P_uni + (1−λ_bi)·0.9·P_seed (λ = n/(n+2), n/(n+4)),
//     seeds = the seed_next.inc row; learned pairs only with count ≥ kLearnedPairMin (no plain
//     one-word bigram guess), learned triples ≥ kLearnedPairMin.
//
// Lives in VietTelex.exe only (learned_store in app/src: %LOCALAPPDATA%\VietTelex\
// learned-words.bin, atomic writes, debounced). The TIP never loads it: it sends committed words
// over the hint IPC (caret_hint_ipc.h HintJob::Learn). Not thread-safe (UI thread).
#pragma once
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace vtx::app::learn {

constexpr int kUniCap = 3000;
constexpr int kBiCap = 6000;
constexpr int kTriCap = 3000;
constexpr int kUnknownSuggestThreshold = 3;
constexpr int kLearnedPairMin = 2;  // = SuggestRank.learnedTriMin
constexpr int kMaxWordLength = 12;
constexpr const wchar_t* kFileName = L"learned-words.bin";

// LearnedModel.learnable (UTF-8).
bool learnable(const std::string& w);
// Lowercase NFC UTF-8 (the model's keys).
std::string key(const std::string& w);

// ---- Learned casing (10/2026) = iOS/Keyboard/UserLMTables.swift CaseTable, same numbers.
// The casing a user CONSISTENTLY writes a word with mid-sentence ("SenPrints", a person "Văn").
// Only mid-sentence evidence (the caller decides: predict::casingEvidence — prev word present,
// not a DisplayCase chain); here all-caps / one-letter forms are ignored. Per entry: `form` (the
// prevailing non-lowercase form, Boyer–Moore votes), `hits` (its net votes), `total` (every
// mid-sentence observation incl. lowercase; a new entry starts at the word's unigram count before
// it — earlier uses count as lowercase). Preferred = form when hits ≥ 3 and hits ≥ 80% of total.
// Counters saturate at 255 (both halved, rounding up). At most 512 entries.
constexpr int kCaseCap = 512;
constexpr int kCaseMaxCount = 255;
constexpr int kCaseMinHits = 3;

struct CaseStat {
    std::string form;  // NFC UTF-8, as typed
    int hits = 0;
    int total = 0;
    bool operator==(const CaseStat& o) const { return form == o.form && hits == o.hits && total == o.total; }
};

enum class CaseKind { Lower, Mixed, Ignored };
// No uppercase character => Lower; one letter / every character uppercase (Caps Lock) => Ignored.
// "Uppercase" = a character (code point + its marks) whose lowercase differs from itself.
CaseKind caseKind(const std::string& form);

class CaseTable {
public:
    // One mid-sentence observation of `form` (NFC, as typed); `key` lowercase; `priorCount` =
    // unigram count before this record. true if the table changed.
    bool observe(const std::string& form, const std::string& key, int priorCount);
    // Preferred form of `key`, empty = not consistent enough.
    std::string preferred(const std::string& key) const;
    void remove(const std::string& key) { stats_.erase(key); }
    void clear() { stats_.clear(); }
    bool empty() const { return stats_.empty(); }
    size_t size() const { return stats_.size(); }
    const CaseStat* find(const std::string& key) const {
        const auto it = stats_.find(key);
        return it == stats_.end() ? nullptr : &it->second;
    }
    std::unordered_map<std::string, CaseStat>& stats() { return stats_; }
    const std::unordered_map<std::string, CaseStat>& stats() const { return stats_; }

private:
    std::unordered_map<std::string, CaseStat> stats_;
};

class Model {
public:
    using KnownFn = std::function<bool(const std::string&)>;  // vnlexicon has the word (lowercase)
    explicit Model(KnownFn isKnown = nullptr, int64_t nowMs = 0);

    // `caseEvidence` = the casing of `word` (as typed) is mid-sentence evidence
    // (predict::casingEvidence); false never touches the casing table.
    void record(const std::string& word, const std::string& prev1 = std::string(),
                const std::string& prev2 = std::string(), int weight = 1, bool caseEvidence = false);
    // Learned casing of `key` (lowercase UTF-8); empty = none. O(1).
    std::string learnedCase(const std::string& key) const { return cases_.empty() ? std::string() : cases_.preferred(key); }
    const CaseTable& cases() const { return cases_; }
    int count(const std::string& w) const;
    int bigramCount(const std::string& prev, const std::string& w) const;
    int trigramCount(const std::string& prev2, const std::string& prev, const std::string& w) const;
    bool suggestable(const std::string& w) const;
    // LearnedModel.nextWords: `seeds` = seed_next.inc row of prev1 (lowercase UTF-8); pairMin 0 =
    // no gate (completion context +4).
    std::vector<std::string> nextWords(const std::string& prev1, const std::string& prev2,
                                       const std::vector<std::string>& seeds, int limit,
                                       int pairMin = kLearnedPairMin) const;
    void decayIfDue(int64_t nowMs);
    void clear(int64_t nowMs);

    bool empty() const { return uniN_ == 0 && biN_ == 0 && triN_ == 0; }
    int wordCount() const { return uniN_; }
    int pairCount() const { return biN_; }
    int tripleCount() const { return triN_; }
    int64_t lastDecayMs() const { return lastDecayMs_; }
    // Changes since markSaved() — the store writes only when > 0.
    int changes() const { return changes_; }
    void markSaved() { changes_ = 0; }
    // Approximate heap bytes (tests / report).
    size_t memoryBytes() const;

    // VTL2 (UserLMCodec): byte-identical to the Swift encoder for the same record sequence.
    // flags bit 0 + a casing section after the manual list only when the casing table has a
    // row for a word in the table — otherwise the bytes are exactly the old format.
    std::vector<uint8_t> encode() const;
    // nullptr = corrupt / wrong format (CRC, bounds, ordering — the Swift decoder's checks).
    static std::unique_ptr<Model> decode(const uint8_t* data, size_t size, KnownFn isKnown = nullptr);

private:
    int32_t intern(const std::string& w);
    int32_t idOf(const std::string& w) const;
    int uni(int32_t id) const { return static_cast<int>(uniC_[static_cast<size_t>(id)]); }
    void setUni(int32_t id, int c);
    int biCount(int32_t p, int32_t n) const;
    void addBi(int32_t p, int32_t n, int by);
    int triSlotOf(uint64_t ctx) const;
    int triSlot(uint64_t ctx);
    int triCount(int slot, int32_t n) const;
    void addTri(uint64_t ctx, int32_t n, int by);
    void scale(bool u, bool b, bool r, double f);
    void compact();
    void pruneIfNeeded();
    void dropOrphanCases();

    std::vector<std::string> words_;
    std::unordered_map<std::string, int32_t> ids_;
    std::vector<uint32_t> uniC_;
    std::vector<std::vector<uint64_t>> biB_;   // (next id << 32 | count), sorted by next id
    std::unordered_map<uint64_t, int32_t> triIdx_;
    std::vector<uint64_t> triCtx_;
    std::vector<std::vector<uint64_t>> triB_;
    int uniN_ = 0, biN_ = 0, triN_ = 0;
    int64_t uniTotal_ = 0;
    int64_t lastDecayMs_ = 0;
    CaseTable cases_;
    int changes_ = 0;
    KnownFn isKnown_;
    mutable std::unordered_map<std::string, bool> knownCache_;
};

// CRC-32 (IEEE, as zlib) — the VTL2 trailer.
uint32_t crc32(const uint8_t* p, size_t n);

}  // namespace vtx::app::learn
