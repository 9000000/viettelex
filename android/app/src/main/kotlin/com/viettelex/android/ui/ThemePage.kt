package com.viettelex.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Slider
import androidx.compose.material3.TextButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.viettelex.keyboard.KeyboardSettings
import com.viettelex.keyboard.KeyboardTheme
import com.viettelex.keyboard.KeyboardTransparency
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.ThemeGate
import com.viettelex.keyboard.ThemePalette
import com.viettelex.keyboard.ThemeSettings
import com.viettelex.keyboard.WallpaperCrop
import com.viettelex.keyboard.WallpaperMath
import com.viettelex.keyboard.withTransparency
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.ByteArrayOutputStream
import java.io.File
import com.viettelex.keyboard.tr

/**
 * Ảnh nền: app giữ bản gốc (inSampleSize + scale ≤2048px, xoay theo EXIF, chưa mờ, chưa cắt)
 * ở filesDir/wallpaper-src.jpg + khung cắt [WallpaperCrop] trong prefs; "nướng" đúng vùng cắt
 * ≤1080px, mờ (hộp 3 lượt), nén JPEG ≤400KB → filesDir/wallpaper.jpg (IME cùng process đọc,
 * chỉ giải vùng thấy được). Hai file KHÔNG vào sao lưu (backup_rules.xml).
 */
object WallpaperStore {
    fun file(ctx: Context) = File(ctx.filesDir, Keys.WALLPAPER_FILE)
    private fun src(ctx: Context) = File(ctx.filesDir, Keys.WALLPAPER_SRC_FILE)
    fun hasSource(ctx: Context) = src(ctx).exists()

    /** Ảnh từ picker → bitmap ≤ [maxEdge] (không giải bản gốc full-size). */
    fun decodeSmall(ctx: Context, uri: Uri, maxEdge: Int = WallpaperMath.SOURCE_MAX_EDGE): Bitmap? {
        val cr = ctx.contentResolver
        val b = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, b) }
        if (b.outWidth <= 0) return null
        val (tw, th) = WallpaperMath.targetSize(b.outWidth, b.outHeight, maxEdge)
        val o = BitmapFactory.Options().apply { inSampleSize = WallpaperMath.sampleSize(b.outWidth, b.outHeight, tw, th) }
        var bmp = cr.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, o) } ?: return null
        val (sw, sh) = WallpaperMath.targetSize(bmp.width, bmp.height, maxEdge)
        if (sw != bmp.width) bmp = Bitmap.createScaledBitmap(bmp, sw, sh, true)
        val rot = runCatching {
            when (cr.openInputStream(uri)?.use {
                ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }) {
                ExifInterface.ORIENTATION_ROTATE_90 -> 90
                ExifInterface.ORIENTATION_ROTATE_180 -> 180
                ExifInterface.ORIENTATION_ROTATE_270 -> 270
                else -> 0
            }
        }.getOrDefault(0)
        if (rot != 0) bmp = Bitmap.createBitmap(bmp, 0, 0, bmp.width, bmp.height, Matrix().apply { postRotate(rot.toFloat()) }, true)
        return bmp
    }

    fun encode(bmp: Bitmap): ByteArray {
        var q = 80
        while (true) {
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, q, out)
            if (out.size() <= WallpaperMath.MAX_BYTES || q <= 40) return out.toByteArray()
            q -= 10
        }
    }

    fun blurred(bmp: Bitmap, radius: Int): Bitmap {
        if (radius <= 0) return bmp
        val px = IntArray(bmp.width * bmp.height)
        bmp.getPixels(px, 0, bmp.width, 0, 0, bmp.width, bmp.height)
        WallpaperMath.blur(px, bmp.width, bmp.height, radius)
        return Bitmap.createBitmap(px, bmp.width, bmp.height, Bitmap.Config.ARGB_8888)
    }

    /** Bản gốc đã lưu (≤2048; ảnh chọn trước bản có trình chỉnh ≤1080). */
    fun loadSource(ctx: Context): Bitmap? =
        src(ctx).takeIf { it.exists() }?.let { BitmapFactory.decodeFile(it.path) }

    /**
     * Ảnh cho IME: cắt vùng [crop] (null = cả ảnh — ảnh cũ chưa có khung, IME tự cắt giữa như
     * trước), thu ≤1080, mờ. Luôn là bitmap MỚI.
     */
    fun render(source: Bitmap, crop: WallpaperCrop?, blur: Int): Bitmap {
        val r = crop?.pixelRect(source.width, source.height) ?: intArrayOf(0, 0, source.width, source.height)
        val cw = r[2] - r[0]; val ch = r[3] - r[1]
        val (tw, th) = WallpaperMath.bakedSize(source.width, source.height, crop)
        val m = Matrix().apply { setScale(tw.toFloat() / cw, th.toFloat() / ch) }
        var cut = Bitmap.createBitmap(source, r[0], r[1], cw, ch, m, true)
        if (cut === source) cut = source.copy(Bitmap.Config.ARGB_8888, false)
        return blurred(cut, blur)
    }

    /** "Xong" ở trình chỉnh: lưu bản gốc (nếu mới chọn) + nướng vùng cắt cho IME. */
    fun save(ctx: Context, source: Bitmap, isNew: Boolean, crop: WallpaperCrop?, blur: Int): Boolean {
        val out = encode(render(source, crop, blur))
        if (isNew) src(ctx).writeBytes(encodeSource(source))
        file(ctx).writeBytes(out)
        return true
    }

    fun encodeSource(bmp: Bitmap): ByteArray =
        ByteArrayOutputStream().also { bmp.compress(Bitmap.CompressFormat.JPEG, 88, it) }.toByteArray()

    fun reblur(ctx: Context, blur: Int, crop: WallpaperCrop?): Boolean {
        val bmp = loadSource(ctx) ?: return false
        file(ctx).writeBytes(encode(render(bmp, crop, blur)))
        return true
    }

    fun remove(ctx: Context) { file(ctx).delete(); src(ctx).delete() }

    fun preview(ctx: Context): ImageBitmap? {
        val f = file(ctx).takeIf { it.exists() } ?: return null
        val o = BitmapFactory.Options().apply { inSampleSize = 2 }
        return BitmapFactory.decodeFile(f.path, o)?.asImageBitmap()
    }
}

internal fun loadThemeSettings(ctx: Context): ThemeSettings {
    val all = Prefs.of(ctx).all
    return ThemeSettings.load { all[it] }
}

private fun saveThemeSettings(ctx: Context, s: ThemeSettings) {
    Prefs.of(ctx).edit().apply {
        putString(Keys.KEYBOARD_THEME, s.theme.id)
        putBoolean(Keys.WALLPAPER_ENABLED, s.wallpaper)
        putInt(Keys.WALLPAPER_DIM, s.dim)
        putInt(Keys.WALLPAPER_BLUR, s.blur)
        putLong(Keys.WALLPAPER_VERSION, s.version)
        s.crop?.let { putString(Keys.WALLPAPER_CROP, it.serialize()) } ?: remove(Keys.WALLPAPER_CROP)
        putInt(Keys.KEYBOARD_TRANSPARENCY, s.keyboardTransparency)
        putInt(Keys.KEY_LABEL_TRANSPARENCY, s.labelTransparency)
    }.apply()
}

/** Dòng trong section Giao diện mở trang theme. */
@Composable
fun ThemeRow(onOpen: () -> Unit) {
    val c = LocalVT.current
    val ctx = LocalContext.current
    val current = remember { loadThemeSettings(ctx).theme.title }
    VTRow(onClick = onOpen) {
        Text(tr("Theme & ảnh nền"), style = VTType.body, color = c.label, modifier = Modifier.weight(1f))
        Text("$current ›", style = VTType.body, color = c.secondary)
    }
}

/** Palette để xem trước trong app: SYSTEM mô phỏng màu sáng/tối mặc định. */
private fun previewPalette(t: KeyboardTheme, dark: Boolean): ThemePalette = t.palette(dark) ?: if (dark)
    ThemePalette(bg = 0xFF1F1F1F.toInt(), keyFill = 0xFF3C3C3F.toInt(), specialFill = 0xFF2B2F36.toInt(),
        ink = 0xFFE3E3E3.toInt(), trail = 0xFFA8C7FA.toInt(), balloon = 0xFF4A4A4E.toInt(), popup = 0xFF3C3C3F.toInt(),
        action = 0xFFA8C7FA.toInt(), actionInk = 0xFF062E6F.toInt(), chip = 0xFF004A77.toInt(), isDark = true)
else ThemePalette(bg = 0xFFEEF0F4.toInt(), keyFill = 0xFFFFFFFF.toInt(), specialFill = 0xFFD6DBE3.toInt(),
    ink = 0xFF1F1F1F.toInt(), trail = 0xFF0B57D0.toInt(), balloon = 0xFFFFFFFF.toInt(), popup = 0xFFFFFFFF.toInt(),
    action = 0xFF0B57D0.toInt(), actionInk = 0xFFFFFFFF.toInt(), chip = 0xFFD3E3FD.toInt(), isDark = false)

@Composable
fun ThemePage(onBack: () -> Unit) {
    val c = LocalVT.current
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    BackHandler(onBack = onBack)
    val dark = (ctx.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
        android.content.res.Configuration.UI_MODE_NIGHT_YES
    var s by remember { mutableStateOf(loadThemeSettings(ctx)) }
    var wall by remember { mutableStateOf(WallpaperStore.preview(ctx)) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmReset by remember { mutableStateOf(false) }
    // Ảnh đưa vào trình chỉnh (mới chọn: chưa ghi gì — Huỷ thì ảnh nền cũ còn nguyên).
    var editor by remember { mutableStateOf<EditorInput?>(null) }
    fun update(n: ThemeSettings) { s = n; saveThemeSettings(ctx, n) }

    fun afterWrite(ok: Boolean, enable: Boolean) {
        busy = false
        if (!ok) { error = tr("Không đọc được ảnh này."); return }
        error = null
        wall = WallpaperStore.preview(ctx)
        update(s.copy(wallpaper = if (enable) true else s.wallpaper, version = System.currentTimeMillis()))
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            val bmp = withContext(Dispatchers.Default) { runCatching { WallpaperStore.decodeSmall(ctx, uri) }.getOrNull() }
            busy = false
            if (bmp == null) error = tr("Không đọc được ảnh này.") else { error = null; editor = EditorInput(bmp, null, isNew = true) }
        }
    }

    editor?.let { input ->
        WallpaperEditorDialog(input.image, input.crop, remember(input) { KeyboardFrame.portrait(ctx) },
            palette = (s.effectiveTheme.palette(dark) ?: previewPalette(KeyboardTheme.SYSTEM, dark)).overWallpaper()
                .withTransparency(s.keyboardTransparency, s.labelTransparency, dark),
            initialDim = s.dim, initialBlur = s.blur,
            onCancel = { editor = null },
            onDone = { crop, dim, blur ->
                editor = null
                busy = true
                scope.launch {
                    val ok = withContext(Dispatchers.Default) {
                        runCatching { WallpaperStore.save(ctx, input.image, input.isNew, crop, blur) }.getOrDefault(false)
                    }
                    if (ok) s = s.copy(crop = crop, dim = dim, blur = blur)
                    afterWrite(ok, enable = true)
                }
            })
    }

    SubPageHeader(FeaturePage.GiaoDien.title, onBack)

    val active = s.wallpaperActive(wall != null)
    val pal = (s.effectiveTheme.palette(dark) ?: previewPalette(KeyboardTheme.SYSTEM, dark)).let { if (active) it.overWallpaper() else it }
        .withTransparency(s.keyboardTransparency, s.labelTransparency, dark)
    val raise by rememberIntPref(Keys.KEYBOARD_RAISE, Prefs.D.keyboardRaise)
    VTSection(footer = tr("Áp dụng lần mở bàn phím kế tiếp.")) {
        // Nâng bàn phím: khung cao thêm đúng tỉ lệ thu nhỏ của bản xem trước, phím giữ cỡ.
        val raisePreview = raise * PREVIEW_SCALE
        KeyboardPreview(pal, if (active) wall else null, s.dim, large = true, backdrop = KeyboardTransparency.systemBackdrop(dark),
            modifier = Modifier.fillMaxWidth().height(180.dp + raisePreview.dp), bottomPadDp = raisePreview)
    }

    if (!ThemeGate.allowsWallpaper) {
        VTSection(footer = tr("Theme có nhãn Plus và ảnh nền thuộc VietTelex Plus (Giới Thiệu → VietTelex Plus). Hệ thống, Tối OLED và Tương phản cao luôn miễn phí.")) {}
    }

    VTSection(header = "Theme") {
        KeyboardTheme.entries.chunked(3).forEach { row ->
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { t ->
                    val locked = !ThemeGate.allows(t)
                    val selected = s.theme == t
                    Column(Modifier.weight(1f).clickable(enabled = !locked) { update(s.copy(theme = t)) },
                        verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        KeyboardPreview(previewPalette(t, dark), null, 0, large = false,
                            modifier = Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(8.dp))
                                .border(if (selected) 3.dp else 1.dp, if (selected) c.accent else c.separator, RoundedCornerShape(8.dp)))
                        Text(t.title + if (t.isPlus) " · Plus" else "", style = VTType.footnote,
                            color = if (locked) c.secondary else c.label, maxLines = 1)
                    }
                }
                repeat(3 - row.size) { Box(Modifier.weight(1f)) }
            }
        }
    }

    VTSection(header = tr("Ảnh nền · Plus"),
        footer = tr("Ảnh được thu nhỏ và nén ngay trên máy, không gửi đi đâu. Lớp phủ giúp chữ trên phím dễ đọc.")) {
        VTRow(onClick = if (busy || !ThemeGate.allowsWallpaper) null else {
            { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }
        }) {
            Text(if (wall != null) tr("Đổi ảnh nền") else tr("Chọn ảnh nền"), style = VTType.body,
                color = if (ThemeGate.allowsWallpaper) c.accent else c.secondary)
        }
        if (wall != null && WallpaperStore.hasSource(ctx)) {
            RowDivider()
            // Mở lại bản gốc với khung đang dùng (ảnh cũ chưa có khung ⇒ bắt đầu từ khung giữa).
            VTRow(onClick = if (busy || !ThemeGate.allowsWallpaper) null else {
                {
                    busy = true
                    scope.launch {
                        val bmp = withContext(Dispatchers.Default) { runCatching { WallpaperStore.loadSource(ctx) }.getOrNull() }
                        busy = false
                        if (bmp == null) error = tr("Không đọc được ảnh này.") else editor = EditorInput(bmp, s.crop, isNew = false)
                    }
                }
            }) {
                Text(tr("Chỉnh ảnh"), style = VTType.body, color = if (ThemeGate.allowsWallpaper) c.accent else c.secondary)
            }
        }
        if (wall != null) {
            RowDivider()
            SettingToggle(tr("Dùng ảnh nền"), null, s.wallpaper) { update(s.copy(wallpaper = it)) }
            RowDivider()
            Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                Text(tr("Độ tối lớp phủ: %s%%", s.dim), style = VTType.body, color = c.label)
                Slider(value = s.dim.toFloat(), onValueChange = { update(s.copy(dim = (it / 5).toInt() * 5)) }, valueRange = 0f..80f)
                Text(tr("Độ mờ ảnh: %s", s.blur), style = VTType.body, color = c.label)
                Slider(value = s.blur.toFloat(), onValueChange = { s = s.copy(blur = it.toInt()) }, valueRange = 0f..20f,
                    onValueChangeFinished = {
                        busy = true
                        val blur = s.blur; val crop = s.crop
                        scope.launch {
                            val ok = withContext(Dispatchers.Default) { runCatching { WallpaperStore.reblur(ctx, blur, crop) }.getOrDefault(false) }
                            afterWrite(ok, enable = false)
                        }
                    })
            }
            RowDivider()
            VTRow(onClick = {
                WallpaperStore.remove(ctx); wall = null
                update(s.copy(wallpaper = false, crop = null, version = System.currentTimeMillis()))
            }) { Text(tr("Xoá ảnh nền"), style = VTType.body, color = c.red) }
        }
        if (busy) VTRow { Text(tr("Đang xử lý ảnh…"), style = VTType.footnote, color = c.secondary) }
        error?.let { VTRow { Text(it, style = VTType.footnote, color = c.red) } }
    }

    VTSection(header = tr("Độ trong suốt"),
        footer = tr("Phím: nền, ảnh nền, nền và viền phím — 100% chỉ còn chữ (thấy app phía sau). Ký tự: chữ và biểu tượng trên phím — 100% là phím trơn không chữ.")) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
            Text(tr("Độ trong suốt phím: %s%%", s.keyboardTransparency), style = VTType.body, color = c.label)
            Slider(value = s.keyboardTransparency.toFloat(), valueRange = 0f..100f,
                onValueChange = { update(s.copy(keyboardTransparency = Math.round(it / 5) * 5)) })
            Text(tr("Độ trong suốt ký tự: %s%%", s.labelTransparency), style = VTType.body, color = c.label)
            Slider(value = s.labelTransparency.toFloat(), valueRange = 0f..100f,
                onValueChange = { update(s.copy(labelTransparency = Math.round(it / 5) * 5)) })
        }
    }

    // Tính Năng → Giao diện gộp luôn chiều cao hàng + logo (không thuộc "Khôi phục giao diện gốc").
    VTSection(header = tr("Bàn phím")) {
        var adj by rememberIntPref(Keys.ROW_HEIGHT_ADJUST, Prefs.D.rowHeightAdjust)
        val numberRow by rememberBoolPref(Keys.NUMBER_ROW, Prefs.D.numberRow)
        val numberRowFull by rememberBoolPref(Keys.NUMBER_ROW_FULL_HEIGHT, Prefs.D.numberRowFullHeight)
        VTRow {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(tr("Chiều cao hàng phím"), style = VTType.body, color = c.label)
                Text(
                    if (adj == 0) tr("Chuẩn") else String.format(java.util.Locale.ROOT, tr("%+d dp mỗi hàng (%+d dp cả bàn phím)"), adj,
                        com.viettelex.android.ime.KeyLayout.adjustTotalDp(adj, numberRow, numberRowFull)),
                    style = VTType.footnote, color = c.secondary,
                )
            }
            IosStepper(adj, -10..10) { adj = it }
        }
        RowDivider()
        KeyboardRaiseRow()
        RowDivider()
        BoolToggle(Keys.SHOW_SPACE_LOGO, Prefs.D.showSpaceLogo, tr("Hiện logo Vᴛ"), tr("Logo mờ ở góc phải phím cách."))
    }

    VTSection(footer = tr("Về theme Hệ thống, tắt ảnh nền (ảnh vẫn giữ để bật lại), độ tối/mờ và độ trong suốt về mặc định. Chiều cao hàng và logo giữ nguyên.")) {
        VTRow(onClick = if (s.isDefault || busy) null else { { confirmReset = true } }) {
            Text(tr("Khôi phục giao diện gốc"), style = VTType.body, color = if (s.isDefault) c.secondary else c.red)
        }
    }
    if (confirmReset) AlertDialog(
        onDismissRequest = { confirmReset = false },
        title = { Text(tr("Khôi phục giao diện gốc?")) },
        text = { Text(tr("Theme, ảnh nền và độ trong suốt về mặc định. Ảnh nền không bị xoá.")) },
        confirmButton = { TextButton(onClick = {
            confirmReset = false
            val blurChanged = s.blur != 0
            update(s.resetToDefaults())
            // Ảnh đang lưu đã mờ theo độ cũ → dựng lại bản không mờ từ ảnh gốc.
            if (blurChanged && wall != null) {
                busy = true
                scope.launch {
                    val crop = s.crop
                    val ok = withContext(Dispatchers.Default) { runCatching { WallpaperStore.reblur(ctx, 0, crop) }.getOrDefault(false) }
                    afterWrite(ok, enable = false)
                }
            }
        }) { Text(tr("Khôi phục"), color = c.red) } },
        dismissButton = { TextButton(onClick = { confirmReset = false }) { Text(tr("Huỷ")) } },
    )
}

/** Ảnh đưa vào trình chỉnh ảnh nền. */
private data class EditorInput(val image: Bitmap, val crop: WallpaperCrop?, val isNew: Boolean)

/** Bản xem trước ≈ 0.7 cỡ bàn phím thật (180 dp cho ~258 dp phím + strip). */
private const val PREVIEW_SCALE = 0.7f

/**
 * "Nâng bàn phím" (#112): thanh trượt 0…48 dp (bước 4) — đệm nền dưới hàng phím đáy để
 * bàn phím nằm cao hơn (ngón cái dễ với, tránh thanh cử chỉ). Bản xem trước trên trang cao theo.
 */
@Composable
private fun KeyboardRaiseRow() {
    val c = LocalVT.current
    var raise by rememberIntPref(Keys.KEYBOARD_RAISE, Prefs.D.keyboardRaise)
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
        Text(tr("Nâng bàn phím"), style = VTType.body, color = c.label)
        Text(if (raise == 0) tr("Tắt") else tr("Cao hơn %d dp", raise), style = VTType.footnote, color = c.secondary)
        Slider(value = raise.toFloat(), valueRange = 0f..KeyboardSettings.KEYBOARD_RAISE_MAX.toFloat(),
            steps = KeyboardSettings.KEYBOARD_RAISE_MAX / 4 - 1,
            onValueChange = { raise = KeyboardSettings.clampRaise(Math.round(it / 4) * 4) })
        Text(tr("Thêm khoảng trống dưới hàng phím cuối để bàn phím nằm cao hơn."), style = VTType.footnote, color = c.secondary)
    }
}

/** Bàn phím thu nhỏ vẽ bằng đúng token theme. [keysOnly]: chỉ phím (lớp phủ trình chỉnh ảnh nền).
 *  [bottomPadDp]: dải nền trống dưới hàng phím đáy (xem trước "Nâng bàn phím"). */
@Composable
internal fun KeyboardPreview(p: ThemePalette, wallpaper: ImageBitmap?, dim: Int, large: Boolean, modifier: Modifier,
                             backdrop: Int? = null, keysOnly: Boolean = false, bottomPadDp: Float = 0f) {
    Box(modifier) {
        val bottom = p.bgBottom
        if (!keysOnly) Canvas(Modifier.fillMaxSize()) {
            // Nền trong suốt: lộ app phía sau (giả lập bằng màu nền app sáng/tối).
            backdrop?.let { drawRect(Color(it)) }
            if (bottom != null) drawRect(Brush.verticalGradient(listOf(Color(p.bg), Color(bottom))))
            else drawRect(Color(p.bg))
        }
        if (wallpaper != null) {
            Image(wallpaper, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop, alpha = p.surfaceAlpha)
            Canvas(Modifier.fillMaxSize()) { drawRect(Color(p.wallpaperOverlay).copy(alpha = dim / 100f * p.surfaceAlpha)) }
        }
        Canvas(Modifier.fillMaxSize()) {
            val pad = if (large) 6.dp.toPx() else 3.dp.toPx()
            val gap = if (large) 5.dp.toPx() else 2.dp.toPx()
            val r = if (large) 6.dp.toPx() else 2.dp.toPx()
            val kw = (size.width - pad * 2 - gap * 9) / 10
            val kh = (size.height - bottomPadDp.dp.toPx() - pad * 2 - gap * 3) / 4
            fun key(x: Float, y: Float, w: Float, fill: Int) {
                drawRoundRect(Color(fill), Offset(x, y), Size(w, kh), CornerRadius(r))
                p.keyBorder?.let { drawRoundRect(Color(it), Offset(x, y), Size(w, kh), CornerRadius(r), style = Stroke(1.dp.toPx())) }
                if (large) drawCircle(Color(p.keyInk).copy(alpha = 0.8f * p.labelAlpha), minOf(w, kh) * 0.09f, Offset(x + w / 2, y + kh / 2))
            }
            val counts = intArrayOf(10, 9, 7)
            for (row in 0..2) {
                val n = counts[row]
                val x0 = pad + (10 - n) * (kw + gap) / 2
                for (i in 0 until n) key(x0 + i * (kw + gap), pad + row * (kh + gap), kw, p.keyFill)
            }
            val y = pad + 3 * (kh + gap)
            key(pad, y, kw * 2 + gap, p.specialFill)
            key(pad + 2 * (kw + gap), y, kw * 6 + gap * 5, p.keyFill)
            key(pad + 8 * (kw + gap), y, kw * 2 + gap, p.action)
        }
    }
}
