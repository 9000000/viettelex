// swift-tools-version: 5.9
// libtelexcore — the TelexCore engine exported through a C ABI for the Linux
// frontends (Fcitx5 addon, IBus engine). See linux/docs/LINUX-SPEC.md §2.
//
// Sources/TelexCoreEngine holds SYMLINKS to ../../TelexCore/Sources/TelexCore/*.swift
// (every file except ClientPolicy.swift, the only one importing Foundation), so the
// Linux library compiles the exact engine the Mac/iOS apps ship — no fork, no copy —
// and stays Foundation-free (small, self-contained .so with --static-swift-stdlib).
// `scripts/check-engine-links.sh` fails the build when TelexCore gains a file that is
// not linked here.
//
// viettelex-text-tool — text tools for the selection (Thêm dấu, HOA, thường, …), run by
// the frontends as a CHILD PROCESS like macOS `VietTelex --add-tones`. Sources/TextToolCLI
// symlinks the shared iOS/Keyboard files (TextTools, AddTones + lexicon/LM — the same ones
// the macOS target compiles, see project.yml). AddTones/SwipeEnglish `import TelexCore`: the
// TelexCore package on macOS, the Foundation-free TelexCoreEngine on Linux (module alias).
// On Linux it links FoundationEssentials only (no CoreFoundation/ICU), which stays out of
// the engine .so and out of the IM processes.
//
// Build (Linux):  swift build -c release --static-swift-stdlib   (normally via linux/CMakeLists.txt,
//   which also names FoundationEssentials' static deps for the linker — Swift ≥ 6.3 swiftbuild
//   does not autolink them: -Xlinker --start-group -Xlinker -lFoundationEssentials
//   -Xlinker -l_FoundationCollections -Xlinker -l_FoundationCShims -Xlinker -lswiftSynchronization
//   -Xlinker --end-group)
//   → .build/release/libtelexcore.so   (C header: include/telexcore.h)
//   → .build/release/viettelex-text-tool
//
// Size (measured 14/10/2026, Swift 6.4 noble arm64, stripped): libtelexcore.so 5.5 MB,
// viettelex-text-tool 12.4 MB. Almost all of it is the static Swift runtime/stdlib (+
// FoundationEssentials in the tool); our own symbols are ~85 KB (.so) / ~300 KB (tool), the
// engine ~76 KB in each. So, on purpose:
//   * no -Osize: no measurable change in the stripped files (it would only touch our code);
//   * no extra --gc-sections: SwiftPM already links release products with
//     -Xlinker --gc-sections (dead stripping is on by default);
//   * the tool does not link libtelexcore.so to share the engine: the .so exports only the
//     vt_* C ABI and carries its own static Swift runtime, so the tool would still need its
//     runtime (two Swift runtimes in one process) for ~76 KB saved.
import PackageDescription

let package = Package(
    name: "TelexCoreCAPI",
    // TelexCore declares macOS 13 (only matters for `swift build` on a Mac).
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "telexcore", type: .dynamic, targets: ["TelexCoreC"]),
        .executable(name: "viettelex-text-tool", targets: ["TextToolCLI"]),
    ],
    dependencies: [
        .package(name: "TelexCore", path: "../../TelexCore"),
    ],
    targets: [
        .target(
            name: "TelexCoreEngine",
            path: "Sources/TelexCoreEngine"
        ),
        .target(
            name: "TelexCoreC",
            dependencies: ["TelexCoreEngine"],
            path: "Sources/TelexCoreC",
            linkerSettings: [
                // Export only the vt_* C ABI from the .so (Swift runtime stays private).
                .unsafeFlags(["-Xlinker", "--version-script=\(Context.packageDirectory)/exports.map"],
                             .when(platforms: [.linux])),
            ]
        ),
        .executableTarget(
            name: "TextToolCLI",
            dependencies: [
                .product(name: "TelexCore", package: "TelexCore", condition: .when(platforms: [.macOS])),
                .target(name: "TelexCoreEngine", condition: .when(platforms: [.linux])),
            ],
            path: "Sources/TextToolCLI",
            swiftSettings: [
                .define("VIETTELEX_CLI"),
                // Linux: `import TelexCore` = bản engine không Foundation (TelexCoreEngine) và
                // `import Foundation` = FoundationEssentials — Foundation đầy đủ kéo CoreFoundation
                // + dữ liệu ICU (~45 MB) vào file chạy tĩnh (57 MB → 13 MB sau strip). Ba API
                // NSString còn thiếu: LinuxShims.swift.
                .unsafeFlags(["-module-alias", "TelexCore=TelexCoreEngine",
                              "-module-alias", "Foundation=FoundationEssentials"],
                             .when(platforms: [.linux])),
            ],
            linkerSettings: [
                // Debian hardening (lintian hardening-no-relro / bindnow).
                .unsafeFlags(["-Xlinker", "-z", "-Xlinker", "relro", "-Xlinker", "-z", "-Xlinker", "now"],
                             .when(platforms: [.linux])),
            ]
        ),
    ]
)
