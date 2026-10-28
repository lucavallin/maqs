import Testing

/// The parent of every suite that touches `GatewayState.shared`, the one gateway state of the process. The suites
/// nested under it run one test at a time, so no two tests change that state at once; suites outside it still run in
/// parallel. A new suite joins it from its own file with `extension SharedGatewaySuite { @Suite struct … }`.
@Suite(.serialized) struct SharedGatewaySuite {}
