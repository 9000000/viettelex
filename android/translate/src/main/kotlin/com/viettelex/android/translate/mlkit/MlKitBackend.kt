package com.viettelex.android.translate.mlkit

import android.content.Context
import com.google.mlkit.common.MlKit
import com.google.mlkit.common.model.DownloadConditions
import com.google.mlkit.common.model.RemoteModelManager
import com.google.mlkit.nl.translate.TranslateRemoteModel
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import com.viettelex.android.translate.TranslateBackend
import com.viettelex.keyboard.TranslateDirection
import com.viettelex.keyboard.TranslateEngine
import com.viettelex.keyboard.TranslateEngineFactory
import com.viettelex.keyboard.TranslateResult

/**
 * Máy dịch ML Kit (on-device) — CHỈ có trong module on-demand `:translate`; app gốc nạp bằng
 * reflection ([com.viettelex.android.translate.TranslateFeature.IMPL]). Chữ KHÔNG rời máy:
 * Translator chạy model cục bộ; mạng chỉ dùng khi người dùng bấm tải gói trong app.
 *
 * MlKitInitProvider bị gỡ (manifest module) ⇒ khởi tạo ML Kit ngay khi tạo backend — tức lúc
 * chạm "Dịch" / mở trang cài đặt dịch, không bao giờ lúc mở process.
 */
class MlKitBackend(ctx: Context) : TranslateBackend {
    init {
        try { MlKit.initialize(ctx.applicationContext) } catch (_: IllegalStateException) { /* đã khởi tạo */ }
    }

    private fun model(code: String) = TranslateRemoteModel.Builder(code).build()

    override val engineFactory = TranslateEngineFactory { plan -> MlKitEngine(plan) }

    override fun downloadedModels(onDone: (Set<String>?) -> Unit) {
        RemoteModelManager.getInstance().getDownloadedModels(TranslateRemoteModel::class.java)
            .addOnSuccessListener { ms -> onDone(ms.map { it.language }.toSet()) }
            .addOnFailureListener { onDone(null) }
    }

    override fun downloadModels(langs: List<String>, wifiOnly: Boolean, onDone: (Exception?) -> Unit) {
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

    override fun deleteModel(lang: String, onDone: () -> Unit) {
        RemoteModelManager.getInstance().deleteDownloadedModel(model(lang)).addOnCompleteListener { onDone() }
    }
}

/** Mỗi lượt một Translator, đóng khi xong ([TranslateEngine.close]). */
private class MlKitEngine(private val plan: TranslateDirection.Plan) : TranslateEngine {
    private var translator: Translator? = null
    private var closed = false

    override fun translate(text: String, onDone: (TranslateResult) -> Unit) {
        // Kiểm tra gói TRƯỚC: không bao giờ tự tải gói từ bàn phím.
        RemoteModelManager.getInstance().getDownloadedModels(TranslateRemoteModel::class.java)
            .addOnSuccessListener { ms ->
                if (closed) return@addOnSuccessListener
                // English: ML Kit coi là luôn có (pivot) — có thể không nằm trong danh sách ⇒ không đòi.
                val have = ms.map { it.language }.toSet() + "en"
                if (plan.from !in have || plan.to !in have) { onDone(TranslateResult.MissingModel); return@addOnSuccessListener }
                val t = Translation.getClient(TranslatorOptions.Builder()
                    .setSourceLanguage(plan.from).setTargetLanguage(plan.to).build())
                translator = t
                t.translate(text)          // executor nền của ML Kit; listener về main thread
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
