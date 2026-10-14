import XCTest

/// macOS 27 vẽ tiêu đề menu nguồn nhập bằng CFBundleName ĐÃ BẢN ĐỊA HOÁ: thiếu khoá
/// trong InfoPlist.strings thì menu hiện nguyên chữ "CFBundleName" (báo lỗi 14/10/2026).
final class InfoPlistStringsTests: XCTestCase {
    func testEveryLocalizationNamesTheBundle() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources")
        for lang in ["vi", "en"] {
            let url = resources.appendingPathComponent("\(lang).lproj/InfoPlist.strings")
            let dict = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], lang)
            XCTAssertEqual(dict["CFBundleName"], "VietTelex", lang)
            XCTAssertEqual(dict["CFBundleDisplayName"], "VietTelex", lang)
        }
    }
}
