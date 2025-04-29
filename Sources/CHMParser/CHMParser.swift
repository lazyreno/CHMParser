// The Swift Programming Language
// https://docs.swift.org/swift-book
// CHMLib GitHub: https://github.com/jedwing/CHMLib

import Foundation
import CHMLib

/// `CHMParser` 用于解析和操作 CHM 文件
public class CHMParser {
    
    private var filePointer: UnsafeMutableRawPointer?
    
    /// 初始化并打开指定路径的 CHM 文件
    ///
    /// - Parameter path: CHM 文件路径
    /// - Returns: 成功打开文件时返回实例否则返回 `nil`
    public init?(path: String) {
        filePointer = UnsafeMutableRawPointer(chm_open(path))
        guard filePointer != nil else {
            return nil
        }
    }
    
    /// 关闭 CHM 文件并释放资源
    deinit {
        if let filePointer = filePointer {
            chm_close(OpaquePointer(filePointer))
        }
    }
    
    // MARK: - 文件列举
    
    /// 遍历 CHM 文件中的所有文件并调用回调
    private static let fileEnumerator: @convention(c) (OpaquePointer?, UnsafeMutablePointer<chmUnitInfo>?, UnsafeMutableRawPointer?) -> Int32 = { _, unitInfo, context in
        guard let unitInfo = unitInfo, let context = context else { return 0 }
        
        let wrapper = Unmanaged<CallbackWrapper>.fromOpaque(context).takeUnretainedValue()
        let path = withUnsafePointer(to: unitInfo.pointee.path) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        
        return wrapper.callback(path) ? 1 : 0
    }
    
    /// 列举 CHM 文件中的所有文件路径
    ///
    /// - Parameter callback: 每个文件路径的回调
    /// - Returns: 如果列举成功返回 `true`，否则返回 `false`
    public func enumerateFiles(_ callback: @escaping (String) -> Bool) -> Bool {
        guard let filePointer = filePointer else { return false }
        
        let wrapper = CallbackWrapper(callback: callback)
        let context = Unmanaged.passUnretained(wrapper).toOpaque()
        
        let result = chm_enumerate(OpaquePointer(filePointer), CHM_ENUMERATE_NORMAL, CHMParser.fileEnumerator, context)
        
        return result != 0
    }
    
    // MARK: - 文件提取
    
    /// 提取 CHM 文件中指定路径的文件内容
    ///
    /// - Parameter path: 需要提取的文件路径
    /// - Returns: 提取的文件数据如果失败，返回 `nil`
    public func extractFile(at path: String) -> Data? {
        guard let filePointer = filePointer else { return nil }
        
        var entry = chmUnitInfo()
        guard chm_resolve_object(OpaquePointer(filePointer), path, &entry) == CHM_RESOLVE_SUCCESS else {
            return nil
        }
        
        let buffer = malloc(Int(entry.length))
        defer { free(buffer) }
        
        guard chm_retrieve_object(OpaquePointer(filePointer), &entry, buffer, 0, LONGINT64(entry.length)) == Int64(entry.length) else {
            return nil
        }
        
        return Data(bytes: buffer!, count: Int(entry.length))
    }
    
    /// 提取所有文件并保存到指定目录
    ///
    /// - Parameter directory: 目标保存目录
    /// - Returns: 如果提取成功返回 `true`，否则返回 `false`
    public func extractAllFiles(to directory: URL) -> Bool {
        var success = true
        
        success = success && enumerateFiles { path in
            guard !path.hasSuffix("/") else { return true }
            
            if let data = self.extractFile(at: path) {
                let fileURL = directory.appendingPathComponent(path)
                do {
                    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: fileURL)
                } catch {
                    print("CHM 文件写入失败: \(path)，操作：保存文件到目录 \(directory.path)，错误: \(error.localizedDescription)")
                    success = false
                }
            } else {
                print("提取 CHM 文件失败: \(path)，操作：从 CHM 文件提取内容，原因：未能提取文件")
                success = false
            }
            return true
        }
        
        return success
    }
    
    // MARK: - 首页获取
    
    /// 获取 CHM 文件的首页路径
    ///
    /// 尝试顺序如下：
    /// 1. 从 TOC 文件（.hhc）中解析首页地址
    /// 2. 使用系统定义的默认首页路径尝试解析
    /// 3. 根据文件名优先级匹配首页，或回退到第一个 HTML 文件
    ///
    /// - Returns: 如果成功找到首页路径，返回该路径否则返回 `nil`
    public func homePage() -> String? {
        guard let filePointer = filePointer else { return nil }
        
        if let toc = homePageFromTOC() {
            return toc
        }
        
        if let sys = homePageFromSystemPaths() {
            return sys
        }
        
        let homepage = homePageFromFilenameFallback()
        return homepage
    }
    
    /// 尝试从 TOC（Table of Contents，目录）文件中获取首页路径
    ///
    /// CHM 文件中常包含一个 `.hhc` 文件作为目录，
    /// 该文件是 HTML 格式并包含 `<param name="Local" value="...">`
    /// 指向首页路径此方法解析该值并校验路径有效性
    ///
    /// - Returns: 如果成功解析并验证路径存在，返回该路径否则返回 `nil`
    public func homePageFromTOC() -> String? {
        guard let filePointer = filePointer else { return nil }
        
        var tocPath: String?
        
        // Step 1: 找到 .hhc 文件
        _ = enumerateFiles { path in
            if path.lowercased().hasSuffix(".hhc") {
                tocPath = path
                return false
            }
            return true
        }
        
        guard let tocPath = tocPath,
              let data = extractFile(at: tocPath),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        
        // Step 2: 提取 Local 参数（HTML/CHM TOC 是 HTML 格式，嵌套 <param name="Local" value="...">）
        let pattern = #"<param\s+name=["']Local["']\s+value=["']([^"']+)["']"# // 正则提取 value
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        
        let localPath = String(content[range])
        
        // Step 3: 校验路径是否有效
        var dummy = chmUnitInfo()
        if chm_resolve_object(OpaquePointer(filePointer), localPath, &dummy) == CHM_RESOLVE_SUCCESS {
            return localPath
        }
        
        return nil
    }
    
    /// 尝试使用系统默认首页路径（如 `/index.html`）获取首页
    ///
    /// 某些 CHM 文件没有 TOC 或特殊首页定义，
    /// 此方法将尝试一系列常见系统路径进行解析
    ///
    /// - Returns: 如果成功解析，返回有效首页路径否则返回 `nil`
    private func homePageFromSystemPaths() -> String? {
        guard let filePointer = filePointer else { return nil }
        
        // 一些常见的系统指针路径，可以尝试查找
        let candidatePaths = [
            "::/index.html", "::/default.html", "::/start.html",
            "/index.html", "/default.html", "/start.html"
        ]
        
        var entry = chmUnitInfo()
        for path in candidatePaths {
            if chm_resolve_object(OpaquePointer(filePointer), path, &entry) == CHM_RESOLVE_SUCCESS {
                return path
            }
        }
        
        return nil
    }
    
    /// 根据常见命名优先级查找首页路径
    ///
    /// 常见首页文件名包括 `index.html`、`default.html`、`home.html` 等，
    /// 此方法会按顺序查找文件名匹配，若未命中任何匹配，将回退返回第一个发现的 HTML 文件
    ///
    /// - Returns: 匹配首页路径或第一个 HTML 文件路径若无可用文件则返回 `nil`
    private func homePageFromFilenameFallback() -> String? {
        let priorityFilenames = [
            "index.html", "index.htm",
            "default.html", "default.htm",
            "start.html", "start.htm",
            "home.html", "home.htm",
            "main.html", "main.htm",
            "contents.html", "contents.htm"
        ]
        
        var bestMatch: String?
        var firstHtmlFile: String?
        
        // 枚举所有 HTML 文件
        _ = enumerateFiles { path in
            let lower = path.lowercased()
            
            // 跳过目录路径（以 '/' 结尾）
            guard !lower.hasSuffix("/") else { return true }
            
            // 记录第一个 HTML 文件作为兜底
            if (lower.hasSuffix(".html") || lower.hasSuffix(".htm")) && firstHtmlFile == nil {
                firstHtmlFile = path
            }
            
            // 匹配优先首页名
            for name in priorityFilenames {
                if lower.hasSuffix("/" + name) || lower == name {
                    bestMatch = path
                    return false // 找到匹配首页，停止枚举
                }
            }
            
            return true
        }
        
        return bestMatch ?? firstHtmlFile
    }
}
