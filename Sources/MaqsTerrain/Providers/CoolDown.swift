/// The pause in online requests after a 429: 60 s, twice as long after each further 429, at most 900 s; a success
/// sets the length back to 60 s. VersaTiles answers its rate limit with 429 and no `Retry-After`, so the pace is ours.
///
/// A 429 that arrives while a pause runs answers a request sent before the pause began (up to four run at once), so it
/// is the same burst: it neither lengthens the pause nor doubles the next one.
struct CoolDown: Sendable {
    static let initialLength: Duration = .seconds(60)
    static let maximumLength: Duration = .seconds(900)

    /// When the current or last pause ends; nil before the first 429.
    private(set) var end: ContinuousClock.Instant?
    /// The length of the next pause.
    private var nextLength = initialLength

    mutating func rateLimited(at now: ContinuousClock.Instant) {
        guard !isActive(at: now) else { return }
        end = now + nextLength
        nextLength = min(nextLength * 2, Self.maximumLength)
    }

    /// A tile arrived: the next pause is 60 s again. A pause already running still runs out, because the success
    /// answers a request sent before the 429 and says nothing about the server's limit now.
    mutating func succeeded() {
        nextLength = Self.initialLength
    }

    func isActive(at now: ContinuousClock.Instant) -> Bool {
        guard let end else { return false }
        return now < end
    }
}
