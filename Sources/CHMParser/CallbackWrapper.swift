//
//  File.swift
//  CHMSwift
//
//  Created by edy on 2025/4/29.
//

// 桥接类，该类将 Swift 闭包转换为 C 语言可调用的回调函数
class CallbackWrapper {
    let callback: (String) -> Bool
    
    init(callback: @escaping (String) -> Bool) {
        self.callback = callback
    }
}
