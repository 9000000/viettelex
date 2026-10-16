// SelfTest.swift — `viettelex-text-tool --self-test <iOS/KeyboardTests/Fixtures>` (ctest
// caret_suggest): các ca của macOS AppTests/CaretSuggestionsTests.swift + MathHintTests.swift
// (fixture chung math-results.txt / number-chips.txt) chạy trên bản Linux của logic
// (CaretSuggest.swift) và giao thức --serve (Serve.swift). Trả số ca lệch.
import Foundation
import TelexCore

func caretSelfTest(fixtures: String) -> Int {
    var bad = 0, n = 0
    func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        n += 1
        if !ok { bad += 1; print("LỆCH: \(what())") }
    }
    func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) { check(a == b, "\(what): «\(a)» ≠ «\(b)»") }
    func S(_ k: CaretSuggestion.Kind, _ d: String, _ r: String, _ i: String) -> CaretSuggestion {
        CaretSuggestion(kind: k, display: d, replace: r, insert: i)
    }
    func lines(_ name: String) -> [[String]] {
        readFixture(fixtures + "/" + name).map {
            $0.split(separator: "|", omittingEmptySubsequences: false).map { String($0).replacingOccurrences(of: "␣", with: " ") }
        }
    }

    // MARK: Phép tính (MathHintTests)
    var m = 0
    for c in lines("math-results.txt") where c.first == "chip" && c.count == 3 {
        eq(CaretHintLogic.mathResult(beforeCaret: c[1]) ?? "-", c[2], "math chip «\(c[1])»"); m += 1
    }
    check(m > 10, "math-results: chỉ \(m) ca chip")
    eq(CaretHintLogic.mathResult(beforeCaret: "12*3="), "36", "12*3=")
    eq(CaretHintLogic.mathResult(beforeCaret: "giá 200+10%="), "220", "200+10%=")
    eq(CaretHintLogic.mathResult(beforeCaret: "125 x (4 + 5.5) ="), "1187.5", "125 x (4 + 5.5) =")
    eq(CaretHintLogic.mathResult(beforeCaret: "a=b"), nil, "a=b")
    eq(CaretHintLogic.mathResult(beforeCaret: "x = 5"), nil, "x = 5")
    eq(CaretHintLogic.mathResult(beforeCaret: "12*3"), nil, "chưa có =")
    eq(CaretHintLogic.math(before: "12*3="), S(.math, "= 36", "", "36"), "math suggestion")

    // MARK: Chip số — chỉ dạng tiền (fixture chung, bỏ đọc chữ)
    var k = 0
    for c in lines("number-chips.txt") where c.first == "chip" && (c.count == 3 || c.count == 5) {
        var ctx = c[1], sp = ""
        if !ctx.hasSuffix(" ") { ctx += " "; sp = " " }
        let want: CaretSuggestion? = c.count == 5 && CaretHintLogic.isMoneyFormat(c[2])
            ? S(.number, c[2], c[3] + sp, c[4] + sp) : nil
        eq(CaretHintLogic.moneyChip(before: ctx), want, "money «\(ctx)»"); k += 1
    }
    check(k > 20, "number-chips: chỉ \(k) ca chip")
    eq(CaretHintLogic.moneyChip(before: "giá 1tr2 ")?.display, "1.200.000 ₫", "1tr2")
    eq(CaretHintLogic.moneyChip(before: "giá 1tr2"), nil, "chưa có dấu cách")
    eq(CaretHintLogic.moneyChip(before: "1250000 "), nil, "đọc chữ: bỏ")
    check(CaretHintLogic.numberWorthChecking(boundary: " ", run: "1tr2", prevRun: ""), "worth 1tr2")
    check(CaretHintLogic.numberWorthChecking(boundary: " ", run: "tỷ", prevRun: "2"), "worth 2 tỷ")
    check(!CaretHintLogic.numberWorthChecking(boundary: ",", run: "50k", prevRun: ""), "worth , ")
    check(!CaretHintLogic.numberWorthChecking(boundary: " ", run: "hello", prevRun: "word"), "worth chữ")

    // MARK: Sửa lỗi gõ sai (CaretSuggestionsTests)
    typealias T = TypoFixLogic
    check(T.worthChecking(boundary: " ", raw: "tpoi", word: "tpoi"), "gate space")
    check(T.worthChecking(boundary: ",", raw: "tpoi", word: "tpoi"), "gate ,")
    check(!T.worthChecking(boundary: ".", raw: "tpoi", word: "tpoi"), "gate .")
    check(!T.worthChecking(boundary: "'", raw: "tpoi", word: "tpoi"), "gate '")
    check(!T.worthChecking(boundary: "\n", raw: "tpoi", word: "tpoi"), "gate Enter")
    check(!T.worthChecking(boundary: " ", raw: "tooi", word: "tôi"), "gate âm tiết hợp lệ")
    check(!T.worthChecking(boundary: " ", raw: "kp", word: "kp"), "gate ngắn")
    check(!T.worthChecking(boundary: " ", raw: "tp1i", word: "tp1i"), "gate số")
    check(!T.worthChecking(boundary: " ", raw: "tpoi", word: "(tpoi"), "gate ký hiệu")

    let flags = T.EngineFlags()
    func fix(_ raw: String) -> String? { T.lexiconCorrection(raw: raw, flags: flags) }
    eq(fix("tpoi"), "tôi", "fix tpoi")
    eq(fix("Tpoi"), "Tôi", "fix Tpoi")
    eq(fix("khoong"), nil, "fix khoong")
    eq(fix("khpong"), "không", "fix khpong")
    eq(fix("nhuwng"), nil, "fix nhuwng")
    eq(fix("github"), nil, "fix github")
    eq(fix("hello"), nil, "fix hello")
    eq(fix("toi"), nil, "fix toi")
    eq(fix("tooi"), nil, "fix tooi")
    check(T.isKnown("the"), "known the")
    check(!T.isKnown("tpoi"), "known tpoi")
    eq(T.EngineFlags(bits: "1010000110"), T.EngineFlags(), "flags mặc định")
    check(T.EngineFlags(bits: "0000010000").vniMode, "flags vni")

    typealias C = T.Cand
    let p = T.Params(minLen: 3, minFreq: 150, margin: 80, edits: [.sub, .swap], rivals: [.del, .ins])
    eq(T.pick([C(word: "tôi", freq: 255, edit: .sub)], p: p)?.word, "tôi", "pick một")
    eq(T.pick([C(word: "tôi", freq: 140, edit: .sub)], p: p), nil, "pick hiếm")
    eq(T.pick([C(word: "tôi", freq: 255, edit: .sub), C(word: "tới", freq: 200, edit: .sub)], p: p), nil, "pick sát nút")
    eq(T.pick([C(word: "tội", freq: 175, edit: .sub), C(word: "tôi", freq: 255, edit: .del)], p: p), nil, "pick đối thủ")
    eq(T.pick([C(word: "tôi", freq: 255, edit: .sub), C(word: "tối", freq: 150, edit: .ins)], p: p)?.word, "tôi", "pick margin")

    eq(T.suggestion(before: "anh tpoi,", word: "tpoi", boundary: ",", raw: "tpoi", fix: "tôi"),
       S(.typo, "tôi", "tpoi,", "tôi,"), "typo giữ ranh giới")
    eq(T.suggestion(before: "anh xtpoi ", word: "tpoi", boundary: " ", raw: "tpoi", fix: "tôi"), nil, "typo dính")
    eq(T.suggestion(before: "anh tpoi", word: "tpoi", boundary: " ", raw: "tpoi", fix: "tôi"), nil, "typo lệch")
    check(T.suggestion(before: "Xong. Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi") != nil, "typo hoa đầu câu")
    check(T.suggestion(before: "Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi") != nil, "typo đầu văn bản")
    eq(T.suggestion(before: "gặp Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi"), nil, "typo tên riêng")
    eq(T.suggestion(before: "\u{FFFC}Tpoi ", word: "Tpoi", boundary: " ", raw: "Tpoi", fix: "Tôi"), nil, "typo chưa neo")

    // MARK: Thêm dấu cho cụm không dấu
    func feed(_ t: inout ToneRunLogic.Tracker, _ text: String) -> [ToneRunLogic.Trigger?] {
        var out: [ToneRunLogic.Trigger?] = []
        var chunk = ""
        for ch in text {
            if ch.isLetter || ch.isNumber { chunk.append(ch); continue }
            out.append(t.feed(chunk: chunk, boundary: String(ch)))
            chunk = ch.isWhitespace ? "" : chunk + String(ch)
        }
        return out
    }
    var tr = ToneRunLogic.Tracker()
    eq(feed(&tr, "toi di hoc "), [nil, nil, .pause], "tracker 1")
    eq(feed(&tr, "hom nay "), [.pause, .pause], "tracker 2")
    tr.reset(); eq(feed(&tr, "toi di hoc."), [nil, nil, .sentenceEnd], "tracker .")
    eq(feed(&tr, " roi "), [nil, nil], "tracker câu mới")
    tr.reset(); eq(feed(&tr, "toi, di hoc "), [nil, nil, nil, .pause], "tracker ,")
    tr.reset(); eq(feed(&tr, "tôi di hoc "), [nil, nil, nil], "tracker có dấu")
    tr.reset(); eq(feed(&tr, "the cat is "), [nil, nil, nil], "tracker Anh")
    tr.reset(); eq(feed(&tr, "toi di\nhoc "), [nil, nil, nil], "tracker xuống dòng")
    tr.reset(); eq(feed(&tr, "a b "), [nil, nil], "tracker ngắn")
    for (c, want) in [("toi", true), ("hoc", true), ("toi,", true), ("Toi", true), ("TOI", true), ("tOi", false),
                      ("the", false), ("tôi", false), ("abcdefgh", false), ("", false), ("hoc.", true)] {
        eq(ToneRunLogic.isUnaccentedSyllable(Substring(c)), want, "unaccented «\(c)»")
    }

    eq(ToneRunLogic.run(before: "toi di hoc "), "toi di hoc ", "run 1")
    eq(ToneRunLogic.run(before: "Chiều nào toi di hoc hom nay "), "toi di hoc hom nay ", "run 2")
    eq(ToneRunLogic.run(before: "Xong. toi di hoc."), "toi di hoc.", "run 3")
    eq(ToneRunLogic.run(before: "xin chao ban. toi di hoc "), "toi di hoc ", "run câu trước")
    eq(ToneRunLogic.run(before: "dong 1\ntoi di hoc "), "toi di hoc ", "run dòng")
    eq(ToneRunLogic.run(before: "toi di "), nil, "run ngắn")
    eq(ToneRunLogic.run(before: "tôi đi học "), nil, "run có dấu")
    eq(ToneRunLogic.run(before: "open the file "), nil, "run Anh")

    let run = "toi di hoc "
    let restored = apply(.addTones, run)
    eq(restored, "tôi đi học ", "addTones")
    eq(ToneRunLogic.suggestion(run: run, restored: restored ?? ""), S(.tones, "tôi đi học", run, "tôi đi học "), "tones sugg")
    eq(ToneRunLogic.suggestion(run: run, restored: run), nil, "tones không đổi")
    eq(ToneRunLogic.suggestion(run: run, restored: "tôi"), nil, "tones lệch độ dài")

    // MARK: Ngày giờ
    let en: (String) -> Bool = T.isEnglish
    typealias D = DateHintLogic
    eq(D.detect(boundary: " ", prevRun: "hôm", run: "nay", isEnglish: en), .today, "date hôm nay")
    eq(D.detect(boundary: " ", prevRun: "Hôm", run: "qua", isEnglish: en), .yesterday, "date Hôm qua")
    eq(D.detect(boundary: " ", prevRun: "ngày", run: "mai", isEnglish: en), .tomorrow, "date ngày mai")
    eq(D.detect(boundary: " ", prevRun: "bây", run: "giờ", isEnglish: en), .now, "date bây giờ")
    eq(D.detect(boundary: " ", prevRun: "you", run: "tomorrow", isEnglish: en), .tomorrow, "date you tomorrow")
    eq(D.detect(boundary: " ", prevRun: "right", run: "now", isEnglish: en), .now, "date right now")
    eq(D.detect(boundary: " ", prevRun: "", run: "now", isEnglish: en), nil, "date now trơn")
    eq(D.detect(boundary: " ", prevRun: "gặp", run: "today", isEnglish: en), nil, "date gặp today")
    eq(D.detect(boundary: ",", prevRun: "hôm", run: "nay", isEnglish: en), nil, "date ,")
    eq(D.detect(boundary: " ", prevRun: "hom", run: "nay", isEnglish: en), nil, "date không dấu")
    eq(D.detect(boundary: " ", prevRun: "hôm", run: "sau", isEnglish: en), nil, "date hôm sau")

    let now = D.LocalTime(year: 2026, month: 9, day: 28, hour: 21, minute: 35)
    eq(D.format(.today, now: now), "28/09/2026", "format today")
    eq(D.format(.tomorrow, now: now), "29/09/2026", "format tomorrow")
    eq(D.format(.yesterday, now: now), "27/09/2026", "format yesterday")
    eq(D.format(.now, now: now), "21:35", "format now")
    eq(D.format(.tomorrow, now: .init(year: 2026, month: 12, day: 31, hour: 0, minute: 5)), "01/01/2027", "qua năm")
    eq(D.format(.yesterday, now: .init(year: 2028, month: 3, day: 1, hour: 9, minute: 0)), "29/02/2028", "năm nhuận")
    eq(D.format(.now, now: .init(year: 2026, month: 1, day: 1, hour: 7, minute: 4)), "07:04", "giờ 2 chữ số")

    eq(D.suggestion(before: "Hẹn hôm nay ", prevRun: "hôm", run: "nay", phrase: .today, now: now),
       S(.date, "28/09/2026", "hôm nay ", "28/09/2026 "), "date sugg")
    eq(D.suggestion(before: "bây giờ ", prevRun: "bây", run: "giờ", phrase: .now, now: now)?.insert, "21:35 ", "date giờ")
    eq(D.suggestion(before: "see you tomorrow ", prevRun: "you", run: "tomorrow", phrase: .tomorrow, now: now)?.replace,
       "tomorrow ", "date Anh")
    eq(D.suggestion(before: "xhôm nay ", prevRun: "hôm", run: "nay", phrase: .today, now: now), nil, "date dính")
    eq(D.suggestion(before: "hôm nay", prevRun: "hôm", run: "nay", phrase: .today, now: now), nil, "date lệch")

    // MARK: Giao thức --serve
    eq(HintProtocol.unescape(Substring(HintProtocol.escape("a\tb\nc\\d\re"))), "a\tb\nc\\d\re", "escape")
    eq(HintProtocol.handle("ping"), "ok", "ping")
    eq(HintProtocol.handle("math\t12*3="), "math\t= 36\t\t36", "serve math")
    eq(HintProtocol.handle("math\tabc"), "-", "serve math không")
    eq(HintProtocol.handle("number\tgiá 1tr2 "), "number\t1.200.000 ₫\t1tr2 \t1.200.000 ₫ ", "serve number")
    eq(HintProtocol.handle("date\tHẹn hôm nay \thôm\tnay\t \t2026\t9\t28\t21\t35"),
       "date\t28/09/2026\thôm nay \t28/09/2026 ", "serve date")
    eq(HintProtocol.handle("date\tnay \t\tnay\t \t2026\t9\t28\t21\t35"), "-", "serve date không")
    eq(HintProtocol.handle("typo\tanh tpoi \ttpoi\t \ttpoi\t1010000110"), "typo\ttôi\ttpoi \ttôi ", "serve typo")
    eq(HintProtocol.handle("typo\tgithub \tgithub\t \tgithub\t1010000110"), "-", "serve typo Anh")
    eq(HintProtocol.handle("tones\txin chao ban. toi di hoc "), "tones\ttôi đi học\ttoi di hoc \ttôi đi học ", "serve tones")
    eq(HintProtocol.handle("tones\ttoi di "), "-", "serve tones ngắn")
    eq(HintProtocol.handle("tones\tdong 1\\ntoi di hoc "), "tones\ttôi đi học\ttoi di hoc \ttôi đi học ", "serve tones \\n")
    eq(HintProtocol.handle("lạ\tx"), "-", "serve lệnh lạ")
    eq(HintProtocol.handle(""), "-", "serve rỗng")

    // MARK: Gợi ý từ (macOS AppTests/WordPredictionTests — Predict.swift)
    typealias L = PredictionLogic
    typealias R = PredictionLogic.Request
    eq(L.request(before: "xin chào bạn đư", typed: "đư", english: false),
       R(typed: "đư", prev: "bạn", prev2: "chào", english: false), "request đang gõ")
    eq(L.request(before: "đư", typed: "đư", english: false), R(typed: "đư", prev: nil, prev2: nil, english: false),
       "request đầu văn bản")
    eq(L.request(before: "abc.đư", typed: "đư", english: false), nil, "request không đứng riêng")
    eq(L.request(before: "chào đ", typed: "đ", english: false), nil, "request 1 chữ")
    eq(L.request(before: "chào đư", typed: "đươ", english: false), nil, "request lệch")
    eq(L.request(before: "a1", typed: "a1", english: false), nil, "request số")
    eq(L.request(before: "\u{FFFC}đư", typed: "đư", english: false), nil, "request chưa neo")
    eq(L.request(before: "cảm ", typed: "", english: false), R(typed: "", prev: "cảm", prev2: nil, english: false),
       "request từ kế tiếp")
    eq(L.request(before: "Tôi Đang ", typed: "", english: false)?.prev, "đang", "request chữ thường")
    eq(L.request(before: "Tôi Đang ", typed: "", english: false)?.prev2, "tôi", "request prev2")
    eq(L.request(before: "xin chào, bạn ", typed: "", english: false),
       R(typed: "", prev: "bạn", prev2: nil, english: false), "request dấu phẩy cắt")
    eq(L.request(before: "dòng một\nđi ", typed: "", english: false)?.prev2, nil, "request xuống dòng cắt")
    for b in ["hai  ", "xong. ", " ", "", "a.b "] {
        eq(L.request(before: b, typed: "", english: false), nil, "request không «\(b)»")
    }
    check(L.muted(typed: "đươ", declined: "đư"), "muted tiền tố")
    check(L.muted(typed: "Đư", declined: "đư"), "muted hoa")
    check(!L.muted(typed: "đa", declined: "đư"), "muted khác")
    check(!L.muted(typed: "", declined: "đư"), "muted rỗng")
    check(!L.muted(typed: "đư", declined: nil), "muted nil")

    func cands(_ before: String, typed: String = "", raw: String = "", english: Bool = false,
               filter: Bool = true) -> [String] {
        guard let r = L.request(before: before, typed: typed, english: english) else { return [] }
        return PredictionModel.shared.candidates(r, raw: raw, filterSensitive: filter)
    }
    // Từ kế tiếp: dòng trigram 2 từ, hoặc seed iOS với một từ (= WordPredictionTests macOS).
    eq(cands("Tên "), [], "next một từ ngữ cảnh, không seed: không")
    eq(cands("cảm ").first, "ơn", "next seed cảm → ơn")
    eq(cands("xin ").first, "lỗi", "next seed xin → lỗi")
    eq(cands("zzqx cảm ").first, "ơn", "next seed không trigram")
    eq(cands("nguyễn ").first, "Văn", "next seed DisplayCase")
    eq(cands("good ", english: true).first, "morning", "next seed tiếng Anh")
    eq(cands("anh ", english: true), [], "next seed Việt trong ngữ cảnh Anh: không")
    eq(cands("xong, tên "), [], "next dấu phẩy cắt: không")
    eq(cands("zzqx tên "), [], "next cặp không trigram, không seed: không")
    eq(cands("vãi ").first, "cả", "lọc nhạy cảm bật")
    eq(cands("vãi ", filter: false).first, "lồn", "lọc nhạy cảm tắt")
    eq(cands("ngon "), [], "lọc bật: seed chỉ có từ nhạy cảm")
    eq(cands("ngon ", filter: false).first, "vl", "lọc tắt")
    // Tiếng Anh giữa câu Việt (prefersEnglish) — và nơi không được bật.
    eq(cands("tôi gặp pé", typed: "pé", raw: "pers").first, "person", "en override pers")
    eq(cands("ưởn", typed: "ưởn", raw: "wron").first, "wrong", "en override wron")
    for (t, raw) in [("toi", "toi"), ("duoc", "duoc"), ("cam", "cam"), ("thẻ", "ther"), ("thin", "thin"), ("chan", "chan")] {
        let c = cands("anh " + t, typed: t, raw: raw)
        check(!c.contains { SwipeEnglish.contains($0.lowercased()) && !VNSuggest.contains($0) }, "en override không «\(raw)»: \(c)")
    }
    // Sửa lỗi gõ tiếng Anh (= CaretSuggestionsTests macOS).
    let fx: (String) -> String? = { TypoFixLogic.lexiconCorrection(raw: $0, flags: .init()) }
    eq(fx("spellnig"), "spelling", "typo en spellnig")
    eq(fx("teh"), "the", "typo en teh")
    eq(fx("becuase"), "because", "typo en becuase")
    eq(fx("goverment"), "government", "typo en goverment")
    eq(fx("hte"), nil, "typo en hte (he sát nút)")
    eq(fx("tpoi"), "tôi", "typo vi vẫn trước")
    eq(TypoFixLogic.correction(raw: "shjt", compose: { $0 }, frequency: { _ in nil }, hasCompletion: { _ in false },
                               isKnown: { _ in false }, englishFrequency: { $0 == "shit" ? 200 : nil }), nil, "typo lọc bật")
    eq(TypoFixLogic.correction(raw: "shjt", compose: { $0 }, frequency: { _ in nil }, hasCompletion: { _ in false },
                               isKnown: { _ in false }, englishFrequency: { $0 == "shit" ? 200 : nil },
                               filterSensitive: false), "shit", "typo lọc tắt")
    check(!cands("cảm ơn ").isEmpty, "next cảm ơn: có")
    check(!cands("xin chào ").isEmpty, "next xin chào: có")
    check(cands("hôm nay ").count <= L.rankDepth, "next ≤ rankDepth")
    eq(cands("hello world ", english: true), [], "next tiếng Anh: không")
    eq(cands("zzqx zzqy "), [], "next từ lạ")
    let ho = cands("thành phố hồ ")
    check(!ho.contains("chí") && ho.first == "Chí", "display case hồ: \(ho)")
    let du = cands("tôi đư", typed: "đư", raw: "dduw")
    check(du.contains("được"), "complete đư: \(du)")
    check(du.count <= L.rankDepth && du.allSatisfy { $0.count > 2 }, "complete thật: \(du)")
    let up = cands("Đư", typed: "Đư", raw: "Dduw")
    check(!up.isEmpty && up.allSatisfy { $0.first?.isUppercase == true }, "complete hoa: \(up)")
    eq(cands("cảm ơ", typed: "ơ", raw: "ow"), [], "complete 1 chữ")
    eq(cands("xin ch", typed: "ch", raw: "ch").first, "chào", "complete xin ch")
    check(cands("my keyb", typed: "keyb", raw: "keyb").contains("keyboard"), "complete keyb")
    check(cands("this is beca", typed: "beca", raw: "beca", english: true).contains("because"), "complete beca")
    let thi = cands("thí", typed: "thí", raw: "this", english: true)
    check(thi.allSatisfy { $0.hasPrefix("this") && $0.count > 4 }, "complete phím thô: \(thi)")
    for (b, t) in [("đị", "đị"), ("đi", "đi"), ("fu", "fu"), ("sh", "sh"), ("vc", "vc")] {
        let c = cands(b, typed: t, raw: t)
        check(c.allSatisfy { !SensitiveWords.set.contains($0.lowercased()) }, "nhạy cảm «\(t)»: \(c)")
    }
    eq(L.answer(["được", "đường", "đưa", "đứng"], typed: "đư"), "predict\tđược\tđư\tđược ", "answer: chỉ hạng 1")
    eq(L.answer(["ơn"], typed: ""), "predict\tơn\t\tơn ", "answer từ kế tiếp")
    eq(L.answer([], typed: "x"), "-", "answer rỗng")
    eq(HintProtocol.handle("predict\tTên \t\t\t0"), "-", "serve predict một từ không seed: không")
    eq(HintProtocol.handle("predict\tcảm \t\t\t0"), "predict\tơn\t\tơn ", "serve predict seed")
    eq(HintProtocol.handle("predict\tvãi \t\t\t0\t0"), "predict\tlồn\t\tlồn ", "serve predict lọc tắt")
    eq(HintProtocol.handle("predict\tvãi \t\t\t0\t1"), "predict\tcả\t\tcả ", "serve predict lọc bật")
    eq(HintProtocol.handle("predict\tthành phố hồ \t\t\t0"), "predict\tChí\t\tChí ", "serve predict next")
    eq(HintProtocol.handle("predict\tabc.đư\tđư\tdduw\t0"), "-", "serve predict không")
    // Đo (in ra để báo cáo): thời gian một lượt đã nạp.
    let reqs: [(String, String, String)] = [("cảm ơn ", "", ""), ("xin chào ", "", ""), ("tôi đang ", "", ""), ("hôm nay ", "", ""),
                                            ("tôi đư", "đư", "dduw"), ("xin ch", "ch", "ch"), ("ng", "ng", "ng"),
                                            ("my keyb", "keyb", "keyb"), ("khô", "khô", "khoo")]
    let clock = ContinuousClock()
    var worst = Duration.zero
    let t0 = clock.now
    for _ in 0..<50 {
        for (b, t, raw) in reqs {
            let a = clock.now
            _ = cands(b, typed: t, raw: raw)
            worst = max(worst, clock.now - a)
        }
    }
    let total = clock.now - t0
    let avgUs = Double(total.components.attoseconds / 1_000_000_000_000 + total.components.seconds * 1_000_000)
        / Double(50 * reqs.count)
    let worstUs = worst.components.attoseconds / 1_000_000_000_000 + worst.components.seconds * 1_000_000
    print("PREDICT per-request avg \(Int(avgUs)) µs, worst \(worstUs) µs (\(50 * reqs.count) requests)")
    check(avgUs < 3000, "predict avg \(avgUs) µs")

    print("caret-suggest: \(n) ca, lệch: \(bad)")
    return bad
}
