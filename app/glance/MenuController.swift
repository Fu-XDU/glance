import AppKit
import Foundation

extension Notification.Name {
    static let glanceMenuDidUpdate = Notification.Name("glance.menuDidUpdate")
    static let glanceEndpointDidChange = Notification.Name("glance.endpointDidChange")
}

final class MenuController: NSObject, NSMenuDelegate {
    static private(set) var latestItems: [MenuItem] = []

    private var statusItem: NSStatusItem!
    private var lastUpdated: Date?
    private var currentMenuItems: [MenuItem] = []
    private var timer: Timer?
    private var refreshTimer: Timer?
    private var nextInterval: TimeInterval = 3
    private let minInterval: TimeInterval = 3
    private let maxInterval: TimeInterval = 300
    private var isMenuOpen = false
    private var keyMonitor: Any?
    private var endpointObserver: NSObjectProtocol?
    private var fetchGeneration = 0
    private var menuSocket: AnyObject?
    private lazy var preferencesWindowController = PreferencesWindowController()
    private let selectedSymbolKey = "glance.selectedSymbol"

    private var selectedSymbol: String? {
        get { UserDefaults.standard.string(forKey: selectedSymbolKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: selectedSymbolKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedSymbolKey)
            }
        }
    }

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Glance"
        statusItem.menu = buildMenu(items: [])
        installPreferencesShortcut()
        endpointObserver = NotificationCenter.default.addObserver(
            forName: .glanceEndpointDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchMenu()
        }
        fetchMenu()
    }

    deinit {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let endpointObserver {
            NotificationCenter.default.removeObserver(endpointObserver)
        }
        stopSocket()
    }

    /// 状态栏菜单打开时 ⌘, 由菜单项处理。其余时间 Glance 在前台则在这里响应 ⌘, 和 ⌘W。
    private func installPreferencesShortcut() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !event.isARepeat else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command else { return event }
            switch event.charactersIgnoringModifiers {
            case ",":
                if self.isMenuOpen { return event }
                self.showPreferences(nil)
                return nil
            case "w":
                guard let window = NSApp.keyWindow,
                      window.identifier?.rawValue == "GlancePreferences" else { return event }
                window.performClose(nil)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Networking

    func fetchMenu() {
        timer?.invalidate()
        fetchGeneration += 1
        let generation = fetchGeneration
        stopSocket()

        let url = GlanceEndpoint.url
        if url.scheme == "ws" || url.scheme == "wss" {
            connectSocket(url, generation: generation)
        } else {
            pollHTTP(url, generation: generation)
        }
    }

    private func pollHTTP(_ url: URL, generation: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self, self.fetchGeneration == generation else { return }
                if let data, error == nil, let response = try? JSONDecoder().decode(MenuResponse.self, from: data) {
                    self.applyResponse(response)
                } else {
                    self.applyFailure()
                }
                self.scheduleNext()
            }
        }.resume()
    }

    private func connectSocket(_ url: URL, generation: Int) {
        guard #available(macOS 10.15, *) else {
            applyFailure()
            scheduleNext()
            return
        }
        let connection = MenuSocket(url: url)
        menuSocket = connection
        connection.task.resume()
        receiveSocket(connection.task, generation: generation)
    }

    private func stopSocket() {
        if #available(macOS 10.15, *), let connection = menuSocket as? MenuSocket {
            connection.cancel()
        }
        menuSocket = nil
    }

    @available(macOS 10.15, *)
    private func receiveSocket(_ task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.fetchGeneration == generation else { return }
                switch result {
                case .success(let message):
                    if let data = Self.socketData(message),
                       let response = try? JSONDecoder().decode(MenuResponse.self, from: data) {
                        self.applyResponse(response)
                    }
                    self.receiveSocket(task, generation: generation)
                case .failure:
                    self.applyFailure()
                    self.scheduleNext()
                }
            }
        }
    }

    @available(macOS 10.15, *)
    private static func socketData(_ message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .string(let text):
            return Data(text.utf8)
        case .data(let data):
            return data
        @unknown default:
            return nil
        }
    }

    private func applyResponse(_ response: MenuResponse) {
        lastUpdated = Date()
        MenuController.latestItems = response.menu
        currentMenuItems = injectPreferences(into: response.menu)
        applyMenuData(items: currentMenuItems, defaultTitle: response.title)
        NotificationCenter.default.post(name: .glanceMenuDidUpdate, object: nil)
        let requested = TimeInterval(response.refreshAfterSeconds ?? Int(minInterval))
        nextInterval = max(minInterval, min(requested, maxInterval))
    }

    private func applyFailure() {
        currentMenuItems = []
        statusItem.button?.title = "⚠"
        if isMenuOpen, let menu = statusItem.menu {
            replaceOpenMenuContent(menu, with: [])
            updateLastUpdatedItem(in: menu)
        } else {
            statusItem.menu = buildMenu(items: [])
        }
        nextInterval = min(nextInterval * 2, self.maxInterval)
    }

    private func scheduleNext() {
        timer?.invalidate()
        let timer = Timer(timeInterval: nextInterval, repeats: false) { [weak self] _ in
            self?.fetchMenu()
        }
        // 菜单打开时 RunLoop 处于 eventTracking，需加入 common 才能继续拉取。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func applyMenuData(items: [MenuItem], defaultTitle: String) {
        updateStatusBarTitle(defaultTitle: defaultTitle, items: items)
        if isMenuOpen, let menu = statusItem.menu {
            updateOpenMenu(menu, with: items)
            updateLastUpdatedItem(in: menu)
        } else {
            statusItem.menu = buildMenu(items: items)
        }
    }

    // MARK: - Menu Building

    private func buildMenu(items: [MenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for item in items {
            menu.addItem(makeNSMenuItem(from: item))
        }
        if items.isEmpty {
            menu.addItem(makePreferencesItem())
            menu.addItem(makeQuitItem())
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeLastUpdatedItem())
        menu.autoenablesItems = false
        ensurePreferencesShown(in: menu)
        return menu
    }

    private func makeQuitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "退出 Glance", action: #selector(quitApp), keyEquivalent: "")
        item.target = self
        return item
    }

    private func makePreferencesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "偏好设置…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        item.keyEquivalentModifierMask = .command
        item.target = self
        return item
    }

    private func preferencesMenuModel() -> MenuItem {
        MenuItem(title: "偏好设置…", action: "preferences", keyEquivalent: ",")
    }

    /// 偏好设置与「快捷操作」平级，紧挨在它下面。服务端若把它放进子菜单，这里会挪出来。
    private func injectPreferences(into items: [MenuItem]) -> [MenuItem] {
        let stripped = items.compactMap { item -> MenuItem? in
            if item.action == "preferences" || item.title.hasPrefix("偏好设置") {
                return nil
            }
            return removingPreferences(from: item)
        }
        guard let quickIndex = stripped.firstIndex(where: { $0.title == "快捷操作" }) else {
            if let quitIndex = stripped.firstIndex(where: { $0.action == "quit" }) {
                var result = stripped
                result.insert(preferencesMenuModel(), at: quitIndex)
                return result
            }
            return stripped + [preferencesMenuModel()]
        }
        var result = stripped
        result.insert(preferencesMenuModel(), at: quickIndex + 1)
        return result
    }

    private func removingPreferences(from item: MenuItem) -> MenuItem {
        let children = item.children?.compactMap { child -> MenuItem? in
            if child.action == "preferences" || child.title.hasPrefix("偏好设置") {
                return nil
            }
            return removingPreferences(from: child)
        }
        return MenuItem(
            title: item.title,
            action: item.action,
            value: item.value,
            statusTitle: item.statusTitle,
            keyEquivalent: item.keyEquivalent,
            children: (children?.isEmpty == false) ? children : nil
        )
    }

    private func makeNSMenuItem(from item: MenuItem) -> NSMenuItem {
        let nsItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
        if let children = item.children, !children.isEmpty {
            let submenu = NSMenu(title: item.title)
            for child in children {
                submenu.addItem(makeNSMenuItem(from: child))
            }
            nsItem.submenu = submenu
        } else {
            configureLeafItem(nsItem, with: item)
        }
        return nsItem
    }

    private func configureLeafItem(_ nsItem: NSMenuItem, with item: MenuItem) {
        nsItem.state = .off
        switch item.action {
        case "select":
            nsItem.representedObject = item.value
            nsItem.target = self
            nsItem.action = #selector(selectSymbol(_:))
            if item.value == selectedSymbol {
                nsItem.state = .on
            }
        case "open_url":
            nsItem.representedObject = item.value
            nsItem.target = self
            nsItem.action = #selector(openURL(_:))
        case "copy":
            nsItem.representedObject = item.value
            nsItem.target = self
            nsItem.action = #selector(copyText(_:))
        case "quit":
            nsItem.representedObject = nil
            nsItem.target = self
            nsItem.action = #selector(quitApp)
        case "preferences":
            nsItem.representedObject = nil
            nsItem.target = self
            nsItem.action = #selector(showPreferences(_:))
        default:
            nsItem.representedObject = nil
            nsItem.target = nil
            nsItem.action = nil
        }
        applyKeyEquivalent(nsItem, key: item.keyEquivalent)
    }

    private func applyKeyEquivalent(_ nsItem: NSMenuItem, key: String?) {
        if let key, !key.isEmpty {
            nsItem.keyEquivalent = key
            nsItem.keyEquivalentModifierMask = .command
        } else {
            nsItem.keyEquivalent = ""
        }
    }

    private func makeLastUpdatedItem() -> NSMenuItem {
        let item = NSMenuItem(title: lastUpdatedString(), action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.tag = 9999
        return item
    }

    private func lastUpdatedString() -> String {
        guard let date = lastUpdated else { return "尚未更新" }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "上次更新：\(seconds)秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "上次更新：\(minutes)分钟前" }
        let hours = minutes / 60
        return "上次更新：\(hours)小时前"
    }

    /// 菜单打开时就地更新标题/动作，避免替换整个 NSMenu 导致菜单关闭或数值冻结。
    private func updateOpenMenu(_ menu: NSMenu, with items: [MenuItem]) {
        let footerCount = 2 // separator + lastUpdated
        let expectedContentCount = items.isEmpty ? 2 : items.count
        let currentContentCount = max(0, menu.numberOfItems - footerCount)

        if currentContentCount != expectedContentCount {
            replaceOpenMenuContent(menu, with: items)
            return
        }

        if items.isEmpty {
            let preferences = menu.item(at: 0)
            let quitItem = menu.item(at: 1)
            if preferences?.action == #selector(showPreferences(_:)), quitItem?.action == #selector(quitApp) {
                preferences?.title = "偏好设置…"
                quitItem?.title = "退出 Glance"
            } else {
                replaceOpenMenuContent(menu, with: items)
            }
            return
        }

        for (index, item) in items.enumerated() {
            guard let nsItem = menu.item(at: index) else {
                replaceOpenMenuContent(menu, with: items)
                return
            }
            updateNSMenuItem(nsItem, with: item)
        }
        ensurePreferencesShown(in: menu)
    }

    private func replaceOpenMenuContent(_ menu: NSMenu, with items: [MenuItem]) {
        let footerCount = 2
        let removeCount = max(0, menu.numberOfItems - footerCount)
        for _ in 0..<removeCount {
            menu.removeItem(at: 0)
        }
        if items.isEmpty {
            menu.insertItem(makePreferencesItem(), at: 0)
            menu.insertItem(makeQuitItem(), at: 1)
        } else {
            for (index, item) in items.enumerated() {
                menu.insertItem(makeNSMenuItem(from: item), at: index)
            }
        }
        ensurePreferencesShown(in: menu)
    }

    private func updateNSMenuItem(_ nsItem: NSMenuItem, with item: MenuItem) {
        nsItem.title = item.title
        if let children = item.children, !children.isEmpty {
            if nsItem.submenu == nil {
                nsItem.submenu = NSMenu(title: item.title)
                nsItem.action = nil
                nsItem.target = nil
                nsItem.representedObject = nil
            }
            nsItem.submenu?.title = item.title
            updateSubmenu(nsItem.submenu!, with: children)
        } else {
            if nsItem.submenu != nil {
                nsItem.submenu = nil
            }
            configureLeafItem(nsItem, with: item)
        }
    }

    private func updateSubmenu(_ submenu: NSMenu, with items: [MenuItem]) {
        if submenu.numberOfItems != items.count {
            submenu.removeAllItems()
            for item in items {
                submenu.addItem(makeNSMenuItem(from: item))
            }
            return
        }
        for (index, item) in items.enumerated() {
            guard let nsItem = submenu.item(at: index) else { continue }
            updateNSMenuItem(nsItem, with: item)
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        isMenuOpen = true
        // 打开菜单时再确认一次位置：和「快捷操作」平级，并紧挨在它下面。
        ensurePreferencesShown(in: menu)
        updateLastUpdatedItem(in: menu)
        startRefreshTimer(for: menu)
    }

    private func ensurePreferencesShown(in menu: NSMenu) {
        menu.autoenablesItems = false
        for top in menu.items {
            guard let submenu = top.submenu else { continue }
            submenu.autoenablesItems = false
            for nested in submenu.items where isPreferencesItem(nested) {
                submenu.removeItem(nested)
            }
        }

        let item = menu.items.first(where: isPreferencesItem) ?? makePreferencesItem()
        item.title = "偏好设置…"
        item.target = self
        item.action = #selector(showPreferences(_:))
        item.keyEquivalent = ","
        item.keyEquivalentModifierMask = .command
        item.isHidden = false
        item.isEnabled = true

        guard let quickIndex = menu.items.firstIndex(where: { $0.title == "快捷操作" }) else {
            if item.menu == nil {
                if let separator = menu.items.firstIndex(where: { $0.isSeparatorItem }) {
                    menu.insertItem(item, at: separator)
                } else {
                    menu.addItem(item)
                }
            }
            return
        }
        if menu.items.firstIndex(where: { $0 === item }) == quickIndex + 1 {
            return
        }
        if item.menu != nil {
            item.menu?.removeItem(item)
        }
        let insertAt = (menu.items.firstIndex(where: { $0.title == "快捷操作" }) ?? quickIndex) + 1
        menu.insertItem(item, at: min(insertAt, menu.numberOfItems))
    }

    private func isPreferencesItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(showPreferences(_:)) || item.title.hasPrefix("偏好设置")
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        isMenuOpen = false
        stopRefreshTimer()
    }

    private func startRefreshTimer(for menu: NSMenu) {
        stopRefreshTimer()
        let refreshTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateLastUpdatedItem(in: menu)
        }
        RunLoop.main.add(refreshTimer, forMode: .common)
        self.refreshTimer = refreshTimer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func updateLastUpdatedItem(in menu: NSMenu) {
        menu.item(withTag: 9999)?.title = lastUpdatedString()
    }

    private func updateStatusBarTitle(defaultTitle: String, items: [MenuItem]) {
        if let symbol = selectedSymbol,
           let item = findSelectableItem(symbol: symbol, in: items) {
            statusItem.button?.title = statusBarText(for: item)
        } else {
            statusItem.button?.title = defaultTitle
        }
    }

    private func statusBarText(for item: MenuItem) -> String {
        item.statusTitle ?? item.title
    }

    private func findSelectableItem(symbol: String, in items: [MenuItem]) -> MenuItem? {
        for item in items {
            if item.action == "select", item.value == symbol {
                return item
            }
            if let children = item.children,
               let found = findSelectableItem(symbol: symbol, in: children) {
                return found
            }
        }
        return nil
    }

    // MARK: - Actions

    @objc func showPreferences(_ sender: Any?) {
        preferencesWindowController.present()
    }

    @objc private func selectSymbol(_ sender: NSMenuItem) {
        guard let symbol = sender.representedObject as? String else { return }
        selectedSymbol = symbol
        if let item = findSelectableItem(symbol: symbol, in: currentMenuItems) {
            statusItem.button?.title = statusBarText(for: item)
        }
        if isMenuOpen, let menu = statusItem.menu {
            updateOpenMenu(menu, with: currentMenuItems)
        } else {
            statusItem.menu = buildMenu(items: currentMenuItems)
        }
    }

    @objc private func openURL(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
