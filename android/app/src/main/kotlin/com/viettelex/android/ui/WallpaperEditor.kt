package com.viettelex.android.ui

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.BlurredEdgeTreatment
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.viettelex.android.ime.KeyLayout
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.ThemePalette
import com.viettelex.keyboard.WallpaperCrop
import com.viettelex.keyboard.WallpaperMath
import com.viettelex.keyboard.tr
import kotlinx.coroutines.delay

/**
 * Vùng bàn phím dọc (px) cho khung chỉnh ảnh nền: cỡ IME đo lần gần nhất ở hướng dọc
 * ([Keys.IME_PORTRAIT_SIZE]); chưa từng mở bàn phím ⇒ ước lượng cùng công thức IME.
 * [keysTop]/[keysH] = dải phím (dưới strip gợi ý, trên đệm thanh điều hướng) để vẽ phím mẫu.
 */
data class KeyboardFrame(val w: Int, val h: Int, val keysTop: Int, val keysH: Int) {
    val aspect: Double get() = if (w > 0 && h > 0) w.toDouble() / h else 1.4

    companion object {
        fun portrait(ctx: Context): KeyboardFrame {
            val res = ctx.resources
            val dm = res.displayMetrics
            val prefs = Prefs.of(ctx)
            val tablet = res.configuration.smallestScreenWidthDp >= 600
            val keyDp = KeyLayout.keyAreaDp(tablet, landscape = false,
                rowHeightAdjust = prefs.getInt(Keys.ROW_HEIGHT_ADJUST, Prefs.D.rowHeightAdjust),
                numberRow = prefs.getBoolean(Keys.NUMBER_ROW, Prefs.D.numberRow),
                numberRowFull = prefs.getBoolean(Keys.NUMBER_ROW_FULL_HEIGHT, Prefs.D.numberRowFullHeight))
            val stripDp = if (prefs.getBoolean(Keys.SHOW_SUGGESTIONS, Prefs.D.showSuggestions)) KeyLayout.OPEN_STRIP else 0f
            val strip = Math.round(stripDp * dm.density)
            val keys = Math.round(keyDp * dm.density)
            val measured = WallpaperMath.parseSize(
                ctx.getSharedPreferences(Keys.RUNTIME_PREFS, Context.MODE_PRIVATE).getString(Keys.IME_PORTRAIT_SIZE, null))
            val (w, h) = measured ?: WallpaperMath.estimatePortraitPx(minOf(dm.widthPixels, dm.heightPixels),
                dm.density, keyDp, stripDp, navBarPx(ctx) +
                    com.viettelex.android.ime.ImeInsets.raisePx(prefs.getInt(Keys.KEYBOARD_RAISE, Prefs.D.keyboardRaise), dm.density))
            return KeyboardFrame(w, h, strip.coerceAtMost(h), keys.coerceAtMost((h - strip).coerceAtLeast(1)))
        }

        @android.annotation.SuppressLint("DiscouragedApi", "InternalInsetResource")
        private fun navBarPx(ctx: Context): Int {
            val r = ctx.resources
            val id = r.getIdentifier("navigation_bar_height", "dimen", "android")
            return if (id != 0) r.getDimensionPixelSize(id) else 0
        }
    }
}

/**
 * Trình chỉnh ảnh nền: kéo + chụm ảnh dưới khung đúng tỉ lệ vùng bàn phím dọc, phím mẫu
 * + độ tối/độ mờ áp trực tiếp. Chạm hai lần = về khung giữa. Toán khung: [WallpaperCrop].
 */
@Composable
fun WallpaperEditorDialog(
    image: Bitmap,
    initialCrop: WallpaperCrop?,
    frame: KeyboardFrame,
    palette: ThemePalette,
    initialDim: Int,
    initialBlur: Int,
    onCancel: () -> Unit,
    onDone: (WallpaperCrop, Int, Int) -> Unit,
) {
    val c = LocalVT.current
    val iw = image.width; val ih = image.height
    val start = remember {
        initialCrop?.refit(iw, ih, frame.aspect) ?: WallpaperCrop.cover(iw, ih, frame.aspect)
    }
    var zoom by remember { mutableDoubleStateOf(start.zoom(iw, ih)) }
    var cx by remember { mutableDoubleStateOf(start.centerX) }
    var cy by remember { mutableDoubleStateOf(start.centerY) }
    var dim by remember { mutableIntStateOf(initialDim) }
    var blur by remember { mutableIntStateOf(initialBlur) }
    var lastGesture by remember { mutableLongStateOf(0L) }
    var interacting by remember { mutableStateOf(false) }
    LaunchedEffect(lastGesture) { if (lastGesture != 0L) { delay(300); interacting = false } }
    val bitmap = remember(image) { image.asImageBitmap() }
    fun crop() = WallpaperCrop.make(iw, ih, frame.aspect, zoom, cx, cy)
    fun reset() { zoom = 1.0; cx = 0.5; cy = 0.5 }

    Dialog(onDismissRequest = onCancel, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(c.groupedBg).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Huỷ"), style = VTType.body, color = c.accent, modifier = Modifier.clickable(onClick = onCancel))
                Text(tr("Chỉnh ảnh nền"), style = VTType.headline, color = c.label, textAlign = TextAlign.Center,
                    modifier = Modifier.weight(1f))
                Text(tr("Xong"), style = VTType.headline, color = c.accent,
                    modifier = Modifier.clickable { onDone(crop(), dim, blur) })
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState(), enabled = !interacting),
                verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Text(tr("Kéo để dời ảnh, chụm hai ngón để phóng to. Chạm hai lần để về khung giữa."),
                    style = VTType.footnote, color = c.secondary, textAlign = TextAlign.Center,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp))
                BoxWithConstraints(Modifier.fillMaxWidth().padding(horizontal = 12.dp)) {
                    val density = LocalDensity.current
                    val fwPx = with(density) { maxWidth.toPx() }
                    val fhPx = (fwPx / frame.aspect).toFloat()
                    val fh = with(density) { fhPx.toDp() }
                    val cr = crop()
                    // Bán kính mờ đo theo px ảnh đã nướng (≤1080) → quy ra px đang hiện.
                    val r = cr.pixelRect(iw, ih)
                    val (bw, _) = WallpaperMath.bakedSize(iw, ih, cr)
                    val blurDp = with(density) { (blur * fwPx / bw.coerceAtLeast(1)).toDp() }
                    Box(Modifier.fillMaxWidth().height(fh).clip(RoundedCornerShape(12.dp))
                        .border(1.dp, c.separator, RoundedCornerShape(12.dp))
                        .background(Color.Black)
                        .semantics { contentDescription = tr("Khung ảnh nền bàn phím") }
                        .pointerInput(iw, ih, frame) {
                            detectTransformGestures { _, pan, zoomChange, _ ->
                                interacting = true; lastGesture = System.nanoTime()
                                zoom = (zoom * zoomChange).coerceIn(1.0, WallpaperCrop.MAX_ZOOM)
                                val k = crop()
                                val moved = WallpaperCrop.make(iw, ih, frame.aspect, zoom,
                                    cx - pan.x / size.width * k.w, cy - pan.y / size.height * k.h)
                                cx = moved.centerX; cy = moved.centerY
                            }
                        }
                        .pointerInput(Unit) { detectTapGestures(onDoubleTap = { reset() }) }) {
                        Canvas(Modifier.fillMaxSize().let {
                            // Modifier.blur chỉ có hiệu lực API 31+ (máy cũ: xem trước không mờ, ảnh lưu vẫn mờ).
                            if (blur > 0 && Build.VERSION.SDK_INT >= 31) it.blur(blurDp, BlurredEdgeTreatment.Rectangle) else it
                        }) {
                            drawImage(bitmap, srcOffset = IntOffset(r[0], r[1]), srcSize = IntSize(r[2] - r[0], r[3] - r[1]),
                                dstSize = IntSize(size.width.toInt(), size.height.toInt()), filterQuality = FilterQuality.Medium)
                        }
                        Canvas(Modifier.fillMaxSize()) {
                            drawRect(Color(palette.wallpaperOverlay).copy(alpha = dim / 100f * palette.surfaceAlpha))
                        }
                        val top = with(density) { (fhPx * frame.keysTop / frame.h).toDp() }
                        val keysH = with(density) { (fhPx * frame.keysH / frame.h).toDp() }
                        Column(Modifier.fillMaxSize().alpha(if (interacting) 0.35f else 1f)) {
                            Spacer(Modifier.height(top))
                            KeyboardPreview(palette, null, 0, large = true, modifier = Modifier.fillMaxWidth().height(keysH),
                                keysOnly = true)
                        }
                    }
                }
                Column(Modifier.padding(horizontal = 20.dp)) {
                    Text(tr("Độ tối lớp phủ: %s%%", dim), style = VTType.body, color = c.label)
                    Slider(value = dim.toFloat(), onValueChange = { dim = (it / 5).toInt() * 5 }, valueRange = 0f..80f)
                    Text(tr("Độ mờ ảnh: %s", blur), style = VTType.body, color = c.label)
                    Slider(value = blur.toFloat(), onValueChange = { blur = it.toInt() }, valueRange = 0f..20f)
                    val centred = zoom == 1.0 && cx == 0.5 && cy == 0.5
                    Text(tr("Về khung giữa"), style = VTType.body, color = if (centred) c.tertiary else c.accent,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp).clickable(enabled = !centred) { reset() })
                }
            }
        }
    }
}
