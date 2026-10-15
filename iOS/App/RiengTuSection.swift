import SwiftUI

/// Tính Năng → "Riêng tư & clipboard": Lịch sử clipboard + Chế độ ẩn danh. Bàn phím đọc
/// cùng key qua App Group (ClipboardFeature.historyKey / incognitoKey).
struct RiengTuSection: View {
    @AppStorage("clipboardHistory", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var clipboardHistory = false
    @AppStorage("incognitoMode", store: UserDefaults(suiteName: "group.com.viettelex"))
    private var incognitoMode = false

    var body: some View {
        Section {
            toggle(L("Lịch sử clipboard"),
                   L("Nút clipboard trên thanh gợi ý mở 20 mục vừa copy; ghim để giữ lâu. Mục không ghim tự xoá sau 1 giờ (mật khẩu/OTP: 2 phút). Chỉ lưu trên máy. Plus: vừa copy STK/SĐT/OTP → chip “Dán …” hiện trên thanh gợi ý."),
                   isOn: $clipboardHistory)
            if clipboardHistory {
                FullAccessNotice(reason: L("Lịch sử clipboard"))
                Text(L("iOS chỉ cho bàn phím đọc clipboard khi đang hiện và có Toàn quyền. Để tự ghi mục mới mà không bị hỏi: Cài đặt → VietTelex → Dán từ ứng dụng khác → Cho phép. Bỏ qua ô mật khẩu."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: { Text("Clipboard") } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if clipboardHistory { Text(Self.iosLimitNote) }
                Text(L("Tắt Lịch sử clipboard sẽ xoá toàn bộ mục đã lưu ở lần mở bàn phím kế tiếp."))
            }
        }
        Section {
            toggle(L("Chế độ ẩn danh"),
                   L("Bàn phím không học từ bạn gõ và không lưu clipboard."),
                   isOn: $incognitoMode)
        } header: { Text(L("Riêng tư")) }
    }

    /// Giới hạn iOS (bàn phím chỉ đọc clipboard khi đang hiện) — nói rõ để không tưởng là lỗi.
    static var iosLimitNote: String {
        L("Giới hạn của iOS: lúc bàn phím ẩn, bàn phím không thấy bạn copy gì — copy nhiều lần trong lúc đó chỉ ghi được mục cuối cùng, khi bàn phím hiện lại. Mở nút clipboard sẽ đọc ngay mục vừa copy. Mục dài quá 10.000 ký tự không được lưu.")
    }

    private func toggle(_ title: String, _ caption: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(caption).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .tint(.green)
    }
}
