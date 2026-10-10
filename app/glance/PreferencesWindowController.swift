import AppKit
import AVKit

enum PreferencesMetrics {
    /// 偏好设置窗口的宽度。改这一个数即可。
    static let windowWidth: CGFloat = 360
    static let windowHeight: CGFloat = 560
}

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let pictureInPictureSettings = PictureInPictureSettingsViewController()

    init() {
        let general = GeneralSettingsViewController()
        general.title = "通用"
        pictureInPictureSettings.title = "画中画"
        let tabs = PreferencesTabViewController(general: general, pictureInPicture: pictureInPictureSettings)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PreferencesMetrics.windowWidth, height: PreferencesMetrics.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = tabs
        window.title = "偏好设置"
        window.identifier = NSUserInterfaceItemIdentifier("GlancePreferences")
        window.contentMinSize = NSSize(width: PreferencesMetrics.windowWidth, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .preference
            window.titlebarSeparatorStyle = .line
        }
        if !window.setFrameAutosaveName("GlancePreferences") {
            window.center()
        }
        var frame = window.frame
        frame.size.width = PreferencesMetrics.windowWidth
        window.setFrame(frame, display: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else { return }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
        window.toolbar?.displayMode = .iconAndLabel
        window.toolbar?.allowsUserCustomization = false
    }

    func windowWillClose(_ notification: Notification) {
        pictureInPictureSettings.relocatePictureInPictureIfNeeded()
    }
}

private final class PreferencesTabViewController: NSTabViewController {
    init(general: NSViewController, pictureInPicture: NSViewController) {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = false
        addChild(general)
        addChild(pictureInPicture)
        selectedTabViewItemIndex = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard #available(macOS 11.0, *), tabViewItems.count >= 2 else { return }
        tabViewItems[0].identifier = "general"
        tabViewItems[1].identifier = "pip"
        tabViewItems[0].image = Self.symbol("gearshape", fallback: "gearshape", label: "通用")
        tabViewItems[1].image = Self.symbol("pip", fallback: "rectangle.on.rectangle", label: "画中画")
    }

    @available(macOS 11.0, *)
    private static func symbol(_ name: String, fallback: String, label: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: label)
        return image?.withSymbolConfiguration(config)
    }
}

private final class PictureInPictureSettingsViewController: NSViewController {
    private let presenter: PictureInPicturePresenting? = PictureInPictureFactory.make()
    private let quoteList = QuoteListView()
    private let scrollView = NSScrollView()
    private let previewBox = NSView()
    private let pipButton = NSButton()
    private let hint = NSTextField(wrappingLabelWithString: "开启画中画后，数据刷新时会同步更新。")
    private let fallbackImage = NSImageView()
    private var quotes: [PiPQuote] = []
    private var menuObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: PreferencesMetrics.windowWidth, height: PreferencesMetrics.windowHeight))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = NSSize(width: PreferencesMetrics.windowWidth, height: PreferencesMetrics.windowHeight)
        buildLayout()
        installPreview()
        menuObserver = NotificationCenter.default.addObserver(
            forName: .glanceMenuDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.apply(quotes: PiPQuote.quotes(from: MenuController.latestItems))
        }
        presenter?.onActiveChange = { [weak self] _ in
            self?.updatePiPButton()
        }
        presenter?.onFailure = { [weak self] message in
            self?.showPiPError(message)
        }
    }

    deinit {
        if let menuObserver {
            NotificationCenter.default.removeObserver(menuObserver)
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        apply(quotes: PiPQuote.quotes(from: MenuController.latestItems))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        presenter?.attach(to: previewBox)
        previewBox.layoutSubtreeIfNeeded()
        renderCurrentSelection()
        presenter?.prepareIfNeeded()
        updatePiPButton()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        hint.preferredMaxLayoutWidth = max(hint.bounds.width, 200)
        layoutQuoteList()
    }

    func relocatePictureInPictureIfNeeded() {
        presenter?.parkIfNeeded()
    }

    private func buildLayout() {
        let header = NSTextField(labelWithString: "选择要展示的信息")
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.translatesAutoresizingMaskIntoConstraints = false

        pipButton.bezelStyle = .circular
        pipButton.imagePosition = .imageOnly
        pipButton.imageScaling = .scaleProportionallyDown
        pipButton.target = self
        pipButton.action = #selector(togglePictureInPicture)
        pipButton.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            pipButton.controlSize = .large
        }

        let clip = TopAlignedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .lineBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 11.0, *) {
            scrollView.scrollerStyle = .overlay
        }
        scrollView.documentView = quoteList

        previewBox.wantsLayer = true
        previewBox.layer?.backgroundColor = CGColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1)
        previewBox.layer?.cornerRadius = 10
        previewBox.layer?.masksToBounds = true
        previewBox.translatesAutoresizingMaskIntoConstraints = false

        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.maximumNumberOfLines = 2
        hint.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(pipButton)
        view.addSubview(scrollView)
        view.addSubview(previewBox)
        view.addSubview(hint)

        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(200), for: .vertical)
        previewBox.setContentCompressionResistancePriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(lessThanOrEqualTo: pipButton.leadingAnchor, constant: -12),

            pipButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            pipButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            pipButton.widthAnchor.constraint(equalToConstant: 36),
            pipButton.heightAnchor.constraint(equalToConstant: 36),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            previewBox.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 16),
            previewBox.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            previewBox.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            previewBox.heightAnchor.constraint(equalToConstant: 200),

            hint.topAnchor.constraint(equalTo: previewBox.bottomAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),

            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 88),
        ])
        updatePiPButton()
    }

    private func installPreview() {
        guard presenter == nil else { return }
        fallbackImage.imageScaling = .scaleProportionallyUpOrDown
        fallbackImage.imageAlignment = .alignCenter
        fallbackImage.translatesAutoresizingMaskIntoConstraints = false
        previewBox.addSubview(fallbackImage)
        NSLayoutConstraint.activate([
            fallbackImage.leadingAnchor.constraint(equalTo: previewBox.leadingAnchor),
            fallbackImage.trailingAnchor.constraint(equalTo: previewBox.trailingAnchor),
            fallbackImage.topAnchor.constraint(equalTo: previewBox.topAnchor),
            fallbackImage.bottomAnchor.constraint(equalTo: previewBox.bottomAnchor),
        ])
    }

    private func apply(quotes: [PiPQuote]) {
        self.quotes = quotes
        quoteList.update(quotes: quotes, selected: PiPSelectionStore.values, target: self, action: #selector(toggleQuote(_:)))
        layoutQuoteList()
        renderCurrentSelection()
    }

    private func layoutQuoteList() {
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        let height = max(quoteList.fittingHeight, scrollView.contentView.bounds.height)
        quoteList.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    private func renderCurrentSelection() {
        let lines = currentLines()
        if let presenter {
            presenter.setLines(lines)
        } else {
            let size = previewBox.bounds.size.width > 1 ? previewBox.bounds.size : CGSize(width: 640, height: 200)
            fallbackImage.image = PiPFrame.image(lines: lines, pointSize: size)
        }
        updatePiPButton()
    }

    private func currentLines() -> [PiPLine] {
        let selected = PiPSelectionStore.values
        return quotes.filter { selected.contains($0.id) }.map(\.line)
    }

    private func updatePiPButton() {
        let active = presenter?.isActive ?? false
        pipButton.image = Self.pipButtonImage(active: active)
        if presenter == nil {
            pipButton.isEnabled = false
            pipButton.toolTip = "画中画需要 macOS 12 或更高版本"
        } else {
            pipButton.isEnabled = active || !currentLines().isEmpty
            pipButton.toolTip = active ? "关闭画中画" : "开启画中画"
        }
        pipButton.setAccessibilityLabel(pipButton.toolTip)
    }

    private static func pipButtonImage(active: Bool) -> NSImage? {
        if #available(macOS 10.15, *) {
            let image = (active
                ? AVPictureInPictureController.pictureInPictureButtonStopImage
                : AVPictureInPictureController.pictureInPictureButtonStartImage
            ).copy() as? NSImage
            image?.isTemplate = true
            image?.size = NSSize(width: 16, height: 16)
            return image
        }
        if #available(macOS 11.0, *) {
            return NSImage(systemSymbolName: active ? "pip.exit" : "pip.enter", accessibilityDescription: "画中画")
        }
        return nil
    }

    @objc private func toggleQuote(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        var selected = PiPSelectionStore.values
        if sender.state == .on {
            selected.insert(id)
        } else {
            selected.remove(id)
        }
        PiPSelectionStore.values = selected
        renderCurrentSelection()
    }

    @objc private func togglePictureInPicture() {
        guard let presenter else { return }
        previewBox.layoutSubtreeIfNeeded()
        presenter.attach(to: previewBox)
        presenter.setLines(currentLines())
        presenter.prepareIfNeeded()
        presenter.toggle()
        updatePiPButton()
    }

    private func showPiPError(_ message: String) {
        guard let window = view.window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = "无法开启画中画"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.beginSheetModal(for: window)
    }
}

private enum PiPSelectionStore {
    private static let key = "glance.pip.selectedValues"

    static var values: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: key) }
    }
}

private final class TopAlignedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

private final class QuoteListView: NSView {
    private var rows: [QuoteToggleRow] = []
    private let emptyLabel: NSTextField = {
        let label = NSTextField(labelWithString: "暂无可展示的行情")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        return label
    }()

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            emptyLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var fittingHeight: CGFloat {
        if rows.isEmpty { return 36 }
        return 8 + CGFloat(rows.count) * 28 + 8
    }

    func update(quotes: [PiPQuote], selected: Set<String>, target: AnyObject, action: Selector) {
        let sameIDs = rows.map(\.id) == quotes.map(\.id)
        if quotes.isEmpty {
            rows.forEach { $0.removeFromSuperview() }
            rows = []
            emptyLabel.isHidden = false
        } else if sameIDs {
            emptyLabel.isHidden = true
            for (row, quote) in zip(rows, quotes) {
                row.apply(quote)
            }
        } else {
            emptyLabel.isHidden = true
            rows.forEach { $0.removeFromSuperview() }
            rows = quotes.map { quote in
                QuoteToggleRow(quote: quote, selected: selected.contains(quote.id), target: target, action: action)
            }
            rows.forEach(addSubview)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        var y: CGFloat = 6
        let width = max(bounds.width - 16, 0)
        for row in rows {
            row.frame = NSRect(x: 8, y: y, width: width, height: 26)
            y += 28
        }
    }
}

private final class QuoteToggleRow: NSView {
    let id: String
    private let checkbox: NSButton
    private let valueLabel = NSTextField(labelWithString: "")

    init(quote: PiPQuote, selected: Bool, target: AnyObject, action: Selector) {
        id = quote.id
        checkbox = NSButton(checkboxWithTitle: quote.name, target: target, action: action)
        checkbox.identifier = NSUserInterfaceItemIdentifier(quote.id)
        checkbox.state = selected ? .on : .off
        checkbox.font = .systemFont(ofSize: 13)
        (checkbox.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 26))

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        addSubview(valueLabel)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        checkbox.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: valueLabel.leadingAnchor, constant: -8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        apply(quote)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ quote: PiPQuote) {
        checkbox.title = quote.name
        valueLabel.stringValue = quote.valueText
        toolTip = quote.valueText.isEmpty ? quote.name : "\(quote.name)  \(quote.valueText)"
    }
}
