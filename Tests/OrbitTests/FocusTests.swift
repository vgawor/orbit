import Foundation
import Testing
@testable import Orbit

/// Timers and focus sessions. Settings are set explicitly so the user's saved values don't matter.
@Suite("Timer & Focus") @MainActor
struct FocusTests {
    private func make(automatic: Bool = true, rounds: Int = 2) -> (FocusModule, AlertCenter) {
        let alerts = AlertCenter()
        let focus = FocusModule(alerts: alerts)
        focus.cycleFocusMinutes = 25
        focus.breakMinutes = 5
        focus.singleFocusMinutes = 50
        focus.rounds = rounds
        focus.automatic = automatic
        focus.stopSession()
        return (focus, alerts)
    }

    @Test func severalTimersRunSideBySide() throws {
        let (focus, _) = make()
        defer { focus.stop() }
        focus.startTimer(15, label: "Tea")
        focus.startTimer(5)
        focus.startTimer(0)          // clamped to 1 minute
        #expect(focus.timers.map(\.label) == ["1 min", "5 min", "Tea"])   // ending first on top
        #expect(focus.runningCount == 3)
        #expect(focus.nextTimer?.minutes == 1)

        let tea = try #require(focus.timers.first { $0.label == "Tea" })
        func current() -> FocusModule.Countdown? { focus.timers.first { $0.id == tea.id } }
        focus.toggleTimer(tea.id)     // pause
        #expect(current()?.isPaused == true)
        let left = try #require(current()?.remaining(at: .now.addingTimeInterval(3600)))
        #expect(left > 14 * 60)       // a paused timer doesn't count down
        #expect(focus.nextTimer?.minutes == 1)
        focus.toggleTimer(tea.id)     // resume
        #expect(current()?.isPaused == false)

        focus.removeTimer(tea.id)
        #expect(focus.timers.count == 2)
    }

    @Test func singleFocusEndsAfterOneBlock() {
        let (focus, alerts) = make()
        defer { focus.stop() }
        focus.startFocus(minutes: 40)
        #expect(focus.stage == .running)
        #expect(focus.total == 40 * 60)
        #expect(focus.runningCount == 1)
        focus.finishPhase()
        #expect(focus.stage == .idle)
        #expect(alerts.current?.title == "Focus done")
    }

    @Test func automaticCycleRunsAllRounds() {
        let (focus, alerts) = make(automatic: true, rounds: 2)
        defer { focus.stop() }
        focus.startCycle()
        #expect(focus.phase == .focus && focus.round == 1)
        focus.finishPhase()                       // focus 1 done → break starts by itself
        #expect(focus.phase == .rest && focus.stage == .running)
        #expect(focus.total == 5 * 60)
        focus.finishPhase()                       // break done → round 2
        #expect(focus.phase == .focus && focus.round == 2 && focus.stage == .running)
        focus.finishPhase()                       // last round → finished
        #expect(focus.stage == .idle)
        #expect(alerts.current?.title == "Focus cycle complete")
    }

    @Test func manualCycleWaitsForYou() {
        let (focus, _) = make(automatic: false, rounds: 3)
        defer { focus.stop() }
        focus.startCycle()
        focus.finishPhase()
        #expect(focus.stage == .breakReady)
        focus.toggle()                            // the one button starts the break
        #expect(focus.phase == .rest && focus.stage == .running)
        focus.finishPhase()
        #expect(focus.stage == .focusReady && focus.round == 2)
        focus.toggle()
        #expect(focus.phase == .focus && focus.stage == .running)
    }

    @Test func pauseResumeAndStop() {
        let (focus, _) = make()
        defer { focus.stop() }
        focus.toggle()
        #expect(focus.stage == .running)
        focus.toggle()
        #expect(focus.stage == .paused)
        #expect(focus.hasStarted)
        focus.toggle()
        #expect(focus.stage == .running)
        focus.stopSession()
        #expect(focus.stage == .idle && focus.runningCount == 0)
    }
}
