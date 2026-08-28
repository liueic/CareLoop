import Foundation

// MARK: - 已选食物状态（与首页建议联动）

struct BaobaoSelection: Codable, Equatable, Sendable {
    var recipeID: String
    var recipeName: String
    var confirmedAt: Date
}

enum BaobaoState {
    private static let storageKey = "careloop.baobao.selection"

    static func selection(on date: Date = Date(), calendar: Calendar = .current) -> BaobaoSelection? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let selection = try? JSONDecoder().decode(BaobaoSelection.self, from: data),
              calendar.isDate(selection.confirmedAt, inSameDayAs: date) else {
            return nil
        }
        return selection
    }

    static func confirm(recipeID: String, recipeName: String) {
        let selection = BaobaoSelection(recipeID: recipeID, recipeName: recipeName, confirmedAt: Date())
        if let data = try? JSONEncoder().encode(selection) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

// MARK: - 文案引擎（短句 + 语气词 + 括号表情）

enum BaobaoPersona {
    static let name = "饱饱"

    static let greeting = "嗨呀，今天想吃点什么呀 (=^･^=)"
    static let quickReplies = ["今天吃什么", "想吃清淡点", "不想吃苦瓜"]

    static let confirmWords = ["就这个", "就它了", "可以", "好的", "好呀", "行", "嗯", "ok", "OK", "选定"]

    static func confirmReply(for name: String) -> String {
        "好嘞！今天的菜单就定\(name)啦 (=^･^=)"
    }

    static let undoReply = "好哒，已经撤掉啦～再看看别的？ (>_<)"

    static func alternativesReply(for names: [String]) -> String {
        guard !names.isEmpty else {
            return "唔……实在找不到更合适的啦，要不要问问医生或营养师呀 (>_<)"
        }
        let list = names.prefix(2).joined(separator: "、")
        return "明白明白！那换这个～ \(list)，一样好吃哦 (=^･^=)"
    }

    static let noMatchReply = "唔……这个我可能帮不上忙耶 (>_<) 换个吃法问问我？"

    static let thinking = "···"

    /// 从用户输入中提取被点名的食谱（用于"就这个吧"的确认对象）。
    static func mentionedRecipe(in text: String, from recipes: [Recipe]) -> Recipe? {
        recipes.first { text.contains($0.name) }
            ?? recipes.first { recipe in
                // 允许部分匹配（如"丝瓜"命中"丝瓜炒蛋"）
                recipe.name.count > 2 && text.contains(String(recipe.name.prefix(2)))
            }
    }

    /// 用户表达"不想吃/不喜欢"时，找出被嫌弃的食材或食谱。
    static func rejectedIngredient(in text: String, from recipes: [Recipe]) -> String? {
        let markers = ["不想吃", "不喜欢", "不吃", "讨厌", "换", "不要"]
        guard markers.contains(where: { text.contains($0) }) else { return nil }
        let ingredients = recipes.flatMap(\.ingredients) + recipes.map(\.name)
        return ingredients
            .filter { $0.count >= 2 && text.contains($0) }
            .max { $0.count < $1.count }
    }
}
