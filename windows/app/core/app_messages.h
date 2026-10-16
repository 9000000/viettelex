// app_messages.h — every private message VietTelex.exe posts to its own main window, in
// one place. They share one window procedure (main.cpp mainProc, which offers each message
// to textActionsMessage first), so two modules picking the same WM_APP + n silently eat
// each other's messages: until this file the updater's "check finished" / "download
// finished" (WM_APP + 0x61/0x62) were swallowed by Công cụ văn bản's work/clipboard messages
// of the same values. app_tests checks the list is collision-free.
#pragma once

namespace vtx::app {

constexpr unsigned kWmApp = 0x8000u;  // WM_APP

// updater.cpp -> main window
constexpr unsigned kMsgUpdateChecked = kWmApp + 0x61;     // lParam: UpdateInfo* (owned by receiver)
constexpr unsigned kMsgUpdateDownloaded = kWmApp + 0x62;  // lParam: wchar_t* path or nullptr; wParam: status
// text_actions.cpp (Công cụ văn bản + caret-hint jobs)
constexpr unsigned kMsgTextToolWork = kWmApp + 0x71;      // selection from the TIP: transform + answer
constexpr unsigned kMsgTextToolClipDone = kWmApp + 0x72;  // clipboard worker finished (wParam 1 = ok)
constexpr unsigned kMsgHintWork = kWmApp + 0x73;          // caret-hint job from a TIP: answer it
// hook_fallback.cpp (hook thread) -> main window: the Ctrl+Shift chord completed (decide
// there whether another keyboard is active and VietTelex must be brought in)
constexpr unsigned kMsgSwitchChord = kWmApp + 0x74;
// text_actions.cpp: Windows' "text suggestions on the physical keyboard" setting changed
// (registry change notification, thread-pool wait -> main window).
constexpr unsigned kMsgPredictSetting = kWmApp + 0x75;
// text_actions.cpp: "Học từ bạn gõ" events from a TIP (HintJob::Learn): record them.
constexpr unsigned kMsgLearnWork = kWmApp + 0x76;
// (ime/src/globals.h kAppCommandMsg = WM_APP + 0x56 and main.cpp kTrayMsg = WM_APP + 0x57
// are the other two on this window.)
constexpr unsigned kAppCommand = kWmApp + 0x56;
constexpr unsigned kTrayCallback = kWmApp + 0x57;

constexpr unsigned kMainWindowMessages[] = {kMsgUpdateChecked,   kMsgUpdateDownloaded, kMsgTextToolWork,
                                            kMsgTextToolClipDone, kMsgHintWork,        kAppCommand,
                                            kTrayCallback,       kMsgSwitchChord,      kMsgPredictSetting,
                                            kMsgLearnWork};

}  // namespace vtx::app
