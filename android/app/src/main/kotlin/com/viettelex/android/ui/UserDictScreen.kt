package com.viettelex.android.ui

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.viettelex.keyboard.ImmediateMainThread
import com.viettelex.keyboard.Keys
import com.viettelex.keyboard.UserLangModel
import java.io.File
import java.util.concurrent.Executor
import com.viettelex.keyboard.tr

/**
 * Từ điển cá nhân: xem/tìm/xoá từ bàn phím đã học, thêm tay tên riêng/thuật ngữ.
 *
 * App (process ":settings") và IME chung filesDir: app mở userlm.bin bằng một UserLangModel đồng
 * bộ (IO tại chỗ), sửa, ghi lại, rồi đổi mốc [Keys.USERLM_RESET_AT] — IME nhận qua PrefSync
 * (broadcast; lỡ thì so mốc file prefs lúc hiện bàn phím) ⇒ bỏ bảng trong RAM (huỷ ghi chờ,
 * không ghi đè) và nạp lại file.
 */
private object UserDictStore {
    private val direct = Executor { it.run() }
    fun open(ctx: Context) = UserLangModel(File(ctx.filesDir, Keys.USERLM_FILE), ImmediateMainThread(), direct)

    /** Ghi file (đồng bộ) + báo IME nạp lại. */
    fun commit(ctx: Context, m: UserLangModel) {
        m.save()
        Prefs.of(ctx).edit().putLong(Keys.USERLM_RESET_AT, System.currentTimeMillis()).apply()
    }

    fun eraseAll(ctx: Context) {
        File(ctx.filesDir, Keys.USERLM_FILE).delete()
        // IME thấy mốc đổi ⇒ bỏ model trong RAM, seed lại, không ghi đè.
        Prefs.of(ctx).edit().putLong(Keys.USERLM_RESET_AT, System.currentTimeMillis()).apply()
    }
}

@Composable
fun UserDictDialog(onDismiss: () -> Unit) {
    val c = LocalVT.current
    val ctx = LocalContext.current
    val model = remember { UserDictStore.open(ctx) }
    var rev by remember { mutableIntStateOf(0) }          // đổi ⇒ tính lại danh sách
    var query by remember { mutableStateOf("") }
    var newWord by remember { mutableStateOf("") }
    var notice by remember { mutableStateOf<String?>(null) }
    var confirmErase by remember { mutableStateOf(false) }
    val entries = remember(rev, query) { model.entries(query) }
    val total = remember(rev) { model.entries().size }

    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(c.groupedBg).safeDrawingPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(tr("Từ điển cá nhân"), style = VTType.headline, color = c.label, modifier = Modifier.weight(1f))
                Text(tr("Xong"), style = VTType.body, color = c.accent, modifier = Modifier.clickable(onClick = onDismiss))
            }
            LazyColumn(Modifier.fillMaxSize()) {
                item {
                    VTSection(header = tr("Thêm từ"), footer = notice
                        ?: tr("Tên riêng, thuật ngữ… (một từ, chỉ chữ cái). Từ thêm tay được gợi ý ngay khi gõ vài chữ đầu.")) {
                        val canAdd = newWord.isNotBlank()
                        VTRow {
                            VTTextField(newWord, { newWord = it; notice = null }, "VD: Kubernetes", modifier = Modifier.weight(1f))
                            Box(
                                Modifier.padding(start = 8.dp).size(28.dp).clickable(enabled = canAdd) {
                                    if (model.addWord(newWord)) {
                                        UserDictStore.commit(ctx, model)
                                        notice = tr("Đã thêm “%s”.", newWord.trim())
                                        newWord = ""; rev++
                                    } else notice = tr("Chỉ nhận một từ gồm chữ cái (tối đa %s ký tự).", UserLangModel.MANUAL_MAX_LEN)
                                },
                                contentAlignment = Alignment.Center,
                            ) { GlyphIcon(Glyph.Plus, if (canAdd) c.accent else c.tertiary, 24.dp) }
                        }
                    }
                }
                item {
                    VTSection(header = tr("Tìm")) {
                        VTRow { VTTextField(query, { query = it }, tr("Tìm từ…")) }
                    }
                }
                item {
                    Text(
                        (if (query.isBlank()) tr("Từ đã học (%s)", total) else tr("Kết quả (%s)", entries.size)).uppercase(),
                        style = VTType.footnote, color = c.secondary,
                        modifier = Modifier.padding(start = 32.dp, end = 32.dp, bottom = 7.dp),
                    )
                }
                items(entries, key = { it.word }) { e ->
                    val first = e === entries.first()
                    val last = e === entries.last()
                    val shape = RoundedCornerShape(
                        topStart = if (first) 12.dp else 0.dp, topEnd = if (first) 12.dp else 0.dp,
                        bottomStart = if (last) 12.dp else 0.dp, bottomEnd = if (last) 12.dp else 0.dp,
                    )
                    Column(Modifier.padding(horizontal = 16.dp).clip(shape).background(c.card)) {
                        if (!first) RowDivider()
                        VTRow {
                            Text(e.word, style = VTType.body, color = c.label, modifier = Modifier.weight(1f))
                            Text(if (e.manual) tr("thêm tay") else "${e.count}", style = VTType.footnote, color = c.secondary)
                            Box(
                                Modifier.padding(start = 12.dp).size(28.dp).clickable {
                                    if (model.removeWord(e.word)) { UserDictStore.commit(ctx, model); rev++ }
                                },
                                contentAlignment = Alignment.Center,
                            ) { GlyphIcon(Glyph.Trash, c.red, 18.dp) }
                        }
                    }
                }
                if (entries.isEmpty()) item {
                    VTSection {
                        VTRow {
                            Text(if (query.isBlank()) tr("Chưa có từ nào — gõ bằng VietTelex để bàn phím học.") else tr("Không có từ khớp."),
                                style = VTType.body, color = c.secondary)
                        }
                    }
                }
                item {
                    Box(Modifier.height(24.dp).width(1.dp))
                    VTSection(footer = tr("Xoá một từ cũng xoá các cặp/bộ ba từ đi kèm nó. Mọi dữ liệu chỉ nằm trên máy.")) {
                        VTRow(onClick = {
                            if (!confirmErase) { confirmErase = true; return@VTRow }
                            UserDictStore.eraseAll(ctx)
                            confirmErase = false
                            // model của màn này: nạp lại (file đã xoá ⇒ rỗng)
                            model.reloadAfterExternalErase(); rev++
                        }) {
                            Text(if (confirmErase) tr("Chạm lần nữa để xoá tất cả") else tr("Xoá tất cả từ đã học"),
                                style = VTType.body, color = c.red)
                        }
                    }
                }
            }
        }
    }
}
