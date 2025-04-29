// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CHMParser", // Swift 包名称（对外暴露的模块名）
    platforms: [
        .iOS(.v13),     // 支持的最低 iOS 版本
        .macOS(.v10_15) // 支持的最低 macOS 版本
    ],
    products: [
        // 对外暴露的库，开发者可通过 import CHMParser 使用
        .library(
            name: "CHMParser",
            targets: ["CHMParser"]),
    ],
    dependencies: [],
    targets: [
        // Swift 封装层，供最终调用者使用的接口
        .target(
            name: "CHMParser",
            dependencies: ["CHMLib"],   // 依赖底层 C 语言
            path: "Sources/CHMParser"),  // Swift 文件路径
        // C 语言底层库
            .target(
                name: "CHMLib",
                path: "Sources/CHMLib", // C 文件路径
                exclude: [
                    "chm_http.c",
                    "test_chmLib.c",         // 测试程序，无需编译
                    "Makefile.am",           // Automake 文件，非 Xcode 用
                    "Makefile.simple",       // 简化 Makefile，非必要
                    "enum_chmLib.c",         // 示例枚举工具（命令行用）
                    "enumdir_chmLib.c",      // 示例枚举目录工具（命令行用）
                    "extract_chmLib.c"       // 示例提取工具（命令行用）
                ],
                publicHeadersPath: "include",   // Swift 可以访问的公开头文件路径
                cSettings: [
                    .headerSearchPath("include"),   // 指定头文件搜索路径，用于找到 chm_lib.h 等自定义头文件
                    .define("HAVE_INTTYPES_H"),     // 表示系统有 <inttypes.h>，启用相关类型支持（如 uint64_t 等）
                    .define("HAVE_STDINT_H"),       // 表示系统有 <stdint.h>，确保使用标准整数类型（如 uint32_t）
                    .define("HAVE_STRING_H")        // 表示系统有 <string.h>，启用 memcpy、strcmp 等字符串函数支持
                ]),
        // 单元测试
        .testTarget(
            name: "CHMParserTests",
            dependencies: ["CHMParser"]), // 测试 Swift 接口
    ]
)
