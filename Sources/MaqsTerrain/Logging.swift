import os

/// The one logger of `MaqsTerrain`. Coordinates, tile coordinates and tile URLs are logged only with `privacy: .private`; never tile contents.
let logger = Logger(subsystem: "com.lucavallin.maqs", category: "terrain")
