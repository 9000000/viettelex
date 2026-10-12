#include "input_switch.h"

namespace vtx {

HotkeyNote hotkeyNote(SwitchHotkey h, PerAppInput windows) {
    if (h == SwitchHotkey::CtrlShift || h == SwitchHotkey::AltZ) return HotkeyNote::TipRemembers;
    switch (windows) {
        case PerAppInput::On: return HotkeyNote::WindowsPerApp;
        case PerAppInput::Off: return HotkeyNote::WindowsGlobal;
        default: return HotkeyNote::WindowsUnknown;
    }
}

namespace {
uint8_t modBitForVk(unsigned vk) {
    switch (vk) {
        case 0x10: case 0xA0: case 0xA1: return kModShift;  // VK_SHIFT, VK_LSHIFT, VK_RSHIFT
        case 0x11: case 0xA2: case 0xA3: return kModCtrl;   // VK_CONTROL, VK_LCONTROL, VK_RCONTROL
        case 0x12: case 0xA4: case 0xA5: return kModAlt;    // VK_MENU, VK_LMENU, VK_RMENU
        case 0x5B: case 0x5C: return kModWin;               // VK_LWIN, VK_RWIN
        default: return 0;
    }
}
}  // namespace

bool isChordModifierVk(unsigned vk) { return modBitForVk(vk) != 0; }

uint8_t chordHeldAfter(uint8_t before, unsigned vk, bool down) {
    const uint8_t b = modBitForVk(vk);
    return down ? static_cast<uint8_t>(before | b) : static_cast<uint8_t>(before & ~b);
}

ForeignChord foreignChordAction(SwitchHotkey h, int tipProp, unsigned fgLangId, bool suspended) {
    if (!chordWatcherWanted(h) || suspended) return ForeignChord::Ignore;
    if (tipProp != 0) return ForeignChord::Ignore;          // the TIP is active: it toggles itself
    if (fgLangId == kLangViVN) return ForeignChord::Ignore; // Vietnamese already (VietTelex or a
                                                            // Microsoft Vietnamese keyboard: Windows'
                                                            // own Ctrl+Shift cycles those)
    return ForeignChord::ActivateVietTelex;
}

uintptr_t pickVietnameseHkl(const uintptr_t* hkls, size_t count) {
    for (size_t i = 0; i < count; ++i)
        if ((hkls[i] & 0xFFFF) == kLangViVN) return hkls[i];
    return 0;
}

DefaultInputAdvice defaultInputAdvice(SwitchHotkey h, unsigned defaultLangId) {
    if (h != SwitchHotkey::CtrlShift && h != SwitchHotkey::AltZ) return DefaultInputAdvice::None;
    if (defaultLangId == 0 || defaultLangId == kLangViVN) return DefaultInputAdvice::None;
    return DefaultInputAdvice::MakeVietTelexDefault;
}

std::string defaultLayoutOrTipSpec(unsigned langId, const std::string& clsid, const std::string& profile) {
    static const char kHex[] = "0123456789ABCDEF";
    std::string s = "0x";
    for (int shift = 12; shift >= 0; shift -= 4) s.push_back(kHex[(langId >> shift) & 0xF]);
    return s + ":" + clsid + profile;
}

}  // namespace vtx
