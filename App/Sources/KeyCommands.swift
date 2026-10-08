import UIKit

/// ⌘↩ while the composer is focused. The multi-line message field is a UITextView: it swallows ⌘↩ (no newline,
/// no send) before SwiftUI's `.keyboardShortcut` / `.onKeyPress` can see it — measured on iOS 26.4 with a hardware
/// keyboard. A UIKeyCommand at the END of the responder chain with `wantsPriorityOverSystemBehavior` wins over the
/// text system; it posts `.looplSendShortcut`, which the composer turns into a send (only when Send is enabled).
final class LooplAppDelegate: UIResponder, UIApplicationDelegate {
    override var keyCommands: [UIKeyCommand]? {
        let send = UIKeyCommand(title: "Send", action: #selector(sendShortcut), input: "\r", modifierFlags: .command)
        send.wantsPriorityOverSystemBehavior = true
        return [send]
    }
    @objc func sendShortcut() { NotificationCenter.default.post(name: .looplSendShortcut, object: nil) }
}

extension Notification.Name { static let looplSendShortcut = Notification.Name("loopl.sendShortcut") }
