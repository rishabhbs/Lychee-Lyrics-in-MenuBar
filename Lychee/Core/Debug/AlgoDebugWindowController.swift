//
//  AlgoDebugWindowController.swift
//  Lychee
//
//  Opens a standalone NSWindow (not a popover) for the algorithm debug UI.
//  Manages activation policy so the window behaves like a real app window
//  while visible, then reverts to accessory mode on close.
//

#if DEBUG
import AppKit
import SwiftUI

final class AlgoDebugWindowController: NSObject, NSWindowDelegate {
    static let shared = AlgoDebugWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Lychee — Algorithm Debug"
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 800, height: 520)
            w.contentView = NSHostingView(rootView: AlgoDebugView())
            w.delegate = self
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
#endif
