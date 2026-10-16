package com.viettelex.android.ime

import com.viettelex.keyboard.BarLayout
import com.viettelex.keyboard.SuggestionSet
import com.viettelex.keyboard.SuggestionSlots
import com.viettelex.keyboard.ClipChip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Lỗi iOS 27/09/2026: thẻ Dán vẽ chồng chữ gợi ý, slot đổi bề rộng theo nội dung. */
class StripGeometryTest {
    @Test fun threeEqualContiguousSlots() {
        val l = FloatArray(3); val r = FloatArray(3)
        StripGeometry.thirds(100f, 400f, l, r)
        assertEquals(100f, l[0]); assertEquals(400f, r[2])
        for (i in 0..2) assertEquals(100f, r[i] - l[i], 0.001f)
        assertEquals(r[0], l[1]); assertEquals(r[1], l[2])
    }

    @Test fun gboardProportions() {
        // #112: strip 42 dp ≈ 0.75 hàng phím chuẩn (56 dp); pill / ô nhấn nằm gọn trong dải.
        val row = KeyLayout.keyAreaDp(false, false, 0) / 4f
        assertEquals(0.75f, KeyLayout.OPEN_STRIP / row, 0.01f)
        val half = StripGeometry.PILL_H / 2
        assertTrue(KeyLayout.BAR_CY - half >= 0f && KeyLayout.BAR_CY + half <= KeyLayout.OPEN_STRIP)
        assertTrue(StripGeometry.WORD_SP >= 16f)
        // Icon: thu gọn 14 dp, mở 22 dp (⌄ bớt 2), nội suy theo độ mở và kẹp 0…1.
        assertEquals(14f, StripGeometry.iconDp(0f), 0.001f)
        assertEquals(22f, StripGeometry.iconDp(1f), 0.001f)
        assertEquals(20f, StripGeometry.iconDp(1f, delta = 2f), 0.001f)
        assertEquals(18f, StripGeometry.iconDp(0.5f), 0.001f)
        assertEquals(22f, StripGeometry.iconDp(3f), 0.001f)
    }

    @Test fun pasteCardReplacesWholeBar() {
        // Có chữ gợi ý + thẻ Dán ⇒ chỉ thẻ Dán (không slot nào vẽ chồng).
        val set = SuggestionSet(literal = "xin", word = "xin", word2 = "xinh", paste = true)
        assertSame(BarLayout.PasteCard, SuggestionSlots.arrange(set, undoAsPill = true, bestInMiddle = true))
    }

    // #113: đang gõ có gợi ý ⇒ ẩn icon con trỏ + 📋, 3 slot ăn phần trống; ☰/⌄ giữ nguyên.
    private fun slotWidth(width: Float, clipButton: Boolean, tools: Boolean): Float {
        val l = FloatArray(3); val r = FloatArray(3)
        val zone = KeyLayout.STRIP_ZONE_W
        StripGeometry.thirds(StripGeometry.barLeft(zone, StripGeometry.TOOL_W, tools),
            StripGeometry.barRight(width, zone, StripGeometry.CLIP_W, clipButton, tools), l, r)
        for (i in 0..2) assertEquals(r[0] - l[0], r[i] - l[i], 0.001f)   // vẫn 3 ô bằng nhau
        return r[0] - l[0]
    }

    @Test fun suggestionsWidenSlotsByHidingTools() {
        val w = 411f
        // Idle (không gợi ý): như cũ — ☰ zone + con trỏ 44 + … + 📋 40 + ⌄ zone.
        assertEquals((w - 2 * 52f - 44f - 40f) / 3f, slotWidth(w, clipButton = true, tools = true), 0.001f)
        assertEquals((w - 2 * 52f - 44f) / 3f, slotWidth(w, clipButton = false, tools = true), 0.001f)
        // Có gợi ý: chỉ trừ 2 zone (☰, ⌄) — mỗi slot rộng thêm (44 + 40) / 3 dp.
        val wide = slotWidth(w, clipButton = true, tools = false)
        assertEquals((w - 2 * 52f) / 3f, wide, 0.001f)
        assertEquals(28f, wide - slotWidth(w, clipButton = true, tools = true), 0.001f)
        assertEquals(wide, slotWidth(w, clipButton = false, tools = false), 0.001f)
        assertEquals(52f, StripGeometry.barLeft(52f, 44f, toolsShown = false), 0.001f)
    }

    @Test fun toolsHiddenOnlyWhileContent() {
        assertTrue(StripGeometry.toolsShown(hasContent = false, editOpen = false, clipOpen = false))
        assertFalse(StripGeometry.toolsShown(hasContent = true, editOpen = false, clipOpen = false))
        // Bảng sửa / lịch sử clipboard đang mở ⇒ icon vẫn hiện để đóng được.
        assertTrue(StripGeometry.toolsShown(hasContent = true, editOpen = true, clipOpen = false))
        assertTrue(StripGeometry.toolsShown(hasContent = true, editOpen = false, clipOpen = true))
    }

    private fun content(set: SuggestionSet) =
        StripGeometry.hasContent(SuggestionSlots.arrange(set, undoAsPill = true, bestInMiddle = true), set.idle)

    @Test fun whatCountsAsContent() {
        assertFalse(content(SuggestionSet()))                                       // trống
        assertFalse(content(SuggestionSet(nextWords = listOf("tôi", "em", "anh"), idle = true)))  // ô trống: chữ đệm
        assertTrue(content(SuggestionSet(literal = "xin", word = "xin", word2 = "xinh")))         // đang soạn
        assertTrue(content(SuggestionSet(nextWords = listOf("chào", "bạn", "anh"))))              // sau một từ
        assertTrue(content(SuggestionSet(nextWords = listOf("gmail.com", "yahoo.com"))))          // chip email @
        assertTrue(content(SuggestionSet(number = "1.000")))                                      // chip số
        assertTrue(content(SuggestionSet(math = "= 4")))                                          // phép tính
        assertTrue(content(SuggestionSet(paste = true, idle = true)))                             // thẻ Dán
        assertTrue(content(SuggestionSet(paste = true, clipChips = listOf(ClipChip(ClipChip.Kind.OTP, "482913", "OTP 482913")))))
        assertTrue(content(SuggestionSet(emojis = listOf("😀"))))
    }
    /** "Nút emoji" = Thanh trên: ô 😊 40 dp cạnh ⌄ LUÔN trừ khỏi bar (cả khi có gợi ý), 📋 bên trái nó. */
    @Test fun emojiButtonAlwaysReserved() {
        val w = 411f; val zone = KeyLayout.STRIP_ZONE_W
        for (tools in listOf(true, false)) for (clip in listOf(true, false)) {
            val plain = StripGeometry.barRight(w, zone, StripGeometry.CLIP_W, clip, tools)
            val emoji = StripGeometry.barRight(w, zone, StripGeometry.CLIP_W, clip, tools, emojiButton = true)
            assertEquals(StripGeometry.EMOJI_W, plain - emoji, 0.001f)
            assertEquals(w - zone - emoji, StripGeometry.rightExtraW(StripGeometry.CLIP_W, clip, tools, emojiButton = true), 0.001f)
        }
        // Có gợi ý (tools ẩn): chỉ còn 😊 bên phải; 3 slot vẫn bằng nhau.
        val l = FloatArray(3); val r = FloatArray(3)
        StripGeometry.thirds(StripGeometry.barLeft(zone, StripGeometry.TOOL_W, false),
            StripGeometry.barRight(w, zone, StripGeometry.CLIP_W, true, false, emojiButton = true), l, r)
        assertEquals((w - 2 * zone - StripGeometry.EMOJI_W) / 3f, r[0] - l[0], 0.001f)
        assertEquals(0f, StripGeometry.rightExtraW(StripGeometry.CLIP_W, false, true), 0.001f)
    }
}
