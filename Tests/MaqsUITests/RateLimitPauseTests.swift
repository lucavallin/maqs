import Testing
@testable import MaqsUI

@Suite struct RateLimitPauseTests {
    private let start = ContinuousClock.now

    @Test func inactiveAtStart() {
        #expect(!RateLimitPause().isActive(at: start))
    }

    @Test func oneRateLimitLastsSixtySeconds() {
        var pause = RateLimitPause()
        pause.rateLimited(at: start)
        #expect(pause.isActive(at: start))
        #expect(pause.isActive(at: start + .seconds(59)))
        #expect(!pause.isActive(at: start + .seconds(61)))
    }

    @Test func aSecondRateLimitLastsOneHundredTwentySeconds() {
        var pause = RateLimitPause()
        pause.rateLimited(at: start)
        let second = start + .seconds(61)
        pause.rateLimited(at: second)
        #expect(pause.isActive(at: second + .seconds(119)))
        #expect(!pause.isActive(at: second + .seconds(121)))
    }

    @Test func neverLongerThanFifteenMinutes() {
        var pause = RateLimitPause()
        var instant = start
        for length in [60, 120, 240, 480, 900, 900, 900] {
            pause.rateLimited(at: instant)
            #expect(pause.isActive(at: instant + .seconds(length - 1)), "length \(length)")
            #expect(!pause.isActive(at: instant + .seconds(length + 1)), "length \(length)")
            instant += .seconds(length + 1)
        }
    }

    @Test func aSuccessResetsTheLengthToSixtySeconds() {
        var pause = RateLimitPause()
        pause.rateLimited(at: start)
        pause.rateLimited(at: start + .seconds(61))
        pause.succeeded()
        // The pause running since +61 s (120 s long) is not ended by the success.
        #expect(pause.isActive(at: start + .seconds(62)))
        #expect(pause.isActive(at: start + .seconds(180)))
        let third = start + .seconds(200)
        pause.rateLimited(at: third)
        #expect(pause.isActive(at: third + .seconds(59)))
        #expect(!pause.isActive(at: third + .seconds(61)))
    }

    /// Requests in flight when the first 429 arrives answer 429 too; they are the same burst, not further ones.
    @Test func aRateLimitDuringThepauseNeitherLengthensNorDoublesIt() {
        var pause = RateLimitPause()
        pause.rateLimited(at: start)
        pause.rateLimited(at: start + .seconds(1))
        pause.rateLimited(at: start + .seconds(2))
        #expect(!pause.isActive(at: start + .seconds(61)))
        let next = start + .seconds(61)
        pause.rateLimited(at: next)
        #expect(pause.isActive(at: next + .seconds(119)))
        #expect(!pause.isActive(at: next + .seconds(121)))
    }
}
