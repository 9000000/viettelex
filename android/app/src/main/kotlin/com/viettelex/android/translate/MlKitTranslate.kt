package com.viettelex.android.translate

import android.content.Context
import com.google.mlkit.common.MlKit
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.viettelex.keyboard.TranslateDirection
import com.viettelex.keyboard.TranslateEngine
import com.viettelex.keyboard.TranslateEngineFactory
import com.viettelex.keyboard.TranslateLangs
import com.viettelex.keyboard.TranslateResult

/**
 * Cầu nối ML Kit Translation (on-device). Chữ KHÔNG rời máy: Translator chạy model cục bộ.
 * Mạng chỉ dùng khi người dùng bấm tải gói trong app ([TranslateModels.download]).
 *
 * Chi phí 0 khi không dùng: MlKitInitProvider bị gỡ khỏi manifest (không khởi tạo lúc mở
 * process) — [ensureInit] chạy lần đầu cần ML Kit (chạm "Dịch" / mở trang cài đặt dịch).
 */
object MlKitTranslate {
    @Volatile private var inited = false

    fun ensureInit(ctx: Context) {
        if (inited) return
        synchronized(this) {
            if (inited) return
            try { MlKit.initialize(ctx.applicationContext) } catch (_: IllegalStateException) { /* đã khởi tạo */ }
            inited = true
        }
    }
}

/** Gói ngôn ngữ (~30 MB mỗi thứ tiếng) — chỉ tải khi người dùng bấm trong app. */
object TranslateModels {
    private fun model(code: String) = TranslateRemoteModel.Builder(code).build()

    /** Gói cần cho cặp vi ↔ [target] (English luôn kèm — ML Kit đi vòng qua English). */
    fun required(target: String): Set<String> = linkedSetOf(TranslateLangs.VI, target, "en")

    fun downloaded(ctx: Context, onDone: (Set<String>?) -> Unit) {
        MlKitTranslate.ensureInit(ctx)
        RemoteModelManager.getInstance().getDownloadedModels(TranslateRemoteModel::class.java)
            .addOnSuccessListener { ms -> onDone(ms.map { it.language }.toSet()) }
            .addOnFailureListener { onDone(null) }
    }

    /** Tải tuần tự [langs]; [onDone] null = xong hết, khác = lỗi đầu tiên. */
    fun download(ctx: Context, langs: List<String>, wifiOnly: Boolean, onDone: (Exception?) -> Unit) {
        MlKitTranslate.ensureInit(ctx)
        val cond = DownloadConditions.Builder().apply { if (wifiOnly) requireWifi() }.build()
        val mgr = RemoteModelManager.getInstance()
        fun next(i: Int) {
            if (i >= langs.size) { onDone(null); return }
            mgr.download(model(langs[i]), cond)
                .addOnSuccessListener { next(i + 1) }
                .addOnFailureListener { onDone(it) }
        }
        next(0)
    }

    fun delete(ctx: Context, lang: String, onDone: () -> Unit) {
        MlKitTranslate.ensureInit(ctx)
        RemoteModelManager.getInstance().deleteDownloadedModel(model(lang))
            .addOnCompleteListener { onDone() }
    }
}

/** Máy dịch cho bàn phím: mỗi lượt một Translator, đóng khi xong ([TranslateEngine.close]). */
class MlKitEngineFactory(private val ctx: Context) : TranslateEngineFactory {
    override fun create(plan: TranslateDirection.Plan): TranslateEngine {
        MlKitTranslate.ensureInit(ctx)
        return MlKitEngine(plan)
    }
}

private class MlKitEngine(private val plan: TranslateDirection.Plan) : TranslateEngine {
    private var translator: Translator? = null
    private var closed = false

    override fun translate(text: String, onDone: (TranslateResult) -> Unit) {
        // Kiểm tra gói TRƯỚC: Translator.translate không bao giờ được tự tải (không tải ngầm từ bàn phím).
        RemoteModelManager.getInstance().getDownloadedModels(TranslateRemoteModel::class.java)
            .addOnSuccessListener { ms ->
                if (closed) return@addOnSuccessListener
                // English: ML Kit coi là luôn có (pivot) — có thể không nằm trong danh sách ⇒ không đòi.
                val have = ms.map { it.language }.toSet() + "en"
                if (plan.from !in have || plan.to !in have) { onDone(TranslateResult.MissingModel); return@addOnSuccessListener }
                val t = Translation.getClient(TranslatorOptions.Builder()
                    .setSourceLanguage(plan.from).setTargetLanguage(plan.to).build())
                translator = t
                t.translate(text)          // chạy trên executor nền của ML Kit; listener về main thread
                    .addOnSuccessListener { if (!closed) onDone(TranslateResult.Ok(it)) }
                    .addOnFailureListener { if (!closed) onDone(TranslateResult.Failed(it.toString())) }
            }
            .addOnFailureListener { if (!closed) onDone(TranslateResult.Failed(it.toString())) }
    }

    override fun close() {
        closed = true
        translator?.close()
        translator = null
    }
}
