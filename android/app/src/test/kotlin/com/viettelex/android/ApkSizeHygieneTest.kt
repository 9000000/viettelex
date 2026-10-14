package com.viettelex.android

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Dung lượng APK: minSdk 26 ⇒ icon luôn lấy adaptive (mipmap-anydpi-v26) — PNG ic_launcher cũ
 * theo mật độ là thừa; asset không ai đọc (spacelogo.png) không quay lại; công cụ Preview chỉ ở debug.
 */
class ApkSizeHygieneTest {
    private val main = listOf(File("src/main"), File("app/src/main")).first { it.exists() }
    private val gradle = listOf(File("build.gradle.kts"), File("app/build.gradle.kts")).first { it.exists() && it.readText().contains("com.android.application") }

    @Test fun adaptiveIconOnly() {
        val minSdk = Regex("""minSdk\s*=\s*(\d+)""").find(gradle.readText())!!.groupValues[1].toInt()
        assertTrue(minSdk >= 26)
        assertTrue(File(main, "res/mipmap-anydpi-v26/ic_launcher.xml").exists())
        assertTrue(File(main, "res/mipmap-anydpi-v26/ic_launcher_round.xml").exists())
        val legacy = main.resolve("res").listFiles()!!.filter { it.name.startsWith("mipmap-") && it.name != "mipmap-anydpi-v26" }
            .flatMap { d -> d.listFiles()!!.filter { it.name == "ic_launcher.png" || it.name == "ic_launcher_round.png" } }
        assertTrue("PNG launcher cũ thừa: $legacy", legacy.isEmpty())
    }

    @Test fun noUnusedAssets() {
        assertFalse(File(main, "assets/spacelogo.png").exists())
    }

    @Test fun toolingPreviewDebugOnly() {
        val g = gradle.readText()
        assertFalse(Regex("""(?m)^\s*implementation\("androidx.compose.ui:ui-tooling""").containsMatchIn(g))
    }
}
