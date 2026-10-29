# Security

## Reporting a vulnerability

Report it privately through GitHub: open the repository's Security tab and choose "Report a vulnerability". Please do not open a public issue for it. No package version is tagged yet, so reports apply to `main` and to the latest data release.

## Threat notes

**Downloads and installs (`MaqsCore`).** Region files come from GitHub Releases and land on the user's disk. Each file is checked for its size and its SHA-256 against the manifest before it moves into place; a file that fails is deleted and never installed, and readers never see a partial download. The manifest is decoded strictly: every entry URL must be HTTPS on the manifest's own host, and ids and file names are checked before they become paths. [ADR 0014](docs/decisions.md) has the rules.

**Parsing untrusted files.** PMTiles archives are read by the internal `MaqsPMTiles` reader, which checks every offset, length and varint before a read and caps the size of directories, tiles and metadata, so a truncated, corrupt or hostile archive is a typed error rather than a crash or an unbounded allocation ([ADR 0015](docs/decisions.md)). `MaqsData` opens its SQLite files read-only and checks their metadata and tables before use ([ADR 0016](docs/decisions.md)). The map's tile gateway reads an archive only for a URL that parses as a tile of its templates.

**Provider compliance.** Online tiles come from VersaTiles' free public server, which rate-limits by IP. Getting the apps that use this package blocked is the failure that matters, so the etiquette is code:

- Every request the package makes carries the app's identifying User-Agent, MapLibre's included. The map's tile gateway also sets it on each tile request it sends, whatever the request carried.
- No request carries a header that disables caching; the provider's `Cache-Control` decides.
- The map pauses online tiles after a 429, never a tight retry loop; [`docs/architecture.md`](docs/architecture.md#map) gives the lengths. On its own MapLibre would retry every tile every 5 s. `MaqsTerrain` pauses its own requests the same way.
- Inside an installed region the map sends no tile request, even with signal, and with `onlineTiles` off it sends none anywhere.
- The gateway follows a redirect only to the same scheme, host and port, so tiles come only from the hosts `config/sources.json` names.

[`docs/architecture.md`](docs/architecture.md#map) describes the gateway, and [ADR 0017](docs/decisions.md) gives the reasons.

**Position.** A tile request carries tile coordinates, not the user's position, but the tiles requested around a user place them roughly ([`docs/architecture.md`](docs/architecture.md#terrain) has the estimate for terrain). An app with a strict privacy stance sets `onlineTiles` to false, and the package then sends no tile request at all. The package never logs a position in the clear.
