import SwiftUI
import AppKit

extension Notification.Name {
    static let lycheeSettingsTabChanged = Notification.Name("lycheeSettingsTabChanged")
}

// MARK: - Settings Window

struct SettingsView: View {
    enum Tab { case customize, about, story }
    @State private var selectedTab: Tab = .customize

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if selectedTab == .customize {
                CustomizeTabContent()
            } else if selectedTab == .about {
                AboutTabContent()
            } else {
                StoryTabContent()
            }
        }
        .frame(width: 480)
        .background(Color(NSColor.windowBackgroundColor))
        .lycheeWindowTheme()
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            Spacer()
            SettingsTabButton(
                title: "Customize", icon: "slider.horizontal.3",
                isSelected: selectedTab == .customize
            ) {
                selectedTab = .customize
                NotificationCenter.default.post(name: .lycheeSettingsTabChanged, object: nil)
            }
            SettingsTabButton(
                title: "About", icon: "info.circle",
                isSelected: selectedTab == .about
            ) {
                selectedTab = .about
                NotificationCenter.default.post(name: .lycheeSettingsTabChanged, object: nil)
            }
            SettingsTabButton(
                title: "A word", icon: "person.circle",
                isSelected: selectedTab == .story
            ) {
                selectedTab = .story
                NotificationCenter.default.post(name: .lycheeSettingsTabChanged, object: nil)
            }
            Spacer()
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

// MARK: - Tab Button

private struct SettingsTabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(width: 76, height: 50)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? Color.accentColor.opacity(0.1)
                          : isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
        .onHover { isHovered = $0 }
    }
}

// MARK: - Info Button

private struct InfoButton: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button(action: { isShowing.toggle() }) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(12)
                .frame(maxWidth: 240)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Setting Row  (label ~30% | control ~70%)

private struct SettingRow<Content: View>: View {
    let title: String
    let tooltip: String?
    let alignment: VerticalAlignment
    let content: Content

    init(
        title: String,
        tooltip: String? = nil,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.tooltip = tooltip
        self.alignment = alignment
        self.content = content()
    }

    var body: some View {
        HStack(alignment: alignment, spacing: 16) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13))
                if let tooltip {
                    InfoButton(text: tooltip)
                }
            }
            .frame(width: 130, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 5)
    }
}

// MARK: - Cache Time Range

private enum CacheTimeRange: String, CaseIterable, Identifiable {
    case hour1  = "Last hour"
    case hours5 = "Last 5 hours"
    case today  = "Today"
    case week   = "This week"
    case all    = "All time"

    var id: String { rawValue }

    var cutoffDate: Date? {
        let cal = Calendar.current
        switch self {
        case .hour1:  return Date().addingTimeInterval(-3_600)
        case .hours5: return Date().addingTimeInterval(-18_000)
        case .today:  return cal.startOfDay(for: Date())
        case .week:   return cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date()))
        case .all:    return nil
        }
    }
}

// MARK: - Customize Tab

private struct CustomizeTabContent: View {
    @ObservedObject var trackState = TrackState.shared
    @State private var cacheTimeRange: CacheTimeRange = .hour1
    @State private var cacheCleared = false
    #if DEBUG
    @State private var onboardingDone = AppDelegate.hasCompletedOnboardingForCurrentBuild
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            gapStyleSection
                .padding(.bottom, 10)
            Divider()
            settingsTableSection
                .padding(.top, 4)
                .padding(.bottom, 4)
            Divider()
            dataSection
                .padding(.top, 16)
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(width: 480)
    }

    // MARK: Gap Style — 2×2 grid

    private var gapStyleSection: some View {
        HStack(alignment: .top, spacing: 16) {
            HStack(spacing: 4) {
                Text("Gap Style")
                    .font(.system(size: 13))
                InfoButton(text: "Fills the space between lyrics and the right edge of the menu bar.")
            }
            .frame(width: 130, alignment: .topLeading)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                ForEach([TrackState.GapStyle.none, .dots, .fade, .wave], id: \.self) { style in
                    GapStylePreviewCard(
                        style: style,
                        isSelected: trackState.gapStyle == style
                    ) {
                        trackState.setGapStyle(style)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 5)
    }

    // MARK: Settings Table

    private var settingsTableSection: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Theme has no tooltip — self-explanatory
            SettingRow(title: "Theme") {
                HStack(spacing: 16) {
                    ForEach(TrackState.PopoverTheme.allCases, id: \.self) { theme in
                        radioButton(label: theme.rawValue, isSelected: trackState.popoverTheme == theme) {
                            trackState.setPopoverTheme(theme)
                        }
                    }
                }
                .frame(height: 24)
            }

            SettingRow(title: "Menu Bar Size",
                       tooltip: "Width of Lychee's presence in the menu bar when expanded.") {
                HStack(spacing: 16) {
                    ForEach(TrackState.MenuBarWidth.allCases, id: \.self) { width in
                        radioButton(label: width.rawValue, isSelected: trackState.menuBarWidth == width) {
                            trackState.setMenuBarWidth(width)
                        }
                    }
                }
                .frame(height: 24)
            }

            SettingRow(title: "Inactivity",
                       tooltip: "Hide the menu bar display after this long without music playing.") {
                Picker("", selection: Binding(
                    get: { trackState.inactivityTimeout },
                    set: { trackState.setInactivityTimeout($0) }
                )) {
                    ForEach(TrackState.InactivityTimeout.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 110)
                .frame(height: 24)
                .padding(.leading, -8)
            }

            SettingRow(title: "Text Size",
                       tooltip: "Size of lyrics text in the mini player.") {
                fontSizeSlider
                    .frame(maxWidth: 210)
                    .frame(height: 24)
            }
        }
    }

    private var fontSizeSlider: some View {
        let cases = TrackState.LyricsFontSize.allCases
        let binding = Binding<Double>(
            get: { Double(cases.firstIndex(of: trackState.lyricsFontSize) ?? 1) },
            set: { v in
                let idx = Int(v.rounded())
                if cases.indices.contains(idx) { trackState.setLyricsFontSize(cases[idx]) }
            }
        )
        return Slider(value: binding, in: 0...Double(cases.count - 1), step: 1)
    }

    // MARK: Data

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if DEBUG
            SettingRow(
                title: "Onboarding Done?",
                tooltip: "Toggle onboarding completion for this build."
            ) {
                Toggle("", isOn: Binding(
                    get: { onboardingDone },
                    set: { value in
                        onboardingDone = value
                        AppDelegate.setOnboardingCompletedForCurrentBuild(value)
                    }
                ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .frame(height: 24)
            }
            #endif
            SettingRow(
                title: "Clear Cache",
                tooltip: "Delete locally saved lyrics. Cleared songs will be re-fetched from the network on next play."
            ) {
                HStack(spacing: 8) {
                    if cacheCleared {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.green.opacity(0.8))
                        Text("Cleared lyrics from \(cacheTimeRange.rawValue.lowercased()).")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    } else {
                        Picker("", selection: $cacheTimeRange) {
                            ForEach(CacheTimeRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(maxWidth: 130)
                        .padding(.leading, -8)

                        Button(action: clearCacheForRange) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash").font(.system(size: 11))
                                Text("Delete").font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.red.opacity(0.06))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.red.opacity(0.2), lineWidth: 0.5)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                        .lycheeFocusEffectDisabled()
                    }
                }
                .frame(height: 24)
                .animation(.easeInOut(duration: 0.18), value: cacheCleared)
            }
        }
    }

    private func clearCacheForRange() {
        LyricsCache.shared.clearEntries(savedSince: cacheTimeRange.cutoffDate)
        TrackState.shared.savedCandidateLRC = nil
        withAnimation { cacheCleared = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { cacheCleared = false }
        }
    }

    private func radioButton(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                Text(label)
                    .font(.system(size: 12))
                    .foregroundColor(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
    }
}

// MARK: - Gap Style Preview Card

private struct GapStylePreviewCard: View {
    let style: TrackState.GapStyle
    let isSelected: Bool
    let action: () -> Void
    @ObservedObject private var trackState = TrackState.shared
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var isHovered = false

    private var isDark: Bool {
        switch trackState.popoverTheme {
        case .dark:   return true
        case .light:  return false
        case .system: return systemColorScheme == .dark
        }
    }

    private var mockupBg:    Color { isDark ? Color(white: 0.10) : Color(white: 0.88) }
    private var mockupFg:    Color { isDark ? .white : Color(white: 0.12) }
    private var mockupFgDim: Color { isDark ? Color.white.opacity(0.85) : Color(white: 0.12).opacity(0.72) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                menuBarMockup
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(
                                isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
                Text(style.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .lycheeFocusEffectDisabled()
        .onHover { isHovered = $0 }
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
    }

    private var menuBarMockup: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(mockupBg)
            HStack(spacing: 0) {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.purple.opacity(0.9), Color.pink.opacity(0.9)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 11, height: 11)
                Spacer().frame(width: 4)
                Text("♪ In the stars")
                    .font(.system(size: 8))
                    .foregroundColor(mockupFgDim)
                    .fixedSize().lineLimit(1)
                Spacer().frame(width: 4)
                // GeometryReader fills all remaining space → gap fill reaches exactly to 8px from right edge
                GeometryReader { geo in
                    gapPreview(width: geo.size.width)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 38)
    }

    @ViewBuilder
    private func gapPreview(width: CGFloat) -> some View {
        if width >= 4 {
            switch style {
            case .none:
                Color.clear
            case .dots:
                HStack(spacing: 3) {
                    ForEach(0..<max(1, Int(width / 7)), id: \.self) { _ in
                        Text("·").font(.system(size: 7)).foregroundColor(mockupFg.opacity(0.3))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .fade:
                LinearGradient(
                    colors: [.clear, mockupFg.opacity(0.4)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 1).frame(maxHeight: .infinity, alignment: .center)
            case .wave:
                GapFillView.WavePath(width: width)
                    .stroke(mockupFg, lineWidth: 0.75)
                    .mask(LinearGradient(
                        colors: [.white.opacity(0.1), .white],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(height: 6).frame(maxHeight: .infinity, alignment: .center)
            }
        } else {
            Color.clear
        }
    }
}

// MARK: - About Tab

private struct AboutTabContent: View {
    @State private var autoCheck = true
    @State private var analyticsEnabled = TelemetryService.shared.isEnabled
    @State private var isCheckForUpdatesHovered = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                Text("Lychee")
                    .font(.system(size: 22, weight: .semibold))
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("Lyrics in menu bar.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 48)
                Button(action: {
                    if let url = URL(string: "https://tally.so/r/2E1J5V") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Send Feedback")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)

            Divider()

            HStack(spacing: 4) {
                Text("Usage Analytics")
                    .font(.system(size: 13, weight: .medium))
                InfoButton(text: "Lychee only collects a few anonymous numbers to see how many people are using it, how often it finds synced, plain, or no lyrics, and roughly how quickly results appear. That helps improve the lyrics algorithm.\n\nLychee never collects what you're listening to, your searches, lyrics, exact lookup times, account, location, or any personal information. But if you're a spy and prefer to leave no trace, feel free to turn this off.")
                Spacer()
                Toggle("", isOn: $analyticsEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: analyticsEnabled) { enabled in
                        TelemetryService.shared.setEnabled(enabled)
                    }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                Button(action: { AppDelegate.shared?.checkForUpdates() }) {
                    Text("Check for Updates")
                        .underline()
                        .foregroundStyle(isCheckForUpdatesHovered ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .focusable(false)
                .onHover { isHovered in
                    isCheckForUpdatesHovered = isHovered
                    if isHovered {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
                Spacer()
                Toggle(isOn: $autoCheck) {
                    Text("Auto-check")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: autoCheck) { newValue in
                    AppDelegate.shared?.automaticallyChecksForUpdates = newValue
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
        .onAppear {
            autoCheck = AppDelegate.shared?.automaticallyChecksForUpdates ?? true
        }
    }
}

// MARK: - Story Tab

private struct StoryTabContent: View {
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {

                Text("Hi, \nI'm Rishabh Gangwar, a UX Designer \nbased in India. \nI like listening to new music while I work \nbut I hate having to switch back to Spotify \nevery time I want to check the lyrics.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                    .padding(.top, 16)

                Text("Obvious solution?")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 6) {
                    Text("✗  Stop distracting myself while working.")
                    Text("✓  Build a menu bar lyrics app.")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 16)

                Text("And then there was Lychee. It has come a long way from a lunch break vibe-coding experiment. Thanks to everyone who tried it. ")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)

                Text("Lychee is free to use and will stay that way.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom,16)
                    
                Text("But if it's brought something to your listening qualia and you wanna support more such fun apps in the future, consider contributing to \nnext month's Claude subscription ;)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom,20)
            

                Button(action: {
                    if let url = URL(string: "https://paypal.me/rishabh37") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "heart")
                            .font(.system(size: 12))
                        Text("Paypal")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            .padding(.horizontal, 88)
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .frame(width: 480)
    }
}
