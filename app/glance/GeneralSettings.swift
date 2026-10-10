import AppKit
import Foundation

enum GlanceEndpoint {
    static let schemes = ["http", "https", "ws", "wss"]
    static let defaultScheme = "http"
    static let defaultHost = "127.0.0.1:1423/api/menu"

    private static let schemeKey = "glance.endpoint.scheme"
    private static let hostKey = "glance.endpoint.host"

    static var scheme: String {
        let saved = UserDefaults.standard.string(forKey: schemeKey) ?? defaultScheme
        return schemes.contains(saved) ? saved : defaultScheme
    }

    static var host: String {
        let saved = UserDefaults.standard.string(forKey: hostKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty {
            return saved
        }
        return defaultHost
    }

    static var url: URL {
        makeURL(scheme: scheme, host: host) ?? URL(string: "\(defaultScheme)://\(defaultHost)")!
    }

    static func save(scheme: String, host: String) {
        UserDefaults.standard.set(scheme, forKey: schemeKey)
        UserDefaults.standard.set(host, forKey: hostKey)
    }

    static func makeURL(scheme: String, host: String) -> URL? {
        let scheme = scheme.lowercased()
        guard schemes.contains(scheme) else { return nil }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(" "),
              let url = URL(string: "\(scheme)://\(host)"),
              url.scheme == scheme,
              url.host != nil else { return nil }
        return url
    }

    /// 粘贴完整地址时，把协议拆回下拉框。
    static func split(_ raw: String) -> (scheme: String?, host: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for scheme in schemes {
            let prefix = scheme + "://"
            if lower.hasPrefix(prefix) {
                return (scheme, String(trimmed.dropFirst(prefix.count)))
            }
        }
        return (nil, trimmed)
    }
}

enum MenuPreview {
    static func text(for response: MenuResponse) -> String {
        var lines = ["标题：\(response.title)"]
        if let seconds = response.refreshAfterSeconds {
            lines.append("刷新间隔：\(seconds) 秒")
        }
        lines.append("")
        append(response.menu, indent: 0, to: &lines)
        if response.menu.isEmpty {
            lines.append("菜单为空")
        }
        return lines.joined(separator: "\n")
    }

    private static func append(_ items: [MenuItem], indent: Int, to lines: inout [String]) {
        let pad = String(repeating: "    ", count: indent)
        for item in items {
            var line = pad + item.title
            if let status = item.statusTitle, !status.isEmpty {
                line += "    \(status)"
            }
            lines.append(line)
            if let children = item.children, !children.isEmpty {
                append(children, indent: indent + 1, to: &lines)
            }
        }
    }
}

@available(macOS 10.15, *)
final class MenuSocket: NSObject {
    let session: URLSession
    let task: URLSessionWebSocketTask

    init(url: URL) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        super.init()
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

private enum ProbeError: LocalizedError {
    case timeout
    case empty
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "连接超时"
        case .empty:
            return "没有收到数据"
        case .invalid(let message):
            return message
        }
    }
}

private final class EndpointProbe {
    private var generation = 0
    private var session: URLSession?
    private var socket: AnyObject?

    func test(url: URL, completion: @escaping (Result<MenuResponse, Error>) -> Void) {
        generation += 1
        let generation = self.generation
        cancelSocket()
        session?.invalidateAndCancel()
        session = nil
        socket = nil

        let scheme = url.scheme?.lowercased()
        if scheme == "ws" || scheme == "wss" {
            testSocket(url, generation: generation, completion: completion)
        } else {
            testHTTP(url, generation: generation, completion: completion)
        }
    }

    private func testHTTP(_ url: URL, generation: Int, completion: @escaping (Result<MenuResponse, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            if let error {
                self?.deliver(generation, .failure(error), completion: completion)
                return
            }
            guard let data, !data.isEmpty else {
                self?.deliver(generation, .failure(ProbeError.empty), completion: completion)
                return
            }
            do {
                let response = try JSONDecoder().decode(MenuResponse.self, from: data)
                self?.deliver(generation, .success(response), completion: completion)
            } catch {
                self?.deliver(generation, .failure(ProbeError.invalid("返回内容无法解析为菜单")), completion: completion)
            }
        }.resume()
    }

    private func testSocket(_ url: URL, generation: Int, completion: @escaping (Result<MenuResponse, Error>) -> Void) {
        guard #available(macOS 10.15, *) else {
            deliver(generation, .failure(ProbeError.invalid("当前系统不支持 WebSocket")), completion: completion)
            return
        }
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: url)
        self.session = session
        self.socket = task
        task.resume()
        task.receive { [weak self] result in
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let raw):
                    data = raw
                @unknown default:
                    data = nil
                }
                guard let data, !data.isEmpty else {
                    self?.deliver(generation, .failure(ProbeError.empty), completion: completion)
                    return
                }
                do {
                    let response = try JSONDecoder().decode(MenuResponse.self, from: data)
                    self?.deliver(generation, .success(response), completion: completion)
                } catch {
                    self?.deliver(generation, .failure(ProbeError.invalid("返回内容无法解析为菜单")), completion: completion)
                }
            case .failure(let error):
                self?.deliver(generation, .failure(error), completion: completion)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.deliver(generation, .failure(ProbeError.timeout), completion: completion)
        }
    }

    private func deliver(
        _ generation: Int,
        _ result: Result<MenuResponse, Error>,
        completion: @escaping (Result<MenuResponse, Error>) -> Void
    ) {
        let finish = {
            guard self.generation == generation else { return }
            self.generation += 1
            self.cancelSocket()
            self.session?.invalidateAndCancel()
            self.socket = nil
            self.session = nil
            completion(result)
        }
        if Thread.isMainThread {
            finish()
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }

    private func cancelSocket() {
        if #available(macOS 10.15, *), let task = socket as? URLSessionWebSocketTask {
            task.cancel(with: .goingAway, reason: nil)
        }
    }
}

final class GeneralSettingsViewController: NSViewController {
    private let schemePopup = NSPopUpButton()
    private let hostField = NSTextField()
    private let testButton = NSButton()
    private let resultScroll = NSScrollView()
    private let resultView = NSTextView()
    private let confirmButton = NSButton()
    private let probe = EndpointProbe()
    private var resultFont: NSFont {
        if #available(macOS 10.15, *) {
            return .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
        return .userFixedPitchFont(ofSize: 12) ?? .systemFont(ofSize: 12)
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: PreferencesMetrics.windowWidth, height: PreferencesMetrics.windowHeight))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: PreferencesMetrics.windowWidth, height: PreferencesMetrics.windowHeight)
        buildLayout()
        schemePopup.selectItem(withTitle: GlanceEndpoint.scheme)
        hostField.stringValue = GlanceEndpoint.host
        showResult("测试连接后，解析出的菜单会显示在这里。", isPlaceholder: true)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = resultScroll.contentSize.width
        guard width > 1 else { return }
        resultView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if abs(resultView.frame.width - width) > 0.5 {
            resultView.frame.size.width = width
        }
    }

    private func buildLayout() {
        let header = NSTextField(labelWithString: "数据地址")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false

        schemePopup.addItems(withTitles: GlanceEndpoint.schemes)
        schemePopup.translatesAutoresizingMaskIntoConstraints = false
        schemePopup.setContentHuggingPriority(.required, for: .horizontal)
        schemePopup.setContentCompressionResistancePriority(.required, for: .horizontal)

        let schemeMark = NSTextField(labelWithString: "://")
        schemeMark.font = .systemFont(ofSize: 13)
        schemeMark.textColor = .secondaryLabelColor
        schemeMark.translatesAutoresizingMaskIntoConstraints = false
        schemeMark.setContentHuggingPriority(.required, for: .horizontal)

        hostField.placeholderString = GlanceEndpoint.defaultHost
        hostField.translatesAutoresizingMaskIntoConstraints = false
        hostField.cell?.isScrollable = true
        hostField.cell?.lineBreakMode = .byTruncatingTail

        testButton.title = "测试"
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testConnection)
        testButton.translatesAutoresizingMaskIntoConstraints = false
        testButton.setContentHuggingPriority(.required, for: .horizontal)

        let resultHeader = NSTextField(labelWithString: "解析结果")
        resultHeader.font = .systemFont(ofSize: 13, weight: .semibold)
        resultHeader.translatesAutoresizingMaskIntoConstraints = false

        resultView.isEditable = false
        resultView.isSelectable = true
        resultView.isRichText = false
        resultView.drawsBackground = false
        resultView.textContainerInset = NSSize(width: 6, height: 8)
        resultView.isVerticallyResizable = true
        resultView.isHorizontallyResizable = false
        resultView.textContainer?.widthTracksTextView = true
        resultView.textContainer?.heightTracksTextView = false
        resultScroll.hasVerticalScroller = true
        resultScroll.autohidesScrollers = true
        resultScroll.borderType = .lineBorder
        resultScroll.drawsBackground = true
        resultScroll.backgroundColor = .textBackgroundColor
        resultScroll.translatesAutoresizingMaskIntoConstraints = false
        resultScroll.documentView = resultView

        confirmButton.title = "确定"
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self
        confirmButton.action = #selector(confirmSettings)
        confirmButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(schemePopup)
        view.addSubview(schemeMark)
        view.addSubview(hostField)
        view.addSubview(testButton)
        view.addSubview(resultHeader)
        view.addSubview(resultScroll)
        view.addSubview(confirmButton)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),

            schemePopup.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            schemePopup.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            schemePopup.widthAnchor.constraint(equalToConstant: 84),

            schemeMark.centerYAnchor.constraint(equalTo: schemePopup.centerYAnchor),
            schemeMark.leadingAnchor.constraint(equalTo: schemePopup.trailingAnchor, constant: 6),

            hostField.centerYAnchor.constraint(equalTo: schemePopup.centerYAnchor),
            hostField.leadingAnchor.constraint(equalTo: schemeMark.trailingAnchor, constant: 6),
            hostField.trailingAnchor.constraint(equalTo: testButton.leadingAnchor, constant: -8),

            testButton.centerYAnchor.constraint(equalTo: schemePopup.centerYAnchor),
            testButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            testButton.widthAnchor.constraint(equalToConstant: 56),

            resultHeader.topAnchor.constraint(equalTo: schemePopup.bottomAnchor, constant: 18),
            resultHeader.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),

            resultScroll.topAnchor.constraint(equalTo: resultHeader.bottomAnchor, constant: 8),
            resultScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            resultScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resultScroll.bottomAnchor.constraint(equalTo: confirmButton.topAnchor, constant: -16),

            confirmButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            confirmButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            confirmButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
        ])
    }

    @objc private func testConnection() {
        guard let url = currentURL() else {
            showResult("地址无效", isError: true)
            return
        }
        testButton.isEnabled = false
        showResult("正在测试…", isPlaceholder: true)
        probe.test(url: url) { [weak self] result in
            guard let self else { return }
            self.testButton.isEnabled = true
            switch result {
            case .success(let response):
                self.showResult(MenuPreview.text(for: response))
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.showResult(message, isError: true)
            }
        }
    }

    @objc private func confirmSettings() {
        guard let url = currentURL() else {
            showResult("地址无效", isError: true)
            return
        }
        let (overrideScheme, host) = GlanceEndpoint.split(hostField.stringValue)
        let scheme = overrideScheme ?? schemePopup.titleOfSelectedItem ?? GlanceEndpoint.defaultScheme
        GlanceEndpoint.save(scheme: scheme, host: host)
        hostField.stringValue = host
        NotificationCenter.default.post(name: .glanceEndpointDidChange, object: nil)
        let alert = NSAlert()
        alert.messageText = "已保存"
        alert.informativeText = "菜单将使用 \(url.absoluteString)。"
        alert.addButton(withTitle: "好")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func currentURL() -> URL? {
        let (overrideScheme, host) = GlanceEndpoint.split(hostField.stringValue)
        if let overrideScheme {
            schemePopup.selectItem(withTitle: overrideScheme)
            hostField.stringValue = host
        }
        let scheme = schemePopup.titleOfSelectedItem ?? GlanceEndpoint.defaultScheme
        return GlanceEndpoint.makeURL(scheme: scheme, host: host)
    }

    private func showResult(_ text: String, isPlaceholder: Bool = false, isError: Bool = false) {
        let color: NSColor
        if isError {
            color = .systemRed
        } else if isPlaceholder {
            color = .secondaryLabelColor
        } else {
            color = .labelColor
        }
        resultView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: resultFont,
            .foregroundColor: color,
        ]))
    }
}
