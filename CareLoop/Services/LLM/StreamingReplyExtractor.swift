import Foundation

/// 从流式到达的模型输出中增量抽取 JSON 字符串字段的值，用于逐字上屏。
///
/// 模型最终回复约定为 `{"reply":"...","citedRecipeIDs":[...]}` 形态；直接把原始
/// JSON 流到气泡里会把引号和转义符显示给用户。本类型逐段吃入 delta，只吐出
/// `reply` 字段解码后的可见文本。输出不是 JSON（纯文本透传）时原样转发。
///
/// 每次 feed 都会对缓冲区重扫一遍——回复体量在几百 token 级别，开销可忽略，
/// 换来实现简单且天然正确（转义、代理对、未闭合截断都无需额外状态）。
struct StreamingReplyExtractor: Sendable {
    private let key: String
    private(set) var buffer = ""
    private var mode: Mode = .undetermined
    /// 已吐出的字符数（按 Swift Character 计）。
    private var emitted = 0

    init(key: String = "reply") {
        self.key = key
    }

    /// 吃入一段 delta，返回本次可上屏的增量文本。
    mutating func feed(_ delta: String) -> String {
        buffer += delta
        switch mode {
        case .undetermined:
            let trimmed = buffer.drop(while: { $0.isWhitespace })
            if trimmed.isEmpty { return "" }
            if trimmed.hasPrefix("```") {
                // 代码围栏头（如 ```json）：取换行后的内容再判定，围栏头本身不上屏。
                guard let newline = trimmed.firstIndex(of: "\n") else { return "" }
                let inner = trimmed[trimmed.index(after: newline)...].drop(while: { $0.isWhitespace })
                if inner.isEmpty { return "" }
                if inner.hasPrefix("{") {
                    mode = .jsonField
                    return emitNewCharacters()
                }
                mode = .passthrough
                return drainPassthrough()
            }
            if trimmed.hasPrefix("{") {
                mode = .jsonField
                return emitNewCharacters()
            }
            mode = .passthrough
            return drainPassthrough()
        case .jsonField:
            return emitNewCharacters()
        case .passthrough:
            return drainPassthrough()
        }
    }

    /// 流结束时调用：jsonField 模式下若始终没找到目标字段则返回 nil（调用方按校验降级处理）。
    func finish() -> String? {
        if mode == .passthrough { return buffer }
        return nil
    }

    var isPassthrough: Bool { mode == .passthrough }

    // MARK: - 内部

    private enum Mode {
        case undetermined
        case jsonField
        case passthrough
    }

    private mutating func drainPassthrough() -> String {
        let out = String(buffer.dropFirst(emitted))
        emitted = buffer.count
        return out
    }

    /// 在缓冲区里定位 `"key" : "` 的值起点，向后解码到未闭合引号或不完整转义为止，
    /// 吐出超出已发数的新字符。
    private mutating func emitNewCharacters() -> String {
        guard let valueStart = locateValueStart() else { return "" }
        let decoded = Self.decodeStringBody(in: buffer, from: valueStart)
        guard decoded.count > emitted else { return "" }
        let chunk = String(decoded.dropFirst(emitted))
        emitted = decoded.count
        return chunk
    }

    /// 查找形如 `"reply"` + 可选空白 + `:` + 可选空白 + `"` 的位置，返回值内容起点。
    private func locateValueStart() -> String.Index? {
        let quotedKey = "\"\(key)\""
        var searchStart = buffer.startIndex
        while let keyRange = buffer.range(of: quotedKey, range: searchStart..<buffer.endIndex) {
            var index = keyRange.upperBound
            while index < buffer.endIndex, buffer[index].isWhitespace {
                index = buffer.index(after: index)
            }
            guard index < buffer.endIndex, buffer[index] == ":" else {
                searchStart = keyRange.upperBound
                continue
            }
            index = buffer.index(after: index)
            while index < buffer.endIndex, buffer[index].isWhitespace {
                index = buffer.index(after: index)
            }
            guard index < buffer.endIndex, buffer[index] == "\"" else {
                searchStart = keyRange.upperBound
                continue
            }
            return buffer.index(after: index)
        }
        return nil
    }

    /// 从开引号之后的位置起，解码 JSON 字符串内容直到：
    /// - 未转义的闭引号（正常结束）
    /// - 转义序列不完整（流截断，等待后续 delta）
    /// 返回已确定的部分。
    private static func decodeStringBody(in buffer: String, from start: String.Index) -> String {
        var output = ""
        var index = start
        while index < buffer.endIndex {
            let char = buffer[index]
            if char == "\"" {
                break
            }
            if char == "\\" {
                guard let (decoded, next) = decodeEscape(in: buffer, at: index) else {
                    return output
                }
                output.append(decoded)
                index = next
                continue
            }
            output.append(char)
            index = buffer.index(after: index)
        }
        return output
    }

    /// 解码 position 处的完整转义序列，返回（解码字符, 下一个未消费位置）。
    /// 序列不完整（截断）或非法时返回 nil，调用方应停止扫描、保留已解码部分。
    private static func decodeEscape(in buffer: String, at index: String.Index) -> (Character, String.Index)? {
        guard let escapeIndex = buffer.index(index, offsetBy: 2, limitedBy: buffer.endIndex) else { return nil }
        let escape = buffer[buffer.index(after: index)]
        switch escape {
        case "\"": return ("\"", escapeIndex)
        case "\\": return ("\\", escapeIndex)
        case "/": return ("/", escapeIndex)
        case "n": return ("\n", escapeIndex)
        case "t": return ("\t", escapeIndex)
        case "r": return ("\r", escapeIndex)
        case "b": return ("\u{08}", escapeIndex)
        case "f": return ("\u{0C}", escapeIndex)
        case "u":
            // \uXXXX：4 位十六进制占据 index+2..<index+6。
            guard let hexEnd = buffer.index(escapeIndex, offsetBy: 4, limitedBy: buffer.endIndex),
                  let unit = UInt32(String(buffer[escapeIndex..<hexEnd]), radix: 16)
            else { return nil }
            if (0xD800...0xDBFF).contains(unit) {
                // 高代理项：必须紧跟 \uXXXX 低代理项（共再占 6 个字符）。
                guard let lowEnd = buffer.index(hexEnd, offsetBy: 6, limitedBy: buffer.endIndex),
                      buffer[hexEnd] == "\\",
                      buffer[buffer.index(after: hexEnd)] == "u"
                else { return nil }
                let lowHexStart = buffer.index(hexEnd, offsetBy: 2)
                guard let lowUnit = UInt32(String(buffer[lowHexStart..<lowEnd]), radix: 16),
                      (0xDC00...0xDFFF).contains(lowUnit),
                      let combined = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (lowUnit - 0xDC00))
                else { return nil }
                return (Character(combined), lowEnd)
            }
            guard let scalar = Unicode.Scalar(unit) else { return nil }
            return (Character(scalar), hexEnd)
        default:
            return nil
        }
    }
}
