// caret_hints.h — "gợi ý cạnh con trỏ" (port macOS 1.8.2: App/Sources/MathHint.swift +
// CaretSuggestions.swift): kết quả phép tính ("12*3=" → "= 36"), chip số dạng tiền
// ("1tr2␣" → "1.200.000 ₫"), sửa lỗi gõ sai ("tpoi␣" → "tôi"), thêm dấu cho cụm không dấu
// ("toi di hoc." → "tôi đi học."), ngày giờ ("hôm nay␣" → "28/09/2026").
//
// Chia việc như macOS (rẻ trong process IME, nặng ở process con):
//   • Session (session.cpp) theo dõi ĐUÔI văn bản vừa gõ (key stream, không đọc màn hình mỗi
//     phím) và chỉ ở điểm kích hoạt — phím "=", ranh giới từ — mới xét các cổng rẻ dưới đây
//     (so chuỗi, vt_is_valid_syllable). Tắt hết ⇒ một lần đọc cờ mỗi phím.
//   • Tính gợi ý (MathResults/NumberChips/lexicon/Thêm dấu — mã Swift chung iOS/macOS) chạy
//     trong `viettelex-text-tool --serve` (engine-capi/Sources/TextToolCLI/Serve.swift): một
//     process con SỐNG LÂU, khởi động ở lần kích hoạt đầu, tự thoát khi rảnh. HintService
//     gửi yêu cầu trên thread riêng, trả kết quả về main thread của IM.
//   • Chỉ Tab áp dụng (phép tính: cả Enter), Esc = bỏ (sửa lỗi: không gợi ý lại từ đó trong
//     phiên), phím khác = tắt gợi ý và đi tiếp như thường. Không bao giờ tự thay. Không chạy ở
//     ô mật khẩu (Session passthrough). Gợi ý thay chữ đã chốt (mọi loại trừ phép tính) chỉ
//     khi Session được sửa chữ quanh con trỏ (surrounding đã chứng minh / Direct).
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <functional>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <vector>

namespace viettelex {

struct CaretSuggestion {
    enum class Kind { Math, Number, Typo, Tones, Date };
    Kind kind = Kind::Math;
    std::string display;  // shown near the caret ("= 36", "1.200.000 ₫", "tôi")
    std::string replace;  // tail of the text before the caret to replace ("" = insert only)
    std::string insert;   // text inserted in its place
    bool operator==(const CaretSuggestion &o) const {
        return kind == o.kind && display == o.display && replace == o.replace && insert == o.insert;
    }
};

// Which caret suggestions are on (Settings [general]); defaults = macOS.
struct HintFlags {
    bool math = true;     // math_results
    bool number = true;   // number_chips
    bool typo = true;     // typo_hints
    bool tones = false;   // tone_hints
    bool date = true;     // date_hints
    bool any() const { return math || number || typo || tones || date; }
};

// One request for the helper (Serve.swift protocol line) + when to run it.
struct HintRequest {
    std::string line;       // "math\t<before>" …, fields escaped
    int delayMs = 0;        // run only after this pause (tones after a space: 900 ms)
    uint64_t gen = 0;       // Session key generation at trigger time
    // The Session's live key generation: a queued / delayed request whose generation moved on
    // is dropped without contacting the helper ("gõ tiếp là huỷ").
    std::shared_ptr<const std::atomic<uint64_t>> liveGen;
};

namespace hints {

// What a key does while a suggestion is shown (CaretHintLogic.action).
enum class KeyAction { Accept, DismissConsume, DismissPass };
// `mods` = VT_MOD_* of the key. Only plain keys accept: Tab for every kind, Enter / keypad
// Enter only for math (after "50k␣" Enter sends the message). Esc (plain) declines.
KeyAction keyAction(CaretSuggestion::Kind kind, uint32_t keysym, uint32_t mods);

// Label near the caret: the display text + the key that applies it ("= 36   Tab / Enter").
std::string label(const CaretSuggestion &s);

// Protocol (Serve.swift): fields joined by TAB, `\` TAB LF CR escaped.
std::string escape(const std::string &s);
std::string request(const std::vector<std::string> &fields);
// "-" / garbage → false. "<kind>\t<display>\t<replace>\t<insert>" → true.
bool parseAnswer(const std::string &line, CaretSuggestion &out);

// Cheap boundary gates (no data), same rules as the macOS code they name.
// CaretHintLogic.numberWorthChecking: space after a run with a digit, or a ≤6-char unit
// right after a run with a digit ("2 tỷ").
bool numberWorthChecking(uint32_t boundary, const std::string &run, const std::string &prevRun);
// Superset of DateHintLogic.detect the helper then decides: "hôm nay/qua", "ngày mai",
// "bây giờ" (any case of the first letter), or today/tomorrow/yesterday/now after an ASCII word.
bool dateCandidate(uint32_t boundary, const std::string &prevRun, const std::string &run);
// TypoFixLogic.worthChecking: boundary in "  ,;!?)", raw 3–10 ASCII letters, word all
// letters and NOT a valid Vietnamese syllable.
bool typoWorthChecking(uint32_t boundary, const std::string &raw, const std::string &word);
// The raw keys (ASCII letters, any case) spell a word of the engine's English list
// (vt_is_english_word): TypoFixLogic.correction rejects it (isKnown) before any lookup, so
// the Session never sends it to the helper — most English words never wake the helper.
bool typoKnownEnglish(const std::string &raw);

// ToneRunLogic.Tracker: counts unaccented syllables at boundaries.
enum class ToneTrigger { None, SentenceEnd, Pause };
class ToneTracker {
public:
    // `chunk` = the run committed right before the boundary (with its punctuation).
    ToneTrigger feed(const std::string &chunk, uint32_t boundary);
    void reset() { count_ = 0; }
    int count() const { return count_; }

private:
    int count_ = 0;
};

// Words the user declined (Esc) this session, lowercase, last `cap` kept (AutoCorrect.Rejected).
class Rejected {
public:
    explicit Rejected(size_t cap = 300) : cap_(cap) {}
    bool contains(const std::string &w) const;
    void add(const std::string &w);

private:
    size_t cap_;
    std::deque<std::string> order_;
    std::set<std::string> set_;
};

// Lowercase for the letters caret hints compare (ASCII + Vietnamese precomposed letters).
std::string lower(const std::string &s);

}  // namespace hints

// Runs HintRequests against a long-lived `viettelex-text-tool --serve` on one worker thread.
// Latest request wins (an older one still queued is dropped). `post` hands the answer back on
// the IM main thread (Fcitx5 EventDispatcher / g_main_context_invoke). One per IM process.
class HintService {
public:
    using Post = std::function<void(std::function<void()>)>;
    using Done = std::function<void(bool ok, const CaretSuggestion &s)>;

    explicit HintService(Post post, std::string helperPath = std::string());
    ~HintService();
    HintService(const HintService &) = delete;
    HintService &operator=(const HintService &) = delete;

    // Main thread. `done` runs on the main thread only when the helper answered with a
    // suggestion (ok = true) and the request was not superseded.
    void submit(HintRequest req, Done done);
    // Synchronous round trip (worker thread / tests): false on no answer / timeout.
    bool query(const std::string &line, std::string &answer, int timeoutMs = 3000);
    bool available() const;

private:
    struct Job {
        HintRequest req;
        Done done;
    };
    void loop();
    bool ensureHelper();
    void stopHelper();

    Post post_;
    std::string helper_;
    std::mutex mu_;
    std::condition_variable cv_;
    std::unique_ptr<Job> next_;  // guarded by mu_
    bool stop_ = false;          // guarded by mu_
    std::thread worker_;
    std::shared_ptr<std::atomic<bool>> alive_;
    // helper process (worker thread only, and query())
    std::mutex procMu_;
    std::atomic<int> pid_{-1};  // read by the destructor to unblock a query in flight
    int in_ = -1, out_ = -1;
    std::string buf_;
};

}  // namespace viettelex
