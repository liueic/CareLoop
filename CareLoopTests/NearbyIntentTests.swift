import Foundation
@testable import CareLoop
import Testing

/// 附近意图关键词检测：命中时聊天页强制走云端 Agent（附近工具只在云端工具循环挂载）。
struct NearbyIntentTests {
    @Test(arguments: [
        "附近有什么能吃的",
        "周边有啥清淡的",
        "周围有什么粥店",
        "今天不想做饭，出去吃",
        "外面吃点什么好",
        "点个外卖吧",
        "楼下有吃的吗",
    ])
    func detectsNearbyIntent(_ text: String) {
        #expect(NearbyIntentDetector.isNearbyIntent(text), "应命中附近意图：\(text)")
    }

    @Test(arguments: [
        "今晚吃什么",
        "想吃清淡点",
        "不想吃苦瓜",
        "帮我看看血糖趋势",
    ])
    func rejectsNonNearbyIntent(_ text: String) {
        #expect(!NearbyIntentDetector.isNearbyIntent(text), "不应误判为附近意图：\(text)")
    }
}
