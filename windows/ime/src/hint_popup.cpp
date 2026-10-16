#include "hint_popup.h"

#include "caret_hints.h"
#include "version.h"

namespace vtx::tip {

namespace {

// Class name unique to this module load (see toolClassName in text_service.cpp).
const wchar_t* popupClassName() {
    static const std::wstring name = [] {
        std::wstring n = std::wstring(L"VietTelexHint_") + VTX_VER_STRING_W + L"_";
        const uintptr_t v = reinterpret_cast<uintptr_t>(g_hInst);
        for (int s = static_cast<int>(sizeof v * 8) - 4; s >= 0; s -= 4) n.push_back(L"0123456789abcdef"[(v >> s) & 0xF]);
        return n;
    }();
    return name.c_str();
}

int dpiFor(HWND w) {
    using Fn = UINT(WINAPI*)(HWND);
    static Fn fn = reinterpret_cast<Fn>(
        reinterpret_cast<void*>(GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow")));
    if (fn && w) {
        const UINT d = fn(w);
        if (d >= 72) return static_cast<int>(d);
    }
    HDC dc = GetDC(nullptr);
    const int d = dc ? GetDeviceCaps(dc, LOGPIXELSY) : 96;
    if (dc) ReleaseDC(nullptr, dc);
    return d > 0 ? d : 96;
}

// Apps light/dark (HKCU …\Personalize AppsUseLightTheme). Unreadable (AppContainer) = light.
bool appsDark() {
    DWORD v = 1, sz = sizeof v;
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                     L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &v, &sz) != ERROR_SUCCESS)
        return false;
    return v == 0;
}

int scale(int v, int dpi) { return MulDiv(v, dpi, 96); }

const wchar_t kTabLabel[] = L"Tab";

}  // namespace

void UnregisterHintPopupClass() { UnregisterClassW(popupClassName(), g_hInst); }

LRESULT CALLBACK HintPopup::wndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    auto* self = reinterpret_cast<HintPopup*>(GetWindowLongPtrW(h, GWLP_USERDATA));
    switch (msg) {
        case WM_MOUSEACTIVATE: return MA_NOACTIVATE;
        case WM_NCHITTEST: return (self && self->notify_) ? HTCLIENT : HTTRANSPARENT;
        case WM_LBUTTONDOWN:
            if (self && self->notify_) PostMessageW(self->notify_, self->pickMsg_, 0, 0);
            return 0;
        case WM_ERASEBKGND: return 1;
        case WM_PAINT: {
            PAINTSTRUCT ps;
            HDC dc = BeginPaint(h, &ps);
            if (self) self->paint(dc);
            EndPaint(h, &ps);
            return 0;
        }
        default: break;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

bool HintPopup::ensureWindow() {
    if (wnd_ && IsWindow(wnd_)) return true;
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof wc;
    wc.style = CS_DROPSHADOW | CS_SAVEBITS;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = g_hInst;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = popupClassName();
    RegisterClassExW(&wc);  // fails harmlessly when another thread registered it
    wnd_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT, popupClassName(),
                           L"", WS_POPUP, 0, 0, 1, 1, nullptr, nullptr, g_hInst, nullptr);
    if (!wnd_) return false;
    SetWindowLongPtrW(wnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    return true;
}

void HintPopup::makeFonts(int dpi) {
    if (font_ && fontDpi_ == dpi) return;
    if (font_) DeleteObject(font_);
    if (small_) DeleteObject(small_);
    font_ = CreateFontW(-scale(15, dpi), 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    small_ = CreateFontW(-scale(12, dpi), 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                         CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    fontDpi_ = dpi;
}

bool HintPopup::show(const std::wstring& text, const RECT& caret, HWND notify, UINT pickMsg) {
    if (text.empty() || !ensureWindow()) return false;
    HWND focus = GetFocus();
    dpi_ = dpiFor(focus ? focus : GetForegroundWindow());
    dark_ = appsDark();
    makeFonts(dpi_);
    text_ = text;
    notify_ = notify;
    pickMsg_ = pickMsg;
    // Clicks: only a clickable (prediction) popup takes them; otherwise they fall through.
    LONG_PTR ex = GetWindowLongPtrW(wnd_, GWL_EXSTYLE);
    const LONG_PTR want = notify_ ? (ex & ~static_cast<LONG_PTR>(WS_EX_TRANSPARENT)) : (ex | WS_EX_TRANSPARENT);
    if (want != ex) SetWindowLongPtrW(wnd_, GWL_EXSTYLE, want);

    HDC dc = GetDC(wnd_);
    if (!dc) return false;
    SIZE a = {0, 0}, b = {0, 0};
    HGDIOBJ old = SelectObject(dc, font_);
    GetTextExtentPoint32W(dc, text_.c_str(), static_cast<int>(text_.size()), &a);
    SelectObject(dc, small_);
    GetTextExtentPoint32W(dc, kTabLabel, lstrlenW(kTabLabel), &b);
    SelectObject(dc, old);
    ReleaseDC(wnd_, dc);
    const int padX = scale(10, dpi_), padY = scale(6, dpi_), gap = scale(10, dpi_);
    const long w = a.cx + gap + b.cx + 2 * padX;
    const long h = (a.cy > b.cy ? a.cy : b.cy) + 2 * padY;

    MONITORINFO mi = {};
    mi.cbSize = sizeof mi;
    HMONITOR mon = MonitorFromRect(&caret, MONITOR_DEFAULTTONEAREST);
    if (!mon || !GetMonitorInfoW(mon, &mi)) return false;
    const hints::Rect c{caret.left, caret.top, caret.right, caret.bottom};
    const hints::Rect work{mi.rcWork.left, mi.rcWork.top, mi.rcWork.right, mi.rcWork.bottom};
    long px = 0, py = 0;
    hints::popupOrigin(c, w, h, work, px, py, dpi_);
    SetWindowPos(wnd_, HWND_TOPMOST, static_cast<int>(px), static_cast<int>(py), static_cast<int>(w),
                 static_cast<int>(h), SWP_NOACTIVATE | SWP_SHOWWINDOW | SWP_FRAMECHANGED);
    InvalidateRect(wnd_, nullptr, TRUE);
    return true;
}

void HintPopup::paint(HDC dc) {
    RECT rc;
    GetClientRect(wnd_, &rc);
    const COLORREF bg = dark_ ? RGB(0x2B, 0x2B, 0x2B) : RGB(0xFF, 0xFF, 0xFF);
    const COLORREF border = dark_ ? RGB(0x4A, 0x4A, 0x4A) : RGB(0xC8, 0xC8, 0xC8);
    const COLORREF fg = dark_ ? RGB(0xF2, 0xF2, 0xF2) : RGB(0x1A, 0x1A, 0x1A);
    const COLORREF sub = dark_ ? RGB(0xA8, 0xA8, 0xA8) : RGB(0x6E, 0x6E, 0x6E);
    HBRUSH b = CreateSolidBrush(bg);
    FillRect(dc, &rc, b);
    DeleteObject(b);
    HBRUSH fb = CreateSolidBrush(border);
    FrameRect(dc, &rc, fb);
    DeleteObject(fb);
    SetBkMode(dc, TRANSPARENT);
    const int padX = scale(10, dpi_);
    RECT t = rc;
    t.left += padX;
    t.right -= padX;
    HGDIOBJ old = SelectObject(dc, font_);
    SetTextColor(dc, fg);
    DrawTextW(dc, text_.c_str(), static_cast<int>(text_.size()), &t, DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_NOPREFIX);
    SelectObject(dc, small_);
    SetTextColor(dc, sub);
    DrawTextW(dc, kTabLabel, -1, &t, DT_SINGLELINE | DT_VCENTER | DT_RIGHT | DT_NOPREFIX);
    SelectObject(dc, old);
}

void HintPopup::hide() {
    if (wnd_ && IsWindowVisible(wnd_)) ShowWindow(wnd_, SW_HIDE);
}

void HintPopup::destroy() {
    if (wnd_) {
        SetWindowLongPtrW(wnd_, GWLP_USERDATA, 0);
        DestroyWindow(wnd_);
        wnd_ = nullptr;
    }
    if (font_) DeleteObject(font_);
    if (small_) DeleteObject(small_);
    font_ = small_ = nullptr;
    fontDpi_ = 0;
}

}  // namespace vtx::tip
