package com.viettelex.android.ime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Bảng sửa văn bản (27/09/2026): lưới, hàm thuần đầu/cuối dòng + chọn từ, lệnh trên FakeEditor. */
class EditPanelTest {
    private val tracker = SelectionTracker()

    private fun proxy(ed: FakeEditor, reliable: Boolean = true): IcProxy {
        tracker.reset(ed.selStart, ed.selEnd)
        val p = IcProxy({ ed }, tracker)
        p.startInput(null, false)
        if (reliable) {
            p.begin(); p.insertText("x"); p.end(); tracker.onUpdate(ed.selStart, ed.selEnd)
            p.begin(); p.deleteCodePoints(1); p.end(); tracker.onUpdate(ed.selStart, ed.selEnd)
            assertTrue(tracker.reliable)
        }
        return p
    }

    private fun run(p: IcProxy, a: EditAction, selecting: Boolean = false): Boolean {
        p.begin()
        try { return EditCommands.run(a, selecting, p, tracker) } finally { p.end() }
    }

    // MARK: lưới

    @Test fun gridHasEveryActionOnce() {
        val all = EditPanel.GRID.flatten()
        assertEquals(EditAction.values().toSet(), all.toSet())
        assertEquals(all.size, all.toSet().size)
        assertTrue(EditPanel.GRID.all { it.size == 4 })
    }

    @Test fun gridBuildsEditKeysInsideSpanWithOneHand() {
        val keys = KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 224f, 1f, oneHand = OneHandSide.LEFT))
        assertEquals(16, keys.size)
        assertTrue(keys.all { it.kind == KeyKind.EDIT && EditAction.of(it.insert) != null })
        assertTrue(keys.all { it.right <= 390f * OneHand.RATIO + 0.01f })
        // Router tới đúng ô (plane không phải chữ: vùng nở).
        for (k in keys) assertEquals(k, KeyLayout.hit(keys, Plane.EDIT, k.centerX, k.centerY, 4f, 1f))
    }

    /** Nối công cụ văn bản: editTools ⇒ hàng thứ 5 gồm mọi TextTool, chạm = TOOL:id. */
    @Test fun toolsRowWhenTextToolsUnlocked() {
        val keys = KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 280f, 1f, oneHand = OneHandSide.RIGHT, editTools = true))
        assertEquals(16 + com.viettelex.keyboard.TextTool.entries.size, keys.size)
        val tools = keys.filter { EditPanel.toolOf(it.insert) != null }
        assertEquals(com.viettelex.keyboard.TextTool.entries, tools.map { EditPanel.toolOf(it.insert) })
        val gridBottom = keys.filter { EditAction.of(it.insert) != null }.maxOf { it.bottom }
        assertTrue(tools.all { it.top >= gridBottom && it.bottom <= 280f + 0.01f })
        assertTrue(keys.all { it.left >= 390f * (1 - OneHand.RATIO) - 0.01f })
        for (k in keys) assertEquals(k, KeyLayout.hit(keys, Plane.EDIT, k.centerX, k.centerY, 4f, 1f))
        assertEquals(null, EditPanel.toolOf("LEFT"))
        assertEquals(null, EditAction.of(tools.first().insert))
        // Khoá ⇒ lưới 4×4 như cũ.
        assertEquals(16, KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 280f, 1f)).size)
    }

    /** Dịch trên máy: ô "Dịch" cuối hàng công cụ; chỉ bật dịch ⇒ hàng có đúng một ô. */
    @Test fun translateCellOnToolsRow() {
        val both = KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 280f, 1f, editTools = true, editTranslate = true))
        assertEquals(16 + com.viettelex.keyboard.TextTool.entries.size + 1, both.size)
        val tr = both.single { it.insert == EditPanel.TRANSLATE_INSERT }
        assertEquals(null, EditPanel.toolOf(tr.insert)); assertEquals(null, EditAction.of(tr.insert))
        assertEquals(both.filter { it.top == tr.top }.maxOf { it.right }, tr.right)
        for (k in both) assertEquals(k, KeyLayout.hit(both, Plane.EDIT, k.centerX, k.centerY, 4f, 1f))
        val only = KeyLayout.build(LayoutConfig(Plane.EDIT, 390f, 280f, 1f, editTranslate = true))
        assertEquals(17, only.size)
        assertTrue(only.any { it.insert == EditPanel.TRANSLATE_INSERT })
    }

    // MARK: hàm thuần

    @Test fun lineStartAndEnd() {
        assertEquals(5, EditOps.lineStartBack("hello"))
        assertEquals(3, EditOps.lineStartBack("ab\ncde"))
        assertEquals(0, EditOps.lineStartBack("ab\n"))
        assertEquals(2, EditOps.lineStartBack("x\r\nyz"))            // \r\n một ngắt
        assertEquals(4, EditOps.lineEndForward("tail"))
        assertEquals(2, EditOps.lineEndForward("ab\ncd"))
        assertEquals(0, EditOps.lineEndForward("\nx"))
        assertEquals(1, EditOps.lineEndForward("a b"))
    }

    @Test fun wordAroundCursor() {
        // "xin chà|o bạn" ⇒ cả "chào"
        assertEquals(-3 to 1, EditOps.wordAround("xin chà", "o bạn"))
        // sát cuối từ
        assertEquals(-3 to 0, EditOps.wordAround("xin bạn", " nhé"))
        // sát đầu từ
        assertEquals(0 to 3, EditOps.wordAround("xin ", "bạn"))
        // giữa khoảng trắng ⇒ từ ngay trước
        assertEquals(-6 to -2, EditOps.wordAround("xin chào  ", ""))
        assertEquals(-5 to -2, EditOps.wordAround("xin bạn, ", ""))
        assertEquals(0 to 2, EditOps.wordAround("xin bạn, ", "ok"))
        // tiếng Việt NFD (dấu kết hợp) vẫn là một từ
        val nfd = "việt"
        assertEquals(-nfd.length to 0, EditOps.wordAround(nfd, ""))
        assertNull(EditOps.wordAround("", ""))
        assertNull(EditOps.wordAround("  ", "  "))
    }

    // MARK: lệnh trên FakeEditor

    @Test fun arrowsReuseTrackpadMovement() {
        val ed = FakeEditor("ab\ncd")
        val p = proxy(ed)
        run(p, EditAction.LEFT)
        assertEquals(4 to 4, ed.selStart to ed.selEnd)
        tracker.onUpdate(4, 4)
        run(p, EditAction.RIGHT)
        assertEquals(5, ed.selStart)
        tracker.onUpdate(5, 5)
        run(p, EditAction.UP)                         // ô một dòng có '\n' ⇒ setSelection cùng cột
        assertEquals(2, ed.selStart)
        assertTrue(ed.keys.isEmpty())                 // không DPAD khi biết chắc con trỏ
    }

    @Test fun lineStartEndBySetSelection() {
        val ed = FakeEditor("một\nhai ba", selStart = 6)
        val p = proxy(ed)
        run(p, EditAction.LINE_END)
        assertEquals(10 to 10, ed.selStart to ed.selEnd)
        tracker.onUpdate(10, 10)
        run(p, EditAction.LINE_START)
        assertEquals(4, ed.selStart)
        assertTrue(ed.metaKeys.isEmpty() && ed.keys.isEmpty())
    }

    @Test fun lineStartFallsBackToHomeKeyWhenCursorUnknown() {
        val ed = FakeEditor("abc")
        val p = proxy(ed, reliable = false)
        run(p, EditAction.LINE_START)
        assertEquals(listOf(EditorPort.PortKey.HOME), ed.keys)
    }

    @Test fun selectingModeUsesShiftArrows() {
        val ed = FakeEditor("xin chào")
        val p = proxy(ed)
        run(p, EditAction.LEFT, selecting = true)
        run(p, EditAction.LEFT, selecting = true)
        assertEquals("ào", ed.text.substring(minOf(ed.selStart, ed.selEnd), maxOf(ed.selStart, ed.selEnd)))
        run(p, EditAction.LINE_START, selecting = true)
        assertEquals(Triple(EditorPort.PortKey.HOME, true, false), ed.metaKeys.last())
        assertEquals(-1, tracker.cursor)              // con trỏ không biết cho tới onUpdateSelection
    }

    @Test fun selectWordSelectsAndTrackerKnowsItsOwn() {
        val ed = FakeEditor("xin chào bạn", selStart = 6)
        val p = proxy(ed)
        assertTrue(run(p, EditAction.SELECT_WORD))
        assertEquals(4 to 8, ed.selStart to ed.selEnd)
        assertFalse(tracker.onUpdate(4, 8))           // selection của mình ≠ đổi từ ngoài
    }

    @Test fun copyCutPasteSelectAllViaContextMenu() {
        val ed = FakeEditor("xin chào bạn", selStart = 6)
        val p = proxy(ed)
        run(p, EditAction.SELECT_WORD)
        run(p, EditAction.COPY)
        assertEquals("chào", ed.clipboard)
        assertEquals("xin chào bạn", ed.text)
        run(p, EditAction.CUT)
        assertEquals("xin  bạn", ed.text)
        run(p, EditAction.PASTE)
        assertEquals("xin chào bạn", ed.text)
        run(p, EditAction.SELECT_ALL)
        assertEquals(0 to ed.text.length, ed.selStart to ed.selEnd)
        assertEquals(listOf(EditorPort.MenuAction.COPY, EditorPort.MenuAction.CUT, EditorPort.MenuAction.PASTE,
            EditorPort.MenuAction.SELECT_ALL), ed.menus)
        assertTrue(ed.metaKeys.isEmpty())
    }

    @Test fun undoRedoViaMenuThenCtrlZFallback() {
        val ed = FakeEditor("abc", selStart = 0, selEnd = 3)
        val p = proxy(ed, reliable = false)
        run(p, EditAction.CUT)
        assertEquals("", ed.text)
        run(p, EditAction.UNDO)
        assertEquals("abc", ed.text)
        run(p, EditAction.REDO)
        assertEquals("", ed.text)
        // Ô không có menu hoàn tác (Chrome): Ctrl+Z / Ctrl+Shift+Z.
        ed.undoMenuSupported = false
        run(p, EditAction.UNDO)
        run(p, EditAction.REDO)
        assertEquals(listOf(Triple(EditorPort.PortKey.Z, false, true), Triple(EditorPort.PortKey.Z, true, true)),
            ed.metaKeys)
    }

    @Test fun menuUnsupportedFallsBackToShortcuts() {
        val ed = FakeEditor("abc")
        ed.menuSupported = false
        val p = proxy(ed)
        run(p, EditAction.SELECT_ALL); run(p, EditAction.COPY); run(p, EditAction.CUT); run(p, EditAction.PASTE)
        assertEquals(listOf(EditorPort.PortKey.A, EditorPort.PortKey.C, EditorPort.PortKey.X, EditorPort.PortKey.V),
            ed.metaKeys.map { it.first })
        assertTrue(ed.metaKeys.all { it.third && !it.second })
    }

    @Test fun viewSideActionsAreNotRunHere() {
        val ed = FakeEditor("abc")
        val p = proxy(ed)
        for (a in listOf(EditAction.SELECT, EditAction.DELETE, EditAction.CLOSE)) assertFalse(run(p, a))
        assertEquals("abc", ed.text)
    }
}
