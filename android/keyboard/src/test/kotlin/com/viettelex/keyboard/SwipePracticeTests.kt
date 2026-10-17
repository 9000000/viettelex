package com.viettelex.keyboard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.time.Instant

/**
 * Chế độ luyện vuốt (SwipePractice) — song sinh iOS SwipePracticeTests.swift, cùng fixture
 * KeyboardTests/Fixtures/swipe-traces-sample.json (sinh lại: SWIPE_WRITE_FIXTURE=1).
 *
 * Đánh giá decoder trên nét thật đã xuất từ app:
 *   SWIPE_TRACES=/đường/dẫn/viettelex-swipe-traces.json ./gradlew --offline :keyboard:test \
 *     --tests '*SwipePracticeTests.evaluateExportedTraces' -i      (Scripts/eval-swipe-traces.sh)
 */
class SwipePracticeTests {
    @Before fun setUp() = TestAssets.install()

    private val layout = SwipeLayout.qwerty(keyWidth = 36f, rowHeight = 54f)

    @Test fun targetsDeterministicMixedAndSwipeable() {
        val a = (0 until 200).map { SwipePractice.target(42, it) }
        assertEquals(a, (0 until 200).map { SwipePractice.target(42, it) })
        assertTrue(a != (0 until 200).map { SwipePractice.target(43, it) })
        val en = a.count { it.lang == SwipeLang.EN }
        assertTrue("tiếng Anh $en/200", en in 20..70)
        for (t in a) {
            assertTrue(t.word, SwipePractice.keyCount(t.folded) >= 2)
            if (t.lang == SwipeLang.VI) {
                assertEquals(SwipeSuggest.fold(t.word), t.folded)
                assertTrue(SwipeLexicon.indexOf(t.folded) >= 0)
            } else assertTrue("không trùng dạng Việt: ${t.word}", SwipeLexicon.indexOf(t.word) < 0)
        }
        assertEquals("không", SwipePractice.vietnamese.take(20).firstOrNull { it.word == "không" }?.word)
        // parity iOS SwipePracticeTests: cùng seed ⇒ cùng chuỗi mục tiêu
        assertEquals(PARITY_SEED_42, (0 until 12).map { SwipePractice.target(42, it).word })
        assertEquals(400, SwipePractice.vietnamese.size)
        assertEquals(120, SwipePractice.english.size)
    }

    companion object {
        val PARITY_SEED_42 = listOf("lòng", "head", "tử", "dịch", "first", "tốt", "đấy", "đàn", "bỏ", "cách", "câu", "mạnh")
    }

    private fun trace(word: String, lang: SwipeLang, seed: Long, sigma: Double = 0.1): SwipeTrace {
        val p = SwipeSim(seed).path(SwipeSuggest.fold(word), layout, sigma = sigma)
        val pts = (0 until p.count).map { Triple(p.xs[it], p.ys[it], ((p.ts[it] - p.ts[0]) * 1000).toFloat()) }
        val keys = ('a'..'z').associateWith { layout.center(it)!! }
        val d = SwipeDecoder().also { it.setLayout(layout) }
        val rounded = SwipePractice.fromJson(SwipePractice.toJson(SwipeTrace(word, SwipeSuggest.fold(word), lang,
            layout.keyWidth, keys, pts, emptyList(), 1_790_000_000_000L + seed)))!!
        val top = SwipePractice.decode(d, rounded.path(), lang).map { it.folded }
        return rounded.copy(decoded = top)
    }

    @Test fun jsonRoundTripAndGuards() {
        val t = trace("việt", SwipeLang.VI, 1)
        assertEquals(t, SwipePractice.fromJson(MiniJson.parse(SwipePractice.line(t))))
        val doc = SwipePractice.export(listOf(t, trace("meeting", SwipeLang.EN, 2)), "android", Instant.EPOCH)
        val back = SwipePractice.parseExport(doc)!!
        assertEquals(2, back.size)
        assertEquals(SwipeLang.EN, back[1].lang)
        assertNull(SwipePractice.parseExport("{\"format\":\"khác\",\"version\":1,\"traces\":[]}"))
        assertNull(SwipePractice.parseExport("{\"format\":\"viettelex-swipe-traces\",\"version\":9,\"traces\":[]}"))
        assertNull(SwipePractice.parseExport("không phải json"))
        // kho JSON Lines: dòng hỏng / thiếu trường bị bỏ qua
        val store = SwipePractice.line(t) + "\n{hỏng\n{\"target\":\"a\"}\n\n" + SwipePractice.line(t) + "\n"
        assertEquals(2, SwipePractice.parseLines(store).size)
        assertNull(SwipePractice.fromJson(mapOf("target" to "a", "folded" to "a", "keyWidth" to 0, "keys" to emptyMap<String, Any>(), "points" to emptyList<Any>())))
    }

    private fun fixture(): File = listOf("../../iOS", "../iOS", "iOS")
        .map { File(it, "KeyboardTests/Fixtures/swipe-traces-sample.json") }.first { it.parentFile.exists() }

    /** Nét mẫu (giả, σ0.1): parse + decode khớp top-1 đã ghi — iOS kiểm cùng file (parity). */
    @Test fun sampleFixtureParity() {
        val f = fixture()
        if (System.getenv("SWIPE_WRITE_FIXTURE") == "1") {
            val words = listOf("không" to SwipeLang.VI, "người" to SwipeLang.VI, "việt" to SwipeLang.VI,
                "nam" to SwipeLang.VI, "được" to SwipeLang.VI, "check" to SwipeLang.EN, "meeting" to SwipeLang.EN,
                "trong" to SwipeLang.VI)
            f.writeText(SwipePractice.export(words.mapIndexed { i, (w, l) -> trace(w, l, 100L + i) }, "android",
                Instant.parse("2026-09-27T00:00:00Z")))
        }
        val traces = SwipePractice.parseExport(f.readText())
        assertNotNull(traces)
        assertEquals(8, traces!!.size)
        val d = SwipeDecoder().also { it.setLayout(traces[0].layout) }
        for (t in traces) assertEquals(t.target, t.decoded, SwipePractice.decode(d, t.path(), t.lang).map { it.folded })
        val r = SwipePractice.evaluate(traces)
        assertEquals(8, r.n)
        assertEquals(r.recorded, r.top1)
        assertTrue(r.fmt(), r.top1 >= 7)
    }

    @Test fun evaluateExportedTraces() {
        val path = System.getenv("SWIPE_TRACES")
        assumeTrue("đặt SWIPE_TRACES=file JSON xuất từ app", !path.isNullOrEmpty())
        val traces = SwipePractice.parseExport(File(path!!).readText()) ?: error("không đọc được $path")
        println("SWIPE_TRACES tất cả: ${SwipePractice.evaluate(traces).fmt()}")
        for (l in SwipeLang.entries) {
            val sub = traces.filter { it.lang == l }
            if (sub.isNotEmpty()) println("SWIPE_TRACES ${l.name.lowercase()}: ${SwipePractice.evaluate(sub).fmt()}")
        }
        val misses = traces.filter { SwipePractice.decode(SwipeDecoder().also { d -> d.setLayout(it.layout) }, it.path(), it.lang)
            .firstOrNull()?.folded != it.folded }
        println("SWIPE_TRACES sai (tối đa 40): " + misses.take(40).joinToString { "${it.folded}→${it.decoded.firstOrNull()}" })
    }
}
