import XCTest

/// Emoji từ khoá tiếng Anh (CLDR en → section SKEN của emoji.bin) + cờ theo mã ISO in hoa
/// (FLG2) — song sinh Android EmojiEnglishTests. Tiếng Việt không đổi: "Nhật Bản" vẫn → 🇯🇵
/// khi tìm, âm tiết Việt không dấu không tự dưng có emoji trên thanh gợi ý.
final class EmojiEnglishTests: XCTestCase {

    private func t(_ word: String, prev: String? = nil, raw: String? = nil) -> [String] {
        EmojiSearch.typing(prev: prev, composed: word, raw: raw ?? word)
    }

    func testEnglishWordsAndCountryNames() {
        XCTAssertEqual(t("Japan").first, "🇯🇵")
        XCTAssertEqual(t("japan").first, "🇯🇵")
        XCTAssertEqual(t("pizza").first, "🍕")
        XCTAssertEqual(t("dog").first, "🐕")
        XCTAssertTrue(EmojiSearch.search("heart").prefix(3).contains("❤️"))
        XCTAssertEqual(t("states", prev: "United").first, "🇺🇸")
        XCTAssertEqual(t("dog", prev: "hot").first, "🌭")
        XCTAssertEqual(t("Vietnam").first, "🇻🇳")
        XCTAssertTrue(t("zzqxj").isEmpty)
        // quá chung ("flag" = 270 cờ, "face") → không gợi ý khi gõ (ô tìm vẫn ra)
        XCTAssertTrue(t("flag").isEmpty)
        XCTAssertTrue(t("face").isEmpty)
        XCTAssertGreaterThan(EmojiSearch.search("flag").count, 20)
    }

    func testIsoCodesOnlyUppercase() {
        XCTAssertEqual(t("JP"), ["🇯🇵"])
        XCTAssertEqual(t("US"), ["🇺🇸"])
        XCTAssertEqual(t("VN"), ["🇻🇳"])
        XCTAssertEqual(t("KR"), ["🇰🇷"])
        XCTAssertEqual(t("UK"), ["🇬🇧"])
        XCTAssertTrue(t("jp").isEmpty)
        XCTAssertTrue(t("Jp").isEmpty)
        XCTAssertTrue(t("XX").isEmpty)
        XCTAssertTrue(t("JP", raw: "JPP").isEmpty)   // Telex biến đổi → không coi là mã
        // chữ thường trùng âm tiết Việt (la, ma, to, do, ca, co…) → không cờ
        for w in ["la", "ma", "to", "do", "ca", "co", "an", "me", "bo", "vn", "us"] {
            XCTAssertTrue(t(w).isEmpty, w)
        }
    }

    func testVietnameseSyllablesGainNoEmoji() {
        for w in ["an", "bo", "ca", "me", "ban", "can", "hat", "tan", "the", "con", "long",
                  "sang", "tim", "nam", "nguoi", "khong", "thanh", "ngu", "nghi"] {
            XCTAssertTrue(t(w).isEmpty, w)
        }
        XCTAssertTrue(t("bàn", raw: "banf").isEmpty)   // có dấu: không tra tiếng Anh
        XCTAssertTrue(t("Nhật").isEmpty)
        XCTAssertTrue(t("ban", prev: "an").isEmpty)    // cụm toàn âm tiết Việt
        // bảng biên soạn (đứng trước trên thanh gợi ý) không đổi
        XCTAssertFalse(EmojiSuggest.emojis(for: "an").isEmpty)
        XCTAssertTrue(EmojiSuggest.emojis(for: "japan").isEmpty)
    }

    func testVietnameseSearchUnchanged() {
        XCTAssertTrue(EmojiSearch.search("Nhật Bản").prefix(3).contains("🇯🇵"))
        XCTAssertTrue(EmojiSearch.search("nhat ban").prefix(3).contains("🇯🇵"))
        XCTAssertTrue(EmojiSearch.search("japan").prefix(3).contains("🇯🇵"))
        XCTAssertTrue(EmojiSearch.search("pizza").prefix(3).contains("🍕"))
        XCTAssertFalse(EmojiSearch.search("cá", limit: 500).prefix(5).contains("🐈"))
        XCTAssertTrue(EmojiSearch.search("cho").prefix(5).contains { $0 == "🐶" || $0 == "🐕" })
        XCTAssertGreaterThan(EmojiSearch.enKeyCount, 4000)
    }
}
