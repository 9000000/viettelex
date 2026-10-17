// VNLexicon2.swift — loader cho Resources/vnlexicon.bin (dữ liệu GENERATED bởi
// Scripts/gen-vnlexicon.py, đóng gói nhị phân — KHÔNG sửa tay).
// 7184 âm tiết tiếng Việt (hieuthi 7184 + tần suất OpenSubtitles),
// sort theo foldedKey rồi tần suất giảm dần. attr mỗi ký tự = quality<<3|tone
// (quality: 0 none, 1 â/ê/ô, 2 ơ/ư/ă, 3 đ; tone: 0 ngang 1 sắc 2 huyền 3 hỏi
// 4 ngã 5 nặng). Blob mmap từ bundle (.alwaysMapped) — pages clean/evictable,
// không còn base64 literal chiếm __TEXT.
//
// vnlexicon.bin layout (little-endian):
//   0  "VNL2" | 4 version u32=1 | 8 count u32 | 12 sectionCount u32=6
//   16 sectionCount × (offset u32, length u32) — offset tính từ đầu file
//   sections theo thứ tự: folded, display, attr, offsets, dispOffsets, freqs
import Foundation

#if !VIETTELEX_CLI
/// Tìm file dữ liệu: bundle của code (bàn phím / test / app macOS) trước, rồi bàn phím nhúng
/// trong app iOS (`PlugIns/VietTelexKeyboard.appex`) — app iOS KHÔNG chép riêng vnlexicon.bin /
/// enlexicon.bin nữa (14/10/2026, bớt ~334 KB bản trùng; project.yml).
enum VTBundleResource {
    static let keyboardAppex = "VietTelexKeyboard.appex"

    static func url(_ name: String, _ ext: String, anchor: AnyClass) -> URL? {
        url(name, ext, bundles: [Bundle(for: anchor), Bundle.main])
    }

    static func url(_ name: String, _ ext: String, bundles: [Bundle]) -> URL? {
        for b in bundles { if let u = b.url(forResource: name, withExtension: ext) { return u } }
        for b in bundles {
            guard let plugins = b.builtInPlugInsURL,
                  let appex = Bundle(url: plugins.appendingPathComponent(keyboardAppex)),
                  let u = appex.url(forResource: name, withExtension: ext) else { continue }
            return u
        }
        return nil
    }
}
#endif

enum VNLexicon2Data {
    static let count = 7184

    /// Toàn bộ file resource, memory-mapped — không copy vào dirty memory.
    static let blob: Data = {
        #if VIETTELEX_CLI   // công cụ văn bản Linux (linux/engine-capi: viettelex-text-tool)
        let url = VTDataFile.url("vnlexicon.bin")
        #else
        final class BundleToken {}
        let url = VTBundleResource.url("vnlexicon", "bin", anchor: BundleToken.self)
        #endif
        guard let url, let d = try? Data(contentsOf: url, options: .alwaysMapped)
        else { fatalError("vnlexicon.bin missing from bundle") }
        precondition(d.count > 64, "vnlexicon.bin truncated")
        return d
    }()

    private static func u32(at off: Int) -> Int {
        Int(UInt32(littleEndian: blob.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: off, as: UInt32.self)
        }))
    }

    /// (offset, length) của section thứ `i` theo header.
    private static func section(_ i: Int) -> (base: Int, len: Int) {
        (u32(at: 16 + i * 8), u32(at: 16 + i * 8 + 4))
    }

    // Section bases — offset byte tuyệt đối trong `blob`. Validate 1 lần.
    static let sections: (folded: Int, foldedLen: Int, display: Int,
                          displayLen: Int, attr: Int, freqs: Int) = {
        precondition(blob.prefix(4).elementsEqual("VNL2".utf8), "bad magic")
        precondition(u32(at: 4) == 1, "bad version")
        precondition(u32(at: 8) == count, "count mismatch")
        precondition(u32(at: 12) == 6, "section count mismatch")
        let f = section(0), d = section(1), a = section(2)
        let o = section(3), oo = section(4), q = section(5)
        precondition(a.len == f.len, "attr/folded length mismatch")
        precondition(o.len == (count + 1) * 4 && oo.len == (count + 1) * 4)
        precondition(q.len == count)
        precondition(q.base + q.len <= blob.count, "sections exceed file")
        return (f.base, f.len, d.base, d.len, a.base, q.base)
    }()

    /// Offsets vào folded/attr (count+1 phần tử) — giải mã một lần, hot path.
    static let offsets: [UInt32] = u32Array(section: 3)
    /// Offsets vào display (count+1 phần tử).
    static let dispOffsets: [UInt32] = u32Array(section: 4)

    private static func u32Array(section i: Int) -> [UInt32] {
        let (base, len) = section(i)
        return blob.withUnsafeBytes { raw in
            (0..<(len / 4)).map {
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + $0 * 4,
                                                       as: UInt32.self))
            }
        }
    }

    // MARK: accessors — index như blob cũ (0-based trong từng section)

    static func foldedSlice(_ lo: Int, _ hi: Int) -> Data {
        blob[sections.folded + lo ..< sections.folded + hi]
    }
    static func displaySlice(_ lo: Int, _ hi: Int) -> Data {
        blob[sections.display + lo ..< sections.display + hi]
    }
    static func attr(_ i: Int) -> UInt8 { blob[sections.attr + i] }
    static func freq(_ id: Int) -> UInt8 { blob[sections.freqs + id] }

    static let firstCharTop: [Character: [Int]] = [
        "a": [44, 66, 11, 0, 26, 1, 45, 27, 2, 28, 49, 15, 53, 46, 29, 3, 16, 6, 30, 61, 17, 50, 12, 4, 18, 31, 51, 52, 54, 62, 19, 20],
        "b": [101, 238, 210, 132, 267, 133, 142, 102, 115, 70, 268, 180, 269, 143, 84, 310, 166, 71, 252, 134, 192, 239, 76, 292, 156, 229, 157, 103, 322, 104, 388, 385],
        "c": [883, 980, 703, 884, 836, 932, 427, 1010, 497, 433, 653, 933, 422, 945, 878, 452, 438, 431, 804, 1011, 794, 691, 654, 885, 1018, 648, 968, 520, 739, 591, 575, 498],
        "d": [1667, 1054, 1306, 1404, 1236, 1266, 1217, 1140, 1366, 1201, 1202, 1218, 1645, 1646, 1383, 1534, 1647, 1535, 1405, 1301, 1237, 1685, 1592, 1472, 1076, 1648, 1161, 1406, 1292, 1407, 1343, 1332],
        "e": [1728, 1718, 1745, 1719, 1729, 1740, 1726, 1732, 1720, 1741, 1733, 1742, 1730, 1734, 1724, 1721, 1722, 1737, 1743, 1744, 1731, 1748, 1747, 1725, 1723, 1746, 1750, 1749, 1738, 1739, 1736, 1735],
        "g": [1852, 1939, 1985, 1856, 1800, 1883, 2005, 1869, 1762, 1857, 1953, 1933, 1962, 1971, 1779, 1897, 1898, 1858, 1974, 1816, 1865, 2050, 1872, 1866, 1954, 1788, 1845, 1844, 1884, 1914, 1859, 2016],
        "h": [2240, 2323, 2291, 2155, 2154, 2084, 2213, 2115, 2224, 2347, 2232, 2196, 2101, 2300, 2126, 2316, 2260, 2301, 2270, 2225, 2162, 2073, 2255, 2256, 2423, 2324, 2241, 2302, 2286, 2277, 2303, 2127],
        "i": [2480, 2471, 2473, 2475, 2462, 2463, 2464, 2465, 2466, 2467, 2468, 2469, 2478, 2479, 2481, 2474, 2476, 2477, 2472, 2482, 2470],
        "k": [2721, 2628, 2532, 2523, 2660, 2841, 2831, 2704, 2640, 2536, 2483, 2484, 2797, 2485, 2802, 2803, 2697, 2685, 2528, 2733, 2529, 2807, 2629, 2842, 2843, 2821, 2808, 2551, 2717, 2670, 2669, 2826],
        "l": [2847, 2867, 2859, 2970, 3199, 2880, 3279, 3243, 3101, 2868, 3102, 3132, 2941, 3016, 3072, 2951, 3145, 3248, 3200, 3052, 2933, 3030, 3198, 2921, 3265, 3008, 3103, 2853, 3183, 3160, 2848, 3040],
        "m": [3530, 3285, 3450, 3582, 3377, 3484, 3483, 3353, 3368, 3354, 3369, 3543, 3328, 3459, 3485, 3370, 3355, 3338, 3451, 3460, 3291, 3359, 3297, 3605, 3549, 3515, 3371, 3329, 3567, 3505, 3550, 3486],
        "n": [3991, 3691, 4372, 4287, 4256, 4348, 3670, 4288, 4021, 4161, 3714, 3734, 3801, 3839, 3629, 4423, 4089, 3809, 4051, 4449, 4052, 4169, 3692, 4095, 4110, 3893, 3802, 4153, 3654, 4373, 4183, 4075],
        "o": [4470, 4537, 4527, 4528, 4511, 4512, 4471, 4472, 4520, 4538, 4521, 4473, 4474, 4539, 4529, 4540, 4504, 4475, 4530, 4531, 4476, 4505, 4550, 4493, 4513, 4494, 4546, 4499, 4489, 4477, 4514, 4485],
        "p": [4613, 4750, 4656, 4653, 4628, 4766, 4617, 4795, 4775, 4694, 4720, 4710, 4686, 4629, 4803, 4776, 4618, 4603, 4690, 4630, 4751, 4767, 4768, 4691, 4668, 4699, 4721, 4752, 4700, 4657, 4631, 4722],
        "q": [4862, 4882, 4863, 4864, 4982, 4965, 4920, 4883, 4977, 4971, 4936, 4972, 4937, 4884, 4906, 4885, 4876, 4886, 4865, 4978, 4973, 4896, 4929, 4897, 4887, 4974, 4979, 4945, 4913, 4975, 4898, 4922],
        "r": [5164, 4990, 5053, 5029, 5137, 5116, 5165, 5278, 5195, 5167, 5166, 5030, 5281, 5220, 5031, 5246, 4996, 5059, 5070, 5196, 5017, 4997, 5039, 5208, 5276, 5213, 5138, 5234, 5001, 5184, 5139, 5247],
        "s": [5377, 5347, 5517, 5364, 5440, 5497, 5431, 5518, 5410, 5333, 5319, 5298, 5537, 5358, 5441, 5442, 5519, 5300, 5353, 5484, 5320, 5334, 5583, 5335, 5294, 5572, 5378, 5443, 5365, 5528, 5444, 5553],
        "t": [6158, 5592, 5811, 6378, 5812, 5847, 5803, 6456, 5792, 6171, 6285, 5932, 5776, 5605, 6428, 6201, 6099, 5971, 5855, 5836, 5933, 6159, 6095, 6457, 6080, 5994, 6102, 6074, 6116, 5663, 5702, 5677],
        "u": [6561, 6617, 6597, 6562, 6605, 6632, 6633, 6563, 6634, 6598, 6581, 6599, 6582, 6571, 6635, 6627, 6590, 6618, 6587, 6600, 6631, 6612, 6564, 6629, 6637, 6572, 6565, 6626, 6588, 6580, 6638, 6619],
        "v": [6642, 6812, 6724, 6714, 6698, 6767, 6757, 6664, 6770, 6850, 6758, 6680, 6868, 6859, 6665, 6790, 6725, 6778, 6706, 6654, 6666, 6779, 6835, 6791, 6726, 6771, 6851, 6759, 6813, 6836, 6681, 6865],
        "x": [7016, 6969, 6957, 7146, 7119, 6907, 6951, 6901, 7092, 7104, 6948, 6902, 7120, 6952, 6991, 6935, 7160, 6988, 7135, 7021, 7116, 7112, 7147, 7044, 7136, 7105, 7078, 7061, 6916, 7106, 7001, 6903],
        "y": [7167, 7180, 7175, 7181, 7168, 7176, 7179, 7172, 7173, 7169, 7182, 7178, 7177, 7174, 7170, 7171, 7183],
    ]
}
