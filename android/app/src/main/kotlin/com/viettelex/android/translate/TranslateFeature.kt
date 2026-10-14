package com.viettelex.android.translate

import android.content.Context
import android.os.Build
import com.google.android.play.core.splitcompat.SplitCompat
import com.viettelex.android.BuildConfig
import com.viettelex.keyboard.TranslateEngine
import com.viettelex.keyboard.TranslateEngineFactory
import com.viettelex.keyboard.TranslateResult

/**
 * Phần máy dịch (ML Kit: libtranslate_jni.so 16.4 MB khi cài trên arm64, 11.6 MB armv7; Play chỉ
 * giao đúng ABI, nén ⇒ TẢI ~7 MB: arm64 6.8 + dex 0.3 MB, armv7 6.0 MB — đo AAB 1.5.5, khớp nhãn
 * "Tải tính năng Dịch (~7 MB)") nằm ở module Play Feature Delivery `:translate`
 * (on-demand) — APK gốc KHÔNG có ML Kit. Module chỉ tải khi người dùng bấm "Tải tính năng Dịch"
 * trong app; sau đó class [IMPL] được nạp bằng reflection (SplitCompat cho process đang chạy).
 *
 * APK cài ngoài Play (GitHub/sideload) không tải được module ⇒ tính năng Dịch bị ẩn ([offered]).
 */
interface TranslateBackend {
    val engineFactory: TranslateEngineFactory
    /** Mã ngôn ngữ đã có gói trên máy; null = không đọc được. Callback main thread. */
    fun downloadedModels(onDone: (Set<String>?) -> Unit)
    /** Tải tuần tự; null = xong hết, khác = lỗi đầu tiên. */
    fun downloadModels(langs: List<String>, wifiOnly: Boolean, onDone: (Exception?) -> Unit)
    fun deleteModel(lang: String, onDone: () -> Unit)
}

object TranslateFeature {
    /** Tên module (khớp thư mục/`:translate` và split name trong AAB). */
    const val MODULE = "translate"
    /** Lớp cài đặt [TranslateBackend] trong module, constructor (Context). Giữ qua R8 ở translate/proguard-rules.pro. */
    const val IMPL = "com.viettelex.android.translate.mlkit.MlKitBackend"
    private const val PLAY = "com.android.vending"

    @Volatile private var backend: TranslateBackend? = null
    @Volatile private var fromPlay: Boolean? = null

    /**
     * Có hiện tính năng Dịch không: cài từ Play (tải module được), hoặc module đã có sẵn,
     * hoặc bản debug (thử với bundletool --local-testing). Chỉ đọc PackageManager — không đụng ML Kit.
     */
    fun offered(ctx: Context): Boolean = BuildConfig.DEBUG || installedFromPlay(ctx) || isInstalled(ctx)

    /** Split `translate` đã cài (đọc splitNames — rẻ, không nạp gì). */
    fun isInstalled(ctx: Context): Boolean =
        backend != null || ctx.applicationInfo.splitNames?.contains(MODULE) == true

    fun installedFromPlay(ctx: Context): Boolean {
        fromPlay?.let { return it }
        val pm = ctx.packageManager
        val name = try {
            if (Build.VERSION.SDK_INT >= 30) pm.getInstallSourceInfo(ctx.packageName).installingPackageName
            else @Suppress("DEPRECATION") pm.getInstallerPackageName(ctx.packageName)
        } catch (_: Exception) { null }
        return (name == PLAY).also { fromPlay = it }
    }

    /**
     * Nạp backend từ module (null = module chưa cài). Gọi lúc chạm "Dịch" / mở trang cài đặt —
     * không bao giờ lúc khởi động. SplitCompat.install để process đang chạy thấy split vừa tải.
     */
    fun load(ctx: Context): TranslateBackend? {
        backend?.let { return it }
        synchronized(this) {
            backend?.let { return it }
            try { SplitCompat.install(ctx) } catch (_: Throwable) {}
            val b = try {
                val cls = Class.forName(IMPL, true, ctx.applicationContext.classLoader)
                cls.getConstructor(Context::class.java).newInstance(ctx.applicationContext) as TranslateBackend
            } catch (_: ClassNotFoundException) { null } catch (_: LinkageError) { null } catch (_: ReflectiveOperationException) { null }
            backend = b
            return b
        }
    }

    /** Factory cho bàn phím: module chưa có ⇒ máy dịch trả [TranslateResult.MissingModel] (nhắc mở app). */
    fun engineFactory(ctx: Context): TranslateEngineFactory = TranslateEngineFactory { plan ->
        load(ctx)?.engineFactory?.create(plan) ?: MissingEngine
    }

    private object MissingEngine : TranslateEngine {
        override fun translate(text: String, onDone: (TranslateResult) -> Unit) = onDone(TranslateResult.MissingModel)
        override fun close() {}
    }
}
