import os

/// The one logger of `MaqsCore`. Never log a URL with a query string, a file's contents, or anything position-derived.
let logger = Logger(subsystem: "com.lucavallin.maqs", category: "core")
