import os

/// The one logger of `MaqsData`. A file is named by its last path component, never its full path, which holds the
/// app's container. Query points, cone origins and road positions are logged only with `privacy: .private`, and
/// queries are not logged at info: a lookahead runs every second.
let logger = Logger(subsystem: "com.lucavallin.maqs", category: "data")
