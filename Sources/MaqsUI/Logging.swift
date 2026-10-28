import os

/// The one logger of `MaqsUI`. Never log full URLs with query strings or a position; anything position-derived
/// is logged with `privacy: .private`.
let logger = Logger(subsystem: "com.lucavallin.maqs", category: "ui")
