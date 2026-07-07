import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide Dock icon — pure menu bar app
        NSApp.setActivationPolicy(.accessory)
        menuController = MenuController()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
