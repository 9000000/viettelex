// Trình chỉnh ảnh nền: kéo (pan) + chụm (zoom) ảnh dưới khung ĐÚNG tỉ lệ vùng bàn phím
// dọc, có phím xem trước + độ tối/độ mờ áp trực tiếp. Toán khung: Keyboard/Wallpaper.swift
// (WallpaperCrop, test ở KeyboardTests/WallpaperCropTests).
import SwiftUI

struct WallpaperEditorView: View {
    /// Ảnh gốc (≤ Wallpaper.sourceMaxEdge, đã xoay EXIF).
    let image: CGImage
    /// Cỡ (pt) vùng bàn phím dọc — khung chỉnh cùng tỉ lệ.
    let keyboardSize: CGSize
    /// Phần strip gợi ý (pt) ở đỉnh keyboardSize — phím xem trước nằm dưới nó.
    let stripHeight: CGFloat
    /// "Nâng bàn phím" (pt) ở đáy keyboardSize — dải trống dưới phím xem trước.
    let bottomPad: CGFloat
    let palette: KeyboardPalette
    let onCancel: () -> Void
    let onDone: (_ crop: WallpaperCrop, _ dim: Int, _ blur: Int) -> Void

    @State private var dim: Int
    @State private var blur: Int
    @State private var zoom: Double
    @State private var center: CGPoint
    @State private var dragStart: CGPoint?
    @State private var zoomStart: Double?
    @State private var interacting = false

    private let uiImage: UIImage

    init(image: CGImage, crop: WallpaperCrop?, keyboardSize: CGSize, stripHeight: CGFloat,
         bottomPad: CGFloat = 0, palette: KeyboardPalette, dim: Int, blur: Int, onCancel: @escaping () -> Void,
         onDone: @escaping (WallpaperCrop, Int, Int) -> Void) {
        self.image = image
        self.keyboardSize = keyboardSize
        self.stripHeight = stripHeight
        self.bottomPad = bottomPad
        self.palette = palette
        self.onCancel = onCancel
        self.onDone = onDone
        uiImage = UIImage(cgImage: image)
        let a = Wallpaper.aspect(keyboardSize)
        // Ảnh cũ chưa có khung ⇒ bắt đầu từ khung cắt giữa (đúng như bàn phím đang hiện).
        let c = crop?.refit(imageWidth: image.width, imageHeight: image.height, frameAspect: a)
            ?? .cover(imageWidth: image.width, imageHeight: image.height, frameAspect: a)
        _zoom = State(initialValue: c.zoom(imageWidth: image.width, imageHeight: image.height))
        _center = State(initialValue: CGPoint(x: c.centerX, y: c.centerY))
        _dim = State(initialValue: dim)
        _blur = State(initialValue: blur)
    }

    private var aspect: Double { Wallpaper.aspect(keyboardSize) }

    private var crop: WallpaperCrop {
        .make(imageWidth: image.width, imageHeight: image.height, frameAspect: aspect,
              zoom: zoom, centerX: center.x, centerY: center.y)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(L("Kéo để dời ảnh, chụm hai ngón để phóng to. Chạm hai lần để về khung giữa."))
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                GeometryReader { geo in
                    let w = geo.size.width
                    editorFrame(size: CGSize(width: w, height: w / aspect))
                }
                .aspectRatio(aspect, contentMode: .fit)
                .padding(.horizontal, 12)
                controls
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
            .navigationTitle(L("Chỉnh ảnh nền"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Huỷ"), action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Xong")) { onDone(crop, dim, blur) }.fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder private func editorFrame(size: CGSize) -> some View {
        let c = crop
        let dispW = size.width / CGFloat(c.w), dispH = size.height / CGFloat(c.h)
        // Bán kính mờ đo theo px ảnh đã nướng (≤ maxEdge) → quy ra pt đang hiện.
        let cropPx = max(c.w * Double(image.width), c.h * Double(image.height))
        let bakedK = min(1, Double(Wallpaper.maxEdge) / max(cropPx, 1))
        let blurPt = CGFloat(Double(blur) * Double(dispW) / (Double(image.width) * bakedK))
        let strip = keyboardSize.height > 0 ? size.height * stripHeight / keyboardSize.height : 0
        let raise = keyboardSize.height > 0 ? size.height * bottomPad / keyboardSize.height : 0
        // Mỗi lớp có khung cố định = khung chỉnh (ảnh to hơn khung chỉ nằm trong overlay,
        // không làm lớp phím giãn theo).
        Color.black
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: dispW, height: dispH)
                    .blur(radius: blurPt, opaque: true)
                    .offset(x: -CGFloat(c.x) * dispW, y: -CGFloat(c.y) * dispH)
            }
            .overlay(Color(palette.wallpaperOverlay.alpha(Double(dim) / 100 * palette.surfaceAlpha).ui))
            .overlay {
                VStack(spacing: 0) {
                    Color.clear.frame(height: strip)
                    ThemePreview(palette: palette, wallpaper: nil, dim: 0, large: true, keysOnly: true)
                    Color.clear.frame(height: raise)
                }
                .frame(width: size.width, height: size.height)
                .opacity(interacting ? 0.35 : 1)
                .animation(.easeOut(duration: 0.15), value: interacting)
                .allowsHitTesting(false)
            }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.4), lineWidth: 1))
        .contentShape(Rectangle())
        .gesture(pan(size).simultaneously(with: pinch))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            withAnimation(.easeOut(duration: 0.2)) { zoom = 1; center = CGPoint(x: 0.5, y: 0.5) }
        })
        .accessibilityElement()
        .accessibilityLabel(L("Khung ảnh nền bàn phím"))
        .accessibilityHint(L("Kéo để dời ảnh, chụm hai ngón để phóng to. Chạm hai lần để về khung giữa."))
    }

    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                let start = dragStart ?? center
                if dragStart == nil { dragStart = start; interacting = true }
                let c = crop
                let nx = Double(start.x) - Double(v.translation.width / max(size.width, 1)) * c.w
                let ny = Double(start.y) - Double(v.translation.height / max(size.height, 1)) * c.h
                setCenter(nx, ny)
            }
            .onEnded { _ in dragStart = nil; interacting = zoomStart != nil }
    }

    private var pinch: some Gesture {
        MagnificationGesture()
            .onChanged { m in
                let start = zoomStart ?? zoom
                if zoomStart == nil { zoomStart = start; interacting = true }
                zoom = min(max(start * Double(m), 1), WallpaperCrop.maxZoom)
                setCenter(Double(center.x), Double(center.y))
            }
            .onEnded { _ in zoomStart = nil; interacting = dragStart != nil }
    }

    /// Kẹp tâm để khung luôn nằm trong ảnh (không lộ viền đen).
    private func setCenter(_ x: Double, _ y: Double) {
        let c = WallpaperCrop.make(imageWidth: image.width, imageHeight: image.height, frameAspect: aspect,
                                   zoom: zoom, centerX: x, centerY: y)
        center = CGPoint(x: c.centerX, y: c.centerY)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Độ tối lớp phủ: %@%", dim))
            Slider(value: Binding(get: { Double(dim) }, set: { dim = Int($0) }), in: 0...80, step: 5)
            Text(L("Độ mờ ảnh: %@", blur))
            Slider(value: Binding(get: { Double(blur) }, set: { blur = Int($0) }), in: 0...20, step: 1)
            HStack {
                Spacer()
                Button(L("Về khung giữa")) {
                    withAnimation(.easeOut(duration: 0.2)) { zoom = 1; center = CGPoint(x: 0.5, y: 0.5) }
                }
                .disabled(abs(zoom - 1) < 0.001 && abs(center.x - 0.5) < 0.001 && abs(center.y - 0.5) < 0.001)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
    }
}

#if DEBUG
extension WallpaperEditorView {
    /// Ảnh mẫu (dải màu + lưới) cho `-wallpaperEditorDemo 1`.
    static func demo() -> WallpaperEditorView {
        let w = 1536, h = 2048
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let colors = [CGColor(red: 0.95, green: 0.45, blue: 0.3, alpha: 1), CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)]
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
        for i in 0..<6 { ctx.fillEllipse(in: CGRect(x: 180 + i * 190, y: 300 + (i % 3) * 520, width: 160, height: 160)) }
        let size = Wallpaper.keyboardSize(screenSize: UIScreen.main.bounds.size,
                                          pad: UIDevice.current.userInterfaceIdiom == .pad, landscape: false,
                                          rowHeightAdjust: 0, numberRow: false, suggestions: true)
        let crop = WallpaperCrop.make(imageWidth: w, imageHeight: h, frameAspect: Wallpaper.aspect(size),
                                      zoom: 1.4, centerX: 0.4, centerY: 0.35)
        return WallpaperEditorView(image: ctx.makeImage()!, crop: crop, keyboardSize: size,
                                   stripHeight: Wallpaper.suggestionStrip,
                                   palette: KeyboardTheme.system.palette(systemDark: false).overWallpaper(),
                                   dim: 20, blur: 0, onCancel: {}, onDone: { _, _, _ in })
    }
}
#endif
