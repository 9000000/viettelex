package com.viettelex.keyboard

/**
 * "Phím cạnh dấu cách" (setting [Keys.SPACE_SIDE_KEY]; cùng chuỗi với iOS App Group
 * "spaceSideKey"): phím hẹp bên phải space ở hàng đáy bàn CHỮ điện thoại, ô thường.
 *  - [COMMA] (mặc định, bố cục cũ): "," — giữ ra "." và dấu câu khác.
 *  - [PERIOD]: "." cùng chỗ, cùng cỡ — giữ ra "," (chọn sẵn) và dấu câu khác.
 *  - [OFF]: không phím; space rộng thêm. Space đôi vẫn ra ". ".
 * Ô URL / email, tablet, plane số / ký hiệu không đổi. Đọc lúc dựng layout — 0 chi phí mỗi phím.
 */
enum class SpaceSideKey(val id: String) {
    COMMA("comma"), PERIOD("period"), OFF("off");

    /** Ký tự của phím (null = không có phím). */
    val char: String? get() = when (this) { COMMA -> ","; PERIOD -> "."; OFF -> null }

    companion object {
        val DEFAULT = COMMA
        val IDS: Set<String> = entries.map { it.id }.toSet()
        /** Giá trị lạ / thiếu ⇒ [DEFAULT]. */
        fun of(raw: Any?): SpaceSideKey = entries.firstOrNull { it.id == raw } ?: DEFAULT
    }
}
