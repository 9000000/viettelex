package com.viettelex.android.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.viettelex.android.translate.TranslateModels
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.L10n
import com.viettelex.keyboard.TranslateLangs
import com.viettelex.keyboard.tr

/**
 * Cài đặt "Dịch trên máy" (Plus) — dưới dòng tính năng trên màn Plus: chọn ngôn ngữ đích
 * (mọi ngôn ngữ ML Kit hỗ trợ), chỉ-Wi-Fi, tải / xoá gói ngôn ngữ. Gói CHỈ tải khi bấm ở đây.
 */
@Composable
fun TranslateSettings() {
    val c = LocalVT.current
    val ctx = LocalContext.current
    var targetRaw by rememberStringPref(Keys.TRANSLATE_TARGET, TranslateLangs.DEFAULT_TARGET)
    val target = TranslateLangs.normalizeTarget(targetRaw)
    var wifiOnly by rememberBoolPref(Keys.TRANSLATE_WIFI_ONLY, true)
    var have by remember { mutableStateOf<Set<String>?>(null) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf(false) }
    var refresh by remember { mutableStateOf(0) }
    val ui = if (L10n.isEnglish) L10n.EN else L10n.VI     // đọc state ngôn ngữ ⇒ recompose khi đổi

    LaunchedEffect(refresh) { TranslateModels.downloaded(ctx) { have = it ?: emptySet() } }

    val need = listOf(TranslateLangs.VI, target)
    val ready = have?.containsAll(need) == true
    val sizeHint = tr("~30 MB mỗi ngôn ngữ")

    RowDivider()
    VTRow(onClick = { picking = true }) {
        Text(tr("Dịch sang"), style = VTType.body, color = c.label, modifier = Modifier.weight(1f))
        Text(TranslateLangs.displayName(target, ui) + " ›", style = VTType.body, color = c.secondary)
    }
    RowDivider()
    VTRow {
        Text(tr("Chiều ngược lại: đoạn đã là %s sẽ dịch sang tiếng Việt.", TranslateLangs.displayName(target, ui)),
            style = VTType.footnote, color = c.secondary)
    }
    RowDivider()
    SettingToggle(tr("Chỉ tải qua Wi-Fi"), null, wifiOnly) { wifiOnly = it }
    RowDivider()
    val status = when {
        have == null -> "…"
        busy -> tr("Đang tải gói dịch…")
        ready -> tr("✓ Đã có gói: Tiếng Việt + %s", TranslateLangs.displayName(target, ui))
        else -> tr("Tải gói dịch (Tiếng Việt + %s, %s)", TranslateLangs.displayName(target, ui), sizeHint)
    }
    VTRow(onClick = if (ready || busy || have == null) null else {
        {
            busy = true; error = null
            val missing = TranslateModels.required(target).filter { it == "en" || have?.contains(it) != true }
            TranslateModels.download(ctx, missing, wifiOnly) { e ->
                busy = false
                if (e != null) error = if (wifiOnly) tr("Chưa tải được — cần Wi-Fi (hoặc tắt “Chỉ tải qua Wi-Fi”).") else tr("Chưa tải được — kiểm tra kết nối rồi thử lại.")
                refresh++
            }
        }
    }) {
        Text(status, style = VTType.body, color = if (ready) c.green else c.accent)
    }
    error?.let { e ->
        VTRow { Text(e, style = VTType.footnote, color = c.secondary) }
    }
    // Gói đã tải khác (đổi đích nhiều lần) — xoá để lấy lại chỗ. Không xoá tiếng Việt / đích hiện tại.
    val extra = have.orEmpty().filter { it != TranslateLangs.VI && it != target && it != "en" }
    if (extra.isNotEmpty()) {
        RowDivider()
        VTRow(onClick = {
            busy = true
            var left = extra.size
            for (l in extra) TranslateModels.delete(ctx, l) { if (--left == 0) { busy = false; refresh++ } }
        }) {
            Text(tr("Xoá gói không dùng (%s)", extra.joinToString { TranslateLangs.displayName(it, ui) }),
                style = VTType.body, color = c.accent)
        }
    }
    VTRow {
        Text(tr("Dịch chạy ngay trên máy bằng Google ML Kit — chữ bạn gõ không bao giờ được gửi đi. Mạng chỉ dùng khi bạn bấm tải gói."),
            style = VTType.footnote, color = c.secondary)
    }

    if (picking) AlertDialog(
        onDismissRequest = { picking = false },
        title = { Text(tr("Dịch sang")) },
        text = {
            LazyColumn(Modifier.heightIn(max = 420.dp)) {
                items(TranslateLangs.pickerOrder(ui)) { code ->
                    VTRow(onClick = { targetRaw = code; picking = false; error = null }) {
                        Column(Modifier.weight(1f)) {
                            Text(TranslateLangs.displayName(code, ui), style = VTType.body, color = c.label)
                        }
                        if (code == target) Text("✓", style = VTType.body, color = c.accent, modifier = Modifier.padding(start = 8.dp))
                        else if (have?.contains(code) == true) Text("↓", style = VTType.footnote, color = c.secondary)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { picking = false }) { Text(tr("Đóng"), color = c.accent) } },
    )
}
