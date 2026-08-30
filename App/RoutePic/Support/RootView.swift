import RouteKit
import RoutePicStore
import SwiftUI

struct RootView: View {

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            RecordView()
                .tabItem { Label("Record", systemImage: "record.circle") }
            CollectionView()
                .tabItem { Label("Collection", systemImage: "square.grid.2x2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .task { environment.runMaintenance() }
        .onChange(of: scenePhase) { _, phase in
            // Backgrounding is the moment before the app is most likely to be
            // killed, so the journal is forced to disk here (`DESIGN.md` §5.4).
            if phase != .active {
                Task { await environment.recorder.flush() }
            }
        }
    }
}

/// Offers unfinished recordings back to the user.
///
/// `DESIGN.md` §5.4 — the wording separates what was recovered from what was
/// never recorded, because the second is not something the app can fix.
struct RecoverySheet: View {

    let candidates: [SessionRecovery.Candidate]
    let recorder: RecordingController

    var body: some View {
        NavigationStack {
            List(candidates, id: \.url) { candidate in
                VStack(alignment: .leading, spacing: 8) {
                    Text(candidate.mode.title).font(.headline)
                    Text(
                        "\(CardFormatter.distance(candidate.statistics.distanceMeters))"
                        + " · \(CardFormatter.duration(candidate.statistics.movingDuration))"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    if candidate.gapCount > 0 {
                        Text("\(candidate.gapCount) stretch(es) were not recorded and cannot be recovered.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if candidate.hadDamagedTail {
                        Text("The very end of this recording was lost.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Keep") { recorder.restore(candidate) }
                            .buttonStyle(.borderedProminent)
                        Button("Discard", role: .destructive) { recorder.dismiss(candidate) }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 6)
            }
            .navigationTitle("Unfinished recordings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Shown after a session ends.
struct ActivitySummarySheet: View {

    let activity: Activity
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                RouteThumbnail(activity: activity)
                    .aspectRatio(1, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(.horizontal)

                HStack {
                    StatisticTile(
                        title: "Distance",
                        value: CardFormatter.distance(activity.distanceMeters)
                    )
                    StatisticTile(
                        title: "Moving",
                        value: CardFormatter.duration(activity.movingDuration)
                    )
                }

                Spacer()
            }
            .padding(.top)
            .navigationTitle("Saved")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
