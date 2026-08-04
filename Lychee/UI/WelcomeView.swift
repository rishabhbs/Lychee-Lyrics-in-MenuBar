import SwiftUI
import AppKit

extension Notification.Name {
    static let lycheeWelcomeWillShow = Notification.Name("lycheeWelcomeWillShow")
}

struct WelcomeView: View {
    var onDismiss: () -> Void

    @State private var message = WelcomeMessageSystem.pick()

    private let brandRed = Color(red: 0.914, green: 0.302, blue: 0.282)

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 36)
                .padding(.horizontal, 36)
                .padding(.bottom, 32)

            VStack(spacing: 10) {
                Button(action: openPayPal) {
                    Text("Support with PayPal")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(brandRed)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .focusable(false)

                Button(action: openFeedback) {
                    Text("Send feedback")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(Color.primary.opacity(0.11), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 18)

            Button("Maybe later") {
                DispatchQueue.main.async { onDismiss() }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.tertiary)
            .focusable(false)
            .padding(.bottom, 28)
        }
        .frame(width: 420, height: 390)
        .background(Color(NSColor.windowBackgroundColor))
        .lycheeWindowTheme()
        .onReceive(NotificationCenter.default.publisher(for: .lycheeWelcomeWillShow)) { _ in
            message = WelcomeMessageSystem.pick(excluding: message)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 52, height: 52)
                .padding(.bottom, 12)

            Text("Enjoying Lychee?")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 16)

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openFeedback() {
        if let url = URL(string: "https://tally.so/r/2E1J5V") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openPayPal() {
        if let url = URL(string: "https://paypal.me/rishabh37") {
            NSWorkspace.shared.open(url)
        }
    }
}
