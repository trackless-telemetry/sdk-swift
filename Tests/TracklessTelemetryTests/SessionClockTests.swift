import Foundation
import Testing

@testable import TracklessTelemetry

/// A hand-driven `TracklessClock`.
///
/// One clock, because the SDK reads one: the wall clock. `advance` is ordinary
/// elapsed time; `jump` moves it discontinuously, the way an NTP correction or a
/// user changing the time does, and is what the duration clamp is pinned against.
final class FakeClock: TracklessClock, @unchecked Sendable {
    private let lock = NSLock()
    private var storedNow: Date

    /// A fixed, arbitrary wall-clock base so failures read the same every run.
    static let base = Date(timeIntervalSince1970: 1_700_000_000)

    init(now: Date = FakeClock.base) {
        self.storedNow = now
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return storedNow
    }

    /// Ordinary elapsed time.
    func advance(_ seconds: TimeInterval) {
        lock.lock()
        storedNow = storedNow.addingTimeInterval(seconds)
        lock.unlock()
    }

    /// Move the clock discontinuously, forwards or backwards.
    func jump(by seconds: TimeInterval) {
        advance(seconds)
    }
}

@Suite("SessionManager — clock and truncation")
struct SessionManagerClockTests {

    @Test("Duration is ordinary elapsed wall time")
    func durationIsElapsedWallTime() async {
        let clock = FakeClock()
        let session = SessionManager(clock: clock)
        #expect(await session.start())

        clock.advance(42)

        let result = await session.end()
        #expect(result?.duration == 42)
    }

    @Test("A clock jump backwards clamps the duration to zero, never negative")
    func negativeDurationClamped() async {
        let clock = FakeClock()
        let session = SessionManager(clock: clock)
        #expect(await session.start())

        clock.advance(60)
        clock.jump(by: -3_600)

        let result = await session.end()
        #expect(result?.duration == 0)
    }

    /// A forward jump is the other half of the same defect. The cap is far above
    /// any real session and above the server's top duration bucket, so it trims
    /// the artifact without touching a measurement anyone would have quoted.
    @Test("A clock jump forwards clamps the duration to the plausible maximum")
    func absurdDurationClamped() async {
        let clock = FakeClock()
        let session = SessionManager(clock: clock)
        #expect(await session.start())

        clock.advance(30)
        clock.jump(by: 365 * 24 * 60 * 60)

        let result = await session.end()
        #expect(result?.duration == Int(SessionManager.maxPlausibleDuration))
    }

    @Test("markInactive truncates the duration at the mark, not at end()")
    func markInactiveTruncates() async {
        let clock = FakeClock()
        let session = SessionManager(clock: clock)
        #expect(await session.start())

        clock.advance(100)
        await session.markInactive()
        clock.advance(500)

        let result = await session.end()
        #expect(result?.duration == 100)
    }

    @Test("markInactive is idempotent — a repeated resign keeps the first mark")
    func markInactiveIdempotent() async {
        let clock = FakeClock()
        let session = SessionManager(clock: clock)
        #expect(await session.start())

        clock.advance(10)
        await session.markInactive()
        clock.advance(10)
        await session.markInactive()

        let result = await session.end()
        #expect(result?.duration == 10)
    }

    @Test("clearInactiveMark resumes measurement, so the interior gap counts")
    func clearInactiveMarkResumes() async {
        let clock = FakeClock()
        let session = SessionManager(clock: clock)
        #expect(await session.start())

        clock.advance(10)
        await session.markInactive()
        #expect(await session.isMarkedInactive)

        clock.advance(50)
        await session.clearInactiveMark()
        #expect(await session.isMarkedInactive == false)

        clock.advance(5)
        let result = await session.end()
        #expect(result?.duration == 65)
    }

    @Test("A mark does not survive into the next session")
    func markDoesNotLeakAcrossSessions() async {
        let clock = FakeClock()
        let session = SessionManager(clock: clock)
        #expect(await session.start())
        clock.advance(10)
        await session.markInactive()
        _ = await session.end()

        #expect(await session.start())
        #expect(await session.isMarkedInactive == false)
        clock.advance(7)
        #expect(await session.end()?.duration == 7)
    }

    @Test("start() is a no-op while a session is running")
    func doubleStartIsNoOp() async {
        let session = SessionManager(clock: FakeClock())
        #expect(await session.start())
        #expect(await session.start() == false)
    }

    @Test("end() returns nil when no session is running")
    func endWithoutSessionReturnsNil() async {
        let session = SessionManager(clock: FakeClock())
        #expect(await session.end() == nil)
        #expect(await session.start())
        #expect(await session.end() != nil)
        #expect(await session.end() == nil)
    }

    @Test("Depth counts activity within the session and resets on the next one")
    func depthResetsPerSession() async {
        let session = SessionManager(clock: FakeClock())
        #expect(await session.start())
        await session.recordActivity()
        await session.recordActivity()
        #expect(await session.end()?.depth == 2)

        #expect(await session.start())
        #expect(await session.end()?.depth == 0)
    }
}
