//
//  DisplayTimer.swift
//  Lychee
//
//  Shared 60fps timer. All callers (AlbumThumb, LyricsEngine) register one callback each.
//  The underlying Timer is created on first registration and destroyed when the last
//  observer unregisters — no timer runs when nothing needs it.
//
//  Must be used from the main thread only.
//

import Foundation

class DisplayTimer {
    static let shared = DisplayTimer()

    private var timer: Timer?
    private var observers: [UUID: () -> Void] = [:]

    private init() {}

    func add(_ callback: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = callback
        if timer == nil { start() }
        return id
    }

    func remove(_ id: UUID) {
        observers.removeValue(forKey: id)
        if observers.isEmpty { stop() }
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.observers.values.forEach { $0() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
