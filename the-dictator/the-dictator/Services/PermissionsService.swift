import AVFoundation
import AppKit
import ApplicationServices
import Foundation

@MainActor
final class PermissionsService {
    private enum MicrophonePermissionState {
        case authorized
        case notDetermined
        case denied
        case restricted
    }

    private let defaults: UserDefaults
    private let firstRunCheckKey = "the_dictator.permissions.first_run_checked.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func runFirstLaunchChecksIfNeeded(notificationService: NotificationService) {
        let isFirstRun = defaults.bool(forKey: firstRunCheckKey) == false
        if isFirstRun {
            defaults.set(true, forKey: firstRunCheckKey)
        }

        switch microphonePermissionState() {
        case .authorized:
            break
        case .notDetermined:
            Task { @MainActor in
                NSApplication.shared.activate(ignoringOtherApps: true)
                let granted = await requestMicrophoneSystemPermission()
                if !granted {
                    self.notifyMicrophoneDenied(notificationService)
                }
            }
        case .denied, .restricted:
            if isFirstRun {
                notificationService.show(
                    title: "The Dictator",
                    body: "Microphone permission is off. Enable it in System Settings > Privacy & Security > Microphone."
                )
            }
        }

        if isFirstRun && !AXIsProcessTrusted() {
            notificationService.show(
                title: "The Dictator",
                body: "Accessibility permission is off. Enable it in System Settings > Privacy & Security > Accessibility."
            )
        }
    }

    func requestMicrophonePermissionForRecording(notificationService: NotificationService) async -> Bool {
        switch microphonePermissionState() {
        case .authorized:
            return true
        case .notDetermined:
            NSApplication.shared.activate(ignoringOtherApps: true)
            let granted = await requestMicrophoneSystemPermission()
            if !granted {
                notifyMicrophoneDenied(notificationService)
            }
            return granted
        case .denied, .restricted:
            notifyMicrophoneDenied(notificationService)
            return false
        }
    }

    func ensureAccessibilityPermission(notificationService: NotificationService) -> Bool {
        if isAccessibilityPermissionGranted() {
            return true
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        notificationService.show(
            title: "The Dictator",
            body: "Accessibility permission is required for paste insertion. Enable it in System Settings > Privacy & Security > Accessibility."
        )

        return false
    }

    private func notifyMicrophoneDenied(_ notificationService: NotificationService) {
        notificationService.show(
            title: "The Dictator",
            body: "Microphone permission is required to record. Enable it in System Settings > Privacy & Security > Microphone."
        )
    }

    func microphonePermissionStatusDescription() -> String {
        switch microphonePermissionState() {
        case .authorized:
            return "Allowed"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        }
    }

    func isAccessibilityPermissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    private func microphonePermissionState() -> MicrophonePermissionState {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return .authorized
            case .undetermined:
                return .notDetermined
            case .denied:
                return .denied
            @unknown default:
                return .denied
            }
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }

    private func requestMicrophoneSystemPermission() async -> Bool {
        if #available(macOS 14.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        return await AVCaptureDevice.requestAccess(for: .audio)
    }
}
