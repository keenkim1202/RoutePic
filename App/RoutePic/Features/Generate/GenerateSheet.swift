import GenerationKit
import RoutePicStore
import SwiftUI

/// Picks a subject, runs one generation, and keeps the result.
///
/// §7.2 — the sentence explaining *why* a subject was proposed sits next to it
/// rather than hidden: "this is your route" is the claim the feature rests on,
/// and the user is the one judging it.
struct GenerateSheet: View {

    let activity: Activity

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: GenerationCoordinator?
    @State private var showsRouteOverlay = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Group {
                switch coordinator?.phase ?? .idle {
                case .idle:
                    ProgressView("Looking at the shape…")
                case .unavailable(let reason):
                    ContentUnavailableView(
                        "No picture for this one",
                        systemImage: "scribble.variable",
                        description: Text(reason)
                    )
                case .ready(let subjects):
                    subjectPicker(subjects)
                case .running:
                    running
                case .finished(let candidates):
                    results(candidates)
                case .failed(let message):
                    ContentUnavailableView(
                        "That did not work",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                }
            }
            .navigationTitle("Make a picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        coordinator?.cancel()
                        dismiss()
                    }
                }
            }
            .alert("Could not save", isPresented: Binding(
                get: { saveError != nil }, set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
        .task {
            let made = environment.makeGenerationCoordinator()
            coordinator = made
            await made.prepare(for: activity)
        }
    }

    private func subjectPicker(_ subjects: [SubjectCandidate]) -> some View {
        VStack(spacing: 16) {
            RouteThumbnail(activity: activity)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxHeight: 220)

            List(subjects, id: \.subject) { candidate in
                Button {
                    coordinator?.select(candidate)
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.subject).font(.headline)
                            Text(candidate.why)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if coordinator?.subject == candidate {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)

            Button("Make it") { coordinator?.generate(for: activity) }
                .buttonStyle(.borderedProminent)
                .padding(.bottom)
        }
    }

    private var running: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Drawing on this device. Nothing leaves your phone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Cancel") { coordinator?.cancel() }
        }
        .padding()
    }

    private func results(_ candidates: [GeneratedCandidate]) -> some View {
        VStack(spacing: 12) {
            Toggle("Show the route over it", isOn: $showsRouteOverlay)
                .padding(.horizontal)

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(candidates, id: \.imageURL) { candidate in
                        VStack(spacing: 8) {
                            ZStack {
                                if let data = try? Data(contentsOf: candidate.imageURL),
                                   let image = PlatformImage.from(data) {
                                    image.resizable().scaledToFit()
                                }
                                if showsRouteOverlay {
                                    RouteThumbnail(activity: activity)
                                        .blendMode(.screen)
                                        .opacity(0.8)
                                }
                            }
                            .frame(width: 260, height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                            Text(candidate.why)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 260)

                            Button("Keep this one") { save(candidate) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func save(_ candidate: GeneratedCandidate) {
        do {
            try coordinator?.save(candidate, to: activity)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
