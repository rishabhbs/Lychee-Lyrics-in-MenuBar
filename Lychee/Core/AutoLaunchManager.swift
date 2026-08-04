//
//  AutoLaunchManager.swift
//  Lychee
//
//  Registers the app as a login item using SMAppService
//

import ServiceManagement

class AutoLaunchManager {
    static func enable() {
        do {
            try SMAppService.mainApp.register()
            lycheeDebugLog("[AutoLaunch] Registered as login item")
        } catch {
            lycheeDebugLog("[AutoLaunch] Failed: \(error)")
        }
    }
}
