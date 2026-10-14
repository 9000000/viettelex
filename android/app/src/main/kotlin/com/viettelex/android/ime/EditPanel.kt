package com.viettelex.android.ime

import com.viettelex.keyboard.TextTool
import java.text.BreakIterator
import com.viettelex.keyboard.tr

/**
 * Bảng sửa văn bản (mở bằng icon con trỏ trên thanh gợi ý): thay chỗ phím chữ bằng lưới
 * 4×4 — mũi tên, đầu/cuối dòng, chọn / chọn từ / chọn hết, sao chép / cắt / dán, hoàn
 * tác / làm lại, xoá, ABC. Ô là [LaidKey] kind [KeyKind.EDIT] (insert = tên [EditAction])
 * nên dùng chung router, vẽ, và thu hẹp một tay của [KeyboardView].
 *
 * Android làm được TẤT CẢ qua InputConnection ([EditCommands]); iOS bản riêng ẩn các nút
 * extension không làm được (xem iOS/Keyboard/TextEditing.swift).
 */
enum class EditAction {
    LEFT, RIGHT, UP, DOWN, LINE_START, LINE_END,
    /** Bật/tắt chế độ chọn: mũi tên / đầu-cuối dòng mở rộng vùng chọn (Shift). */
    SELECT,
    SELECT_WORD, SELECT_ALL, COPY, CUT, PASTE, UNDO, REDO, DELETE,
    /** Về plane chữ. */
    CLOSE;

    /** Giữ để lặp (như giữ ⌫). */
    val repeats: Boolean get() = this == LEFT || this == RIGHT || this == UP || this == DOWN || this == DELETE

    /** Cần có vùng chọn mới có nghĩa (vẽ mờ khi không có). */
    val needsSelection: Boolean get() = this == COPY || this == CUT

    companion object {
        fun of(s: String): EditAction? = values().firstOrNull { it.name == s }
    }
}

/** Lệnh vuốt phím ([com.viettelex.keyboard.KeyCommandGesture]) → ô bảng sửa tương ứng (cùng [EditCommands]). */
object KeyCommands {
    fun editAction(c: com.viettelex.keyboard.KeyCommand): EditAction = when (c) {
        com.viettelex.keyboard.KeyCommand.COPY -> EditAction.COPY
        com.viettelex.keyboard.KeyCommand.CUT -> EditAction.CUT
        com.viettelex.keyboard.KeyCommand.PASTE -> EditAction.PASTE
        com.viettelex.keyboard.KeyCommand.SELECT_ALL -> EditAction.SELECT_ALL
        com.viettelex.keyboard.KeyCommand.UNDO -> EditAction.UNDO
        com.viettelex.keyboard.KeyCommand.REDO -> EditAction.REDO
    }
}

object EditPanel {
    /** Lưới theo hàng (trên → dưới). Mũi tên xếp hình chữ thập quanh "Chọn". */
    val GRID: List<List<EditAction>> = listOf(
        listOf(EditAction.LINE_START, EditAction.UP, EditAction.LINE_END, EditAction.SELECT_ALL),
        listOf(EditAction.LEFT, EditAction.SELECT, EditAction.RIGHT, EditAction.COPY),
        listOf(EditAction.SELECT_WORD, EditAction.DOWN, EditAction.DELETE, EditAction.CUT),
        listOf(EditAction.CLOSE, EditAction.UNDO, EditAction.REDO, EditAction.PASTE),
    )

    /** insert của ô công cụ văn bản: TOOL_PREFIX + [TextTool.id]. */
    const val TOOL_PREFIX = "TOOL:"

    /** insert của ô "Dịch" (dịch trên máy, PlusGate TRANSLATE) trên hàng công cụ. */
    const val TRANSLATE_INSERT = TOOL_PREFIX + "translate"

    fun toolOf(insert: String): TextTool? =
        if (insert.startsWith(TOOL_PREFIX)) TextTool.byId(insert.substring(TOOL_PREFIX.length)) else null

    /** Nhãn ngắn trên hàng công cụ (5 ô chung hàng) — khớp iOS TextEditing.toolTitle. */
    fun toolTitle(t: TextTool): String = when (t) {
        TextTool.UPPER -> tr("HOA")
        TextTool.LOWER -> tr("thường")
        TextTool.TITLE -> tr("Hoa Từ")
        TextTool.SENTENCE -> tr("Hoa câu")
        TextTool.STRIP_DIACRITICS -> tr("Xoá dấu")
    }

    fun label(a: EditAction): String = when (a) {
        EditAction.LEFT -> "←"
        EditAction.RIGHT -> "→"
        EditAction.UP -> "↑"
        EditAction.DOWN -> "↓"
        EditAction.LINE_START -> "⇤"
        EditAction.LINE_END -> "⇥"
        EditAction.SELECT -> tr("Chọn")
        EditAction.SELECT_WORD -> tr("Chọn từ")
        EditAction.SELECT_ALL -> tr("Chọn hết")
        EditAction.COPY -> tr("Sao chép")
        EditAction.CUT -> tr("Cắt")
        EditAction.PASTE -> tr("Dán")
        EditAction.UNDO -> tr("Hoàn tác")
        EditAction.REDO -> tr("Làm lại")
        EditAction.DELETE -> ""          // icon ⌫
        EditAction.CLOSE -> "ABC"
    }

    /** Ô vẽ chữ to (mũi tên) thay vì nhãn chức năng. */
    fun isGlyph(a: EditAction): Boolean = when (a) {
        EditAction.LEFT, EditAction.RIGHT, EditAction.UP, EditAction.DOWN,
        EditAction.LINE_START, EditAction.LINE_END -> true
        else -> false
    }

    /**
     * Dựng lưới vào [out] trên toàn bề ngang [c] (KeyLayout lo thu hẹp một tay).
     * [LayoutConfig.editTools] ⇒ thêm hàng thứ 5: các [TextTool] (insert TOOL_PREFIX+id).
     */
    fun build(out: MutableList<LaidKey>, c: LayoutConfig) {
        val d = c.density
        val m = KeyLayout.ROW_MARGIN_H * d
        val mv = KeyLayout.ROW_MARGIN_V * d
        val gap = KeyLayout.KEY_SPACING * d
        val hasTools = c.editTools || c.editTranslate
        val rows = GRID.size + if (hasTools) 1 else 0
        val rowH = c.keyAreaPx / rows
        if (hasTools) {
            // (nhãn, insert): các TextTool (nếu bật) rồi ô "Dịch" (nếu bật).
            val cells = (if (c.editTools) TextTool.entries.map { toolTitle(it) to TOOL_PREFIX + it.id } else emptyList()) +
                (if (c.editTranslate) listOf(tr("Dịch") to TRANSLATE_INSERT) else emptyList())
            val w = (c.widthPx - 2 * m - gap * (cells.size - 1)) / cells.size
            val t = GRID.size * rowH + mv
            val b = (GRID.size + 1) * rowH - mv
            var x = m
            for ((l, ins) in cells) {
                out += LaidKey(KeyKind.EDIT, l, l, ins, x, t, x + w, b)
                x += w + gap
            }
        }
        for ((r, row) in GRID.withIndex()) {
            val n = row.size
            val w = (c.widthPx - 2 * m - gap * (n - 1)) / n
            val t = r * rowH + mv
            val b = (r + 1) * rowH - mv
            var x = m
            for (a in row) {
                val l = label(a)
                out += LaidKey(KeyKind.EDIT, l, l, a.name, x, t, x + w, b)
                x += w + gap
            }
        }
    }
}

/** Tính toán văn bản thuần của bảng sửa (UTF-16, tương đối con trỏ) — pinned by EditPanelTest. */
object EditOps {
    /** Số UTF-16 lùi về đầu dòng logic (sau ngắt dòng cuối trong [before]). */
    fun lineStartBack(before: String): Int {
        val br = VerticalMove.breaks(before).lastOrNull() ?: return before.length
        return before.length - br.second
    }

    /** Số UTF-16 tiến tới cuối dòng logic (trước ngắt dòng đầu trong [after]). */
    fun lineEndForward(after: String): Int =
        VerticalMove.breaks(after).firstOrNull()?.first ?: after.length

    /** Code point thuộc "từ": chữ, số, dấu kết hợp (tiếng Việt NFD), '_' và nháy trong từ. */
    private fun isWordCp(cp: Int): Boolean {
        if (Character.isLetterOrDigit(cp) || cp == '_'.code) return true
        return when (Character.getType(cp)) {
            Character.NON_SPACING_MARK.toInt(), Character.COMBINING_SPACING_MARK.toInt(),
            Character.ENCLOSING_MARK.toInt() -> true
            else -> false
        }
    }

    /**
     * Vùng "Chọn từ" tương đối con trỏ: (start ≤ 0, end ≥ start). Con trỏ trong / sát
     * một từ ⇒ cả từ đó; đứng giữa khoảng trắng ⇒ từ ngay TRƯỚC (như Gboard); không có
     * từ nào ⇒ null.
     */
    fun wordAround(before: String, after: String): Pair<Int, Int>? {
        var back = 0
        var i = before.length
        while (i > 0) {
            val cp = before.codePointBefore(i)
            if (!isWordCp(cp)) break
            i -= Character.charCount(cp); back += Character.charCount(cp)
        }
        var fwd = 0
        var j = 0
        while (j < after.length) {
            val cp = after.codePointAt(j)
            if (!isWordCp(cp)) break
            j += Character.charCount(cp); fwd += Character.charCount(cp)
        }
        if (back > 0 || fwd > 0) return -back to fwd
        // Giữa khoảng trắng / dấu câu: lùi qua phần không-từ rồi lấy từ trước đó.
        var k = before.length
        while (k > 0 && !isWordCp(before.codePointBefore(k))) k -= Character.charCount(before.codePointBefore(k))
        if (k == 0) return null
        val end = k
        while (k > 0 && isWordCp(before.codePointBefore(k))) k -= Character.charCount(before.codePointBefore(k))
        return (k - before.length) to (end - before.length)
    }

    /** Grapheme (cho test / an toàn biên). */
    fun graphemes(s: String): Int {
        if (s.isEmpty()) return 0
        val bi = BreakIterator.getCharacterInstance(); bi.setText(s)
        var n = 0
        while (bi.next() != BreakIterator.DONE) n++
        return n
    }
}

/**
 * Thực thi một [EditAction] trên ô nhập (IME gọi TRONG batch [IcProxy.begin]/end, sau khi
 * chốt từ đang soạn). THUẦN trên [EditorPort] — pinned by EditPanelTest (FakeEditor).
 *
 * - Mũi tên khi không chọn: tái dùng trackpad ([IcProxy.moveCursor] / [IcProxy.moveCursorVertical]
 *   — setSelection an toàn biên, DPAD khi không đọc được).
 * - Chế độ chọn: Shift + DPAD / MOVE_HOME / MOVE_END — app tự mở rộng vùng chọn theo
 *   dòng HIỂN THỊ (TextView ArrowKeyMovementMethod, WebView), giống bàn phím cứng.
 * - Đầu/cuối dòng không chọn: theo ngắt dòng trong văn bản quanh con trỏ (setSelection);
 *   không biết con trỏ ⇒ MOVE_HOME / MOVE_END.
 * - Chọn hết / sao chép / cắt / dán / hoàn tác / làm lại: performContextMenuAction; app
 *   từ chối ⇒ phím tắt Ctrl+A/C/X/V, Ctrl+Z, Ctrl+Shift+Z.
 */
object EditCommands {
    /** @return true nếu đã làm gì đó với ô (IME cập nhật gợi ý / auto-shift). */
    fun run(a: EditAction, selecting: Boolean, proxy: IcProxy, tracker: SelectionTracker): Boolean {
        val c = proxy.editorPort() ?: return false
        when (a) {
            EditAction.LEFT, EditAction.RIGHT -> {
                val left = a == EditAction.LEFT
                if (selecting) keyed(c, proxy, tracker, if (left) EditorPort.PortKey.LEFT else EditorPort.PortKey.RIGHT, shift = true)
                else proxy.moveCursor(if (left) -1 else 1)
            }
            EditAction.UP, EditAction.DOWN -> {
                val up = a == EditAction.UP
                if (selecting) keyed(c, proxy, tracker, if (up) EditorPort.PortKey.UP else EditorPort.PortKey.DOWN, shift = true)
                else proxy.moveCursorVertical(if (up) -1 else 1)
            }
            EditAction.LINE_START, EditAction.LINE_END -> {
                val start = a == EditAction.LINE_START
                if (selecting || !lineJump(c, proxy, tracker, start))
                    keyed(c, proxy, tracker, if (start) EditorPort.PortKey.HOME else EditorPort.PortKey.END, shift = selecting)
            }
            EditAction.SELECT_WORD -> return selectWord(c, proxy, tracker)
            EditAction.SELECT_ALL -> menu(c, proxy, tracker, EditorPort.MenuAction.SELECT_ALL, EditorPort.PortKey.A)
            EditAction.COPY -> {
                // Không đổi văn bản / con trỏ: không động tới tracker.
                if (!c.menuAction(EditorPort.MenuAction.COPY)) c.sendKeyMeta(EditorPort.PortKey.C, ctrl = true)
            }
            EditAction.CUT -> menu(c, proxy, tracker, EditorPort.MenuAction.CUT, EditorPort.PortKey.X)
            EditAction.PASTE -> menu(c, proxy, tracker, EditorPort.MenuAction.PASTE, EditorPort.PortKey.V)
            EditAction.UNDO -> menu(c, proxy, tracker, EditorPort.MenuAction.UNDO, EditorPort.PortKey.Z)
            EditAction.REDO -> menu(c, proxy, tracker, EditorPort.MenuAction.REDO, EditorPort.PortKey.Z, shift = true)
            EditAction.SELECT, EditAction.DELETE, EditAction.CLOSE -> return false   // KeyboardView / IME lo
        }
        return true
    }

    private fun keyed(c: EditorPort, proxy: IcProxy, tracker: SelectionTracker, k: EditorPort.PortKey, shift: Boolean) {
        if (shift) c.sendKeyMeta(k, shift = true) else c.sendKey(k)
        tracker.unknown(); proxy.invalidateShadow()
    }

    private fun menu(c: EditorPort, proxy: IcProxy, tracker: SelectionTracker, m: EditorPort.MenuAction,
                     fallback: EditorPort.PortKey, shift: Boolean = false) {
        if (!c.menuAction(m)) c.sendKeyMeta(fallback, shift = shift, ctrl = true)
        tracker.unknown(); proxy.invalidateShadow()
    }

    /** Đầu/cuối dòng bằng setSelection; false ⇒ không biết chắc con trỏ (dùng phím). */
    private fun lineJump(c: EditorPort, proxy: IcProxy, tracker: SelectionTracker, start: Boolean): Boolean {
        val cur = tracker.cursor
        if (proxy.rawKeys || !tracker.reliable || cur < 0 || tracker.hasSelection) return false
        val pos = if (start) {
            val before = c.textBefore(IcProxy.VERTICAL_CAP)?.toString() ?: return false
            cur - EditOps.lineStartBack(before)
        } else {
            val after = c.textAfter(IcProxy.VERTICAL_CAP)?.toString() ?: return false
            cur + EditOps.lineEndForward(after)
        }
        if (pos == cur) return true
        if (!c.setSelection(pos, pos)) { tracker.unknown(); proxy.invalidateShadow(); return true }
        tracker.movedTo(pos); proxy.invalidateShadow()
        return true
    }

    private fun selectWord(c: EditorPort, proxy: IcProxy, tracker: SelectionTracker): Boolean {
        val cur = tracker.cursor
        if (proxy.rawKeys || cur < 0 || tracker.hasSelection) return false
        val before = c.textBefore(IcProxy.CONTEXT_CAP)?.toString() ?: return false
        val after = c.textAfter(IcProxy.CONTEXT_CAP)?.toString() ?: return false
        val (s, e) = EditOps.wordAround(before, after) ?: return false
        if (!c.setSelection(cur + s, cur + e)) { tracker.unknown(); proxy.invalidateShadow(); return false }
        tracker.selectedByMe(cur + s, cur + e); proxy.invalidateShadow()
        return true
    }
}
