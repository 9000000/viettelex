// tip_control.h — per-user setup the per-machine MSI cannot do: add the VietTelex
// keyboard to the current user's language list, autostart, and clean removal.
#pragma once
#include <string>

namespace vtx::app {

bool addKeyboardForUser();     // InstallLayoutOrTip("042A:{CLSID}{PROFILE}")
bool removeKeyboardForUser();  // same with ILOT_UNINSTALL
// Make VietTelex Windows' default input method for this user (SetDefaultLayoutOrTip):
// new app windows then start in VietTelex (input_switch.h, 2026-10 Ctrl+Shift report).
bool setDefaultKeyboardForUser();
// LOWORD of SPI_GETDEFAULTINPUTLANG (the default input language), 0 = unreadable.
unsigned defaultInputLangId();
// Remove another layout/TIP from this user's list ("042A:{CLSID}{PROFILE}" / "042A:0000042A").
bool removeLayoutOrTipForUser(const std::wstring& spec);
// This process runs as LocalSystem (an MSI custom action of a Store / Intune / msiexec /qn
// install): its HKCU belongs to no person.
bool runningAsSystem();
void setAutostart(bool on);    // HKCU\...\Run "VietTelex" = "<exe>" --background
bool autostartEnabled();

}  // namespace vtx::app
