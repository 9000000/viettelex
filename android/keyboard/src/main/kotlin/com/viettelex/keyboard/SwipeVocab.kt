package com.viettelex.keyboard

/**
 * TỪ VỰNG GÕ VUỐT = 1666 dạng của vnlexicon ([SwipeLexicon]) + từ chat/viết tắt (luôn có) +
 * từ tục (chỉ khi TẮT "Lọc từ nhạy cảm" — cùng công tắc thanh gợi ý). Song sinh iOS
 * Keyboard/SwipeVocab.swift — sửa bảng/hằng ở đây thì sửa y hệt bên kia.
 *
 * - Lọc BẬT (mặc định): [SwipeDecoder.expand] bỏ mọi âm tiết trong [SensitiveWords.set] (vnlexicon
 *   có sẵn đĩ, cứt, dâm, điếm) ⇒ vuốt không bao giờ ra từ nhạy cảm, kể cả qua bung dấu.
 * - Lọc TẮT: thêm âm tiết tục vnlexicon không có (địt, lồn, cặc, buồi, đụ) vào dạng sẵn có và
 *   viết tắt tục (vl, đcm, dkm…) thành dạng mới.
 *
 * [CHAT]: viết tắt chat của seed.tsv (ko, dc, ok, vs, mn, vd, ib, cmt, stt, kb, uk, oke, okie,
 * haha…) + nma, ntn, nx, bt, ms. Từ tục = cả [SensitiveWords.set], tần suất từ seed ([sensitiveEntries]).
 * Từ thô tục KHÔNG nằm trong SensitiveWords (vú, ngu, dái, cu, nắc, mày, vãi…) vnlexicon có sẵn ⇒
 * luôn có. Tần suất cùng thang vnlexicon (0–255; điểm = λ·f/255). Từ 1 chữ (k, j) không vuốt được —
 * chạm là ra. Chi phí: dựng một lần mỗi chế độ (lười), đổi công tắc ⇒ decoder dựng lại template
 * một lần; 0 việc ở đường phím chữ.
 */
object SwipeVocab {
    class Entry(val word: String, val freq: Int, val sensitive: Boolean = false)

    /** Chat / viết tắt — luôn có (không nằm trong [SensitiveWords.set]). */
    val CHAT: List<Entry> = listOf(
        Entry("ko", 150), Entry("đc", 140), Entry("dc", 120), Entry("ok", 150), Entry("oke", 100),
        Entry("okie", 80), Entry("vs", 110), Entry("mn", 110), Entry("nma", 100), Entry("ntn", 110),
        Entry("nx", 100), Entry("bt", 110), Entry("ms", 110), Entry("vd", 80), Entry("ib", 90),
        Entry("cmt", 90), Entry("stt", 70), Entry("kb", 70), Entry("uk", 90), Entry("haha", 120),
        Entry("hihi", 110), Entry("hehe", 100), Entry("huhu", 90), Entry("kaka", 60),
    )

    /**
     * Thô tục KHÔNG nằm trong [SensitiveWords.set] — luôn có, nhưng vnlexicon ghi tần suất gần 0
     * (nắc 0,01 điểm; dạng "nac" thua "ngac" cùng hình) ⇒ nâng tần suất. Chỉ nâng khi không cướp từ
     * thường phổ biến (vú/vụ, ngu/ngủ, dái/đại giữ nguyên — xem báo cáo, cần ngữ cảnh).
     */
    val ALWAYS: List<Entry> = listOf(Entry("nắc", 140))

    /**
     * Từ tục khi TẮT lọc = TOÀN BỘ [SensitiveWords.set] (lấy theo chương trình, không chép tay), tần
     * suất = tần suất seed (thang vnlexicon: seed·51/10, như TouchTarget.chatWords). Từ vnlexicon ĐÃ CÓ
     * (đĩ, cứt, dâm, điếm) giữ tần suất vnlexicon nếu cao hơn; từ vnlexicon KHÔNG có được sàn
     * [SENSITIVE_FLOOR] — seed ghi từ tục rất thấp (lồn 5 ⇒ 25), không sàn thì không bao giờ ra.
     * Thứ tự: theo dạng không dấu, dạng có "đ" trước.
     */
    const val SENSITIVE_FLOOR = 150

    fun sensitiveEntries(seed: Map<String, Int>): List<Entry> =
        SensitiveWords.set.sortedWith(compareBy<String>({ SwipeSuggest.fold(it) }, { if ('đ' in it) 0 else 1 }, { it }))
            .map { Entry(it, ((seed[it] ?: 0) * 51 / 10).coerceIn(0, 255), true) }

    /** Bảng đầy đủ theo chế độ: chat + thô tục luôn có (+ tục khi tắt lọc, tần suất từ seed). */
    fun entries(filter: Boolean): List<Entry> =
        if (filter) CHAT + ALWAYS
        else CHAT + ALWAYS + sensitiveEntries(try { SeedData.unigrams } catch (e: Exception) { emptyMap() })

    /** Tần suất (0–255) của âm tiết [word] trong vnlexicon, -1 nếu không có. */
    private fun lexiconFreq(word: String): Int {
        val i = SwipeLexicon.indexOf(SwipeSuggest.fold(word))
        if (i < 0) return -1
        val lex = SwipeLexicon.forms
        for (id in lex.idStart[i] until lex.idStart[i + 1]) if (VNSuggest.display(id) == word) return VNSuggest.freq(id)
        return -1
    }

    class Vocab(
        val filter: Boolean,
        /** Dạng lexicon (0 until SwipeLexicon.forms.count) + dạng mới (dải id lexicon rỗng). */
        val forms: SwipeLexicon.Forms,
        /** Từ thêm theo dạng không dấu (cả dạng lexicon lẫn dạng mới), thứ tự [entries]. */
        val words: Map<String, List<SwipeWord>>,
        private val extraIndex: Map<String, Int>,
    ) {
        /** Chỉ số dạng trong [forms], -1 nếu không có. */
        fun indexOf(folded: String): Int {
            val i = SwipeLexicon.indexOf(folded)
            return if (i >= 0) i else extraIndex[folded] ?: -1
        }
    }

    /** Đặt lúc bàn phím hiện (KeyboardSession.startInput) từ cài đặt "Lọc từ nhạy cảm". */
    @Volatile var filterSensitive: Boolean = true

    private val filtered by lazy { build(true) }
    private val unfiltered by lazy { build(false) }

    val current: Vocab get() = if (filterSensitive) filtered else unfiltered

    fun isSensitive(word: String): Boolean = word in SensitiveWords.set

    /** Dựng từ vựng cho chế độ lọc [filter]. SwipeWord.score = tần suất thô (0–255). */
    fun build(filter: Boolean): Vocab {
        val lex = SwipeLexicon.forms
        val words = LinkedHashMap<String, MutableList<SwipeWord>>()
        for (e in entries(filter)) {
            val f = SwipeSuggest.fold(e.word)
            val i = SwipeLexicon.indexOf(f)
            val lf = if (i >= 0) lexiconFreq(e.word) else -1
            // có sẵn trong vnlexicon: chỉ thay khi bảng cao hơn; không có: từ tục được sàn
            val fr = if (lf < 0 && e.sensitive) maxOf(e.freq, SENSITIVE_FLOOR) else e.freq
            if (lf >= fr) continue
            words.getOrPut(f) { ArrayList() }.add(SwipeWord(e.word, fr.toFloat()))
        }
        val added = words.keys.filter { SwipeLexicon.indexOf(it) < 0 }.sorted()
        val fc = lex.count
        val n = lex.idStart[fc]
        val folded = Array(fc + added.size) { if (it < fc) lex.folded[it] else added[it - fc] }
        val idStart = IntArray(fc + added.size + 1) { if (it < fc) lex.idStart[it] else n }
        // tần suất dạng = mạnh nhất của dạng, tính cả từ thêm (nắc nâng dạng "nac")
        val freq = IntArray(fc + added.size) {
            val ex = words[if (it < fc) lex.folded[it] else added[it - fc]]?.maxOf { w -> w.score.toInt() } ?: 0
            if (it < fc) maxOf(lex.freq[it], ex) else ex
        }
        val keys = ArrayList<Byte>(lex.keys.size + added.size * 4)
        for (b in lex.keys) keys.add(b)
        val keyStart = IntArray(fc + added.size + 1)
        for (i in 0..fc) keyStart[i] = lex.keyStart[i]
        for ((k, a) in added.withIndex()) {
            var last = -1
            for (c in a) {
                val code = c - 'a'
                if (code != last) { keys.add(code.toByte()); last = code }
            }
            keyStart[fc + k + 1] = keys.size
        }
        val forms = SwipeLexicon.Forms(folded, idStart, freq, keys.toByteArray(), keyStart)
        val extraIndex = HashMap<String, Int>()
        for ((k, a) in added.withIndex()) extraIndex[a] = fc + k
        return Vocab(filter, forms, words, extraIndex)
    }
}
