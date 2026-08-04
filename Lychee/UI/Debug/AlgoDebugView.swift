//
//  AlgoDebugView.swift
//  Lychee
//

#if DEBUG
import SwiftUI

// MARK: - Root

struct AlgoDebugView: View {
    @ObservedObject private var service = LyricsDebugService.shared
    @State private var tab: DebugTab = .performance
    @State private var selectedRunID: UUID?

    enum DebugTab { case algorithm, performance }

    private var selectedRun: DebugRun? {
        if let id = selectedRunID { return service.history.first { $0.id == id } }
        return service.history.first
    }

    var body: some View {
        Group {
            if tab == .algorithm {
                algorithmView
            } else {
                PerformanceView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    Text("Performance").tag(DebugTab.performance)
                    Text("Algorithm").tag(DebugTab.algorithm)
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            if tab == .algorithm {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 6) {
                        if service.isRunning {
                            ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
                            Text("Running…").font(.callout)
                        } else {
                            Text("Auto-runs on track change").font(.callout).foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .onChange(of: service.currentRun?.id) { newID in
            if let id = newID, tab == .algorithm { selectedRunID = id }
        }
        .onAppear {
            if selectedRunID == nil { selectedRunID = service.history.first?.id }
        }
    }

    // MARK: Algorithm tab

    private var algorithmView: some View {
        NavigationSplitView {
            List(service.history, selection: $selectedRunID) { run in
                AlgoRunRow(run: run)
                    .tag(run.id)
            }
            .listStyle(.sidebar)
            .navigationTitle("Runs")
            .frame(minWidth: 190, maxWidth: 240)
            .overlay {
                if service.history.isEmpty {
                    Text("No runs yet").font(.caption).foregroundColor(.secondary.opacity(0.5))
                }
            }
        } detail: {
            if let run = selectedRun {
                DebugRunDetailView(run: run)
            } else {
                Text("Play a song — runs appear automatically")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Algo sidebar row

private struct AlgoRunRow: View {
    let run: DebugRun

    private var agree: Bool {
        let ci = run.current.chosenIndex.flatMap { run.current.candidates[safe: $0] }
        let ii = run.improved.chosenIndex.flatMap { run.improved.candidates[safe: $0] }
        return ci?.trackName == ii?.trackName && ci?.artistName == ii?.artistName
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(agree ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.trackName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(run.artistName.isEmpty ? "Unknown" : run.artistName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Algorithm run detail (unchanged structure)

private struct DebugRunDetailView: View {
    let run: DebugRun

    private var algorithmsAgree: Bool {
        let ci = run.current.chosenIndex.flatMap { run.current.candidates[safe: $0] }
        let ii = run.improved.chosenIndex.flatMap { run.improved.candidates[safe: $0] }
        return ci?.trackName == ii?.trackName && ci?.artistName == ii?.artistName
    }

    var body: some View {
        VStack(spacing: 0) {
            runHeader
            if !algorithmsAgree { disagreementBanner }
            HSplitView {
                AlgorithmPaneView(title: "Current", result: run.current).frame(minWidth: 320)
                AlgorithmPaneView(title: "Improved", result: run.improved).frame(minWidth: 320)
            }
        }
    }

    private var runHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(run.trackName).font(.title2.bold()).lineLimit(1)
                HStack(spacing: 6) {
                    Text(run.artistName.isEmpty ? "Unknown" : run.artistName).foregroundColor(.secondary)
                    if !run.albumName.isEmpty {
                        Text("·").foregroundColor(.secondary.opacity(0.4))
                        Text(run.albumName).foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .font(.callout).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Label("\(run.rawCount) raw responses", systemImage: "server.rack")
                Text(run.timestamp, style: .relative) + Text(" ago")
            }
            .font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
    }

    private var disagreementBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text("Algorithms chose different candidates").font(.callout.weight(.medium))
            Spacer()
            let cn = run.current.chosenIndex.flatMap { run.current.candidates[safe: $0]?.trackName } ?? "none"
            let in_ = run.improved.chosenIndex.flatMap { run.improved.candidates[safe: $0]?.trackName } ?? "none"
            Text("Current: \"\(cn)\"  →  Improved: \"\(in_)\"").font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Algorithm pane

private struct AlgorithmPaneView: View {
    let title: String
    let result: DebugResult

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Color.primary.opacity(0.04))
            Divider()
            statsBar
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    if result.candidates.isEmpty {
                        Text("No candidates").foregroundColor(.secondary).padding(.vertical, 40)
                    } else {
                        ForEach(Array(result.candidates.enumerated()), id: \.element.id) { i, c in
                            CandidateRowView(rank: i + 1, candidate: c, isChosen: i == result.chosenIndex)
                            Divider().padding(.leading, 14)
                        }
                    }
                }
            }
        }
    }

    private var statsBar: some View {
        HStack(spacing: 8) {
            chip("\(result.candidates.filter { $0.isSynced }.count) synced", .blue)
            chip("\(result.candidates.filter { !$0.isSynced }.count) plain", .orange)
            if result.groupedCount > 0 { chip("\(result.groupedCount) merged", .purple) }
            if result.removedNonPreferredCount > 0 { chip("\(result.removedNonPreferredCount) filtered", .red) }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func chip(_ label: String, _ color: Color) -> some View {
        Text(label).font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12)).foregroundColor(color).cornerRadius(6)
    }
}

// MARK: - Candidate row

private struct CandidateRowView: View {
    let rank: Int
    let candidate: DebugCandidate
    let isChosen: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 10) {
                    Text("#\(rank)").font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 30, height: 22)
                        .foregroundColor(isChosen ? .white : .secondary)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(isChosen ? Color.accentColor : Color.primary.opacity(0.07)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(candidate.trackName.isEmpty ? "(no title)" : candidate.trackName)
                            .font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !candidate.artistName.isEmpty {
                            Text(candidate.artistName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(candidate.isSynced ? "synced" : "plain")
                        .font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background((candidate.isSynced ? Color.blue : Color.orange).opacity(0.13))
                        .foregroundColor(candidate.isSynced ? .blue : .orange).cornerRadius(4)
                    Text("\(candidate.totalScore)").font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundColor(isChosen ? .accentColor : .secondary).frame(minWidth: 36, alignment: .trailing)
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.45))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.14), value: expanded)
                }
                .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isChosen ? Color.accentColor.opacity(0.05) : Color.clear)

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    scoreBreakdown
                    lyricsPreview
                }
                .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 12)
                .background(Color.primary.opacity(0.025))
                .transition(.opacity.combined(with: .move(edge: .top)))
                .animation(.easeInOut(duration: 0.14), value: expanded)
            }
        }
    }

    private var scoreBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Score breakdown  (base: 100)").font(.caption2).foregroundColor(.secondary.opacity(0.6))
            HStack(spacing: 0) {
                cell("Lang",     candidate.languageScore,  .green)
                cell("Title",    candidate.titleScore,     .blue)
                cell("Artist",   candidate.artistScore,    .purple)
                cell("Duration", candidate.durationScore,  .orange)
                cell("Source",   candidate.sourceScore,    .cyan)
                Divider().frame(height: 30).padding(.horizontal, 8)
                VStack(spacing: 2) {
                    Text("\(candidate.totalScore)").font(.caption.monospacedDigit().weight(.bold))
                    Text("Total").font(.system(size: 9)).foregroundColor(.secondary.opacity(0.65))
                }.frame(width: 48).padding(.vertical, 6)
            }
            .background(Color.primary.opacity(0.04)).cornerRadius(7)
        }
    }

    private func cell(_ label: String, _ score: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(score > 0 ? "+\(score)" : score < 0 ? "\(score)" : "0")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundColor(score > 0 ? color : score < 0 ? .red : .secondary.opacity(0.4))
            Text(label).font(.system(size: 9)).foregroundColor(.secondary.opacity(0.65))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 6)
    }

    private var lyricsPreview: some View {
        Group {
            if !candidate.lrcPreview.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview").font(.caption2).foregroundColor(.secondary.opacity(0.6))
                    ScrollView(.vertical) {
                        Text(candidate.lrcPreview).font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.75))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    .frame(maxHeight: 120).background(Color.primary.opacity(0.04)).cornerRadius(6)
                }
            }
        }
    }
}

// MARK: - Performance tab

private struct PerformanceView: View {
    @ObservedObject private var service = LyricsDebugService.shared
    private let col = PerfColumns()

    private var hasAnyData: Bool {
        !service.currentSession.records.isEmpty || !service.pastSessions.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            tableHeader
            Divider()
            if !hasAnyData {
                VStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 40)).foregroundColor(.secondary.opacity(0.3))
                    Text("Waiting for a song…")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        // Current session
                        Section {
                            ForEach(service.currentSession.records) { rec in
                                PerfRow(rec: rec, col: col) {
                                    service.deleteCurrentRecord(id: rec.id)
                                }
                                Divider().padding(.leading, 14)
                            }
                        } header: {
                            SessionHeader(
                                session: service.currentSession,
                                isLive: true,
                                onDelete: nil
                            )
                        }

                        // Past sessions
                        ForEach(service.pastSessions) { session in
                            Section {
                                ForEach(session.records) { rec in
                                    PerfRow(rec: rec, col: col, onDelete: nil)
                                    Divider().padding(.leading, 14)
                                }
                            } header: {
                                SessionHeader(
                                    session: session,
                                    isLive: false,
                                    onDelete: { service.deletePastSession(id: session.id) }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("Track")    .frame(maxWidth: .infinity, alignment: .leading)
            Text("Source")   .frame(width: col.source,   alignment: .leading)
            Text("Algo")     .frame(width: col.algo,     alignment: .leading)
            Text("Time")     .frame(width: col.detected, alignment: .leading)
            Text("Speed")    .frame(width: col.speed,    alignment: .leading)
            Text("Outcome")  .frame(width: col.outcome,  alignment: .leading)
            Text("Cands")    .frame(width: col.cands,    alignment: .trailing)
            Spacer().frame(width: col.del)
        }
        .font(.caption.weight(.semibold)).foregroundColor(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.primary.opacity(0.04))
    }
}

// Column widths in one place so header and rows stay aligned
private struct PerfColumns {
    let source:   CGFloat = 80
    let algo:     CGFloat = 66
    let detected: CGFloat = 62
    let speed:    CGFloat = 60
    let outcome:  CGFloat = 74
    let cands:    CGFloat = 44
    let del:      CGFloat = 30
}

// MARK: - Session header

private struct SessionHeader: View {
    let session: PerformanceSession
    let isLive: Bool
    let onDelete: (() -> Void)?
    @State private var hovered = false

    private var dateStr: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: session.startedAt)
    }
    private var timeRange: String {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
        let start = f.string(from: session.startedAt)
        if let end = session.endedAt { return "\(start) – \(f.string(from: end))" }
        return "Started \(start)"
    }
    private var durationStr: String {
        guard let d = session.duration else { return "" }
        return "· \(PerformanceSession.durationString(d))"
    }

    var body: some View {
        HStack(spacing: 8) {
            if isLive {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Current session").font(.caption.weight(.semibold))
            } else {
                Text(dateStr).font(.caption.weight(.semibold))
            }
            Text(timeRange).font(.caption).foregroundColor(.secondary)
            Text(durationStr).font(.caption).foregroundColor(.secondary.opacity(0.7))
            Text("· \(session.records.count) records").font(.caption).foregroundColor(.secondary.opacity(0.7))
            Spacer()
            if isLive {
                Button("Clear") {
                    LyricsDebugService.shared.clearCurrentSession()
                }
                .font(.caption).foregroundColor(.red.opacity(0.7)).buttonStyle(.plain)
            } else if let del = onDelete {
                Button(action: del) {
                    Image(systemName: "trash").font(.system(size: 10))
                        .foregroundColor(.red.opacity(hovered ? 0.8 : 0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.95))
        .onHover { hovered = $0 }
    }
}

// MARK: - Perf row

private struct PerfRow: View {
    let rec: PerformanceRecord
    let col: PerfColumns
    let onDelete: (() -> Void)?
    @State private var hovered = false

    private var speedColor: Color {
        guard let t = rec.timeToLyrics else { return .secondary }
        if t < 1.5 { return .green }
        if t < 4.0 { return .yellow }
        return .red
    }
    private var outcomeColor: Color {
        switch rec.outcome {
        case .pending:          return .secondary
        case .synced:           return .green
        case .plain:            return .orange
        case .notFound, .error: return .red
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.trackName.isEmpty ? "Loading…" : rec.trackName)
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                if !rec.artistName.isEmpty {
                    Text(rec.artistName).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(rec.source).font(.caption).foregroundColor(.secondary)
                .frame(width: col.source, alignment: .leading).lineLimit(1)
            Text(rec.algoVersion).font(.caption).foregroundColor(.secondary)
                .frame(width: col.algo, alignment: .leading).lineLimit(1)
            Text(rec.detectedAt, style: .time).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: col.detected, alignment: .leading)

            Group {
                if rec.outcome == .pending {
                    ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                } else {
                    Text(rec.timeToLyrics.map { String(format: "%.1fs", $0) } ?? "—")
                        .font(.caption.monospacedDigit().weight(.semibold)).foregroundColor(speedColor)
                }
            }
            .frame(width: col.speed, alignment: .leading)

            Text(rec.outcome.label).font(.caption.weight(.medium)).foregroundColor(outcomeColor)
                .frame(width: col.outcome, alignment: .leading)
            Text(rec.outcome == .pending ? "—" : "\(rec.candidateCount)")
                .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                .frame(width: col.cands, alignment: .trailing)

            if let del = onDelete {
                Button(action: del) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary.opacity(hovered ? 0.7 : 0))
                }
                .buttonStyle(.plain).frame(width: col.del, alignment: .trailing)
            } else {
                Spacer().frame(width: col.del)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(hovered ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { hovered = $0 }
    }
}

// MARK: - Helpers

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
