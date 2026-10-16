// hint_popup.h — the small window that shows a caret hint (ime/core/caret_hints.h) next to
// the caret: "= 36  Tab", "1.200.000 ₫  Tab". A top-most tool popup that never activates
// and never takes focus (WS_EX_NOACTIVATE, MA_NOACTIVATE) — the app being typed in keeps the
// keyboard. Every hint is ONE item + the "Tab" label; it lets every click through
// (WS_EX_TRANSPARENT, HTTRANSPARENT) except a word prediction ("được  Tab"), where a click
// anywhere on it posts `pickMsg` to `notify` (= Tab). Created on first use in the host thread,
// destroyed at Deactivate. Plain GDI: no extra DLLs in the host process.
#pragma once
#include <string>

#include "globals.h"

namespace vtx::tip {

// DllCanUnloadNow: unregister this module load's popup class.
void UnregisterHintPopupClass();

class HintPopup {
public:
    HintPopup() = default;
    ~HintPopup() { destroy(); }
    HintPopup(const HintPopup&) = delete;
    HintPopup& operator=(const HintPopup&) = delete;

    // Shows `text` (+ a dimmed "Tab" key label) below the caret rectangle `caret` (screen
    // coordinates), flipped above near the bottom of the work area. Clickable when `notify`
    // is set (a click posts `pickMsg` to it). False = not shown.
    bool show(const std::wstring& text, const RECT& caret, HWND notify = nullptr, UINT pickMsg = 0);
    void hide();
    bool visible() const { return wnd_ && IsWindowVisible(wnd_); }
    void destroy();

private:
    static LRESULT CALLBACK wndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp);
    void paint(HDC dc);
    bool ensureWindow();
    void makeFonts(int dpi);

    HWND wnd_ = nullptr;
    HFONT font_ = nullptr, small_ = nullptr;
    int fontDpi_ = 0;
    bool dark_ = false;
    std::wstring text_;
    HWND notify_ = nullptr;
    UINT pickMsg_ = 0;
    int dpi_ = 96;
};

}  // namespace vtx::tip
