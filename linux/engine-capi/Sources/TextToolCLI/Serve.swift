// Serve.swift — `viettelex-text-tool --serve`: process con SỐNG LÂU cho gợi ý cạnh con trỏ
// (linux/common/src/caret_hints.cpp là phía bộ gõ). Một process mỗi process IME, chỉ khởi
// động khi có điểm kích hoạt đầu tiên, tự thoát sau `idleSeconds` không có yêu cầu hoặc khi
// stdin đóng (bộ gõ thoát) — không tốn gì khi không gõ. Dữ liệu (vnlexicon, enlexicon, vnlm
// khi Thêm dấu) chỉ sống ở đây, không bao giờ trong process IME.
//
// Giao thức: một dòng mỗi yêu cầu, một dòng mỗi trả lời, trường cách nhau bằng TAB; trong
// trường `\` `TAB` `LF` `CR` được viết `\\` `\t` `\n` `\r`.
//   ping                                                      → ok
//   math    <before>                                          (before kết thúc bằng "=")
//   number  <before>                                          (before kết thúc bằng " ")
//   date    <before> <prevRun> <run> <boundary> <Y> <M> <D> <h> <m>
//   typo    <before> <word> <boundary> <raw> <flags 10×0/1> [<filter 0|1>]
//   tones   <before>
//   predict <before> <typed> <raw> <english 0|1> [<filter 0|1>]  (gợi ý từ — Predict.swift)
// `filter` = [general] filter_sensitive ("Lọc từ nhạy cảm"); thiếu ⇒ 1 (bật, như iOS).
// Trả lời: `-` (không gợi ý) hoặc `<kind> <display> <replace> <insert>` (predict: một ứng viên).
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum HintProtocol {
    static func escape(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "\\": o += "\\\\"
            case "\t": o += "\\t"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            default: o.unicodeScalars.append(u)
            }
        }
        return o
    }

    static func unescape(_ s: Substring) -> String {
        var o = String.UnicodeScalarView()
        var it = s.unicodeScalars.makeIterator()
        while let u = it.next() {
            guard u == "\\", let n = it.next() else { o.append(u); continue }
            switch n {
            case "t": o.append("\t")
            case "n": o.append("\n")
            case "r": o.append("\r")
            default: o.append(n)
            }
        }
        return String(o)
    }

    static func fields(_ line: String) -> [String] {
        line.split(separator: "\t", omittingEmptySubsequences: false).map(unescape)
    }

    static func answer(_ s: CaretSuggestion?) -> String {
        guard let s else { return "-" }
        return [s.kind.rawValue, s.display, s.replace, s.insert].map(escape).joined(separator: "\t")
    }

    /// Một yêu cầu → một dòng trả lời (không có "\n").
    static func handle(_ line: String) -> String {
        let f = fields(line)
        guard let cmd = f.first else { return "-" }
        func at(_ i: Int) -> String { i < f.count ? f[i] : "" }
        func filterAt(_ i: Int) -> Bool { at(i) != "0" }
        let before = at(1)
        guard before.utf16.count <= 4096 else { return "-" }
        switch cmd {
        case "ping":
            return "ok"
        case "math":
            return answer(CaretHintLogic.math(before: before))
        case "number":
            return answer(CaretHintLogic.moneyChip(before: before))
        case "date":
            let prevRun = at(2), run = at(3), boundary = at(4)
            guard let y = Int(at(5)), let mo = Int(at(6)), let d = Int(at(7)), let h = Int(at(8)), let mi = Int(at(9)),
                  (1...12).contains(mo), (1...31).contains(d),
                  let phrase = DateHintLogic.detect(boundary: boundary, prevRun: prevRun, run: run,
                                                    isEnglish: TypoFixLogic.isEnglish) else { return "-" }
            let t = DateHintLogic.LocalTime(year: y, month: mo, day: d, hour: h, minute: mi)
            return answer(DateHintLogic.suggestion(before: before, prevRun: prevRun, run: run, phrase: phrase, now: t))
        case "typo":
            let word = at(2), boundary = at(3), raw = at(4)
            guard TypoFixLogic.worthChecking(boundary: boundary, raw: raw, word: word),
                  VTDataFile.url("vnlexicon.bin") != nil,
                  let fix = TypoFixLogic.lexiconCorrection(raw: raw, flags: .init(bits: at(5)),
                                                           filterSensitive: filterAt(6)) else { return "-" }
            return answer(TypoFixLogic.suggestion(before: before, word: word, boundary: boundary, raw: raw, fix: fix))
        case "predict":
            return predictAnswer(before: before, typed: at(2), raw: at(3), english: at(4) == "1",
                                 filterSensitive: filterAt(5))
        case "tones":
            guard let run = ToneRunLogic.run(before: before),
                  let restored = apply(.addTones, run) else { return "-" }
            return answer(CaretHintLogic.standsAlone(before: before, token: run)
                          ? ToneRunLogic.suggestion(run: run, restored: restored) : nil)
        default:
            return "-"
        }
    }
}

/// Vòng lặp --serve: đọc stdin theo dòng (poll có hạn giờ), trả lời ngay từng dòng.
func serve(idleSeconds: Int32 = 120) -> Never {
    var pending: [UInt8] = []
    var buf = [UInt8](repeating: 0, count: 16384)
    while true {
        var p = pollfd(fd: 0, events: Int16(POLLIN), revents: 0)
        let r = poll(&p, 1, idleSeconds * 1000)
        if r < 0 { if errno == EINTR { continue }; exit(0) }
        if r == 0 { exit(0) }                             // rảnh lâu: nhường RAM, bộ gõ mở lại khi cần
        let n = buf.withUnsafeMutableBytes { read(0, $0.baseAddress, $0.count) }
        if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; exit(0) }
        if n == 0 { exit(0) }                             // bộ gõ đóng ống
        pending.append(contentsOf: buf[0..<n])
        if pending.count > 1 << 20 { exit(2) }
        while let nl = pending.firstIndex(of: 10) {
            let line = String(decoding: pending[..<nl], as: UTF8.self)
            pending.removeSubrange(...nl)
            writeAll(1, HintProtocol.handle(line) + "\n")
        }
    }
}
