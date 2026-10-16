// WordPrediction.swift — GỢI Ý TỪ trong ô gợi ý cạnh con trỏ (CaretHint, MathHint.swift) cho
// macOS (maintainer 16/10/2026). Hai trường hợp:
//   a) HOÀN THÀNH từ đang gõ ("đư" → được / đường / đưa; tiếng Anh khi ngữ cảnh là tiếng Anh,
//      khi không âm tiết Việt nào khớp: "keyb" → keyboard, hoặc khi phím thô là tiền tố tiếng
//      Anh rõ ràng hơn mọi cách đọc tiếng Việt — `PredictionLogic.prefersEnglish`);
//   b) TỪ KẾ TIẾP ngay sau dấu cách: dòng TRIGRAM vnlm.bin cho 2 từ ngữ cảnh ("cảm ơn ␣" →
//      bạn), hoặc cặp SEED curated của iOS với MỘT từ ngữ cảnh ("cảm ␣" → ơn, "xin ␣" → lỗi —
//      SeedNextData, sinh từ UserLangModel iOS). Không bao giờ lùi về bigram thống kê một từ
//      ("Tên ␣" → gọi: quá đoán mò — Phil 16/10/2026; "tên" không có seed ⇒ không gì).
// Cùng luật với mọi gợi ý cạnh con trỏ: chỉ áp dụng bằng Tab (hoặc click ứng viên), Esc tắt,
// không bao giờ tự thay, ĐỌC LẠI màn hình trước khi thay, không ở ô mật khẩu / Secure Input.
// MỘT ứng viên duy nhất (Phil 16/10/2026: không danh sách, không số thứ tự) — Tab / click
// nhận, Esc bỏ; hiện như mọi gợi ý cạnh con trỏ khác ("được  ⇥ Tab"). Gợi ý khác (sửa lỗi gõ, thêm dấu, ngày giờ, phép tính,
// chip số) đang hiện ⇒ không hiện gợi ý từ (chúng thắng); chúng tới sau thì thay gợi ý từ.
//
// CÔNG TẮC: theo đúng cài đặt hệ thống "Show inline predictive text" (System Settings →
// Keyboard → Text Input) — khoá NSGlobalDomain `NSAutomaticInlinePredictionEnabled` (không có
// khoá ⇒ mặc định của macOS: BẬT). Không có công tắc riêng trong VietTelex. Đọc một lần khi
// controller activate (đổi ô / đổi app) — không bao giờ đọc mỗi phím.
//
// DỮ LIỆU — dùng CHUNG với thanh gợi ý iOS (iOS/docs/IOS-SUGGESTIONS.md), không mô hình mới:
// VNSuggest (vnlexicon.bin, tầng 1) + SuggestRank.rankInline / nextFill (SuggestionSupport,
// tầng 2/7) + SyllableLM (vnlm.bin, mmap) + seed tầng 3 (đếm SeedData.unigrams + bảng từ kế
// tiếp SeedNextData — Scripts/gen-seed-next.sh) + DisplayCase + SensitiveWords (công tắc "Lọc
// từ nhạy cảm", mặc định bật) + EnglishLite (enlexicon.bin mmap). Các file iOS được biên dịch
// thẳng vào target macOS (project.yml).
// KHÔNG HỌC từ người dùng trên macOS (chưa): xem `PredictionModel`.
//
// HIỆU NĂNG (ưu tiên số 1): công tắc tắt ⇒ không nạp gì, mỗi phím một lần đọc Bool dưới khoá.
// Bật: phím chỉ hẹn giờ (`idleDelay`, huỷ khi có phím mới); hết giờ mà không có phím mới mới
// đọc màn hình (một lần) → tính ứng viên trên hàng đợi nền của CaretHint → hiện nếu vẫn chưa có
// phím nào mới (thế hệ phím). Gõ liền mạch ⇒ không đọc màn hình, không tính gì.
import Foundation
import TelexCore

// MARK: - Cài đặt hệ thống

/// "Show inline predictive text" của macOS. Tự chứa (không phụ thuộc bộ đọc cài đặt hệ thống
/// khác) — bộ nhớ đệm dưới khoá, làm mới khi controller activate.
enum SystemInlinePrediction {
    /// Khoá NSGlobalDomain (đo trên máy dev 16/10/2026: `defaults read -g` có
    /// `NSAutomaticInlinePredictionEnabled = 1`; tắt trong System Settings ⇒ 0).
    static let key = "NSAutomaticInlinePredictionEnabled"
    /// Không có khoá (chưa từng đổi) ⇒ mặc định của macOS 14+: BẬT.
    static let defaultValue = true

    /// Giá trị thô trong NSGlobalDomain → bật/tắt.
    static func resolve(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return (s as NSString).boolValue }
        return defaultValue
    }

    private static let lock = NSLock()
    private static var cached: Bool?          // guarded by lock
    private static var lastReadNs: UInt64 = 0 // guarded by lock
    /// Override cho test (nil = đọc hệ thống).
    private static var forced: Bool?          // guarded by lock

    /// Bất kỳ thread. Giá trị đã đệm (lần đầu: đọc một lần).
    static var isOn: Bool {
        if let v = lock.withLock({ forced ?? cached }) { return v }
        return refresh(force: true)
    }

    /// Đọc lại từ NSGlobalDomain (CFPreferences — trong process, đồng bộ cache với cfprefsd).
    /// Gọi ở activateServer: tối đa một lần / `minInterval` (đổi ô liên tục không đọc lại).
    @discardableResult
    static func refresh(force: Bool = false, minInterval: UInt64 = 2_000_000_000) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if !force, let c = lock.withLock({ () -> Bool? in
            guard let c = cached, now &- lastReadNs < minInterval else { return nil }
            return c
        }) { return c }
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let v = resolve(CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication))
        lock.withLock { cached = v; lastReadNs = now }
        return lock.withLock { forced ?? v }
    }

    static func setForTesting(_ v: Bool?) { lock.withLock { forced = v } }
}

// MARK: - Logic thuần

enum PredictionLogic {
    /// Dừng gõ bấy nhiêu giây mới đọc màn hình + hiện (gõ liền mạch ⇒ không làm gì).
    static let idleDelay: TimeInterval = 0.3
    /// Số ứng viên HIỆN: một (Tab / click nhận nó).
    static let maxCandidates = 1
    /// Độ sâu danh sách xếp hạng — chỉ để đối chiếu bản port Windows/Linux (golden
    /// windows/app/tests/fixtures/word-prediction.tsv so cả 3 hạng đầu); ô chỉ hiện hạng 1.
    static let rankDepth = 3
    /// Hoàn thành từ chỉ khi đã gõ ít nhất bấy nhiêu chữ (1 chữ: quá nhiễu cho ô nổi).
    static let minTyped = 2
    /// Cửa sổ đọc màn hình (UTF-16) — đủ cho 2 từ ngữ cảnh.
    static let window = 64

    /// Ngữ cảnh một lượt gợi ý (dựng từ văn bản trước con trỏ — nguồn sự thật, không phải
    /// trạng thái tự dõi theo).
    struct Request: Equatable {
        /// Từ đang gõ (đang soạn) — "" = gợi ý từ kế tiếp.
        var typed: String
        /// 1–2 từ trước trong CÙNG câu (chữ thường); nil = không có / bị dấu câu cắt.
        var prev: String?
        var prev2: String?
        /// Ngữ cảnh tiếng Anh (engine: từ trước là tiếng Anh).
        var english: Bool
    }

    /// Có nên lên lịch gợi ý cho phím này không. `settingOn` = cài đặt hệ thống,
    /// `canReplace` = app đã chứng minh thay được chữ đã chốt (in-place, không marked),
    /// `secure` = ô mật khẩu / Secure Input, `otherHint` = gợi ý khác đang hiện.
    /// `canReplace` chỉ được tính khi cài đặt bật (autoclosure — tắt thì không tốn gì thêm).
    static func shouldSchedule(settingOn: Bool, canReplace: @autoclosure () -> Bool,
                               secure: Bool = false, otherHint: Bool = false) -> Bool {
        settingOn && !secure && !otherHint && canReplace()
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter }

    /// Văn bản trước con trỏ (`before`, kết thúc tại con trỏ) + từ đang soạn `typed` → lượt gợi
    /// ý, nil khi không nên gợi ý:
    ///  • đang gõ: `before` phải kết thúc đúng bằng `typed`, từ đứng riêng (đầu văn bản / sau
    ///    khoảng trắng), `typed` toàn chữ cái, ≥ `minTyped`;
    ///  • từ kế tiếp: `before` kết thúc bằng MỘT dấu cách ngay sau một từ toàn chữ cái.
    /// Ngữ cảnh: tối đa 2 từ trước, cách nhau đúng một dấu cách, toàn chữ cái — dấu câu / xuống
    /// dòng / ký tự khác cắt ngữ cảnh (như iOS: ngữ cảnh xoá ở dấu câu).
    static func request(before: String, typed: String, english: Bool) -> Request? {
        let b = before.precomposedStringWithCanonicalMapping
        let t = typed.precomposedStringWithCanonicalMapping
        var head: Substring
        if !t.isEmpty {
            guard t.count >= minTyped, t.allSatisfy(isWordChar), b.hasSuffix(t) else { return nil }
            head = b.dropLast(t.count)
            if let l = head.last, !(l == " " || l == "\t" || l == "\u{00A0}" || l.isNewline) { return nil }
        } else {
            guard b.hasSuffix(" ") else { return nil }
            head = b.dropLast()
            guard let l = head.last, isWordChar(l) else { return nil }   // hai dấu cách / sau dấu câu
        }
        // Lấy ngược ≤ 2 từ ngữ cảnh.
        var words: [String] = []
        var rest = head
        while words.count < 2 {
            if words.isEmpty, !t.isEmpty {
                // trước từ đang gõ: đúng một dấu cách (hoặc đầu văn bản ⇒ không ngữ cảnh)
                guard rest.last == " " else { break }
                rest = rest.dropLast()
            } else if !words.isEmpty {
                guard rest.last == " " else { break }
                rest = rest.dropLast()
            }
            var w = Substring()
            var i = rest.endIndex
            while i > rest.startIndex {
                let j = rest.index(before: i)
                guard isWordChar(rest[j]) else { break }
                i = j
            }
            w = rest[i...]
            guard !w.isEmpty, w.count <= 24 else { break }
            // chữ ngay trước từ phải là khoảng trắng / đầu văn bản ("a.b" không phải từ)
            if i > rest.startIndex {
                let c = rest[rest.index(before: i)]
                guard c == " " || c == "\t" || c == "\u{00A0}" || c.isNewline else {
                    break
                }
            }
            words.append(String(w).lowercased())
            rest = rest[..<i]
            if let c = rest.last, c.isNewline { break }
        }
        if t.isEmpty, words.isEmpty { return nil }
        return Request(typed: t, prev: words.first, prev2: words.count > 1 ? words[1] : nil, english: english)
    }

    /// Từ kế tiếp từ LM TĨNH chỉ khi có đủ HAI từ ngữ cảnh (dòng trigram mới có nghĩa) và không
    /// phải ngữ cảnh tiếng Anh. Mô hình còn đòi dòng trigram thật (`SuggestRank.topNext(...).trigram`).
    static func wantsNextWord(_ r: Request) -> Bool {
        r.typed.isEmpty && !r.english && r.prev != nil && r.prev2 != nil
    }

    /// Từ kế tiếp từ SEED (cặp curated của iOS — "cảm" → ơn, "xin" → lỗi/chào) chỉ cần MỘT từ
    /// ngữ cảnh: seed là dữ liệu chọn tay, không phải đoán bigram thống kê ("Tên ␣" vẫn không gì
    /// — "tên" không có seed). Ngữ cảnh tiếng Anh: chỉ giữ từ tiếng Anh (như iOS chế độ tiếng Anh).
    static func wantsSeedNext(_ r: Request) -> Bool { r.typed.isEmpty && r.prev != nil }

    /// Hoàn thành tiếng Anh khi: ngữ cảnh tiếng Anh, hoặc không âm tiết Việt nào khớp.
    static func wantsEnglish(_ r: Request, vietnameseHits: Int) -> Bool {
        r.english || vietnameseHits == 0
    }

    // Tiếng Anh giữa câu Việt (Phil 16/10/2026): phím thô là tiền tố tiếng Anh rõ ràng hơn mọi
    // cách đọc tiếng Việt ("ther" hiện "thẻ" → there? KHÔNG: "thẻ"/"thể" là âm tiết trọn vẹn).
    // Dò trên câu heldout (WordPredictionTests.testEnglishOverrideNeverFiresOnVietnamese): mọi
    // tiền tố ≥ 4 phím của âm tiết Việt gõ Telex + gõ không dấu — 0 lần bật nhầm.
    /// Phím thô tối thiểu (3 phím: "toi", "cam", "duoc"… quá nhập nhằng).
    static let englishMinRaw = 4
    /// Tần suất enlexicon tối thiểu của từ tiếng Anh đứng đầu (thang 0–255 chung với vnlexicon).
    static let englishMinFreq = 150
    /// Từ tiếng Anh phải hơn âm tiết Việt khớp phổ biến nhất bấy nhiêu.
    static let englishMargin = 80
    /// Chữ trên màn hình (bỏ qua dấu chưa gõ) đã là âm tiết Việt có tần suất ≥ chừng này ⇒ là
    /// tiếng Việt đang gõ ("thin" ~ thìn/thịn, "chan" ~ chán) — không bao giờ đổi sang tiếng Anh.
    static let englishMaxExact = 60

    /// Có gợi ý tiếng Anh dù ngữ cảnh Việt và vẫn có âm tiết Việt khớp không. `raw` = phím thô,
    /// `typed` = chữ trên màn hình, `pool` = VNSuggest.matches(typed) (đã bỏ chính typed),
    /// `typedFreq` = tần suất của chính typed nếu là âm tiết, `englishTop` = tần suất từ tiếng
    /// Anh hoàn thành đầu tiên của `raw` (nil = không có).
    static func prefersEnglish(raw: String, typed: String, pool: [(word: String, freq: Int)],
                               typedFreq: Int?, englishTop: Int?) -> Bool {
        guard raw.count >= englishMinRaw, raw.unicodeScalars.allSatisfy({ ($0.value | 0x20) >= 97 && ($0.value | 0x20) <= 122 }),
              let en = englishTop, en >= englishMinFreq else { return false }
        let n = typed.count
        var exact = typedFreq ?? -1, best = typedFreq ?? -1
        for m in pool {
            best = max(best, m.freq)
            if m.word.count == n { exact = max(exact, m.freq) }
        }
        return exact < englishMaxExact && en - best >= englishMargin
    }

    /// Ứng viên hoàn thành (đã xếp hạng) → tối đa `rankDepth`, chỉ từ DÀI HƠN chữ đã gõ
    /// (hoàn thành thật — biến thể chỉ khác dấu thì người gõ Telex tự gõ tiếp), bỏ trùng.
    static func completions(_ ranked: [String], typed: String) -> [String] {
        let n = typed.count
        var seen = Set<String>(), out: [String] = []
        for w in ranked where w.count > n {
            if seen.insert(w.lowercased()).inserted { out.append(w) }
            if out.count >= rankDepth { break }
        }
        return out
    }

    /// Ứng viên đã xếp hạng → gợi ý cạnh con trỏ (CHỈ hạng 1): thay đúng từ đang gõ
    /// (`typed` — "" = chỉ chèn) bằng ứng viên + dấu cách.
    static func suggestion(_ words: [String], typed: String) -> CaretSuggestion? {
        guard let first = words.first, !first.isEmpty else { return nil }
        return CaretSuggestion(kind: .predict, display: first, replace: typed, insert: first + " ")
    }

    // Dấu cách TỰ THÊM khi nhận gợi ý ("được␣"): phím NGAY SAU là dấu câu ⇒ dấu câu dính vào từ
    // ("được." không phải "được ."). Cùng luật iOS AutoSpace (SuggestionSupport.swift — iOS gỡ /
    // dời dấu cách TỰ THÊM sau dấu câu theo phím kế; ở đây là dấu cách tự thêm sau gợi ý):
    //   . , ? ! ; :  ⇒ gỡ dấu cách, chèn dấu câu, THÊM LẠI một dấu cách ("được. ");
    //   ngoặc / nháy ĐÓNG cong ) ] } ” ’ » ›  ⇒ như trên ("được) ");
    //   /            ⇒ chỉ gỡ ("và/");
    //   phím khác (chữ, dấu cách, ⌫, mũi tên, click…) ⇒ giữ nguyên, hết hiệu lực.
    // Nháy THẲNG " ' không tính: sau dấu cách thường là nháy MỞ của từ kế.
    enum AcceptSpace: Equatable { case keep, remove, carry }
    static let acceptClosers: Set<Character> = [")", "]", "}", "\u{201D}", "\u{2019}", "»", "›"]

    static func acceptSpaceReaction(_ s: String) -> AcceptSpace {
        guard s.count == 1, let c = s.first else { return .keep }
        if AutoSpace.triggers.contains(c) || acceptClosers.contains(c) { return .carry }
        return c == "/" ? .remove : .keep
    }

    /// Chữ thay cho dấu cách tự thêm (nil = giữ nguyên dấu cách, xử lý phím như thường).
    static func acceptSpaceReplacement(_ s: String) -> String? {
        switch acceptSpaceReaction(s) {
        case .keep: return nil
        case .remove: return s
        case .carry: return s + " "
        }
    }

    /// Esc trên gợi ý hoàn thành: không gợi ý lại khi từ đang gõ vẫn bắt đầu bằng chữ đã từ
    /// chối (tới từ kế tiếp).
    static func muted(typed: String, declined: String?) -> Bool {
        guard let d = declined, !d.isEmpty, !typed.isEmpty else { return false }
        return typed.lowercased().hasPrefix(d.lowercased())
    }
}

// MARK: - Mô hình (dữ liệu dùng chung với iOS)

/// Xếp hạng y như thanh gợi ý iOS của NGƯỜI DÙNG MỚI (UserLangModel chỉ có seed — SuggestRank,
/// cùng trọng số/lọc/hoa-thường):
///  • hoàn thành: `count` = đếm seed unigram, `ctx` = từ kế tiếp seed của từ trước (+4, LM nhân
///    damp — như iOS `Set(nextWords(after: prev, limit: 24))`);
///  • từ kế tiếp: = SuggestRank.nextFill(personal: seed) — có dòng trigram (prev2, prev) thì trigram
///    tĩnh trước rồi seed, không thì chỉ seed; không lùi bigram tĩnh.
/// KHÔNG liên kết UserLangModel (lưu file/di trú/codec: đo 16/10/2026 +~95 KB mỗi kiến trúc) hay
/// literal SeedData.bigrams: thứ tự seed đã được tính sẵn bằng chính mã iOS (SeedNextData).
/// CHỈ dùng trên hàng đợi nền của CaretHint (`work`, nối tiếp).
///
/// KHÔNG HỌC trên macOS (quyết định 16/10/2026): học cần nhận đúng từ đã chốt ở cả hai đường
/// (IMK + tap), loại ô mật khẩu/terminal/app tắt, lưu file + đồng bộ — rủi ro riêng tư/độ đúng
/// lớn hơn lợi ích ở bản đầu.
final class PredictionModel {
    static let shared = PredictionModel()

    private var seedStorage: [String: Int]?
    private var seed: [String: Int] {
        if let s = seedStorage { return s }
        let s = SeedData.unigrams
        seedStorage = s
        return s
    }

    /// Từ kế tiếp seed (SeedNextData — bảng sinh từ UserLangModel iOS chỉ có seed), nạp lười.
    private var seedNextStorage: [String: [String]]?
    private var seedNextTable: [String: [String]] {
        if let s = seedNextStorage { return s }
        let s = SeedNextData.table()
        seedNextStorage = s
        return s
    }

    var isLoaded: Bool { seedStorage != nil || seedNextStorage != nil }

    /// Cài đặt hệ thống tắt ⇒ bỏ bảng seed (lexicon/LM là mmap — trang sạch, hệ thống tự thu).
    func unload() { seedStorage = nil; seedNextStorage = nil }

    private func count(_ w: String) -> Int { seed[w] ?? seed[w.lowercased()] ?? 0 }

    /// = UserLangModel.nextWords(after: prev, limit: 24) của người dùng iOS mới (chưa lọc).
    func seedNext(_ prev: String) -> [String] { seedNextTable[prev.lowercased()] ?? [] }

    /// Ứng viên (đã chỉnh hoa/thường) cho lượt `r`; `raw` = phím thô của từ đang gõ;
    /// `filterSensitive` = "Lọc từ nhạy cảm" (AppState.filterSensitive — như công tắc iOS, mặc
    /// định BẬT: SensitiveWords.filter ở đúng các chỗ thanh gợi ý iOS lọc).
    func candidates(_ r: PredictionLogic.Request, raw: String, filterSensitive filterOn: Bool = true) -> [String] {
        if r.typed.isEmpty {
            // = SuggestRank.nextFill với người dùng iOS mới (`personal` = nextWords seed ≤ 6, đã
            // lọc): có dòng trigram (prev2, prev) ⇒ trigram tĩnh trước rồi seed; không ⇒ chỉ seed
            // — KHÔNG lùi bigram tĩnh ("Tên ␣" → không gì). Hạng 1 vì thế đúng hạng 1 của iOS.
            guard PredictionLogic.wantsSeedNext(r), let prev = r.prev else { return [] }
            var personal = SensitiveWords.filter(Array(seedNext(prev).prefix(6)), enabled: filterOn)
            if r.english { personal = personal.filter { EnglishLite.contains($0) } }
            var tri: [String] = []
            if PredictionLogic.wantsNextWord(r), let prev2 = r.prev2, VNSuggest.lexiconId(of: prev) != nil,
               let top = SuggestRank.topNext(prev, prev2: prev2, limit: 6), top.trigram {
                tri = SensitiveWords.filter(top.words, enabled: filterOn)
            }
            let next = SuggestionFill.pad([], with: tri + personal, need: PredictionLogic.rankDepth)
            return next.map { DisplayCase.apply($0, after: prev) }
        }
        let typed = r.typed
        let pool = r.english ? [] : VNSuggest.matches(typed, poolLimit: 24, excluding: typed.lowercased())
        var english = PredictionLogic.wantsEnglish(r, vietnameseHits: pool.count)
        if !english, !raw.isEmpty {
            english = PredictionLogic.prefersEnglish(
                raw: raw, typed: typed, pool: pool.map { ($0.word, $0.freq) },
                typedFreq: VNSuggest.frequency(of: typed),
                englishTop: EnglishLite.completions(raw, limit: 1).first?.freq)
        }
        if !english {
            let pmi = SuggestRank.inlinePmi(pool, prev: r.prev, prev2: r.prev2)
            // ctx = nextWords seed của từ trước (iOS: Set(nextWords(after: prev, limit: 24))) ⇒
            // +4 cho ứng viên seed, LM nhân bigramDamp — cùng hợp đồng tầng 2/7.
            let ctx = r.prev.map { Set(seedNext($0)) } ?? []
            let ranked = SensitiveWords.filter(
                SuggestRank.rankInline(pool, pmi: pmi, typedLen: typed.count, count: count, ctx: ctx),
                enabled: filterOn)
            return PredictionLogic.completions(ranked, typed: typed).map {
                SuggestionCase.display(DisplayCase.apply($0, after: r.prev), shift: .off, typed: typed)
            }
        }
        // Tiếng Anh: phím thô (a–z) — "this" có thể đang hiện "thí" sau Telex.
        let key = raw.isEmpty ? typed : raw
        let src = key.count >= PredictionLogic.minTyped ? key : typed
        let en = SensitiveWords.filter(EnglishLite.completions(src, limit: 24).map(\.word), enabled: filterOn)
        return PredictionLogic.completions(en, typed: typed.count >= src.count ? typed : src)
    }
}
