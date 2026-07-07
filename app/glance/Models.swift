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
    let children: [MenuItem]?

    enum CodingKeys: String, CodingKey {
        case title
        case action
        case value
        case statusTitle = "status_title"
        case children
    }
}
