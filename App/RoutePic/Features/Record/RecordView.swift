import CoreLocation
import MapKit
import RouteKit
import RoutePicStore
import ShapeKit
import SwiftUI

struct RecordView: View {

    @Environment(AppEnvironment.self) private var environment
    @State private var selectedMode: RecordingMode = .run
    @State private var savedActivity: Activity?
    @State private var showsDiscardConfirmation = false
    @State private var showsRecoverySheet = false

    private var recorder: RecordingController { environment.recorder }

    var body: some View {
        NavigationStack {
            Group {
                if recorder.isRecording {
                    activeSession
                } else {
                    modeChooser
                }
            }
            .navigationTitle("Record")
            .alert("Recording stopped", isPresented: Binding(
                get: { recorder.interruption != nil },
                set: { if !$0 { recorder.interruption = nil } }
            )) {
                Button("OK") { recorder.interruption = nil }
            } message: {
                Text(recorder.interruption ?? "")
            }
            .task {
                recorder.scanForRecovery()
                showsRecoverySheet = !recorder.recoveryCandidates.isEmpty
            }
            .sheet(item: $savedActivity) { activity in
                ActivitySummarySheet(activity: activity)
            }
            // A real binding, not `.constant`: a constant one can never be set
            // back to false, so the sheet could not be dismissed.
            .sheet(isPresented: $showsRecoverySheet) {
                RecoverySheet(candidates: recorder.recoveryCandidates, recorder: recorder)
                    .interactiveDismissDisabled()
            }
            .onChange(of: recorder.recoveryCandidates.count) { _, count in
                showsRecoverySheet = count > 0
            }
        }
    }

    /// The app lowers its own accuracy here (`DESIGN.md` §14.1) — iOS does not
    /// touch what an app asks Core Location for, so this says what we did.
    static let lowPowerWarning =
        "Low Power Mode is on, so the route is recorded at lower accuracy to save battery."

    // MARK: - Idle

    private var modeChooser: some View {
        VStack(spacing: 32) {
            if let warning = environment.startupWarning {
                WarningBanner(text: warning)
            }
            if recorder.isLowPowerMode { WarningBanner(text: Self.lowPowerWarning) }
            if case .failed(let message) = recorder.phase {
                WarningBanner(text: message)
            }

            Spacer()

            Picker("Mode", selection: $selectedMode) {
                ForEach(RecordingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 32)

            Text(selectedMode.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)

            Button {
                Task { await recorder.start(mode: selectedMode) }
            } label: {
                Text(recorder.phase == .starting ? "Starting…" : "Start")
                    .font(.title2.weight(.semibold))
                    .frame(width: 168, height: 168)
                    .background(Circle().fill(Color.accentColor))
                    .foregroundStyle(.white)
            }
            // A second tap while the permission prompt is open starts a
            // second session on top of the first.
            .disabled(recorder.phase == .starting)
            .accessibilityLabel("Start recording a \(selectedMode.title)")

            Spacer()
        }
    }

    // MARK: - Recording

    private var activeSession: some View {
        VStack(spacing: 0) {
            if recorder.isLowPowerMode { WarningBanner(text: Self.lowPowerWarning) }
            if let warning = recorder.snapshot?.storageWarning {
                WarningBanner(text: "Storage problem — the recording is being kept in memory. \(warning)")
            }
            if recorder.snapshot?.suggestsPause == true {
                PauseSuggestionBanner { Task { await recorder.pause() } }
            }

            LiveRouteMap(snapshot: recorder.snapshot)
                .frame(maxHeight: .infinity)

            statisticsBar

            // DESIGN.md §9 — driving keeps two large controls and nothing else;
            // notes and generation wait until the car has stopped.
            HStack(spacing: 20) {
                Button(recorder.phase == .paused ? "Resume" : "Pause") {
                    Task {
                        recorder.phase == .paused ? await recorder.resume() : await recorder.pause()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(recorder.mode == .drive ? .extraLarge : .large)

                Button("Finish") {
                    Task { savedActivity = await recorder.finish() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(recorder.mode == .drive ? .extraLarge : .large)
            }
            .padding()

            Button("Discard", role: .destructive) { showsDiscardConfirmation = true }
                .font(.footnote)
                .padding(.bottom, 8)
                .confirmationDialog(
                    "Discard this recording?",
                    isPresented: $showsDiscardConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Discard", role: .destructive) { Task { await recorder.discard() } }
                    Button("Keep recording", role: .cancel) {}
                } message: {
                    Text("The route recorded so far will be deleted and cannot be recovered.")
                }
        }
    }

    private var statisticsBar: some View {
        let statistics = recorder.snapshot?.statistics ?? .zero
        return HStack {
            StatisticTile(
                title: "Distance",
                value: CardFormatter.distance(statistics.distanceMeters)
            )
            StatisticTile(
                title: "Moving",
                value: CardFormatter.duration(statistics.movingDuration)
            )
            if recorder.mode != .drive, let pace = statistics.paceSecondsPerKilometre {
                StatisticTile(title: "Pace", value: CardFormatter.pace(pace))
            }
        }
        .padding(.horizontal)
        .font(recorder.mode == .drive ? .title2 : .body)
    }
}

// MARK: - Pieces

struct StatisticTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

struct WarningBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
    }
}

struct PauseSuggestionBanner: View {
    let onPause: () -> Void

    var body: some View {
        HStack {
            Label("You have not moved for a while.", systemImage: "pause.circle")
                .font(.footnote)
            Spacer()
            Button("Pause", action: onPause).font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

/// The live map. Draws each moving run as its own polyline so a dropout is
/// visible as a break rather than being bridged (`DESIGN.md` §5.4).
struct LiveRouteMap: View {
    let snapshot: RecordingSession.Snapshot?

    /// Starts on the user and stays wherever they pan it. Following the route
    /// would fight anyone who moves the map to look ahead.
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)

    var body: some View {
        ZStack {
            Map(position: $camera) {
                UserAnnotation()
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    MapPolyline(coordinates: run)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            if let snapshot, snapshot.pointCount < 2 {
                Text("Waiting for a GPS fix…")
                    .font(.footnote)
                    .padding(8)
                    .background(.thinMaterial, in: Capsule())
            }
        }
        .accessibilityLabel(accessibilityDescription)
    }

    private var runs: [[CLLocationCoordinate2D]] {
        (snapshot?.movingRuns ?? []).map { run in
            run.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
    }

    /// VoiceOver gets the numbers, not the picture — a polyline is nothing to
    /// read out (`DESIGN.md` §9, T-7).
    private var accessibilityDescription: String {
        guard let snapshot, snapshot.pointCount >= 2 else {
            return "Map. Waiting for a GPS fix."
        }
        let gaps = snapshot.gapCount == 0
            ? ""
            : " \(snapshot.gapCount) stretches are missing from the recording."
        return "Map showing the route recorded so far."
            + " \(CardFormatter.distance(snapshot.statistics.distanceMeters)) so far.\(gaps)"
    }
}

extension RecordingMode {
    var explanation: String {
        switch self {
        case .walk: "Records a point every 5 m."
        case .run: "Records a point every 8 m."
        case .drive: "Records a point every 25 m. Controls stay large and notes wait until you stop."
        }
    }
}

extension Activity: @retroactive Identifiable {}
