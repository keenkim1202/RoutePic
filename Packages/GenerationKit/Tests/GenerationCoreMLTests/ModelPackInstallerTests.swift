import Foundation
import Testing
@testable import GenerationCoreML

@Suite("Installing a model pack")
struct ModelPackInstallerTests {

    private func slot() -> (URL, ModelPackInstaller) {
        let destination = ModelPackFixture.emptySlot()
        return (destination, ModelPackInstaller(destination: destination))
    }

    @Test("A picked folder becomes an installed pack")
    func installsAPack() async throws {
        let source = try ModelPackFixture.make()
        let (destination, installer) = slot()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        try await installer.install(from: source)

        #expect(await installer.installed()?.controlNetNames == ["lllyasviel_sd-controlnet-scribble"])
        #expect(await installer.installedBytes() == ModelPack.directoryBytes(at: source))
        #expect(await installer.stagedFraction() == nil)
    }

    /// Copying gigabytes and then discovering the folder was wrong is the
    /// failure this ordering exists to prevent.
    @Test("A folder that is not a pack fails before anything is copied")
    func refusesABadSourceWithoutCopying() async throws {
        let source = try ModelPackFixture.make(["notes.txt"])
        let (destination, installer) = slot()
        defer { try? FileManager.default.removeItem(at: source) }

        await #expect(throws: ModelPackProblem.self) { try await installer.install(from: source) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: ModelPack.stagingURL(for: destination).path))
    }

    /// A half-copied pack at the destination would report itself usable and
    /// then fail inside `loadResources()`.
    @Test("Cancelling mid-copy leaves no pack behind")
    func cancellingLeavesNothingInstalled() async throws {
        final class Handle: @unchecked Sendable { var task: Task<Void, any Error>? }

        let source = try ModelPackFixture.make()
        let (destination, installer) = slot()
        defer { try? FileManager.default.removeItem(at: source) }

        let handle = Handle()
        handle.task = Task {
            try await installer.install(from: source) { _ in handle.task?.cancel() }
        }
        await #expect(throws: CancellationError.self) { try await handle.task?.value }

        #expect(await installer.installed() == nil)
        #expect(!FileManager.default.fileExists(atPath: ModelPack.stagingURL(for: destination).path))
    }

    /// Cancelling while the last file is inside a synchronous copy has no next
    /// loop iteration to catch it, so the swap needs its own check.
    @Test("Cancelling on the last file still stops the install")
    func cancellingOnTheLastFileStopsTheSwap() async throws {
        final class Handle: @unchecked Sendable { var task: Task<Void, any Error>? }

        let source = try ModelPackFixture.make()
        let (destination, installer) = slot()
        defer { try? FileManager.default.removeItem(at: source) }

        let total = ModelPack.directoryBytes(at: source)
        let handle = Handle()
        handle.task = Task {
            try await installer.install(from: source) { progress in
                if progress.bytesCopied == total { handle.task?.cancel() }
            }
        }
        await #expect(throws: CancellationError.self) { try await handle.task?.value }

        #expect(await installer.installed() == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Installing over an existing pack replaces it")
    func replacesAnExistingPack() async throws {
        let first = try ModelPackFixture.make(bytesEach: 16)
        let second = try ModelPackFixture.make(ModelPackFixture.chunkedUnet, bytesEach: 32)
        let (destination, installer) = slot()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        try await installer.install(from: first)
        try await installer.install(from: second)

        #expect(await installer.installedBytes() == ModelPack.directoryBytes(at: second))
        #expect(!FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("ControlledUnet.mlmodelc").path
        ))
    }

    /// The pack is reproducible from a conversion the person already ran, so
    /// two gigabytes of it in every backup buys nothing.
    @Test("An installed pack is kept out of backups")
    func installedPackIsExcludedFromBackup() async throws {
        let source = try ModelPackFixture.make()
        let (destination, installer) = slot()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        try await installer.install(from: source)

        let values = try destination.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    /// A copy that lost files still has the right names at the top level, so
    /// only re-inspecting what was written catches it.
    @Test("A truncated copy is not swapped into place")
    func truncatedCopyIsRefused() async throws {
        let source = try ModelPackFixture.make()
        let (destination, installer) = slot()
        let staging = ModelPack.stagingURL(for: destination)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        // Emptied once the last file has landed, which is the moment between
        // the copy loop and the swap — the shape a provider dropping files
        // leaves behind.
        let total = ModelPack.directoryBytes(at: source)
        await #expect(throws: ModelPackProblem.self) {
            try await installer.install(from: source) { progress in
                guard progress.bytesCopied == total else { return }
                try? FileManager.default.removeItem(
                    at: staging.appendingPathComponent("TextEncoder.mlmodelc")
                )
            }
        }

        #expect(await installer.installed() == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    /// The launch sweep and an install both run on this actor, and an install
    /// has awaits in it — so the sweep can land in the middle of one.
    @Test("The launch sweep leaves an install in progress alone")
    func sweepDoesNotDeleteALiveInstall() async throws {
        let source = try ModelPackFixture.make()
        let (destination, installer) = slot()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        try await installer.install(from: source) { _ in
            await installer.discardStaged()
        }

        #expect(await installer.installed() != nil)
    }

    /// A subtree the enumerator cannot read is skipped silently, and a model
    /// missing half its weights would then copy and install as a whole one.
    @Test("An unreadable part of the pack stops the install")
    func unreadableSubtreeStopsTheInstall() async throws {
        let source = try ModelPackFixture.make()
        let (destination, installer) = slot()
        let locked = source.appendingPathComponent("TextEncoder.mlmodelc/weights")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: locked.path
            )
            try? FileManager.default.removeItem(at: source)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: locked.path
        )

        await #expect(throws: (any Error).self) { try await installer.install(from: source) }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: ModelPack.stagingURL(for: destination).path))
    }

    @Test("Removing frees the whole pack")
    func removesEverything() async throws {
        let source = try ModelPackFixture.make()
        let (destination, installer) = slot()
        defer { try? FileManager.default.removeItem(at: source) }

        try await installer.install(from: source)
        try await installer.remove()

        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(await installer.installed() == nil)
        #expect(await installer.installedBytes() == 0)
    }

    /// The swap happens only after a complete copy, so a replacement that
    /// fails has to leave the working pack alone.
    @Test("A failed replacement leaves the installed pack working")
    func aFailedReplacementKeepsTheOldPack() async throws {
        let good = try ModelPackFixture.make()
        let bad = try ModelPackFixture.make(["notes.txt"])
        let (destination, installer) = slot()
        defer {
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: bad)
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        try await installer.install(from: good)
        await #expect(throws: ModelPackProblem.self) { try await installer.install(from: bad) }

        #expect(await installer.installed() != nil)
        #expect(await installer.stagedFraction() == nil)
    }

    @Test("Progress ends at the full size")
    func reportsProgressToCompletion() async throws {
        actor Reports { var last: ModelPackInstaller.Progress?
            func record(_ p: ModelPackInstaller.Progress) { last = p }
        }

        let source = try ModelPackFixture.make(bytesEach: 64)
        let (destination, installer) = slot()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination.deletingLastPathComponent())
        }

        let reports = Reports()
        try await installer.install(from: source) { await reports.record($0) }

        let last = await reports.last
        #expect(last?.fraction == 1)
        #expect(last?.bytesTotal == ModelPack.directoryBytes(at: source))
    }
}
