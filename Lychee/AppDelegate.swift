//
//  AppDelegate.swift
//  Lychee
//
//  Menu bar setup, NSStatusItem, NSPopover management
//

import Cocoa
import SwiftUI
import Combine
import ServiceManagement
import Sparkle

// Applies NSAppearance during the view lifecycle so the very first composited
// frame has the correct appearance — no flash, no click-to-fix.
private final class LycheePopoverController: NSHostingController<PopoverView> {
    override func viewWillAppear() {
        super.viewWillAppear()
        applyAppearance()
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        applyAppearance()
        // Make the popover window key so NSVisualEffectView uses .active vibrancy.
        // Without this, transient popovers stay non-key → VEV uses .inactive state → washed-out look.
        view.window?.makeKey()
    }
    func applyAppearance() {
        // NSPopover creates its internal _NSPopoverWindow using NSApp.appearance as the source,
        // not view.appearance or view.window?.appearance. Setting NSApp.appearance is the only
        // reliable way to control the popover chrome + content appearance consistently.
        let appearance = TrackState.shared.popoverTheme.nsAppearance
        NSApp.appearance = appearance
        view.appearance = appearance
        view.window?.appearance = appearance
    }
}

private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onDismiss?()
        return false
    }
}

private final class WelcomeWindowDelegate: NSObject, NSWindowDelegate {
    var onDismiss: (() -> Void)?
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onDismiss?()
        return false
    }
}

private final class SettingsWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}


class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private static let onboardingCompletedBuildKey = "lychee.completedOnboardingBuildID"
    private static let legacyOnboardingCompletedKey = "lychee.hasCompletedOnboarding"

    static var currentOnboardingBuildID: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        let executableModifiedAt: String
        if let executableURL = Bundle.main.executableURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: executableURL.path),
           let date = attributes[.modificationDate] as? Date {
            executableModifiedAt = String(Int(date.timeIntervalSince1970))
        } else {
            executableModifiedAt = "unknown"
        }
        return "\(version)-\(build)-\(executableModifiedAt)"
    }

    static var hasCompletedOnboardingForCurrentBuild: Bool {
        UserDefaults.standard.string(forKey: onboardingCompletedBuildKey) == currentOnboardingBuildID
    }

    static func setOnboardingCompletedForCurrentBuild(_ completed: Bool) {
        if completed {
            UserDefaults.standard.set(currentOnboardingBuildID, forKey: onboardingCompletedBuildKey)
            UserDefaults.standard.set(true, forKey: legacyOnboardingCompletedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: onboardingCompletedBuildKey)
            UserDefaults.standard.set(false, forKey: legacyOnboardingCompletedKey)
        }
    }

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    private var hostingController: LycheePopoverController?
    private var cancellables = Set<AnyCancellable>()
    private var onboardingWindow: NSWindow!
    private let onboardingDelegate = OnboardingWindowDelegate()
    private var welcomeWindow: NSWindow?
    private let welcomeDelegate = WelcomeWindowDelegate()
    private var settingsWindow: NSWindow?
    private let settingsWindowDelegate = SettingsWindowDelegate()
    private var settingsHostingView: NSHostingView<SettingsView>?
    private var settingsTabObserver: Any?
    private var updaterController: SPUStandardUpdaterController!
    static var isExplicitQuit = false

    private var fullWidth: CGFloat { TrackState.shared.menuBarWidth.pixels }
    private let compactWidth: CGFloat = 28  // 4px padding + 20px album art + 4px padding
    private var menuBarHeight: CGFloat = 0
    private var effectiveExpandedWidth: CGFloat = TrackState.MenuBarWidth.standard.pixels
    // Saved when isMinimized goes true; restored on un-minimize to avoid the step-down
    // cascade that occurs when jumping directly to fullWidth (which may no longer fit).
    private var savedExpandedWidth: CGFloat = TrackState.MenuBarWidth.standard.pixels
    private var statusItemOcclusionObserver: Any?
    private var stepDownWorkItem: DispatchWorkItem?
    private var isProtectingOnboardingPopoverTransition = false

    private var widthFallbackSequence: [CGFloat] {
        let userPref = fullWidth
        let smallerPresets = TrackState.MenuBarWidth.allCases
            .map { $0.pixels }
            .filter { $0 < userPref }
            .sorted(by: >)
        return [userPref] + smallerPresets + [compactWidth]
    }

    func checkForUpdates() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updaterController?.updater.automaticallyChecksForUpdates ?? true }
        set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
    }

    func showSettings() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "Lychee Settings"
            win.isReleasedWhenClosed = false
            win.backgroundColor = .windowBackgroundColor
            win.appearance = TrackState.shared.popoverTheme.nsAppearance
            let hostingView = NSHostingView(rootView: SettingsView())
            settingsHostingView = hostingView
            win.contentView = hostingView
            // Force a layout pass so fittingSize is accurate before the window appears.
            hostingView.layout()
            win.setContentSize(hostingView.fittingSize)
            settingsWindowDelegate.onClose = { [weak self] in
                self?.returnToMenuBarIfNoRegularWindows()
            }
            win.delegate = settingsWindowDelegate
            settingsWindow = win
            // Animate the window when the user switches tabs in the settings view.
            settingsTabObserver = NotificationCenter.default.addObserver(
                forName: .lycheeSettingsTabChanged, object: nil, queue: .main
            ) { [weak self] _ in
                // One run-loop iteration is enough for SwiftUI to commit the new
                // layout so fittingSize is accurate. No longer delay needed.
                DispatchQueue.main.async { self?.animateSettingsWindowResize() }
            }
        }
        guard let win = settingsWindow else { return }
        if !win.isVisible { win.center() }
        // Switching to .regular can resurface windows that were merely orderOut'd
        // (not closed) the last time the app was .regular, so hide them before
        // presenting settings.
        onboardingWindow?.orderOut(nil)
        welcomeWindow?.orderOut(nil)
        if popover.isShown {
            popover.performClose(nil)
        }
        presentRegularWindow(win, center: !win.isVisible)
    }

    func handleCommandQuit() {
        if popover.isShown {
            quitFromPopover()
            return
        }
        _ = closeRegularPresentationToMenuBar()
    }

    func quitFromPopover() {
        guard popover.isShown else {
            _ = closeRegularPresentationToMenuBar()
            return
        }
        AppDelegate.isExplicitQuit = true
        NSApplication.shared.terminate(nil)
    }

    func completeOnboardingAndOpenPopover() {
        AppDelegate.setOnboardingCompletedForCurrentBuild(true)
        isProtectingOnboardingPopoverTransition = true
        popover.behavior = .applicationDefined
        onboardingWindow?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            if !self.popover.isShown {
                self.showPopoverFromStatusItem()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
                guard let self else { return }
                self.popover.behavior = .transient
                self.isProtectingOnboardingPopoverTransition = false
            }
        }
    }

    private func animateSettingsWindowResize() {
        guard let win = settingsWindow, let hv = settingsHostingView else { return }
        hv.layout()
        let newSize = hv.fittingSize
        guard newSize.height > 50 else { return }
        win.setContentSize(newSize)
    }

    private func applyWindowTheme() {
        let appearance = TrackState.shared.popoverTheme.nsAppearance
        if let window = onboardingWindow { applyTheme(to: window, appearance: appearance) }
        if let window = welcomeWindow { applyTheme(to: window, appearance: appearance) }
        if let window = settingsWindow { applyTheme(to: window, appearance: appearance) }
    }

    private func applyTheme(to window: NSWindow, appearance: NSAppearance?) {
        window.appearance = appearance
        window.contentView?.appearance = appearance
    }

    private func presentRegularWindow(_ window: NSWindow, center: Bool, forceFront: Bool = false) {
        NSApp.setActivationPolicy(.regular)
        applyWindowTheme()
        if center && !window.isVisible {
            window.center()
        }

        window.level = .normal
        window.deminiaturize(nil)
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        window.makeKeyAndOrderFront(nil)
        if forceFront {
            // One-shot front ordering for a user-initiated app launch/reopen.
            // The window stays at normal level and can be covered by other apps.
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func dismissRegularWindowToMenuBar(_ window: NSWindow?) {
        if popover.isShown {
            popover.contentViewController?.view.window?.makeKey()
        }
        window?.orderOut(nil)
        returnToMenuBarIfNoRegularWindows(ignoring: [window])
    }

    @discardableResult
    private func closeRegularPresentationToMenuBar() -> Bool {
        if onboardingWindow?.isVisible == true {
            dismissOnboardingWindow()
            return true
        }
        if welcomeWindow?.isVisible == true {
            dismissWelcomeWindow()
            return true
        }
        if settingsWindow?.isVisible == true {
            settingsWindow?.orderOut(nil)
            returnToMenuBarIfNoRegularWindows(ignoring: [settingsWindow])
            return true
        }
        if popover.isShown {
            popover.performClose(nil)
            return true
        }
        if NSApp.activationPolicy() == .regular {
            NSApp.setActivationPolicy(.accessory)
            return true
        }
        return false
    }

    private func returnToMenuBarIfNoRegularWindows(ignoring ignoredWindows: [NSWindow?] = []) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ignoredWindows = ignoredWindows.compactMap { $0 }
            let hasVisibleWindow = NSApp.windows.contains { window in
                self.windowRequiresDockPresence(window, ignoring: ignoredWindows)
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    private func windowRequiresDockPresence(_ window: NSWindow, ignoring ignoredWindows: [NSWindow]) -> Bool {
        guard window.isVisible else { return false }
        if ignoredWindows.contains(where: { window === $0 }) { return false }
        if let statusWindow = statusItem.button?.window, window === statusWindow { return false }
        if let popoverWindow = popover.contentViewController?.view.window, window === popoverWindow { return false }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        TelemetryService.shared.start()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Fresh launches show a real window, so keep normal activation until
        // that window is dismissed. Dismissal returns the app to accessory mode.
        NSApp.setActivationPolicy(.regular)
        setupStatusItem()
        setupPopover()
        // Apply NSApp.appearance at launch so it's set before popover.show() ever runs.
        hostingController?.applyAppearance()
        MusicPoller.shared.start()
        MediaRemotePoller.shared.start()

        TrackState.shared.$isMinimized
            .receive(on: DispatchQueue.main)
            .sink { [weak self] minimized in
                guard let self else { return }
                if self.popover.isShown {
                    self.popover.performClose(nil)
                }
                if minimized {
                    // Save current expanded width so we can restore it exactly on un-minimize,
                    // avoiding the step-down cascade that jumping to fullWidth would trigger.
                    self.savedExpandedWidth = self.effectiveExpandedWidth
                } else {
                    // Restore the pre-minimize width. If it was already at compact (menu bar was
                    // fully crowded), fall back to fullWidth and let occlusion step it down again.
                    self.effectiveExpandedWidth = self.savedExpandedWidth > self.compactWidth
                        ? self.savedExpandedWidth
                        : self.fullWidth
                }
                self.updateStatusItemWidth(minimized: minimized)
            }
            .store(in: &cancellables)

        TrackState.shared.$menuBarWidth
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, !TrackState.shared.isMinimized else { return }
                if self.popover.isShown { self.popover.performClose(nil) }
                self.adaptToAvailableWidth()
            }
            .store(in: &cancellables)

        // App switches change the foreground app's menu bar items, which is the only
        // time available menu bar space actually changes. Re-evaluate our fit each time.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !TrackState.shared.isMinimized else { return }
                self.adaptToAvailableWidth()
            }
            .store(in: &cancellables)

        // Display configuration changes (resolution, external monitor) also affect space.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !TrackState.shared.isMinimized else { return }
                self.adaptToAvailableWidth()
            }
            .store(in: &cancellables)

        if SMAppService.mainApp.status != .enabled {
            AutoLaunchManager.enable()
        }

        // Re-apply appearance when theme toggle changes.
        TrackState.shared.$popoverTheme
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.hostingController?.applyAppearance()
                self?.applyWindowTheme()
            }
            .store(in: &cancellables)

        // Re-apply appearance and re-make key when app regains focus after Cmd+Tab.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.popover.isShown else { return }
                self.hostingController?.applyAppearance()
                self.popover.contentViewController?.view.window?.makeKey()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.returnToMenuBarIfNoRegularWindows()
        }

        DispatchQueue.main.async { [weak self] in
            self?.showInitialLaunchWindow(forceFront: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MusicPoller.shared.stop()
        MediaRemotePoller.shared.stop()
    }

    private func showInitialLaunchWindow(forceFront: Bool = false) {
        if AppDelegate.hasCompletedOnboardingForCurrentBuild {
            showWelcomeWindow(forceFront: forceFront)
        } else {
            showOnboardingWindow(forceFront: forceFront)
        }
    }

    // MARK: - Onboarding

    private func createOnboardingWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.initialFirstResponder = nil
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.appearance = TrackState.shared.popoverTheme.nsAppearance
        window.contentView = NSHostingView(rootView: OnboardingView(onDismiss: { [weak self] in
            self?.dismissOnboardingWindow()
        }))
        onboardingDelegate.onDismiss = { [weak self] in self?.dismissOnboardingWindow() }
        window.delegate = onboardingDelegate
        onboardingWindow = window
    }

    private func showOnboardingWindow(forceFront: Bool = false) {
        if onboardingWindow == nil {
            createOnboardingWindow()
        }
        NotificationCenter.default.post(name: .lycheeOnboardingWillShow, object: nil)
        presentRegularWindow(onboardingWindow, center: true, forceFront: forceFront)
    }

    private func dismissOnboardingWindow() {
        dismissRegularWindowToMenuBar(onboardingWindow)
    }

    // MARK: - Welcome Window

    private func createWelcomeWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.initialFirstResponder = nil
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.appearance = TrackState.shared.popoverTheme.nsAppearance
        let hv = NSHostingView(rootView: WelcomeView(onDismiss: { [weak self] in
            self?.dismissWelcomeWindow()
        }))
        hv.layout()
        window.contentView = hv
        window.setContentSize(hv.fittingSize)
        welcomeDelegate.onDismiss = { [weak self] in self?.dismissWelcomeWindow() }
        window.delegate = welcomeDelegate
        welcomeWindow = window
    }

    private func showWelcomeWindow(forceFront: Bool = false) {
        if welcomeWindow == nil { createWelcomeWindow() }
        NotificationCenter.default.post(name: .lycheeWelcomeWillShow, object: nil)
        if let welcomeWindow {
            presentRegularWindow(welcomeWindow, center: true, forceFront: forceFront)
        }
    }

    private func dismissWelcomeWindow() {
        dismissRegularWindowToMenuBar(welcomeWindow)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            if AppDelegate.hasCompletedOnboardingForCurrentBuild {
                showWelcomeWindow(forceFront: true)
            } else {
                showOnboardingWindow(forceFront: true)
            }
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if AppDelegate.isExplicitQuit { return .terminateNow }
        if closeRegularPresentationToMenuBar() {
            return .terminateCancel
        }
        NSApp.setActivationPolicy(.accessory)
        return .terminateCancel
    }

    // MARK: - Status Item Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: fullWidth)
        let menuBarHeight = NSStatusBar.system.thickness
        self.menuBarHeight = menuBarHeight


        // Disable default button rendering to prevent shadows/artifacts
        statusItem.button?.image = nil
        statusItem.button?.title = ""
        statusItem.button?.isBordered = false
        statusItem.button?.wantsLayer = true
        statusItem.button?.layer?.backgroundColor = NSColor.clear.cgColor
        statusItem.button?.layer?.masksToBounds = false
        statusItem.button?.clipsToBounds = false
        statusItem.button?.layer?.shadowOpacity = 0
        statusItem.button?.layer?.shadowRadius = 0
        if let buttonCell = statusItem.button?.cell as? NSButtonCell {
            buttonCell.backgroundColor = .clear
            buttonCell.imageScaling = .scaleNone
            buttonCell.highlightsBy = []
            buttonCell.showsStateBy = []
        }

        let menuBarContent = MenuBarContentView(menuBarHeight: menuBarHeight)

        let hostingView = NSHostingView(rootView: menuBarContent)
        hostingView.frame = NSRect(x: 0, y: 0, width: fullWidth, height: menuBarHeight + 22)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.shadowOpacity = 0
        hostingView.layer?.shadowRadius = 0
        hostingView.layer?.masksToBounds = false

        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(togglePopover))
        hostingView.addGestureRecognizer(clickGesture)

        statusItem.button?.addSubview(hostingView)
        effectiveExpandedWidth = fullWidth
        TrackState.shared.effectiveMenuBarPixels = fullWidth
        statusItem.length = fullWidth

        // NSWindow.occlusionState is compositor-level: .visible is set only when the window is
        // actually being rendered to the display. When the menu bar hides our item due to crowding,
        // the window stops being composited → occlusionState loses .visible → we step down.
        if let window = statusItem.button?.window {
            statusItemOcclusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.handleOcclusionChange()
            }
        }

        // Let the menu bar settle at launch, then try full width once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.adaptToAvailableWidth()
        }
    }

    // MARK: - Instant Width Update (No Animation)

    private func updateStatusItemWidth(minimized: Bool) {
        let targetWidth = minimized ? compactWidth : effectiveExpandedWidth
        // Tell SwiftUI the effective width so MenuBarContentView lays out correctly.
        TrackState.shared.effectiveMenuBarPixels = targetWidth

        guard let hostingView = statusItem.button?.subviews.first else { return }

        // Disable implicit animations and update instantly
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        hostingView.frame = NSRect(x: 0, y: 0, width: targetWidth, height: menuBarHeight)
        // Compact mode: clip to prevent ghost renders of the previous full-width layout.
        // Full mode: allow overflow so 2-line descenders are visible below the menu bar.
        hostingView.layer?.masksToBounds = (targetWidth == compactWidth)
        statusItem.length = targetWidth

        // Force immediate redraw to prevent intermediate rendering states
        hostingView.layer?.setNeedsDisplay()
        hostingView.layer?.displayIfNeeded()
        statusItem.button?.layer?.setNeedsDisplay()
        statusItem.button?.layer?.displayIfNeeded()
        
        CATransaction.commit()
    }

    // MARK: - Adaptive Width

    // Resets to the user's preferred width. If the menu bar is crowded and hides us,
    // didChangeOcclusionStateNotification fires and stepDownWidth handles the rest.
    private func adaptToAvailableWidth() {
        guard !TrackState.shared.isMinimized else { return }
        effectiveExpandedWidth = fullWidth
        updateStatusItemWidth(minimized: false)
    }

    // Called by the occlusion observer. Debounced 150ms so transient "not visible" flickers
    // during menu bar reflow (e.g. when we expand back after an app switch) don't trigger a
    // spurious step-down. If we're actually too wide, we stay hidden the full 150ms and step down.
    // If we become visible within 150ms (reflow settled and we fit), the work item is cancelled.
    private func handleOcclusionChange() {
        guard let window = statusItem.button?.window,
              !TrackState.shared.isMinimized else { return }

        if !window.occlusionState.contains(.visible) {
            stepDownWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      let win = self.statusItem.button?.window,
                      !win.occlusionState.contains(.visible),
                      !TrackState.shared.isMinimized else { return }
                self.stepDownWidth()
            }
            stepDownWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        } else {
            // Became visible — cancel any pending step-down (e.g. transient flicker during expansion).
            stepDownWorkItem?.cancel()
            stepDownWorkItem = nil
        }
    }

    private func stepDownWidth() {
        let next = widthFallbackSequence.first { $0 < effectiveExpandedWidth } ?? compactWidth
        guard next != effectiveExpandedWidth else { return }
        effectiveExpandedWidth = next
        if popover.isShown, !isProtectingOnboardingPopoverTransition {
            popover.performClose(nil)
        }
        updateStatusItemWidth(minimized: false)
    }

    // MARK: - Popover Setup

    private func setupPopover() {
        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 240)
        popover.behavior = .transient
        popover.delegate = self

        let controller = LycheePopoverController(rootView: PopoverView())
        hostingController = controller
        popover.contentViewController = controller
    }

    // MARK: - Popover Toggle

    @objc func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopoverFromStatusItem()
        }
    }

    private func showPopoverFromStatusItem() {
        if let view = statusItem.button?.subviews.first ?? statusItem.button {
            // Must set NSApp.appearance immediately before show() — the internal
            // _NSPopoverWindow is created during this call and reads NSApp.appearance.
            hostingController?.applyAppearance()
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            // Only activate when not already active. If settings is open the app is
            // already active; re-activating causes macOS to reorder app windows when
            // the transient popover closes, surfacing the settings window unexpectedly.
            if !NSApp.isActive {
                NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
            }
        }
    }

    private func truncateText(_ text: String, maxLength: Int) -> String {
        if text.count <= maxLength { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }
}

// MARK: - SPUUpdaterDelegate

extension AppDelegate: SPUUpdaterDelegate {}

// MARK: - SPUStandardUserDriverDelegate

extension AppDelegate: SPUStandardUserDriverDelegate {
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
            let ignoredWindows = [self.onboardingWindow].compactMap { $0 }
            NSApp.windows
                .filter { self.windowRequiresDockPresence($0, ignoring: ignoredWindows) }
                .forEach { $0.makeKeyAndOrderFront(nil) }
        }
    }

    func standardUserDriverWillShowModalAlert() {
        NSApp.setActivationPolicy(.regular)
        NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
    }
}

// MARK: - NSPopoverDelegate

extension AppDelegate: NSPopoverDelegate {
    func popoverDidShow(_ notification: Notification) {
        popover.contentViewController?.view.window?.makeKey()
        TrackState.shared.isPopoverShown = true
    }

    func popoverDidClose(_ notification: Notification) {
        TrackState.shared.isPopoverShown = false
        // Flip to accessory if no real windows remain visible.
        // Handles the "Let's go" case where dismissOnboardingWindow skipped the flip
        // because the popover was still open at that moment.
        returnToMenuBarIfNoRegularWindows()
    }
}

// MARK: - Menu Bar Content View

struct MenuBarContentView: View {
    @ObservedObject var lyricsEngine = LyricsEngine.shared
    @ObservedObject var trackState = TrackState.shared
    @Environment(\.colorScheme) private var colorScheme

    let menuBarHeight: CGFloat
    private var totalWidth: CGFloat { trackState.effectiveMenuBarPixels - 16 }

    func measureTextWidth(_ text: String) -> CGFloat {
        // Must match the weight LyricsTextZone renders with
        let font = LyricsTextZone.menuBarFont(for: colorScheme)
        let maxWidth: CGFloat = trackState.effectiveMenuBarPixels - 48
        let attrs: [NSAttributedString.Key: Any] = [.font: font]

        let boundingRect = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: 1000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )

        let singleLineHeight = font.ascender + abs(font.descender)
        guard boundingRect.height > singleLineHeight * 1.5 else {
            return min(ceil(boundingRect.width), maxWidth)
        }

        // Text wraps. Compute the balanced two-line split (same algorithm as
        // LyricsTextZone.balancedText) and return the wider of the two lines so
        // GapFillView gets the remaining space instead of collapsing to 0.
        let words = text.components(separatedBy: " ")
        guard words.count > 1 else { return maxWidth }
        var bestSplit = 1
        var bestDiff = CGFloat.infinity
        for i in 1..<words.count {
            let w1 = (words[0..<i].joined(separator: " ") as NSString).size(withAttributes: attrs).width
            let w2 = (words[i...].joined(separator: " ") as NSString).size(withAttributes: attrs).width
            let diff = abs(w1 - w2)
            if diff < bestDiff { bestDiff = diff; bestSplit = i }
        }
        let w1 = (words[0..<bestSplit].joined(separator: " ") as NSString).size(withAttributes: attrs).width
        let w2 = (words[bestSplit...].joined(separator: " ") as NSString).size(withAttributes: attrs).width
        return ceil(max(w1, w2))
    }

    var displayText: String {
        if trackState.trackName.isEmpty { return "Play a song to get started" }

        if trackState.lyricsRejectedForSession {
            let artist = trackState.artistName
            return artist.isEmpty ? trackState.trackName : "\(trackState.trackName) · \(artist)"
        }

        switch trackState.lyricsState {
        case .synced:
            if !trackState.isPlaying { return trackState.trackName }
            return lyricsEngine.isInGap ? "♪ music" : lyricsEngine.currentLine
        case .loading:
            // Include trailing "..." so width accounts for animated dots
            switch trackState.loadingPhase {
            case .initial:      return "\(trackState.trackName) — loading lyrics..."
            case .takingLonger: return "Taking a bit longer than usual..."
            case .nicheChoice:  return "\"\(trackState.trackName)\" very niche choice hm..."
            case .lastTry:      return "Alright one last try..."
            }
        case .notFound:
            return trackState.trackName
        case .plainOnly:
            return "\(trackState.trackName) — No synced lyrics"
        case .idle:
            return trackState.trackName
        }
    }

    var textWidth: CGFloat { measureTextWidth(displayText) }

    var gapWidth: CGFloat {
        let used: CGFloat = 20 + 6 + textWidth + 6
        return max(0, totalWidth - used)
    }

    var body: some View {
        HStack(spacing: 0) {
            AlbumThumb()
                .frame(width: 20, height: menuBarHeight)
            
            let showExpanded = !trackState.isMinimized && trackState.effectiveMenuBarPixels > 28
            if showExpanded {
                Spacer().frame(width: 6)
                LyricsTextZone()
                    .frame(maxWidth: trackState.effectiveMenuBarPixels - 48, alignment: .leading)
                GapFillView(width: gapWidth)
                    .frame(width: gapWidth, height: menuBarHeight)
                Spacer().frame(width: 6)
            }
        }
        .frame(
            width: trackState.effectiveMenuBarPixels,
            alignment: trackState.effectiveMenuBarPixels > 28 ? .leading : .center
        )
    }
}
