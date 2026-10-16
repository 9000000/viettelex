package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** Quyết định thuần của [EmailTokenGuard] — song sinh iOS EmailTokenGuardTests. */
class EmailTokenGuardTest {
    @Test fun tokenTailAndMarks() {
        assertEquals("phuc@gm", EmailTokenGuard.tokenTail("Sơn, phuc@gm"))
        assertEquals("b", EmailTokenGuard.tokenTail("a;b"))
        assertEquals("", EmailTokenGuard.tokenTail("abc "))
        assertEquals("abc", EmailTokenGuard.tokenTail("abc"))
        assertTrue(EmailTokenGuard.hasMark("a.b"))
        assertTrue(EmailTokenGuard.hasMark("@"))
        assertFalse(EmailTokenGuard.hasMark("tuan_anh-1+2"))
    }

    @Test fun syncReadsExistingToken() {
        val g = EmailTokenGuard()
        assertFalse(g.synced)
        g.sync("Sơn, an@x"); assertTrue(g.synced); assertTrue(g.literal)
        g.sync("an@x.com, "); assertFalse(g.literal)
        g.sync(null); assertTrue(g.synced); assertFalse(g.literal)
    }

    @Test fun restorePlanCoversCommittedPiecesAndOpenWord() {
        val g = EmailTokenGuard(); g.sync("")
        assertFalse(g.needsRestore("_"))
        assertTrue(g.needsRestore("@")); assertTrue(g.needsRestore("."))
        g.appended("tuấn", "tuaans", "_")
        assertFalse(g.literal)
        assertEquals("tuấn_ạnh" to "tuaans_anhj", g.restorePlan("ạnh", "anhj"))
        g.restored("tuaans_anhj", "@")
        assertTrue(g.literal); assertFalse(g.needsRestore("."))
        g.appended("", "", ", ")              // dấu phẩy ⇒ token mới
        assertFalse(g.literal); assertEquals("", g.shown)
    }

    @Test fun noPlanWhenAlreadyRaw() {
        val g = EmailTokenGuard(); g.sync("")
        g.appended("phuc", "phuc")
        assertNull(g.restorePlan("", ""))
        assertNull(g.restorePlan("nguyen", "nguyen"))
    }

    @Test fun backspaceTracking() {
        var g = EmailTokenGuard(); g.sync("")
        g.restored("an", "@"); assertTrue(g.literal)
        g.deletedOne()                         // xoá "@" ⇒ token lại là chữ
        assertFalse(g.literal); assertEquals("an", g.shown)
        g = EmailTokenGuard(); g.sync("")
        g.appended("tuấn", "tuaans")
        g.deletedOne()                         // "n" ≠ "s": phần còn lại thành chữ có sẵn
        assertEquals("", g.shown); assertNull(g.restorePlan("", ""))
        g.deletedOne()                         // xoá vào chữ có sẵn ⇒ đọc lại context
        assertFalse(g.synced)
    }
}

/**
 * Ô email (người nhận Gmail/Outlook, iOS 1.2.15 báo — Android cùng luật): gõ tên tiếng Việt để tìm
 * danh bạ, địa chỉ đúng phím thô. Qua KeyboardSession như IME thật. Song sinh iOS EmailFieldBridgeTests.
 */
class EmailFieldTest {
    @Before fun setUp() = TestAssets.install()

    private val emailField = FieldTraits(passthrough = true, suggestionsAllowed = false,
        emailField = true, emailCompose = true)

    private fun session(traits: FieldTraits = emailField, settings: KeyboardSettings = KeyboardSettings()) =
        KeyboardSession(UserLangModel()).also { it.startInput(settings, traits) }

    /** "<" = ⌫, "␣" = dấu cách, chữ = Letter, còn lại (số, "@", ".", "_", ",") = Text. */
    private fun KeyboardSession.typeKeys(p: TextProxy, keys: String) {
        for (c in keys) handle(when {
            c == '<' -> Key.Backspace
            c == '␣' -> Key.Space
            c.isLetter() -> Key.Letter(c)
            else -> Key.Text(c.toString())
        }, p)
    }

    private fun type(keys: String, traits: FieldTraits = emailField, settings: KeyboardSettings = KeyboardSettings()): String {
        val p = MockProxy()
        session(traits, settings).typeKeys(p, keys)
        return p.text
    }

    @Test fun vietnameseNameComposes() {
        assertEquals("Sơn", type("Sown"))
        assertEquals("Nguyễn Sơn", type("Nguyeenx␣Sown"))
        assertEquals("Sơn,", type("Sown,"))
    }

    @Test fun addressesStayRaw() {
        assertEquals("phuc.nguyen@gmail.com", type("phuc.nguyen@gmail.com"))
        assertEquals("dduc@vn.com", type("dduc@vn.com"))
        assertEquals("tuan.anh@", type("tuan.anh@"))
        assertEquals("nguyeenx@", type("nguyeenx@"))             // quy tắc: đúng phím thô
        assertEquals("Sown.nguyeenx@gmail.com", type("Sown.nguyeenx@gmail.com"))
        assertEquals("tuaans_anh1@vn.vn", type("tuaans_anh1@vn.vn"))
        assertEquals("ddax-ddi+1@x.com", type("ddax-ddi+1@x.com"))
        assertEquals("viet.nam", type("viet.nam"))
        assertEquals("hoaf@ddaif.vn", type("hoaf@ddaif.vn"))
    }

    @Test fun digitsAndSymbolsComposeUntilMark() {
        assertEquals("tuấn_anh", type("tuaans_anh"))
        assertEquals("tuấn_anh ", type("tuaans_anh␣"))
    }

    @Test fun tokenAfterSeparatorComposesAgain() {
        assertEquals("an@x.com, Sơn", type("an@x.com,␣Sown"))
        assertEquals("an@x.com;Sơn", type("an@x.com;Sown"))
        assertEquals("an@x.com Sơn", type("an@x.com␣Sown"))
    }

    @Test fun backspaceInsideAddressAndAcrossMark() {
        assertEquals("dduc", type("ddu@<c"))
        assertEquals("dduc@", type("ddu@<c@"))
        assertEquals("phuc@gmail.com", type("phuc@gmx<ail.com"))
    }

    @Test fun passwordAndLiteralFieldsUnchanged() {
        // FORCE_ASCII email / URL / username: passthrough không emailCompose ⇒ literal như cũ.
        assertEquals("Sown@", type("Sown@", FieldTraits(passthrough = true, emailField = true)))
        val p = MockProxy(isSecureField = true)
        session(FieldTraits(isSecure = true, passthrough = true)).typeKeys(p, "Sown@")
        assertEquals("Sown@", p.text)
        assertEquals("Sơn@", type("Sown@", FieldTraits()))        // ô thường: như cũ
    }

    @Test fun neverRewritesTextTheAppInserted() {
        // App (chip người nhận) chèn chữ rồi báo đổi selection: chữ có sẵn không bị viết lại.
        val p = MockProxy(); val s = session()
        p.sb.append("Đức")
        s.externalSelectionChange()
        s.typeKeys(p, "@vn.com")
        assertEquals("Đức@vn.com", p.text)
        // App đổi chữ trong lúc đang soạn mà không báo: fail-safe confirmTail, không xoá mù.
        val q = MockProxy(); val t = session()
        t.typeKeys(q, "dduc")
        q.sb.setLength(0); q.sb.append("Đức Nguyễn <")
        t.typeKeys(q, "@")
        assertEquals("Đức Nguyễn <@", q.text)
    }

    @Test fun existingAddressTokenStaysRawAfterSelectionChange() {
        val p = MockProxy(); val s = session()
        p.sb.append("phuc@gmail.co")
        s.externalSelectionChange()
        s.typeKeys(p, "om")
        assertEquals("phuc@gmail.coom", p.text)
    }

    @Test fun vniDigitsInAddress() {
        val vni = KeyboardSettings(vniMode = true)
        assertEquals("Sơn", type("So7n", settings = vni))
        assertEquals("d9uc1@vn.com", type("d9uc1@vn.com", settings = vni))
        assertEquals("an@x2.com", type("an@x2.com", settings = vni))
    }

    @Test fun emailChipBoundaryRestoresFirst() {
        val p = MockProxy(); val s = session()
        s.typeKeys(p, "dduc")
        s.bridge.boundary("@gmail.com", p, expand = false)
        assertEquals("dduc@gmail.com", p.text)
    }

    @Test fun noShortcutsNoLearning() {
        val p = MockProxy(); val s = session()
        s.typeKeys(p, "an")
        assertNull(s.bridge.shortcutPreview)
        assertFalse(StripMode.learns(true, emailField, false))
        assertTrue(StripMode.learns(true, FieldTraits(), false))
    }
}
