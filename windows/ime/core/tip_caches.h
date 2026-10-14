// tip_caches.h — small per-key / per-focus caches of the TSF text service (2026-10 perf
// audit M1/M3/M4). Pure, so the rules are unit-tested on any OS; text_service.cpp and
// tsf_sink.cpp hold one of each.
#pragma once
#include <cstdint>
#include <string>

namespace vtx {

// (M3) Text before the caret read earlier in the SAME edit session. Nothing else can
// change the document while our edit session holds it, so a later "verify these N
// units before the caret" needs no second GetText when the earlier read already ends
// with them. Any write of ours invalidates it.
class BeforeCaretCache {
public:
    // `exact`: the read returned exactly as many units as the range spans (no hidden
    // text / embedded objects in between) — only then do positions map 1:1 to units.
    void remember(const std::u16string& text, bool exact) {
        text_ = text;
        valid_ = exact;
    }
    void invalidate() { valid_ = false; }
    bool valid() const { return valid_; }
    // True = the remembered text ends with `expect` (so the units right before the caret
    // are known to be `expect`).
    bool proves(const std::u16string& expect) const {
        return valid_ && text_.size() >= expect.size() &&
               text_.compare(text_.size() - expect.size(), expect.size(), expect) == 0;
    }

private:
    std::u16string text_;
    bool valid_ = false;
};

// (M4) The host classification at a word start (compartments, status, parent context)
// runs once per key: OnTestKeyDown evaluates, OnKeyDown of the same key (same key
// generation, same context) reuses it. A host that calls OnKeyDown without
// OnTestKeyDown always evaluates there; a cached result is used at most once.
class PerKeyOnce {
public:
    void noteTest(uint32_t keyGen, const void* ctx) {
        gen_ = keyGen;
        ctx_ = ctx;
        valid_ = true;
    }
    // OnKeyDown: true = skip, the OnTestKeyDown of this key already did it.
    bool takeForKeyDown(uint32_t keyGen, const void* ctx) {
        const bool hit = valid_ && keyGen == gen_ && ctx == ctx_;
        valid_ = false;
        return hit;
    }
    void invalidate() { valid_ = false; }

private:
    uint32_t gen_ = 0;
    const void* ctx_ = nullptr;
    bool valid_ = false;
};

// (M1) The Việt/Anh state VietTelex.exe is told at a FOCUS change (AppCommand::
// StateChanged) only feeds the optional tray icon. Post only when the tray is on and the
// state or the focus root window differs from what this thread last told it — the app's
// own foreground hook covers switches between windows. A user switch always posts
// (UserSwitched) and is recorded with notePosted.
class FocusStateNotify {
public:
    bool shouldPost(bool trayOn, bool vietnamese, uintptr_t root) {
        if (!trayOn) {
            reset();
            return false;
        }
        const int8_t st = vietnamese ? 1 : 0;
        if (st == posted_ && root == root_) return false;
        posted_ = st;
        root_ = root;
        return true;
    }
    void notePosted(bool vietnamese, uintptr_t root) {
        posted_ = vietnamese ? 1 : 0;
        root_ = root;
    }
    void reset() {
        posted_ = -1;
        root_ = 0;
    }

private:
    int8_t posted_ = -1;  // -1 = nothing posted yet
    uintptr_t root_ = 0;
};

// (M1) Chế độ game is VietTelex.exe's runtime state (cleared at its start). If the app is
// gone (crashed, autostart off), a stale "on" in the snapshot must not leave every key
// passing through forever. `appRunning` is only asked when the snapshot says on.
template <class AppRunning>
inline bool effectiveGameMode(bool snapshotGameMode, AppRunning&& appRunning) {
    return snapshotGameMode && appRunning();
}

}  // namespace vtx
