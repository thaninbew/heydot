import AppKit
import AVFoundation
import ServiceManagement

/// System side effects the app needs, injectable so previews and QA renders never touch login items or the microphone.
public struct SystemHooks {
    public var setLaunchAtLogin: (Bool) throws -> Void
    public var launchAtLoginEnabled: () -> Bool
    public var microphoneStatus: () -> AVAuthorizationStatus
    public var requestMicrophone: (@escaping @Sendable (Bool) -> Void) -> Void
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    @MainActor
    public static func live(paths: Paths = Paths()) -> SystemHooks {
        return SystemHooks(
            setLaunchAtLogin: { on in
                guard paths.usesSystemData else { return }
                if on {
                    if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                        try SMAppService.mainApp.register()
                    }
                    if SMAppService.mainApp.status == .requiresApproval {
                        throw NSError(domain: "HeyDot.LoginItem", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "Allow HeyDot in System Settings > General > Login Items, or turn off Open at login."
                        ])
                    }
                } else if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            },
            launchAtLoginEnabled: { paths.usesSystemData && SMAppService.mainApp.status == .enabled },
            microphoneStatus: { AVCaptureDevice.authorizationStatus(for: .audio) },
            requestMicrophone: { done in AVCaptureDevice.requestAccess(for: .audio, completionHandler: done) }
        )
    }
}
