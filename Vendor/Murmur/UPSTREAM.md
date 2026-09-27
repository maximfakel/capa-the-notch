# Murmur upstream

Vendored from [krispuckett/murmur](https://github.com/krispuckett/murmur), commit
`4d39f75274b051c8c4aaee2526ead0ddecc42c22` (MIT, copyright Kris Puckett).

Local change: shader and source-export lookups first check the standard
`Contents/Resources` location in a macOS app bundle, then retain SwiftPM's
normal lookup for command-line builds. The upstream generated `Bundle.module`
accessor otherwise looks beside `.app`, where macOS code signing does not allow
resource bundles.

Upstream's `SPEC.md`, its design notes, is left out: nothing here builds from
it, and it names paths on its author's machine.
