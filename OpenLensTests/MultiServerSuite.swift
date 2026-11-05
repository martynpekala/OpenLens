import Testing

extension Tag {
    @Tag static var multiServer: Self
}

/// Parent suite for the multi-server feature; each area adds a nested suite from its own file.
@Suite("Multi-server", .tags(.multiServer))
struct MultiServerSuite {}
