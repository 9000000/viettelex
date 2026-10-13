package com.viettelex.android.translate.mlkit

import com.google.mlkit.nl.translate.TranslateLanguage
import com.viettelex.android.translate.TranslateBackend
import com.viettelex.android.translate.TranslateFeature
import com.viettelex.keyboard.TranslateLangs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TranslateLangsMlKitTest {
    /** Danh sách chép tay ở :keyboard phải khớp ML Kit đang dùng. */
    @Test fun languageListMatchesMlKit() {
        assertEquals(TranslateLanguage.getAllLanguages().toSet(), TranslateLangs.ALL.toSet())
    }

    /** App gốc nạp đúng lớp này bằng reflection, constructor (Context). */
    @Test fun reflectiveEntryPointMatches() {
        val cls = Class.forName(TranslateFeature.IMPL)
        assertEquals(MlKitBackend::class.java, cls)
        assertTrue(TranslateBackend::class.java.isAssignableFrom(cls))
        cls.getConstructor(android.content.Context::class.java)
    }
}
