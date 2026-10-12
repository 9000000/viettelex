// chromium_store.h — a TextSink shaped like Chromium's TSFTextStore over a busy web editor
// (Messenger / Facebook composer: Lexical + React), for the "mất chữ" field report
// (2026-10: "hai chương trình học AI từ lớp 1" came out "ại chương tình ọc AI ừ óp 1").
//
// What the TIP reads is NOT the page: TSFTextStore keeps a cache (string_buffer_document_
// + selection_) that is refreshed only when the renderer reports its text-input state,
// asynchronously, after it processed the keys/IME calls sent to it. So:
//   * a key the TIP lets through reaches the page at once, but shows up in the cache
//     only some renderer reports later ("lag");
//   * our own edit lands in the cache immediately (inside the edit session) and reaches
//     the page as ExtendSelectionAndDelete(n, 0) + InsertText — RELATIVE to the page's
//     real caret (tsf_text_store.cc CommitTextAndEndCompositionIfAny);
//   * a later report can carry a state OLDER than our edit (the page had not processed
//     it yet): the cache then moves "back" (CalculateTextandSelectionDiffAndNotifyIfNeeded
//     only compares against the previous report, not against the cache);
//   * while a composition is active the cache is not overwritten (has_composition_range_).
// The model keeps both: `page` (what the user sees) and `view` (what TSF reads).
#pragma once
#include <string>
#include <vector>

#include "session.h"

namespace vtx::test {

class ChromiumLaggingStore : public TextSink {
public:
    struct State {
        std::u16string text;
        size_t caret = 0;
        bool operator==(const State& o) const { return text == o.text && caret == o.caret; }
    };
    State page;                 // the renderer: what is on screen
    State view;                 // TSFTextStore's cache: what the TIP reads
    bool comp = false;          // a composition is active (both sides)
    size_t vCompStart = 0, vCompEnd = 0, pCompStart = 0, pCompEnd = 0;
    int lag = 0;                // reports the cache is behind the page (renderer ops)
    std::vector<State> history; // page state after each renderer op
    size_t lastReport = 0;      // index into history of the last report the cache took

    ChromiumLaggingStore() { history.push_back(page); }

    // --- the page processing what it was sent (keys and IME calls), in order ---
    void pageOp() { history.push_back(page); }
    void appInsert(char16_t c) {
        page.text.insert(page.caret, 1, c);
        ++page.caret;
        pageOp();
    }
    void appBackspace() {
        if (page.caret == 0) return;
        page.text.erase(--page.caret, 1);
        pageOp();
    }

    // A renderer report reaches the browser (OnEndEdit for the TIP when it changes the
    // cache). Returns true when the cache changed.
    bool report() {
        if (comp) return false;  // has_composition_range_: cache kept during a composition
        const size_t want = history.size() - 1 > static_cast<size_t>(lag) ? history.size() - 1 - lag : 0;
        if (want <= lastReport) return false;
        const bool sameAsLast = history[want] == history[lastReport];
        lastReport = want;
        if (sameAsLast || history[want] == view) return false;
        view = history[want];
        return true;
    }
    void catchUp() {
        const int l = lag;
        lag = 0;
        report();
        lag = l;
    }

    // --- TextSink: reads come from the cache ---
    std::u16string textBeforeCaret(int max) override {
        const size_t end = comp ? vCompStart : view.caret;
        const size_t n = static_cast<size_t>(max) < end ? static_cast<size_t>(max) : end;
        return view.text.substr(end - n, n);
    }
    char16_t charAfterCaret() override {
        const size_t at = comp ? vCompEnd : view.caret;
        return at < view.text.size() ? view.text[at] : 0;
    }
    bool hasSelection() override { return false; }
    bool replaceBeforeCaret(const std::u16string& expect, const std::u16string& ins) override {
        const size_t n = expect.size();
        if (comp || n > view.caret || view.text.compare(view.caret - n, n, expect) != 0) return false;
        view.text.replace(view.caret - n, n, ins);  // the cache, inside the edit session
        view.caret = view.caret - n + ins.size();
        // The page: ExtendSelectionAndDelete(n, 0), then InsertText — at ITS caret.
        if (n) {
            const size_t d = n < page.caret ? n : page.caret;
            page.text.erase(page.caret - d, d);
            page.caret -= d;
            pageOp();
        }
        page.text.insert(page.caret, ins);
        page.caret += ins.size();
        pageOp();
        return true;
    }
    bool compositionActive() override { return comp; }
    bool setComposition(const std::u16string& t, int absorb, bool) override {
        if (!comp) {
            const size_t a = static_cast<size_t>(absorb);
            if (a > view.caret) return false;
            vCompStart = view.caret - a;
            vCompEnd = view.caret;
            // absorb > 0: SetCompositionFromExistingText(range) — ABSOLUTE cache offsets.
            // absorb == 0: SetCompositionText at the page caret.
            if (a) {
                pCompStart = vCompStart;
                pCompEnd = vCompEnd < page.text.size() ? vCompEnd : page.text.size();
            } else {
                pCompStart = pCompEnd = page.caret;
            }
            comp = true;
        }
        view.text.replace(vCompStart, vCompEnd - vCompStart, t);
        vCompEnd = vCompStart + t.size();
        view.caret = vCompEnd;
        page.text.replace(pCompStart, pCompEnd - pCompStart, t);
        pCompEnd = pCompStart + t.size();
        page.caret = pCompEnd;
        return true;
    }
    void endComposition(const std::u16string& t) override {
        if (!comp) return;
        setComposition(t, 0, false);
        endCompositionAsIs();
    }
    void endCompositionAsIs() override {
        if (!comp) return;
        comp = false;
        pageOp();  // InsertText(composition): the page reports again from here on
    }
};

}  // namespace vtx::test
