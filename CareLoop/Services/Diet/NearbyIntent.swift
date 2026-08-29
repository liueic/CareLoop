import Foundation

/// 「附近」意图检测：命中时聊天页强制走云端 Agent（附近搜索工具只在云端工具循环挂载）。
enum NearbyIntentDetector {
    static let keywords = [
        "附近", "周边", "周围", "出去吃", "外面吃", "外卖", "楼下", "近一点", "遛弯去哪吃",
    ]

    static func isNearbyIntent(_ text: String) -> Bool {
        keywords.contains { text.contains($0) }
    }
}
