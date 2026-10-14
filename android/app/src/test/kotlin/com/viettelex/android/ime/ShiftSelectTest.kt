package com.viettelex.android.ime

import com.viettelex.keyboard.KeyCommand
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Giữ ⇧ + kéo phím cách = mở rộng vùng chọn ("Vuốt phím để sao chép/dán"): toán vùng chọn
 * thuần ([ShiftSelect]) + IcProxy trên FakeEditor; ánh xạ lệnh vuốt → ô bảng sửa.
 */
class ShiftSelectTest {

    // MARK: toán thuần

    @Test fun caretExtendsRightThenBackPastAnchor() {
        // "abc|def" — con trỏ ở 3 (không chọn), văn bản đọc quanh đó.
        val s = ShiftSelect.begin(3, 3, "abc", "", "def")!!
        assertEquals(3, s.anchor)
        assertEquals(5, s.move(2))
        assertEquals(3 to 5, s.start to s.end)
        assertEquals(1, s.move(-4))                 // qua neo: vùng chọn ngược 1..3
        assertEquals(3, s.anchor)
        assertEquals(1 to 3, s.start to s.end)
    }

    @Test fun existingSelectionAnchorsAtStartAndMovesEnd() {
        // "ab[cd]ef": neo = đầu (2), focus = cuối (4).
        val s = ShiftSelect.begin(2, 4, "ab", "cd", "ef")!!
        assertEquals(2, s.anchor); assertEquals(4, s.focus)
        assertEquals(5, s.move(1))
        assertEquals(3, s.move(-2))
        assertEquals(2 to 3, s.start to s.end)
    }

    @Test fun clampsAtWindowEdges() {
        val s = ShiftSelect.begin(1, 1, "a", "", "b")!!
        assertEquals(2, s.move(10))
        assertNull(s.move(1))                       // cuối ô: không đổi
        assertEquals(0, s.move(-10))
        assertNull(s.move(-1))                      // đầu ô
        assertNull(s.move(0))
    }

    @Test fun movesByGraphemeNotUtf16() {
        // "x😀|" và "é" (e + dấu sắc kết hợp) đi một bước = trọn grapheme.
        val s = ShiftSelect.begin(3, 3, "x😀", "", "éz")!!
        assertEquals(1, s.move(-1))                 // 😀 = 2 UTF-16
        assertEquals(3, s.move(1))
        assertEquals(5, s.move(1))                  // é kết hợp = 2 UTF-16
    }

    @Test fun inconsistentReadsRejected() {
        assertNull(ShiftSelect.begin(2, 4, "ab", "c", "ef"))      // vùng chọn đọc về sai độ dài
        assertNull(ShiftSelect.begin(1, 1, "abc", "", ""))        // chữ trước dài hơn vị trí
        assertNull(ShiftSelect.begin(-1, -1, "", "", ""))
    }

    // MARK: IcProxy trên ô giả

    private val tracker = SelectionTracker()

    private fun reliableProxy(ed: FakeEditor): IcProxy {
        tracker.reset(ed.selStart, ed.selEnd)
        val p = IcProxy({ ed }, tracker)
        p.startInput(null, false)
        p.begin(); p.insertText("x"); p.end(); tracker.onUpdate(ed.selStart, ed.selEnd)
        p.begin(); p.deleteCodePoints(1); p.end(); tracker.onUpdate(ed.selStart, ed.selEnd)
        return p
    }

    @Test fun proxyExtendsFromCaretWithSetSelection() {
        val ed = FakeEditor("hello world", 5)
        val p = reliableProxy(ed)
        val s = p.beginShiftSelect()!!
        s.move(3); p.applyShiftSelect(s)
        assertEquals(5, ed.selStart); assertEquals(8, ed.selEnd)
        assertEquals(" wo", ed.selectedText())
        s.move(-5); p.applyShiftSelect(s)
        assertEquals(5, ed.selStart); assertEquals(3, ed.selEnd)   // ngược: neo 5, focus 3
        assertEquals("lo", ed.selectedText())
    }

    @Test fun proxyExtendsExistingSelection() {
        val ed = FakeEditor("hello world", 0, 5)
        tracker.reset(0, 5)
        val p = IcProxy({ ed }, tracker)
        val s = p.beginShiftSelect()!!
        assertEquals(0, s.anchor); assertEquals(5, s.focus)
        s.move(6); p.applyShiftSelect(s)
        assertEquals("hello world", ed.selectedText())
    }

    @Test fun unknownCaretFallsBackToShiftArrows() {
        val ed = FakeEditor("abc", 3)
        tracker.reset(-1, -1)
        val p = IcProxy({ ed }, tracker)
        assertNull(p.beginShiftSelect())
        val ed2 = FakeEditor("abc", 3)
        val p2 = reliableProxy(ed2)
        p2.rawKeys = true
        assertNull(p2.beginShiftSelect())           // TYPE_NULL: chỉ phím
    }

    // MARK: lệnh vuốt → bảng sửa

    @Test fun keyCommandsMapToEditActions() {
        assertEquals(EditAction.COPY, KeyCommands.editAction(KeyCommand.COPY))
        assertEquals(EditAction.CUT, KeyCommands.editAction(KeyCommand.CUT))
        assertEquals(EditAction.PASTE, KeyCommands.editAction(KeyCommand.PASTE))
        assertEquals(EditAction.SELECT_ALL, KeyCommands.editAction(KeyCommand.SELECT_ALL))
        assertEquals(EditAction.UNDO, KeyCommands.editAction(KeyCommand.UNDO))
        assertEquals(EditAction.REDO, KeyCommands.editAction(KeyCommand.REDO))
        assertEquals(EditAction.COPY.needsSelection, KeyCommand.COPY.needsSelection)
        assertEquals(EditAction.CUT.needsSelection, KeyCommand.CUT.needsSelection)
    }
}
