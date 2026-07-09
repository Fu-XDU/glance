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
                    self.statusItem.menu = self.buildMenu(items: response.menu)
                    self.updateStatusBarTitle(defaultTitle: response.title, items: response.menu)
                    let requested = TimeInterval(response.refreshAfterSeconds ?? Int(self.minInterval))
                    self.nextInterval = max(self.minInterval, min(requested, self.maxInterval))
                } else {
                    self.currentMenuItems = []
                    self.statusItem.button?.title = "⚠"
                    self.statusItem.menu = self.buildMenu(items: [])
                    self.nextInterval = min(self.nextInterval * 2, self.maxInterval)
                }
                self.scheduleNext()
            }
        }.resume()
    }

    private func scheduleNext() {
        timer = Timer.scheduledTimer(withTimeInterval: nextInterval, repeats: false) { [weak self] _ in
            self?.fetchMenu()
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
                nsItem.target = self
                nsItem.action = #selector(quitApp)
            default:
                break
            }
        }
        return nsItem
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

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
        updateLastUpdatedItem(in: menu)
        startRefreshTimer(for: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusItem.menu else { return }
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
        statusItem.menu = buildMenu(items: currentMenuItems)
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
