import Foundation

struct MenuResponse: Decodable {
    let title: String
    let refreshAfterSeconds: Int?
    let menu: [MenuItem]

    enum CodingKeys: String, CodingKey {
        case title
        case refreshAfterSeconds = "refresh_after_seconds"
        case menu
    }
}

struct MenuItem: Decodable {
    let title: String
    let action: String?
    let value: String?
    let statusTitle: String?
    let keyEquivalent: String?
    let children: [MenuItem]?

    enum CodingKeys: String, CodingKey {
        case title
        case action
        case value
        case statusTitle = "status_title"
        case keyEquivalent = "key_equivalent"
        case children
    }

    init(
        title: String,
        action: String? = nil,
        value: String? = nil,
        statusTitle: String? = nil,
        keyEquivalent: String? = nil,
        children: [MenuItem]? = nil
    ) {
        self.title = title
        self.action = action
        self.value = value
        self.statusTitle = statusTitle
        self.keyEquivalent = keyEquivalent
        self.children = children
    }
}

struct PiPLine: Equatable {
    var leading: String
    var trailing: String
}

struct PiPQuote: Equatable {
    let id: String
    let name: String
    let valueText: String

    var line: PiPLine {
        PiPLine(leading: name, trailing: valueText)
    }

    /// 从菜单树里收集可勾选的行情。名称去掉价格，避免和右侧数值重复。
    static func quotes(from items: [MenuItem]) -> [PiPQuote] {
        var result: [PiPQuote] = []
        var seen = Set<String>()
        func walk(_ items: [MenuItem]) {
            for item in items {
                if item.action == "select", let id = item.value, !id.isEmpty, seen.insert(id).inserted {
                    let valueText = item.statusTitle ?? ""
                    let name = displayName(title: item.title, valueText: valueText)
                    result.append(PiPQuote(id: id, name: name.isEmpty ? id : name, valueText: valueText))
                }
                if let children = item.children {
                    walk(children)
                }
            }
        }
        walk(items)
        return result
    }

    private static func displayName(title: String, valueText: String) -> String {
        var name = title
        if !valueText.isEmpty, let range = name.range(of: valueText) {
            name.removeSubrange(range)
        }
        if let marker = name.range(of: "卖") {
            let prefix = name[..<marker.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty {
                name = prefix
            }
        }
        let collapsed = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? title : collapsed
    }
}
