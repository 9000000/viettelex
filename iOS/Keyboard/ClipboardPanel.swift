// Panel lịch sử clipboard — phủ vùng phím (dưới thanh gợi ý), mở từ nút 📋 trên
// strip. Chỉ vẽ + báo sự kiện; lưu trữ/ghi nhận ở ClipboardFeature + controller.
import UIKit

final class ClipboardPanel: UIView {
    var onPaste: ((String) -> Void)?
    var onTogglePin: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onClearAll: (() -> Void)?
    var onClose: (() -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let header = UIStackView()
    private let titleLabel = UILabel()
    private let clearButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var dark = false

    /// Ghi chú giới hạn iOS (hiện cuối danh sách / khi trống).
    static var limitNote: String { L("iOS chỉ cho bàn phím đọc clipboard khi bàn phím đang hiện, có Toàn quyền truy cập và đã chọn \"Cho phép dán\". Mục copy lúc bàn phím ẩn được ghi khi bạn mở lại bàn phím (hoặc khi chạm Dán). Lưu chỉ trên máy; mục không ghim tự xoá theo cài đặt Giữ lịch sử clipboard (mặc định 1 giờ).") }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = "Clipboard"
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        clearButton.setTitle(L("Xoá hết"), for: .normal)
        clearButton.titleLabel?.font = .systemFont(ofSize: 15)
        clearButton.addAction(UIAction { [weak self] _ in self?.onClearAll?() }, for: .touchUpInside)
        closeButton.setImage(UIImage(systemName: "keyboard",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)), for: .normal)
        closeButton.accessibilityLabel = L("Đóng clipboard")
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        let spacer = UIView()
        header.addArrangedSubview(titleLabel)
        header.addArrangedSubview(spacer)
        header.addArrangedSubview(clearButton)
        header.addArrangedSubview(closeButton)
        header.axis = .horizontal
        header.spacing = 16
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false
        closeButton.widthAnchor.constraint(equalToConstant: 36).isActive = true
        addSubview(header)

        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.alwaysBounceVertical = true
        scroll.disableKeyboardEdgeEffects()
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            header.leftAnchor.constraint(equalTo: leftAnchor, constant: 12),
            header.rightAnchor.constraint(equalTo: rightAnchor, constant: -8),
            header.heightAnchor.constraint(equalToConstant: 32),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leftAnchor.constraint(equalTo: leftAnchor, constant: 8),
            scroll.rightAnchor.constraint(equalTo: rightAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -8),
            stack.leftAnchor.constraint(equalTo: scroll.frameLayoutGuide.leftAnchor),
            stack.rightAnchor.constraint(equalTo: scroll.frameLayoutGuide.rightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reload(items: [ClipItem], dark: Bool, incognito: Bool, notice: String? = nil) {
        self.dark = dark
        let ink: UIColor = dark ? .white : .black
        backgroundColor = dark ? UIColor(white: 0.17, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.86, alpha: 1)
        titleLabel.textColor = ink
        closeButton.tintColor = ink
        clearButton.tintColor = ink
        clearButton.isHidden = !items.contains { !$0.pinned }
        titleLabel.text = incognito ? L("Clipboard · ẩn danh (không lưu)") : "Clipboard"
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let n = notice { stack.addArrangedSubview(note(n, ink: ink)) }
        if items.isEmpty {
            stack.addArrangedSubview(note(L("Chưa có mục nào. Copy nội dung rồi mở bàn phím để ghi lại."), ink: ink))
        }
        for item in items { stack.addArrangedSubview(row(item, ink: ink)) }
        stack.addArrangedSubview(note(Self.limitNote, ink: ink.withAlphaComponent(0.55)))
    }

    private func note(_ text: String, ink: UIColor) -> UIView {
        let l = UILabel()
        l.text = text
        l.numberOfLines = 0
        l.font = .systemFont(ofSize: 12)
        l.textColor = ink
        return l
    }

    private func row(_ item: ClipItem, ink: UIColor) -> UIView {
        let card = UIView()
        card.backgroundColor = dark ? UIColor(white: 0.42, alpha: 1) : .white
        card.layer.cornerRadius = 8
        let body = UIButton(type: .custom)
        body.contentHorizontalAlignment = .left
        body.titleLabel?.numberOfLines = 2
        body.titleLabel?.lineBreakMode = .byTruncatingTail
        body.titleLabel?.font = .systemFont(ofSize: 15)
        // Hiện tối đa 2 dòng ⇒ chỉ cần phần đầu (mục dài tới ClipboardHistory.maxTextLength).
        let shown = String(item.text.prefix(300)).replacingOccurrences(of: "\n", with: " ⏎ ")
        body.setTitle(item.sensitive ? String(repeating: "•", count: min(item.text.count, 12)) : shown, for: .normal)
        body.setTitleColor(ink, for: .normal)
        body.accessibilityLabel = item.sensitive ? L("Mục ẩn, chạm để dán") : L("Dán: %@", item.text.prefix(80))
        body.addAction(UIAction { [weak self] _ in self?.onPaste?(item.text) }, for: .touchUpInside)
        let pin = iconButton(item.pinned ? "pin.fill" : "pin", ink: ink,
                             label: item.pinned ? L("Bỏ ghim") : "Ghim") { [weak self] in self?.onTogglePin?(item.text) }
        let del = iconButton("xmark", ink: ink, label: L("Xoá mục")) { [weak self] in self?.onDelete?(item.text) }
        let h = UIStackView(arrangedSubviews: [body, pin, del])
        h.axis = .horizontal
        h.spacing = 4
        h.alignment = .center
        h.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(h)
        NSLayoutConstraint.activate([
            h.topAnchor.constraint(equalTo: card.topAnchor, constant: 4),
            h.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -4),
            h.leftAnchor.constraint(equalTo: card.leftAnchor, constant: 10),
            h.rightAnchor.constraint(equalTo: card.rightAnchor, constant: -2),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
        return card
    }

    private func iconButton(_ symbol: String, ink: UIColor, label: String,
                            action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)), for: .normal)
        b.tintColor = ink.withAlphaComponent(0.7)
        b.accessibilityLabel = label
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        b.widthAnchor.constraint(equalToConstant: 40).isActive = true
        b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return b
    }
}
