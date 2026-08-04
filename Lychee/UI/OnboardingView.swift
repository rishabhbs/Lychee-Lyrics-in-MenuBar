import SwiftUI
import AppKit

// MARK: - Notification

extension Notification.Name {
    static let lycheeOnboardingWillShow = Notification.Name("lycheeOnboardingWillShow")
}

// MARK: - Onboarding View

struct OnboardingView: View {
    var onDismiss: () -> Void

    private let brandRed = Color(red: 0.914, green: 0.302, blue: 0.282)
    private let horizontalRuler: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .padding(.top, 56)
                    .padding(.bottom, 12)

                Text("Welcome to Lychee")
                    .font(.system(size: 24, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 6)

                Text("Lyrics in your menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)

            howItWorksSection

            Spacer(minLength: 8)

            Button(action: handleLetsGo) {
                Text("Let's go")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(brandRed)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusable(false)
            .padding(.horizontal, horizontalRuler)
            .padding(.top, 12)
            .padding(.bottom, 56)
        }
        .frame(width: 360, height: 420)
        .background(Color(NSColor.windowBackgroundColor))
        .lycheeWindowTheme()
    }

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HOW IT WORKS")
                .font(.system(size: 10, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .kerning(1.2)

            OnboardingStep(
                symbol: "checkmark",
                title: "Open Lychee",
                text: "Done already. Good job.",
                accent: brandRed
            )
            OnboardingStep(
                symbol: "music.note",
                title: "Open Spotify/Apple Music",
                text: "Lychee checks what's playing.",
                accent: brandRed
            )
            OnboardingStep(
                symbol: "text.quote",
                title: "Lyrics show up in the menu bar",
                text: "Lychee pulls the best match from LRCLIB.",
                accent: brandRed
            )
        }
        .padding(.horizontal, horizontalRuler)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleLetsGo() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.completeOnboardingAndOpenPopover()
        } else {
            AppDelegate.setOnboardingCompletedForCurrentBuild(true)
            DispatchQueue.main.async { onDismiss() }
        }
    }
}

// MARK: - Onboarding Step

private struct OnboardingStep: View {
    let symbol: String
    let title: String
    let text: String
    let accent: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.11))
                    .frame(width: 34, height: 34)
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.system(size: 12, weight: .light))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(minHeight: 42, alignment: .leading)
    }
}
