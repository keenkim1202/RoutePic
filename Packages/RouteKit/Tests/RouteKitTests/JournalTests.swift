import Foundation
import ShapeKit
import Testing
@testable import RouteKit

@Suite("SessionJournal")
struct JournalTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("routepic-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("session.jrn")
    }

    @Test("A written journal reads back with every record intact")
    func roundTrip() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let id = UUID()
        let journal = try SessionJournal(url: url)
        journal.append(.header(sessionID: id, mode: .run, startedAt: Sim.epoch))
        for fix in Sim.straightWalk(count: 30) {
            journal.append(.fix(fix), now: fix.timestamp)
        }
        journal.close()

        let recovered = try JournalReader.read(contentsOf: url)
        #expect(recovered.sessionID == id)
        #expect(recovered.mode == .run)
        #expect(recovered.route.points.count == 30)
        #expect(!recovered.sawCorruption)
        #expect(recovered.discardedTailBytes == 0)
    }

    @Test("Coordinates survive the journal round-trip exactly")
    func coordinateFidelity() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let fixes = Sim.straightWalk(count: 10)
        let journal = try SessionJournal(url: url)
        for fix in fixes { journal.append(.fix(fix), now: fix.timestamp) }
        journal.close()

        let recovered = try JournalReader.read(contentsOf: url)
        for (fix, point) in zip(fixes, recovered.route.points) {
            // Doubles are stored bit-for-bit, so this is exact, not approximate.
            #expect(point.latitude == fix.latitude)
            #expect(point.longitude == fix.longitude)
        }
    }

    @Test("A truncated tail is discarded and the good prefix survives")
    func truncatedTail() throws {
        // DESIGN.md §5.4 — a crash leaves the last frame half-written. Refusing
        // the whole file over its last 40 bytes would lose the run.
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let journal = try SessionJournal(url: url)
        journal.append(.header(sessionID: UUID(), mode: .walk, startedAt: Sim.epoch))
        for fix in Sim.straightWalk(count: 20) { journal.append(.fix(fix), now: fix.timestamp) }
        journal.close()

        let full = try Data(contentsOf: url)
        let truncated = full.prefix(full.count - 17)

        let recovered = JournalReader.read(Data(truncated))
        #expect(recovered.sawCorruption)
        #expect(recovered.route.points.count >= 18)
        #expect(recovered.route.points.count < 20)
    }

    @Test("A corrupted frame stops the read without losing earlier frames")
    func corruptedFrame() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let journal = try SessionJournal(url: url)
        for fix in Sim.straightWalk(count: 20) { journal.append(.fix(fix), now: fix.timestamp) }
        journal.close()

        var bytes = Array(try Data(contentsOf: url))
        // Flip a byte inside a payload roughly two-thirds through.
        bytes[bytes.count * 2 / 3] ^= 0xFF

        let recovered = JournalReader.read(Data(bytes))
        #expect(recovered.sawCorruption)
        #expect(recovered.route.points.count > 0)
        #expect(recovered.route.points.count < 20)
    }

    @Test("Segment boundaries survive and become gaps")
    func segmentBoundaries() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let journal = try SessionJournal(url: url)
        for fix in Sim.straightWalk(count: 5) { journal.append(.fix(fix), now: fix.timestamp) }
        journal.append(.segmentBoundary(kind: .gap, at: Sim.epoch.addingTimeInterval(200)))
        for fix in Sim.straightWalk(count: 5, startingAt: 300) {
            journal.append(.fix(fix), now: fix.timestamp)
        }
        journal.close()

        let recovered = try JournalReader.read(contentsOf: url)
        #expect(recovered.route.movingRuns.count == 2)
        #expect(recovered.route.segments.contains { $0.kind == .gap })
    }

    @Test("Checkpoints are recovered")
    func checkpoints() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let journal = try SessionJournal(url: url)
        journal.append(.checkpoint(distanceMeters: 1234.5, movingDuration: 600, at: Sim.epoch))
        journal.close()

        let recovered = try JournalReader.read(contentsOf: url)
        #expect(recovered.lastCheckpoint?.distanceMeters == 1234.5)
        #expect(recovered.lastCheckpoint?.movingDuration == 600)
    }

    @Test("Buffered records reach disk only after a flush")
    func flushPolicy() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let policy = SessionJournal.Policy(framesPerFlush: 5, maximumFlushInterval: 1_000)
        let journal = try SessionJournal(url: url, policy: policy, now: Sim.epoch)

        for fix in Sim.straightWalk(count: 3) {
            journal.append(.fix(fix), now: Sim.epoch)
        }
        #expect(try Data(contentsOf: url).isEmpty)

        journal.flush(now: Sim.epoch)
        #expect(try !Data(contentsOf: url).isEmpty)
        journal.close()
    }

    @Test("Elapsed time forces a flush even below the frame count")
    func timeBasedFlush() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let policy = SessionJournal.Policy(framesPerFlush: 100, maximumFlushInterval: 10)
        let journal = try SessionJournal(url: url, policy: policy, now: Sim.epoch)

        journal.append(.fix(Sim.fix(east: 0, north: 0, secondsIn: 0)), now: Sim.epoch)
        #expect(try Data(contentsOf: url).isEmpty)

        journal.append(
            .fix(Sim.fix(east: 10, north: 0, secondsIn: 20)),
            now: Sim.epoch.addingTimeInterval(20)
        )
        #expect(try !Data(contentsOf: url).isEmpty)
        journal.close()
    }

    @Test("A tail too short to be a frame is still reported as damage")
    func shortTailIsDamage() throws {
        // Silence here would tell the UI the recording was complete when its
        // end had been lost.
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let journal = try SessionJournal(url: url)
        for fix in Sim.straightWalk(count: 10) { journal.append(.fix(fix), now: fix.timestamp) }
        journal.close()

        var bytes = try Data(contentsOf: url)
        bytes.append(contentsOf: [0x52, 0x50, 0x00])   // a frame header cut off mid-write

        let recovered = JournalReader.read(bytes)
        #expect(recovered.sawCorruption)
        #expect(recovered.discardedTailBytes == 3)
        #expect(recovered.route.points.count == 10)
    }

    @Test("Extra bytes inside a valid frame are rejected")
    func trailingBytesInPayload() {
        // A CRC that happens to match does not make a frame correct: the length
        // field and the schema must agree.
        var payload = SessionJournal.encode(.checkpoint(distanceMeters: 1, movingDuration: 2, at: Sim.epoch))
        payload.append(0xAB)                       // one byte the decoder will not consume

        var frame = Data([0x52, 0x50, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        frame.append(payload)
        let crc = CRC32.checksum(payload)
        frame.append(contentsOf: [
            UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF),
        ])

        let recovered = JournalReader.read(frame)
        #expect(recovered.sawCorruption)
        #expect(recovered.lastCheckpoint == nil)
    }

    @Test("Close reports failure instead of stranding buffered records")
    func closeReportsSuccess() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let journal = try SessionJournal(url: url)
        for fix in Sim.straightWalk(count: 3) { journal.append(.fix(fix), now: fix.timestamp) }
        #expect(journal.close())
        #expect(journal.unflushedByteCount == 0)

        // Appending after close is ignored rather than crashing on a dead handle.
        journal.append(.fix(Sim.fix(east: 0, north: 0, secondsIn: 99)))
        #expect(journal.unflushedByteCount == 0)
    }

    @Test("An empty journal reads as an empty route, not an error")
    func emptyJournal() {
        let recovered = JournalReader.read(Data())
        #expect(recovered.route.points.isEmpty)
        #expect(!recovered.sawCorruption)
    }

    @Test("Garbage that is not a journal is refused at the first frame")
    func garbageInput() {
        let recovered = JournalReader.read(Data(repeating: 0xAB, count: 200))
        #expect(recovered.sawCorruption)
        #expect(recovered.route.points.isEmpty)
    }
}

@Suite("CRC32")
struct CRC32Tests {

    @Test("Matches the standard IEEE check value")
    func knownValue() {
        // "123456789" → 0xCBF43926 is the canonical CRC-32 check vector.
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }

    @Test("Empty input is zero")
    func empty() {
        #expect(CRC32.checksum([]) == 0)
    }

    @Test("A single flipped bit changes the checksum")
    func sensitivity() {
        var bytes = Array("the quick brown fox".utf8)
        let original = CRC32.checksum(bytes)
        bytes[5] ^= 0x01
        #expect(CRC32.checksum(bytes) != original)
    }
}
