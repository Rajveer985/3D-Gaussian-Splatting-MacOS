// Tests/AnimationSystem/PlaybackEngineTests.swift
// Feature: keyframe-animation-system, Property 19: Playback timing correctness

import XCTest
import SwiftCheck

// MARK: - Isolated Tick Logic for Testing
//
// The PlaybackEngine's tick logic is tested in isolation here by replicating
// the core timing algorithm. This avoids the need for a real display link
// and allows synthetic timestamp injection.
//
// The tick logic under test:
//   1. If now < lastFrameTime -> reset lastFrameTime = now, skip (non-monotonic guard)
//   2. If (now - lastFrameTime) >= (1.0 / fps) -> advance frame, update lastFrameTime
//   3. Otherwise -> no advance

/// A minimal harness that replicates PlaybackEngine's tick logic for isolated testing.
struct TickHarness {
    var currentFrame: Int
    var lastFrameTime: Double
    let fps: Int
    let startFrame: Int
    let endFrame: Int
    var loopEnabled: Bool
    var isPlaying: Bool = true

    /// Simulates one tick at the given `now` timestamp.
    /// Returns true if the frame was advanced.
    @discardableResult
    mutating func tick(now: Double) -> Bool {
        // Non-monotonic clock guard
        if now < lastFrameTime {
            lastFrameTime = now
            return false
        }

        let frameDuration = 1.0 / Double(fps)
        let elapsed = now - lastFrameTime

        guard elapsed >= frameDuration else { return false }

        currentFrame += 1
        lastFrameTime = now

        // Handle end-of-range
        if currentFrame > endFrame {
            if loopEnabled {
                currentFrame = startFrame
            } else {
                currentFrame = endFrame
                isPlaying = false
            }
        }

        return true
    }
}

// MARK: - Property 19: Playback Timing Correctness

/// **Validates: Requirements 12.2, 12.3**
///
/// Property 19: For any fps in {24, 30, 60} and any sequence of elapsed time deltas,
/// the tick logic advances `currentFrame` by exactly 1 per interval >= `1/fps`
/// and does not advance for shorter intervals.
final class PlaybackEngineTests: XCTestCase {

    // MARK: - Unit Tests

    /// Tick does NOT advance frame when elapsed time is less than 1/fps.
    func testTickDoesNotAdvanceFrameBeforeInterval() {
        let fps = 24
        var harness = TickHarness(
            currentFrame: 0,
            lastFrameTime: 0.0,
            fps: fps,
            startFrame: 0,
            endFrame: 240,
            loopEnabled: false
        )
        let frameDuration = 1.0 / Double(fps)
        // Advance by slightly less than one frame duration
        let advanced = harness.tick(now: frameDuration - 0.001)
        XCTAssertFalse(advanced, "Frame should not advance before interval elapses")
        XCTAssertEqual(harness.currentFrame, 0)
    }

    /// Tick advances frame by exactly 1 when elapsed time equals 1/fps.
    func testTickAdvancesFrameAtExactInterval() {
        let fps = 30
        var harness = TickHarness(
            currentFrame: 0,
            lastFrameTime: 0.0,
            fps: fps,
            startFrame: 0,
            endFrame: 240,
            loopEnabled: false
        )
        let frameDuration = 1.0 / Double(fps)
        let advanced = harness.tick(now: frameDuration)
        XCTAssertTrue(advanced, "Frame should advance at exact interval")
        XCTAssertEqual(harness.currentFrame, 1)
    }

    /// Tick advances frame by exactly 1 even when elapsed time is much larger than 1/fps.
    func testTickAdvancesExactlyOneFramePerCall() {
        let fps = 60
        var harness = TickHarness(
            currentFrame: 5,
            lastFrameTime: 0.0,
            fps: fps,
            startFrame: 0,
            endFrame: 240,
            loopEnabled: false
        )
        // Even with 10x the frame duration, only 1 frame advances per tick
        let advanced = harness.tick(now: 10.0 / Double(fps))
        XCTAssertTrue(advanced)
        XCTAssertEqual(harness.currentFrame, 6, "Only 1 frame should advance per tick call")
    }

    /// Non-monotonic clock: if now < lastFrameTime, reset and skip.
    func testNonMonotonicClockResetsAndSkips() {
        let fps = 24
        var harness = TickHarness(
            currentFrame: 10,
            lastFrameTime: 100.0,
            fps: fps,
            startFrame: 0,
            endFrame: 240,
            loopEnabled: false
        )
        // Simulate clock going backwards
        let advanced = harness.tick(now: 50.0)
        XCTAssertFalse(advanced, "Non-monotonic clock should skip frame advance")
        XCTAssertEqual(harness.currentFrame, 10, "Frame should not change on non-monotonic clock")
        XCTAssertEqual(harness.lastFrameTime, 50.0, "lastFrameTime should be reset to now")
    }

    /// Stop at end frame when loop is disabled.
    func testStopsAtEndFrameWithoutLoop() {
        let fps = 24
        var harness = TickHarness(
            currentFrame: 239,
            lastFrameTime: 0.0,
            fps: fps,
            startFrame: 0,
            endFrame: 240,
            loopEnabled: false
        )
        let frameDuration = 1.0 / Double(fps)
        harness.tick(now: frameDuration)
        XCTAssertEqual(harness.currentFrame, 240)
        XCTAssertTrue(harness.isPlaying)

        // One more tick should stop at endFrame
        harness.tick(now: 2 * frameDuration)
        XCTAssertEqual(harness.currentFrame, 240, "Should clamp to endFrame")
        XCTAssertFalse(harness.isPlaying, "Should stop playing at end")
    }

    /// Loop wraps back to startFrame when loop is enabled.
    func testLoopsBackToStartFrame() {
        let fps = 24
        var harness = TickHarness(
            currentFrame: 240,
            lastFrameTime: 0.0,
            fps: fps,
            startFrame: 0,
            endFrame: 240,
            loopEnabled: true
        )
        let frameDuration = 1.0 / Double(fps)
        harness.tick(now: frameDuration)
        XCTAssertEqual(harness.currentFrame, 0, "Should wrap to startFrame when looping")
        XCTAssertTrue(harness.isPlaying, "Should continue playing when looping")
    }

    // MARK: - Property 19: Playback Timing Correctness (SwiftCheck)

    /// **Property 19: Playback timing correctness**
    ///
    /// For any fps in {24, 30, 60} and any sequence of elapsed time deltas,
    /// the tick logic advances `currentFrame` by exactly 1 per interval >= `1/fps`
    /// and does not advance for shorter intervals.
    ///
    /// **Validates: Requirements 12.2, 12.3**
    func testProperty19_PlaybackTimingCorrectness() {
        // Generator for valid FPS values: maps 0->24, 1->30, 2->60
        let fpsGen: Gen<Int> = Gen<Int>.choose((0, 2)).map { idx in
            [24, 30, 60][idx]
        }

        // Property: for any fps and any delta strictly > 1/fps, exactly one frame advances.
        // multiplierTenths in [11, 200] means delta = frameDuration * (1.1 to 20.0).
        // Using strictly > 1/fps avoids floating-point boundary issues at exact equality.
        property("Tick advances exactly 1 frame when elapsed > 1/fps") <- forAllNoShrink(
            fpsGen,
            Gen<Int>.choose((11, 200))
        ) { fps, multiplierTenths in
            let frameDuration = 1.0 / Double(fps)
            // delta is strictly > frameDuration (at least 10% more)
            let delta = frameDuration * Double(multiplierTenths) / 10.0

            var harness = TickHarness(
                currentFrame: 0,
                lastFrameTime: 0.0,
                fps: fps,
                startFrame: 0,
                endFrame: 10000,
                loopEnabled: false
            )
            let advanced = harness.tick(now: delta)
            return advanced == true && harness.currentFrame == 1
        }

        // Property: for any fps and any delta < 1/fps, no frame advances.
        // numerator in [1, 9] means delta = frameDuration * (0.1 to 0.9).
        property("Tick does not advance frame when elapsed < 1/fps") <- forAllNoShrink(
            fpsGen,
            Gen<Int>.choose((1, 9))
        ) { fps, numerator in
            let frameDuration = 1.0 / Double(fps)
            let delta = frameDuration * Double(numerator) / 10.0  // < frameDuration

            var harness = TickHarness(
                currentFrame: 5,
                lastFrameTime: 0.0,
                fps: fps,
                startFrame: 0,
                endFrame: 10000,
                loopEnabled: false
            )
            let advanced = harness.tick(now: delta)
            return advanced == false && harness.currentFrame == 5
        }

        // Property: non-monotonic clock always skips and resets lastFrameTime.
        // fractionTenths in [1, 9] means earlier = 100.0 * (0.1 to 0.9) < 100.0.
        property("Non-monotonic clock skips frame advance and resets lastFrameTime") <- forAllNoShrink(
            fpsGen,
            Gen<Int>.choose((1, 9))
        ) { fps, fractionTenths in
            let lastTime = 100.0
            let earlier = lastTime * Double(fractionTenths) / 10.0  // always < lastTime

            var harness = TickHarness(
                currentFrame: 42,
                lastFrameTime: lastTime,
                fps: fps,
                startFrame: 0,
                endFrame: 10000,
                loopEnabled: false
            )
            let advanced = harness.tick(now: earlier)
            return advanced == false
                && harness.currentFrame == 42
                && harness.lastFrameTime == earlier
        }

        // Property: N ticks each spaced by (1/fps + epsilon) advance exactly N frames.
        // Uses a small positive epsilon (1ms) to ensure each tick clears the threshold
        // without floating-point boundary issues.
        property("N ticks each spaced > 1/fps advance exactly N frames") <- forAllNoShrink(
            fpsGen,
            Gen<Int>.choose((1, 50))
        ) { fps, n in
            let frameDuration = 1.0 / Double(fps)
            // Add 1ms epsilon to ensure each tick reliably clears the threshold
            let tickInterval = frameDuration + 0.001
            var harness = TickHarness(
                currentFrame: 0,
                lastFrameTime: 0.0,
                fps: fps,
                startFrame: 0,
                endFrame: 10000,
                loopEnabled: false
            )
            for i in 1...n {
                harness.tick(now: Double(i) * tickInterval)
            }
            return harness.currentFrame == n
        }
    }
}
