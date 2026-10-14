// EmojiSearchBar — hàng trên cùng của chế độ tìm emoji: ô tìm TỰ VẼ (extension không
// dùng được bàn phím hệ thống cho ô tìm) + dải kết quả cuộn ngang. Phím chữ bên dưới
// là phím VietTelex thật; KeyboardView chặn phím và đẩy vào EmojiSearchSession.
import UIKit

final class EmojiSearchBar: UIView {
    var onPick: ((String) -> Void)?
    var onClear: (() -> Void)?

    private let field = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let caret = UIView()
    private let clear = UIButton(type: .custom)
    private let results = UIScrollView()
    private let emptyLabel = UILabel()
    private var resultButtons: [UIButton] = []
    private(set) var shownResults: [String] = []
    private let dark: Bool
    /// Ảnh emoji vẽ sẵn (EmojiAtlas); nil ⇒ chữ.
    private let atlas: EmojiAtlasStore?
    private var fieldWidth: NSLayoutConstraint!

    init(dark: Bool) {
        self.dark = dark
        atlas = EmojiAtlas.loadForKeyboard(scale: UIScreen.main.scale,
                                           pad: UIDevice.current.userInterfaceIdiom == .pad)
        super.init(frame: .zero)
        let ink: UIColor = dark ? .white : .black
        backgroundColor = KeyboardView.touchableClear
        // Cùng nền ô tìm ở lưới emoji (≈ tertiarySystemFill) — chuyển qua lại không đổi màu.
        field.backgroundColor = UIColor(red: 118 / 255, green: 118 / 255, blue: 128 / 255, alpha: dark ? 0.24 : 0.12)
        field.layer.cornerRadius = 9
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        icon.image = UIImage(systemName: "magnifyingglass",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        icon.tintColor = ink.withAlphaComponent(0.5)
        icon.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(icon)

        label.font = .systemFont(ofSize: 16)
        label.lineBreakMode = .byTruncatingHead
        label.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(label)

        caret.backgroundColor = .systemBlue
        caret.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(caret)

        clear.setImage(UIImage(systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)), for: .normal)
        clear.tintColor = ink.withAlphaComponent(0.35)
        clear.accessibilityLabel = L("Xoá ô tìm")
        clear.addAction(UIAction { [weak self] _ in self?.onClear?() }, for: .touchUpInside)
        clear.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(clear)

        results.showsHorizontalScrollIndicator = false
        results.disableKeyboardEdgeEffects()   // iOS 26 làm mờ dải kết quả tìm (Phil 27/09)
        results.alwaysBounceHorizontal = true
        results.translatesAutoresizingMaskIntoConstraints = false
        addSubview(results)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = ink.withAlphaComponent(0.4)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        fieldWidth = field.widthAnchor.constraint(equalToConstant: 120)
        NSLayoutConstraint.activate([
            field.leftAnchor.constraint(equalTo: leftAnchor, constant: 6),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            fieldWidth,
            icon.leftAnchor.constraint(equalTo: field.leftAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            label.leftAnchor.constraint(equalTo: icon.rightAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            label.rightAnchor.constraint(lessThanOrEqualTo: clear.leftAnchor, constant: -3),
            caret.leftAnchor.constraint(equalTo: label.rightAnchor, constant: 1),
            caret.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 2),
            caret.heightAnchor.constraint(equalToConstant: 20),
            clear.rightAnchor.constraint(equalTo: field.rightAnchor, constant: -2),
            clear.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            clear.widthAnchor.constraint(equalToConstant: 28),
            clear.heightAnchor.constraint(equalTo: field.heightAnchor),
            results.leftAnchor.constraint(equalTo: field.rightAnchor, constant: 6),
            results.rightAnchor.constraint(equalTo: rightAnchor),
            results.topAnchor.constraint(equalTo: topAnchor),
            results.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.leftAnchor.constraint(equalTo: results.leftAnchor, constant: 4),
            emptyLabel.centerYAnchor.constraint(equalTo: field.centerYAnchor),
        ])
        update(query: "", results: [])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Vẽ lại ô tìm + kết quả. Query rỗng → placeholder + gợi ý Recents.
    func update(query: String, results list: [String]) {
        let ink: UIColor = dark ? .white : .black
        if query.isEmpty {
            label.text = L("Tìm emoji")
            label.textColor = ink.withAlphaComponent(0.4)
        } else {
            label.text = query
            label.textColor = ink
        }
        clear.isHidden = query.isEmpty
        let textW = (label.text! as NSString).size(withAttributes: [.font: label.font!]).width
        let maxW = max((bounds.width > 0 ? bounds.width : 320) * 0.45, 120)
        fieldWidth.constant = min(max(textW + 84, 120), maxW)   // chừa icon + nút xoá: placeholder khỏi bị cắt "…m emoji"

        shownResults = list
        resultButtons.forEach { $0.removeFromSuperview() }
        resultButtons = []
        var x: CGFloat = 0
        let size: CGFloat = 38
        for e in list {
            let b = UIButton(type: .custom)
            b.frame = CGRect(x: x, y: 2, width: size, height: size)
            EmojiPlane.setEmoji(e, on: b, font: 28, atlas: atlas)
            b.addAction(UIAction { [weak self] _ in self?.onPick?(e) }, for: .touchUpInside)
            results.addSubview(b)
            resultButtons.append(b)
            x += size + 2
        }
        results.contentSize = CGSize(width: x, height: size)
        results.contentOffset = .zero
        emptyLabel.isHidden = !list.isEmpty
        emptyLabel.text = query.isEmpty ? L("Gõ để tìm: tim, chó, cười…") : L("Không thấy emoji")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for b in resultButtons { b.frame.origin.y = max((bounds.height - b.frame.height) / 2, 0) }
    }
}
