package com.viettelex.keyboard

import java.io.File
import java.nio.file.Files
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * File sao lưu: khứ hồi, tương thích phiên bản, fixture CHUNG với iOS
 * (iOS/KeyboardTests/Fixtures/backup-*.json — iOS BackupTests đọc cùng file), kế hoạch
 * nhập vào SharedPreferences, gộp từ đã học vào userlm.bin.
 */
class BackupTests {
    private fun fixture(name: String): String {
        val f = listOf("../../iOS", "../iOS", "iOS").map { File(it, "KeyboardTests/Fixtures/$name.json") }
            .firstOrNull { it.exists() } ?: error("không thấy iOS/KeyboardTests/Fixtures/$name.json")
        return f.readText()
    }

    /** Payload đúng bằng nội dung backup-android-v1.json. */
    private val androidPayload = BackupPayload(
        createdAt = Instant.parse("2026-09-27T09:30:00Z"), platform = "android",
        settings = linkedMapOf(
            "simpleTelex" to false, "freeMarking" to true, "quickTelex" to true, "modernTone" to false,
            "contextualEnglish" to true, "reEditWords" to true, "autoFixAdjacent" to false, "teencode" to true,
            "autoRestore" to true, "liveSpellCheck" to true, "swipeTyping" to false, "swipeEnglish" to true,
            "hardwareTelex" to false, "showSuggestions" to true, "filterSensitive" to false,
            "templatesEnabled" to true, "showSpaceLogo" to true, "hapticFeedback" to false,
            "numberRow" to false, "rowHeightAdjust" to 4, "shortcutsEnabled" to false),
        shortcuts = mapOf("mn" to "mọi người", "vn" to "Việt Nam"),
        templates = listOf(TemplateItem("📍", "Mình đang trên đường tới"), TemplateItem("IP❓", "https://api.ipify.org")),
    )

    @Test fun roundTrip() {
        val p = androidPayload.copy(learnedWords = LearnedWords(mapOf("việt" to 3), mapOf("tiếng" to mapOf("việt" to 2)),
            mapOf("học\u0001tiếng" to mapOf("việt" to 1))))
        assertEquals(p, BackupCodec.decode(BackupCodec.encode(p)))
    }

    @Test fun roundTripEscapes() {
        val p = BackupPayload(templates = listOf(TemplateItem("\"q\"", "a\\b\n\t\u0001c 😀")), shortcuts = emptyMap())
        val back = BackupCodec.decode(BackupCodec.encode(p))
        assertEquals(p, back)
        assertNull(back.settings); assertNull(back.learnedWords)
    }

    /** Bộ mã hoá Android sinh ĐÚNG nội dung fixture (so theo cây JSON) — iOS đọc fixture này. */
    @Test fun encoderMatchesSharedFixture() {
        assertEquals(MiniJson.parse(fixture("backup-android-v1")), MiniJson.parse(BackupCodec.encode(androidPayload)))
    }

    @Test fun readsAndroidFixture() = assertEquals(androidPayload, BackupCodec.decode(fixture("backup-android-v1")))

    /** File iOS ghi đọc được trên Android (kể cả từ đã học, key tri có \u0001, chuỗi có "\n). */
    @Test fun readsIOSFixture() {
        val p = BackupCodec.decode(fixture("backup-ios-v1"))
        assertEquals("ios", p.platform)
        assertEquals(Instant.parse("2026-09-27T08:00:00Z"), p.createdAt)
        assertEquals(37, p.settings!!.size)             // emojiSuggest/pasteButton chỉ iOS, bị bỏ qua
        assertEquals("wood", p.settings!![Keys.KEY_SOUND_STYLE])
        assertEquals(true, p.settings!![Keys.KEY_SOUND])
        assertEquals(70, p.settings!![Keys.KEY_SOUND_VOLUME])
        assertEquals(true, p.settings!!["autoSpaceAfterPunct"])
        assertEquals(false, p.settings!![Keys.SUGGEST_IN_NO_SUGGEST_FIELDS])   // #113, mặc định BẬT
        assertEquals("en", p.settings!![Keys.UI_LANGUAGE])   // ngôn ngữ giao diện (chuỗi) đi qua sao lưu
        assertEquals(40, p.settings!!["keyboardTransparency"])
        assertEquals(20, p.settings!!["keyLabelTransparency"])
        assertEquals(false, p.settings!!["autoCapitalize"])
        assertEquals(true, p.settings!!["shortcutsEnabled"])
        assertEquals(false, p.settings!!["reEditWords"])
        assertEquals(true, p.settings!!["autoCorrect"])
        assertEquals(-3, p.settings!!["rowHeightAdjust"])
        assertEquals(true, p.settings!!["numberRow"])
        assertNull(p.settings!!["hardwareTelex"])
        assertEquals(mapOf("ko" to "không", "stk" to "số tài khoản", "đc" to "được"), p.shortcuts)
        assertEquals(listOf(TemplateItem("👋", "Chào buổi sáng"), TemplateItem("", "Anh nói \"ok\" nhé\nDòng 2")), p.templates)
        assertEquals(LearnedWords(mapOf("cảm" to 7, "ơn" to 6, "nhiều" to 4, "viettelex" to 5), mapOf("cảm" to mapOf("ơn" to 5)),
            mapOf("cảm\u0001ơn" to mapOf("nhiều" to 3)), listOf("VietTelex")), p.learnedWords)
    }

    /** Từ thêm tay (Từ điển cá nhân) đi qua sao lưu và KHÔNG mất khi nhập gộp vào file. */
    @Test fun manualWordsSurviveBackupImport() {
        val dir = Files.createTempDirectory("bk-manual").toFile()
        val f = File(dir, "userlm.bin")
        val direct = java.util.concurrent.Executor { it.run() }
        UserLangModel(f, ImmediateMainThread(), direct).apply { addWord("VietTelex"); save() }
        val exported = BackupCodec.decode(BackupCodec.encode(androidPayload.copy(
            learnedWords = LearnedWords(mapOf("kubernetes" to 5), manual = listOf("Kubernetes")))))
        UserLangModel.mergeLearnedIntoFile(exported.learnedWords!!, f)
        assertEquals(setOf("VietTelex", "Kubernetes"), UserLangModel.readLearned(f)!!.manual.toSet())
        val m = UserLangModel(f, ImmediateMainThread(), direct)
        assertEquals(listOf("Kubernetes"), m.manualCompletions("kube"))
        assertEquals(listOf("VietTelex"), m.manualCompletions("viet"))
        dir.deleteRecursively()
    }

    @Test fun forwardCompatibleFile() {
        val p = BackupCodec.decode(fixture("backup-future-v2"))
        assertEquals(mapOf<String, Any>("simpleTelex" to false, "rowHeightAdjust" to 10), p.settings)
        assertEquals(mapOf("hn" to "Hà Nội"), p.shortcuts)
        assertEquals(listOf(TemplateItem("🙂", "Cảm ơn")), p.templates)
    }

    @Test fun rejectsTooNewAndForeign() {
        val e = assertFailsWith<BackupException> { BackupCodec.decode(fixture("backup-too-new")) }
        assertEquals(BackupException.Reason.TOO_NEW, e.reason); assertEquals(7, e.fileVersion)
        assertEquals(BackupException.Reason.NOT_BACKUP,
            assertFailsWith<BackupException> { BackupCodec.decode("{\"format\":\"x\"}") }.reason)
        assertEquals(BackupException.Reason.NOT_JSON,
            assertFailsWith<BackupException> { BackupCodec.decode("- \"a | b\"") }.reason)
        assertEquals(BackupException.Reason.NOT_JSON,
            assertFailsWith<BackupException> { BackupCodec.decode("{\"format\":\"viettelex-backup\"") }.reason)
    }

    @Test fun bomAccepted() = assertEquals("android", BackupCodec.decode("﻿" + fixture("backup-android-v1")).platform)

    // --- SharedPreferences (map giả) ---

    @Test fun snapshotFillsDefaultsAndClamps() {
        val prefs = mapOf<String, Any?>("quickTelex" to true, "rowHeightAdjust" to 42, "debugTouchLog" to true,
            "keyboardTransparency" to 250, "keyLabelTransparency" to 35,
            BackupPrefs.SHORTCUTS_KEY to "# VietTelex — bảng gõ tắt\nko: không\n")
        val p = BackupPrefs.snapshot({ prefs[it] }, listOf(TemplateItem("", "a")), null)
        assertEquals(42, p.settings!!.size)
        assertEquals("en", p.settings!![Keys.TRANSLATE_TARGET])   // Dịch trên máy: mặc định English
        assertEquals("vi", p.settings!![Keys.UI_LANGUAGE])   // chưa chọn ⇒ mặc định Tiếng Việt
        assertEquals(100, p.settings!!["keyboardTransparency"])   // kẹp 0…100
        assertEquals(35, p.settings!!["keyLabelTransparency"])
        assertEquals(true, p.settings!!["smartTouch"])
        assertEquals(false, p.settings!!["autoCorrect"])
        assertEquals(true, p.settings!!["autoCapitalize"])
        assertEquals(false, p.settings!!["spaceSwipeLanguage"])
        assertEquals(false, p.settings!!["autoSpaceAfterPunct"])
        assertEquals(true, p.settings!!["quickTelex"])
        assertEquals(true, p.settings!!["simpleTelex"])
        assertEquals(10, p.settings!!["rowHeightAdjust"])
        assertNull(p.settings!!["showPeriodKey"])                 // 12/10/2026: bỏ công tắc "." — không sao lưu
        assertEquals(0, p.settings!![Keys.KEYBOARD_RAISE])        // #112 mặc định 0
        assertEquals(false, p.settings!![Keys.FLOATING_KEYBOARD]) // #112 thả nổi mặc định tắt
        assertNull(p.settings!!["debugTouchLog"])
        assertEquals(mapOf("ko" to "không"), p.shortcuts)
        assertNull(p.learnedWords)
    }

    @Test fun importIOSFileIntoAndroidPrefs() {
        val prefs = mapOf<String, Any?>(BackupPrefs.SHORTCUTS_KEY to ShortcutFile.exportYAML(mapOf("ko" to "hông", "hn" to "Hà Nội")))
        val plan = BackupPrefs.plan(BackupCodec.decode(fixture("backup-ios-v1")), { prefs[it] },
            listOf(TemplateItem("👋", "Chào buổi sáng")))
        assertEquals(false, plan.writes["reEditWords"])
        assertEquals(-3, plan.writes["rowHeightAdjust"])
        assertEquals(false, plan.writes[Keys.AUTO_CAPITALIZE])
        assertEquals("en", plan.writes[Keys.UI_LANGUAGE])
        assertNull(plan.writes["hardwareTelex"])   // file iOS không có ⇒ không đụng
        // Pref gõ tắt ghi đúng dạng IME đọc: chuỗi YAML của ShortcutFile.
        assertTrue((plan.writes[Keys.SHORTCUTS] as String).startsWith(ShortcutFile.HEADER))
        assertEquals(mapOf("hn" to "Hà Nội", "ko" to "không", "stk" to "số tài khoản", "đc" to "được"),
            BackupPrefs.shortcutsFromPref(plan.writes[BackupPrefs.SHORTCUTS_KEY]))
        assertEquals(listOf("Chào buổi sáng", "Anh nói \"ok\" nhé\nDòng 2"), plan.templates!!.map { it.text })
        assertEquals(4, plan.learnedWords!!.uni.size)          // 3 từ học + 1 từ thêm tay
        assertEquals(listOf("VietTelex"), plan.learnedWords!!.manual)
        assertTrue("3 gõ tắt" in plan.summary, plan.summary)
        assertTrue("1 mẫu câu mới" in plan.summary, plan.summary)
    }

    @Test fun raiseBackupClampedAndLegacyPeriodKeyIgnored() {
        // "showPeriodKey" (bỏ 12/10/2026 — một bố cục hàng đáy kiểu iPhone): pref cũ còn trong
        // máy không lọt vào file; file cũ có key này ⇒ bỏ qua khi nhập, không ghi lại pref.
        val p = BackupPrefs.snapshot({ mapOf<String, Any?>("showPeriodKey" to true, Keys.KEYBOARD_RAISE to 99)[it] },
            emptyList(), null)
        assertNull(p.settings!!["showPeriodKey"])
        assertFalse(BackupSettings.byKey.containsKey("showPeriodKey"))
        assertEquals(KeyboardSettings.KEYBOARD_RAISE_MAX, p.settings!![Keys.KEYBOARD_RAISE])
        val legacy = BackupCodec.decode(BackupCodec.encode(p.copy(settings = p.settings!! + ("showPeriodKey" to true))))
        val back = HashMap<String, Any?>()
        back.putAll(BackupPrefs.plan(legacy, { back[it] }, emptyList()).writes)
        assertNull(back["showPeriodKey"])
        assertEquals(48, back[Keys.KEYBOARD_RAISE])
        val s = KeyboardSettings.load { back[it] }
        assertEquals(48, s.keyboardRaise)
        assertEquals(0, KeyboardSettings.load { if (it == Keys.KEYBOARD_RAISE) -5 else null }.keyboardRaise)
    }

    /** #112: công tắc thả nổi đi theo file sao lưu; vị trí khung (riêng từng máy) thì không. */
    @Test fun floatingBackupKeys() {
        assertTrue(BackupSettings.byKey.containsKey(Keys.FLOATING_KEYBOARD))
        assertFalse(BackupSettings.byKey.containsKey(Keys.FLOATING_POS_PORTRAIT))
        assertFalse(BackupSettings.byKey.containsKey(Keys.FLOATING_POS_LANDSCAPE))
        val a = mapOf<String, Any?>(Keys.FLOATING_KEYBOARD to true, Keys.FLOATING_POS_PORTRAIT to "0.2,0.3")
        val p = BackupCodec.decode(BackupCodec.encode(BackupPrefs.snapshot({ a[it] }, emptyList(), null)))
        assertEquals(true, p.settings!![Keys.FLOATING_KEYBOARD])
        assertNull(p.settings!![Keys.FLOATING_POS_PORTRAIT])
        val b = HashMap<String, Any?>()
        b.putAll(BackupPrefs.plan(p, { b[it] }, emptyList()).writes)
        assertEquals(true, b[Keys.FLOATING_KEYBOARD])
        assertTrue(KeyboardSettings.load { b[it] }.floatingKeyboard)
        assertFalse(KeyboardSettings.load { null }.floatingKeyboard)
    }

    @Test fun deviceToDeviceRoundTripThroughFile() {
        val a = mapOf<String, Any?>("teencode" to true, "rowHeightAdjust" to -2, Keys.KEYBOARD_RAISE to 16,
            BackupPrefs.SHORTCUTS_KEY to BackupPrefs.shortcutsToPref(mapOf("vn" to "Việt Nam")))
        val json = BackupCodec.encode(BackupPrefs.snapshot({ a[it] }, listOf(TemplateItem("x", "một")), null))
        val b = HashMap<String, Any?>()
        val plan = BackupPrefs.plan(BackupCodec.decode(json), { b[it] }, emptyList())
        b.putAll(plan.writes)
        assertEquals(BackupPrefs.settings { a[it] }, BackupPrefs.settings { b[it] })
        assertEquals(mapOf("vn" to "Việt Nam"), BackupPrefs.shortcutsFromPref(b[BackupPrefs.SHORTCUTS_KEY]))
        assertEquals(listOf(TemplateItem("x", "một")), plan.templates)
    }

    /** uiLanguage: khứ hồi qua file; giá trị lạ / sai kiểu bị bỏ qua khi nhập, pref lạ ⇒ "vi". */
    @Test fun uiLanguageBackupRoundTrip() {
        val a = mapOf<String, Any?>(Keys.UI_LANGUAGE to "en")
        val p = BackupCodec.decode(BackupCodec.encode(BackupPrefs.snapshot({ a[it] }, emptyList(), null)))
        assertEquals("en", p.settings!![Keys.UI_LANGUAGE])
        val b = HashMap<String, Any?>()
        b.putAll(BackupPrefs.plan(p, { b[it] }, emptyList()).writes)
        assertEquals("en", b[Keys.UI_LANGUAGE])
        assertEquals("en", L10n.normalize(b[Keys.UI_LANGUAGE]))

        val bad = BackupCodec.decode("""{"format":"viettelex-backup","version":1,"settings":{"uiLanguage":"fr","simpleTelex":false}}""")
        assertNull(bad.settings!![Keys.UI_LANGUAGE])
        val wrongType = BackupCodec.decode("""{"format":"viettelex-backup","version":1,"settings":{"uiLanguage":true}}""")
        assertNull(wrongType.settings!![Keys.UI_LANGUAGE])
        assertEquals("vi", BackupPrefs.settings { if (it == Keys.UI_LANGUAGE) "de" else null }[Keys.UI_LANGUAGE])
    }

    @Test fun shortcutsPrefToleratesGarbage() {
        assertEquals(emptyMap(), BackupPrefs.shortcutsFromPref(null))
        assertEquals(emptyMap(), BackupPrefs.shortcutsFromPref("not json"))
        assertEquals(emptyMap(), BackupPrefs.shortcutsFromPref(5))
    }

    // --- từ đã học ---

    @Test fun learnedMergeTakesMax() {
        val a = LearnedWords(mapOf("a" to 5, "b" to 1), mapOf("a" to mapOf("b" to 2)))
        val b = LearnedWords(mapOf("a" to 3, "c" to 2), mapOf("a" to mapOf("b" to 4, "c" to 1)))
        assertEquals(LearnedWords(mapOf("a" to 5, "b" to 1, "c" to 2), mapOf("a" to mapOf("b" to 4, "c" to 1))), a.merged(b))
    }

    @Test fun learnedFileMergeReadableByUserLangModel() {
        val dir = Files.createTempDirectory("vtbackup").toFile()
        val f = File(dir, Keys.USERLM_FILE)
        assertNull(UserLangModel.readLearned(f))
        UserLangModel.mergeLearnedIntoFile(LearnedWords(mapOf("việt" to 3), mapOf("tiếng" to mapOf("việt" to 2))), f)
        UserLangModel.mergeLearnedIntoFile(LearnedWords(mapOf("việt" to 1, "nam" to 2)), f)
        assertEquals(LearnedWords(mapOf("việt" to 3, "nam" to 2), mapOf("tiếng" to mapOf("việt" to 2))),
            UserLangModel.readLearned(f))
        // Model thật nạp được file vừa ghi.
        val m = UserLangModel(f)
        var waited = 0
        while (m.count("việt") == 0 && waited < 200) { Thread.sleep(10); waited++ }
        assertEquals(3, m.count("việt"))
        dir.deleteRecursively()
    }

    // --- MiniJson ---

    @Test fun miniJsonTypes() {
        val v = MiniJson.parse("{\"b\":true,\"i\":-3,\"d\":1.5,\"n\":null,\"s\":\"\\u00e0\\/\",\"l\":[1,\"x\"]}") as Map<*, *>
        assertEquals(true, v["b"]); assertEquals(-3L, v["i"]); assertEquals(1.5, v["d"])
        assertNull(v["n"]); assertEquals("à/", v["s"]); assertEquals(listOf(1L, "x"), v["l"])
        assertFailsWith<IllegalArgumentException> { MiniJson.parse("{\"a\":1} x") }
        assertFailsWith<IllegalArgumentException> { MiniJson.parse("[1,") }
    }
}
