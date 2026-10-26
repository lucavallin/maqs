import Testing
@testable import MaqsTerrain

@Suite struct CoolDownTests {
    private let start = ContinuousClock.now

    @Test func inactiveAtStart() {
        #expect(!CoolDown().isActive(at: start))
    }

    @Test func oneRateLimitLastsSixtySeconds() {
        var coolDown = CoolDown()
        coolDown.rateLimited(at: start)
        #expect(coolDown.isActive(at: start))
        #expect(coolDown.isActive(at: start + .seconds(59)))
        #expect(!coolDown.isActive(at: start + .seconds(61)))
    }

    @Test func aSecondRateLimitLastsOneHundredTwentySeconds() {
        var coolDown = CoolDown()
        coolDown.rateLimited(at: start)
        let second = start + .seconds(61)
        coolDown.rateLimited(at: second)
        #expect(coolDown.isActive(at: second + .seconds(119)))
        #expect(!coolDown.isActive(at: second + .seconds(121)))
    }

    @Test func neverLongerThanFifteenMinutes() {
        var coolDown = CoolDown()
        var instant = start
        for length in [60, 120, 240, 480, 900, 900, 900] {
            coolDown.rateLimited(at: instant)
            #expect(coolDown.isActive(at: instant + .seconds(length - 1)), "length \(length)")
            #expect(!coolDown.isActive(at: instant + .seconds(length + 1)), "length \(length)")
            instant += .seconds(length + 1)
        }
    }

    @Test func aSuccessResetsTheLengthToSixtySeconds() {
        var coolDown = CoolDown()
        coolDown.rateLimited(at: start)
        coolDown.rateLimited(at: start + .seconds(61))
        coolDown.succeeded()
        let third = start + .seconds(200)
        coolDown.rateLimited(at: third)
        #expect(coolDown.isActive(at: third + .seconds(59)))
        #expect(!coolDown.isActive(at: third + .seconds(61)))
    }

    /// Requests in flight when the first 429 arrives answer 429 too; they are the same burst, not further ones.
    @Test func aRateLimitDuringTheCoolDownNeitherLengthensNorDoublesIt() {
        var coolDown = CoolDown()
        coolDown.rateLimited(at: start)
        coolDown.rateLimited(at: start + .seconds(1))
        coolDown.rateLimited(at: start + .seconds(2))
        #expect(!coolDown.isActive(at: start + .seconds(61)))
        let next = start + .seconds(61)
        coolDown.rateLimited(at: next)
        #expect(coolDown.isActive(at: next + .seconds(119)))
        #expect(!coolDown.isActive(at: next + .seconds(121)))
    }
}
