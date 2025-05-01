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
    
    /// 列举 CHM 文件根目录下的文件路径（不包括子目录）
    ///
    /// - Parameter callback: 每个根目录文件路径的回调
    /// - Returns: 如果列举成功返回 `true`，否则返回 `false`
    private func enumerateRootFiles(_ callback: @escaping (String) -> Bool) -> Bool {
        return enumerateFiles { path in
            guard !path.hasSuffix("/") else { return true } // 排除目录
            
            // 判断是否为根目录下文件（只有一个 '/' 开头，无其他 '/')
            let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            if !trimmedPath.contains("/") {
                return callback(path)
            }
            
            return true
        }
    }
    
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
    /// **警告**: CHMLib 库本身不是线程安全的，多个线程并发调用 `chm_resolve_object` 和 `chm_retrieve_object` 可能会导致读取失败
    /// 因此，建议在并发环境中使用同步机制来确保单线程访问 CHM 文件
    ///
    /// - Parameter path: 需要提取的文件路径
    /// - Returns: 提取的文件数据，如果失败，返回 `nil`
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
    
    /// 提取 CHM 文件中的所有资源到指定目录
    ///
    /// - Note:
    ///   - 该方法会异步获取 CHM 文件中的所有资源路径，并逐个提取文件
    ///   - 使用串行队列来保证 CHMLib 的线程安全访问，避免并发访问时出现错误
    ///   - 通过信号量控制并发任务数，最多同时进行 `maxConcurrentTasks` 个任务
    ///   - 提供进度反馈，提取每个文件时会调用进度回调
    ///   - 所有文件提取完成后，会调用 `completion` 回调，通知操作结果
    ///
    /// - Parameters:
    ///   - directory: 目标目录，所有提取的文件将保存到该目录中
    ///   - progressCallback: 可选的进度回调，每当一个文件提取完成时调用，传递当前完成的数量和总数量
    ///   - completion: 提取操作完成后调用的回调，返回 `true` 表示成功，`false` 表示失败
    public func extractAllFiles(to directory: URL, progressCallback: ((Int, Int) -> Void)? = nil, completion: @escaping @Sendable (Bool) -> Void) {
        // 异步获取所有文件路径
        DispatchQueue.global(qos: .userInitiated).async {
            var paths = [String]()
            
            // 获取文件路径，过滤掉目录
            _ = self.enumerateFiles { path in
                if !path.hasSuffix("/") {
                    paths.append(path)
                }
                return true
            }
            
            let totalCount = paths.count
            var completed = 0
            var success = true
            let fileManager = FileManager.default
            let selfRef = self // 防止捕获 self 导致的循环引用
            
            // 串行队列，确保 CHMLib 按顺序访问
            let serialQueue = DispatchQueue(label: "com.yourapp.chmSerialQueue")
            
            // 控制最大并发数
            let maxConcurrentTasks = 5
            let semaphore = DispatchSemaphore(value: maxConcurrentTasks)
            
            let group = DispatchGroup()
            
            // 遍历所有文件，提取并保存
            for path in paths {
                group.enter()
                
                // 控制并发
                semaphore.wait()
                
                DispatchQueue.global(qos: .userInitiated).async {
                    // 串行执行 CHMLib 操作
                    serialQueue.async {
                        defer {
                            group.leave()
                            semaphore.signal() // 释放信号量
                        }
                        
                        // 提取文件
                        guard let data = selfRef.extractFile(at: path) else {
                            print("提取失败: \(path)")
                            success = false
                            return
                        }
                        
                        // 保存文件
                        let fileURL = directory.appendingPathComponent(path)
                        do {
                            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try data.write(to: fileURL)
                        } catch {
                            print("写入失败: \(fileURL.path), 错误: \(error)")
                            success = false
                        }
                        
                        // 更新进度
                        DispatchQueue.main.async {
                            completed += 1
                            progressCallback?(completed, totalCount)
                        }
                    }
                }
            }
            
            // 所有任务完成后通知
            group.notify(queue: DispatchQueue.main) {
                completion(success)
            }
        }
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
        if let toc = findHomePageFromTOC() {
            return toc
        }
        
        if let sys = findHomePageFromSystemPaths() {
            return sys
        }
        
        let homepage = findHomePageFromFilenameFallback()
        return homepage
    }
    
    /// 尝试从 CHM 文件中的 `.hhc`（Table of Contents）或 `.hhk`（Index）文件中提取首页路径
    ///
    /// 此方法按顺序查找 `.hhc` 和 `.hhk` 文件，解析其中的 `<param name="Local" value="...">` 标签，
    /// 并验证对应路径是否存在于 CHM 文件中如果找到有效路径则立即返回，若都未能解析出有效路径则返回 `nil`
    ///
    /// 处理流程包括：
    /// 1. 遍历 CHM 文件中所有条目，寻找以 `.hhc` 或 `.hhk` 结尾的文件；
    /// 2. 对找到的文件尝试多种常见编码（如 UTF-8、Windows-1252、ISO Latin1）进行解码；
    /// 3. 使用正则表达式提取 HTML 中的 `Local` 路径参数；
    /// 4. 验证该路径在 CHM 中是否有效；
    ///
    /// - Returns: 返回首页路径字符串（如 `"index.html"`）如果成功解析，否则为 `nil`
    public func findHomePageFromTOC() -> String? {
        guard let filePointer = filePointer else { return nil }
        
        let hhxExtensions = ["hhc", "hhk"]
        
        // 遍历扩展名，查找对应的目录文件
        for ext in hhxExtensions {
            var hhxPath: String?
            _ = enumerateFiles { path in
                if path.lowercased().hasSuffix(".\(ext)") {
                    hhxPath = path
                    return false
                }
                return true
            }
            
            // Step 1: 如果未找到文件，跳到下一个扩展名
            guard let path = hhxPath,
                  let data = extractFile(at: path), data.count > 0 else {
                continue
            }
            
            // Step 2: 尝试不同编码解析文件内容
            let encodings: [String.Encoding] = [.utf8, .windowsCP1252, .ascii, .isoLatin1]
            var content: String? = nil
            for encoding in encodings {
                if let decodedContent = String(data: data, encoding: encoding) {
                    content = decodedContent
                    break
                }
            }
            
            // Step 3: 如果没有合适的编码格式，跳到下一个文件
            guard let validContent = content else {
                continue
            }
            
            // Step 4: 使用正则提取 Local 路径
            let pattern = #"<param\s+name=["']Local["']\s+value=["']([^"'>]*)["']"#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                let matches = regex.matches(in: validContent, options: [], range: NSRange(validContent.startIndex..., in: validContent))
                
                // Step 5: 遍历匹配项并验证路径有效性
                for match in matches {
                    if let range = Range(match.range(at: 1), in: validContent) {
                        let localPath = String(validContent[range])
                        
                        let baseDir = (path as NSString).deletingLastPathComponent
                        let candidates = [
                            localPath,
                            "/\(localPath)",
                            "::/\(localPath)",
                            "\(baseDir)/\(localPath)",
                            "/\(baseDir)/\(localPath)",
                            "::/\(baseDir)/\(localPath)"
                        ]
                        
                        for candidate in candidates {
                            var dummy = chmUnitInfo()
                            if chm_resolve_object(OpaquePointer(filePointer), candidate, &dummy) == CHM_RESOLVE_SUCCESS {
                                return candidate
                            }
                        }
                    }
                }
            }
        }
        
        return nil
    }
    
    /// 尝试使用系统默认首页路径（如 `/index.html`）获取首页
    ///
    /// 某些 CHM 文件没有 TOC 或特殊首页定义，
    /// 此方法将尝试一系列常见系统路径进行解析
    ///
    /// - Returns: 如果成功解析，返回有效首页路径否则返回 `nil`
    private func findHomePageFromSystemPaths() -> String? {
        guard let filePointer = filePointer else { return nil }
        
        // 一些常见的系统指针路径，可以尝试查找
        let candidates = [
            "::/index.html", "::/default.html", "::/start.html",
            "/index.html", "/default.html", "/start.html",
            "index.html", "default.html", "start.html"
        ]
        
        var entry = chmUnitInfo()
        for candidate in candidates {
            if chm_resolve_object(OpaquePointer(filePointer), candidate, &entry) == CHM_RESOLVE_SUCCESS {
                return candidate
            }
        }
        
        return nil
    }
    
    /// 根据根目录下常见文件名优先级查找首页路径
    ///
    /// 此方法仅扫描 CHM 文件根目录中的 HTML/HTM 文件，尝试根据常见首页文件名
    /// （如 `index.html`, `default.htm`, `home.html` 等）识别首页路径
    ///
    /// 查找流程如下：
    /// 1. 使用 `enumerateRootFiles` 遍历根目录中的所有文件（不递归子目录）；
    /// 2. 过滤出扩展名为 `.html` 或 `.htm` 的文件；
    /// 3. 判断文件名是否与优先级列表匹配（例如 `index.html` 优先）；
    /// 4. 如果没有优先匹配项或关键词匹配项，则返回第一个发现的 HTML 文件路径；
    ///
    /// - Returns: 匹配到的首页路径字符串，如果未找到则返回 `nil`
    private func findHomePageFromFilenameFallback() -> String? {
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
        var fallbackHtmlFiles: [String] = []
        
        // 只列举根目录下的文件
        _ = enumerateRootFiles { path in
            let lower = path.lowercased()
            
            // 跳过非 HTML 文件
            guard lower.hasSuffix(".html") || lower.hasSuffix(".htm") else { return true }
            
            // 记录第一个 HTML 文件
            if firstHtmlFile == nil {
                firstHtmlFile = path
            }
            
            // 判断是否为优先文件名
            for name in priorityFilenames {
                if lower.hasSuffix("/" + name) || lower == name {
                    bestMatch = path
                    return false // 找到优先匹配，提前返回
                }
            }
            
            fallbackHtmlFiles.append(path)
            return true
        }
        
        // 优先返回完全匹配文件
        if let best = bestMatch {
            return best
        }
        
        // 仅有一个 HTML 文件时直接返回
        if fallbackHtmlFiles.count == 1 {
            return fallbackHtmlFiles.first
        }
        
        // 最后回退到第一个 HTML 文件
        return firstHtmlFile
    }
}
