// hint_popup.h — the small window that shows a caret hint (ime/core/caret_hints.h) next to
// the caret: "= 36  Tab", "1.200.000 ₫  Tab". A top-most tool popup that never activates
// and never takes focus (WS_EX_NOACTIVATE, MA_NOACTIVATE) — the app being typed in keeps the
// keyboard. Single hints let every click through (WS_EX_TRANSPARENT, HTTRANSPARENT); word
// prediction shows up to 3 candidates ("được │ đường │ đưa  Tab") and a click on one posts
// `pickMsg` (wParam = index) to `notify`. Created on first use in the host thread,
// destroyed at Deactivate. Plain GDI: no extra DLLs in the host process.
#pragma once
#include <string>
#include <vector>

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
    // coordinates), flipped above near the bottom of the work area. False = not shown.
    bool show(const std::wstring& text, const RECT& caret) { return show(std::vector<std::wstring>{text}, caret, nullptr, 0); }
    // Several candidates, the first emphasised; clickable when `notify` is set.
    bool show(const std::vector<std::wstring>& items, const RECT& caret, HWND notify, UINT pickMsg);
    void hide();
    bool visible() const { return wnd_ && IsWindowVisible(wnd_); }
    void destroy();

private:
    static LRESULT CALLBACK wndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp);
    void paint(HDC dc);
    int itemAt(int x) const;  // -1 = none
    bool ensureWindow();
    void makeFonts(int dpi);

    HWND wnd_ = nullptr;
    HFONT font_ = nullptr, small_ = nullptr, regular_ = nullptr;
    int fontDpi_ = 0;
    bool dark_ = false;
    std::vector<std::wstring> items_;
    std::vector<int> cellRight_;  // client x where item i ends (incl. its separator gap)
    HWND notify_ = nullptr;
    UINT pickMsg_ = 0;
    int dpi_ = 96;
};

}  // namespace vtx::tip
