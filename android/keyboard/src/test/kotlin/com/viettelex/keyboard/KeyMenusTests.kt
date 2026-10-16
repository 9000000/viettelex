package com.viettelex.keyboard

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Popup giữ "," (dấu câu) và menu giữ 😊 (🌐 🎤 ✋ ⚙) — Android, hàng ô DomainPopup. */
class KeyMenusTests {
    @AfterTest fun reset() { L10n.lang = L10n.DEFAULT }

    @Test fun commaChoicesNeverContainMic() {
        assertEquals(listOf(".", ",", "?", "!", ":", ";", "'", "\"", "-", "…"), CommaPopup.choices)
        assertEquals(CommaPopup.choices, CommaPopup.choices(",", lettersPlane = true))
        assertTrue(CommaPopup.choices.none { "🎤" in it || it.isBlank() })
        assertEquals(".", CommaPopup.choices[CommaPopup.PRESELECT])   // #113: giữ "," chọn sẵn "."
        // Chỉ phím "," bàn chữ; "/" (URL), "@" (email), "." và plane số: không có popup này.
        for (k in listOf("/", "@", ".")) assertTrue(CommaPopup.choices(k, lettersPlane = true).isEmpty())
        assertTrue(CommaPopup.choices(",", lettersPlane = false).isEmpty())
        // "." ô thường không có đuôi tên miền ⇒ view rơi sang CommaPopup chỉ với ",".
        assertTrue(DomainPopup.choices(DomainPopup.Field.NORMAL, ",", lettersPlane = true).isEmpty())
    }

    /** "Phím cạnh dấu cách" = Dấu chấm: giữ "." ra cùng bộ dấu câu, "," chọn sẵn, "." thứ hai. */
    @Test fun periodSideKeyChoices() {
        val p = CommaPopup.choices(".", lettersPlane = true, periodKey = true)
        assertEquals(listOf(",", ".", "?", "!", ":", ";", "'", "\"", "-", "…"), p)
        assertEquals(",", p[CommaPopup.PRESELECT])
        assertEquals(CommaPopup.choices.toSet(), p.toSet())
        // "." không phải phím cạnh space (tablet / ô URL, email) ⇒ không popup này; "," vẫn như cũ.
        assertTrue(CommaPopup.choices(".", lettersPlane = true, periodKey = false).isEmpty())
        assertTrue(CommaPopup.choices(".", lettersPlane = false, periodKey = true).isEmpty())
        assertEquals(CommaPopup.choices, CommaPopup.choices(",", lettersPlane = true, periodKey = true))
    }

    /** "Nút emoji" / "Cỡ chữ trên phím" (16/10/2026): đọc cài đặt, mặc định, sao lưu. */
    @Test fun emojiPlacementAndLabelSizeParsing() {
        assertEquals(EmojiKeyPlacement.BOTTOM, EmojiKeyPlacement.of(null))
        assertEquals(EmojiKeyPlacement.BOTTOM, EmojiKeyPlacement.of("strip"))
        assertEquals(EmojiKeyPlacement.TOP, EmojiKeyPlacement.of("top"))
        assertEquals(KeyLabelSize.MEDIUM, KeyLabelSize.of("huge"))
        assertEquals(KeyLabelSize.LARGE, KeyLabelSize.of("large"))
        val s = KeyboardSettings.load { when (it) { Keys.EMOJI_KEY_PLACEMENT -> "top"; Keys.KEY_LABEL_SIZE -> "large"; else -> null } }
        assertEquals(EmojiKeyPlacement.TOP, s.emojiKeyPlacement)
        assertEquals(KeyLabelSize.LARGE, s.keyLabelSize)
        val d = KeyboardSettings.load { null }
        assertEquals(EmojiKeyPlacement.BOTTOM, d.emojiKeyPlacement)
        assertEquals(KeyLabelSize.MEDIUM, d.keyLabelSize)
        assertEquals("emojiKeyPlacement", Keys.EMOJI_KEY_PLACEMENT)   // cùng tên iOS App Group
        assertEquals(SettingKind.Choice("bottom", setOf("bottom", "top")),
            BackupSettings.all.first { it.key == Keys.EMOJI_KEY_PLACEMENT }.kind)
        assertEquals(SettingKind.Choice("medium", setOf("medium", "large")),
            BackupSettings.all.first { it.key == Keys.KEY_LABEL_SIZE }.kind)
        assertEquals(SettingKind.IntRange(0, -10..18), BackupSettings.all.first { it.key == Keys.ROW_HEIGHT_ADJUST }.kind)
        assertEquals(18, KeyboardSettings.load { if (it == Keys.ROW_HEIGHT_ADJUST) 99 else null }.rowHeightAdjust)
        assertEquals(15, KeyboardSettings.load { if (it == Keys.ROW_HEIGHT_ADJUST) 15 else null }.rowHeightAdjust)
    }

    @Test fun spaceSideKeyParsing() {
        assertEquals(SpaceSideKey.COMMA, SpaceSideKey.of(null))
        assertEquals(SpaceSideKey.COMMA, SpaceSideKey.of("dot"))
        assertEquals(SpaceSideKey.COMMA, SpaceSideKey.of(3))
        assertEquals(SpaceSideKey.PERIOD, SpaceSideKey.of("period"))
        assertEquals(SpaceSideKey.OFF, SpaceSideKey.of("off"))
        assertEquals(setOf("comma", "period", "both", "off"), SpaceSideKey.IDS)
        assertEquals(SpaceSideKey.BOTH, SpaceSideKey.of("both"))
        assertEquals(SpaceSideKey.BOTH, KeyboardSettings.load { if (it == Keys.SPACE_SIDE_KEY) "both" else null }.spaceSideKey)
        assertEquals(SpaceSideKey.PERIOD, KeyboardSettings.load { if (it == Keys.SPACE_SIDE_KEY) "period" else null }.spaceSideKey)
        assertEquals(SpaceSideKey.COMMA, KeyboardSettings.load { null }.spaceSideKey)
        // Sao lưu: có trong Spec, mặc định "comma", giá trị lạ bỏ qua.
        val spec = BackupSettings.all.first { it.key == Keys.SPACE_SIDE_KEY }
        assertEquals(SettingKind.Choice("comma", setOf("comma", "period", "both", "off")), spec.kind)
    }

    /** "," cạnh phải space (điện thoại 390 dp: tâm ≈ 0.73 W) ⇒ hàng loe sang trái, ô "," gần ngón. */
    private val itemW = CommaPopup.itemWidthDp(tablet = false)
    private val keyX = 285f
    private val layout = DomainPopup.layout(keyX, itemW, CommaPopup.choices.size, 390f)

    @Test fun commaRowFlaresLeftFromKey() {
        assertTrue(layout.mirrored)
        assertTrue(layout.originX >= 2f && layout.originX + layout.width <= 388f)
        val c0 = layout.slotMinX(0) + itemW / 2
        assertTrue(kotlin.math.abs(c0 - keyX) < 2 * itemW, "ô \",\" ở $c0, phím ở $keyX")
    }

    @Test fun commaHoldReleaseInPlaceTypesPeriod() {
        val commits = KeyCommitQueue(); val key = Any(); val out = ArrayList<String>()
        commits.arm(key) { out += "," }
        val hold = DomainPopup.Hold(CommaPopup.choices)
        assertTrue(hold.fire(commits, key, layout, 0f, 100f, keyX, 80f) { out += it })
        assertEquals(CommaPopup.PRESELECT, hold.selection)
        commits.release(key)
        assertEquals(listOf("."), out)   // giữ rồi nhả tại chỗ ⇒ "." (#113)
    }

    @Test fun commaSlideInsertsCharacter() {
        val commits = KeyCommitQueue(); val key = Any(); val out = ArrayList<String>()
        commits.arm(key) { out += "," }
        val hold = DomainPopup.Hold(CommaPopup.choices)
        hold.fire(commits, key, layout, 0f, 100f, keyX, 80f) { out += it }
        hold.move(keyX - itemW, 80f)                  // một ô sang trái (hàng loe trái) ⇒ ","
        assertEquals(",", hold.chosen)
        commits.release(key)
        assertEquals(listOf(","), out)
    }

    @Test fun emojiMenuActions() {
        assertEquals(listOf(EmojiKeyAction.SWITCH_KEYBOARD, EmojiKeyAction.VOICE, EmojiKeyAction.ONE_HAND,
            EmojiKeyAction.FLOATING, EmojiKeyAction.SETTINGS),
            EmojiKeyMenu.actions(voiceAvailable = true, oneHandAvailable = true, floatingAvailable = true))
        assertEquals(listOf(EmojiKeyAction.SWITCH_KEYBOARD, EmojiKeyAction.ONE_HAND, EmojiKeyAction.SETTINGS),
            EmojiKeyMenu.actions(voiceAvailable = false, oneHandAvailable = true, floatingAvailable = false))
        // Tablet: không một tay (thả nổi vẫn có).
        assertEquals(listOf(EmojiKeyAction.SWITCH_KEYBOARD, EmojiKeyAction.FLOATING, EmojiKeyAction.SETTINGS),
            EmojiKeyMenu.actions(voiceAvailable = false, oneHandAvailable = false, floatingAvailable = true))
        // Đổi bàn phím luôn đầu và chọn sẵn (nhả tại chỗ = hành vi giữ 😊 cũ).
        for (v in listOf(true, false)) for (o in listOf(true, false)) for (f in listOf(true, false))
            assertEquals(EmojiKeyAction.SWITCH_KEYBOARD, EmojiKeyMenu.actions(v, o, f)[EmojiKeyMenu.PRESELECT])
    }

    /** #112: mục 🪟 có mặt, ngay trước ⚙; nhãn đổi theo trạng thái (thả nổi ↔ gắn lại). */
    @Test fun floatingMenuItemToggles() {
        // Đang nổi: IME tắt một tay ⇒ menu không có ✋ nhưng có 🪟 (để gắn lại).
        val floatingActs = EmojiKeyMenu.actions(voiceAvailable = true, oneHandAvailable = false, floatingAvailable = true)
        assertTrue(EmojiKeyAction.FLOATING in floatingActs)
        assertFalse(EmojiKeyAction.ONE_HAND in floatingActs)
        assertEquals(EmojiKeyAction.SETTINGS, floatingActs.last())
        assertEquals(floatingActs.size - 2, floatingActs.indexOf(EmojiKeyAction.FLOATING))
        assertEquals("Thả nổi bàn phím", EmojiKeyMenu.label(EmojiKeyAction.FLOATING, false, floatingOn = false))
        assertEquals("Gắn bàn phím xuống đáy", EmojiKeyMenu.label(EmojiKeyAction.FLOATING, false, floatingOn = true))
        L10n.lang = "en"
        assertEquals("Float keyboard", EmojiKeyMenu.label(EmojiKeyAction.FLOATING, false, floatingOn = false))
        assertEquals("Dock keyboard", EmojiKeyMenu.label(EmojiKeyAction.FLOATING, false, floatingOn = true))
    }

    @Test fun oneHandLabelFollowsState() {
        assertEquals("Chế độ một tay", EmojiKeyMenu.label(EmojiKeyAction.ONE_HAND, oneHandOn = false))
        assertEquals("Tắt chế độ một tay", EmojiKeyMenu.label(EmojiKeyAction.ONE_HAND, oneHandOn = true))
        L10n.lang = "en"
        assertEquals("One-handed mode", EmojiKeyMenu.label(EmojiKeyAction.ONE_HAND, oneHandOn = false))
        assertEquals("Turn off one-handed mode", EmojiKeyMenu.label(EmojiKeyAction.ONE_HAND, oneHandOn = true))
        for (a in EmojiKeyAction.entries) assertTrue(EmojiKeyMenu.label(a, false).isNotBlank())
    }

    @Test fun emojiMenuOpensWithoutCommitQueue() {
        // Menu hành động: không chèn chữ; nhấc tại chỗ = mục đầu, trượt sang = mục kế, trượt xa = huỷ.
        val acts = EmojiKeyMenu.actions(voiceAvailable = true, oneHandAvailable = true, floatingAvailable = true)
        val l = DomainPopup.layout(200f, 48f, acts.size, 390f)
        val hold = DomainPopup.Hold(acts.map { EmojiKeyMenu.label(it, false) })
        assertTrue(hold.open(l, 0f, 100f, 200f, 80f))
        assertFalse(hold.open(l, 0f, 100f, 200f, 80f))
        assertEquals(EmojiKeyAction.SWITCH_KEYBOARD, acts[hold.selection!!])
        val dir = if (l.mirrored) -1 else 1
        hold.move(200f + dir * 48f, 80f)
        assertEquals(EmojiKeyAction.VOICE, acts[hold.selection!!])
        hold.move(200f, 80f + 300f)
        assertNull(hold.selection)
    }
}
