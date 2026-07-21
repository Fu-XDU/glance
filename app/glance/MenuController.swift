import AppKit
import Foundation

final class MenuController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var lastUpdated: Date?
    private var currentMenuItems: [MenuItem] = []
    private var timer: Timer?
    private var refreshTimer: Timer?
    private var nextInterval: TimeInterval = 3
    private let minInterval: TimeInterval = 3
    private let maxInterval: TimeInterval = 300
    private var isMenuOpen = false

    private let apiURL = URL(string: "http://127.0.0.1:1423/api/menu")!
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
        fetchMenu()
    }

    // MARK: - Networking

    func fetchMenu() {
        timer?.invalidate()
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let data, error == nil, let response = try? JSONDecoder().decode(MenuResponse.self, from: data) {
                    self.lastUpdated = Date()
                    self.currentMenuItems = response.menu
                    self.applyMenuData(items: response.menu, defaultTitle: response.title)
                    let requested = TimeInterval(response.refreshAfterSeconds ?? Int(self.minInterval))
                    self.nextInterval = max(self.minInterval, min(requested, self.maxInterval))
                } else {
                    self.currentMenuItems = []
                    self.statusItem.button?.title = "⚠"
                    if self.isMenuOpen, let menu = self.statusItem.menu {
                        self.replaceOpenMenuContent(menu, with: [])
                        self.updateLastUpdatedItem(in: menu)
                    } else {
                        self.statusItem.menu = self.buildMenu(items: [])
                    }
                    self.nextInterval = min(self.nextInterval * 2, self.maxInterval)
                }
                self.scheduleNext()
            }
        }.resume()
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
            menu.addItem(makeQuitItem())
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeLastUpdatedItem())
        return menu
    }

    private func makeQuitItem() -> NSMenuItem {
        let item = NSMenuItem(title: "退出 Glance", action: #selector(quitApp), keyEquivalent: "")
        item.target = self
        return item
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
        default:
            nsItem.representedObject = nil
            nsItem.target = nil
            nsItem.action = nil
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
        let expectedContentCount = items.isEmpty ? 1 : items.count
        let currentContentCount = max(0, menu.numberOfItems - footerCount)

        if currentContentCount != expectedContentCount {
            replaceOpenMenuContent(menu, with: items)
            return
        }

        if items.isEmpty {
            if let quitItem = menu.item(at: 0), quitItem.action == #selector(quitApp) {
                quitItem.title = "退出 Glance"
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
    }

    private func replaceOpenMenuContent(_ menu: NSMenu, with items: [MenuItem]) {
        let footerCount = 2
        let removeCount = max(0, menu.numberOfItems - footerCount)
        for _ in 0..<removeCount {
            menu.removeItem(at: 0)
        }
        if items.isEmpty {
            menu.insertItem(makeQuitItem(), at: 0)
        } else {
            for (index, item) in items.enumerated() {
                menu.insertItem(makeNSMenuItem(from: item), at: index)
            }
        }
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
        updateLastUpdatedItem(in: menu)
        startRefreshTimer(for: menu)
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
