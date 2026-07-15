// Sources/RiptideApp/Downloads/ReadyNotifier.swift
import AppKit
import UserNotifications

/// Thin UNUserNotificationCenter wrapper. The unbundled run.sh binary has no
/// bundle identity and UNUserNotificationCenter.current() aborts there
/// ("bundleProxyForCurrentProcess is nil"), so every call sits behind
/// `isSupported` and degrades to the in-app toast via `fallback`.
@MainActor
final class ReadyNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let isSupported = Bundle.main.bundleURL.pathExtension == "app"

    var onClick: (() -> Void)?
    var fallback: ((String) -> Void)?
    private var authRequested = false

    /// Lazy auth: called on the first observed active transfer, not at launch.
    func requestAuthorizationIfNeeded() {
        guard Self.isSupported, !authRequested else { return }
        authRequested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyReady(name: String) {
        let message = "'\(name)' is ready to stream"
        guard Self.isSupported else {
            fallback?(message)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Download ready"
        content.body = message
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString,
                                  content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        // Complete only after the click handler has run — signalling done
        // early lets the OS suspend the app before navigation happens.
        Task { @MainActor in
            self.onClick?()
            completionHandler()
        }
    }

    // Banners should show while the app is frontmost too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
