# Swift WebAssembly shared core

`ForeverLMCore` is compiled from the same source file in the macOS app, the
iOS app, Swift package tests, and the browser WebAssembly module:

- `Shared/Portable/ForeverLMCore.swift` contains pure domain behavior.
- `Shared/Portable/TutorContract.swift` owns the cross-platform tutor
  instructions and tool schemas.
- `Shared/Portable/AITaskSettingsCatalog.swift` owns the complete native
  and browser AI-task Settings catalog.
- `WebAssembly/Sources/ForeverLMWebAssembly/main.swift` is the JavaScriptKit bridge.
- `WebAssembly/Tests/ForeverLMCoreTests` owns the cross-platform fixtures.
- `docs-site/website/library/foreverlm-core-wasm.js` validates and exposes the
  browser API. It has no JavaScript domain-logic fallback.

SQLite, CloudKit, files, Keychain, networking, SwiftUI, and AppKit stay in thin
platform adapters. New deterministic domain rules should move into the portable
target a slice at a time. Identity rules such as URL normalization require a
parity fixture suite before the browser switches to the shared implementation.

## Pinned toolchain

The repository pins Swift 6.4.0 in `.swift-version` and JavaScriptKit 0.57.0 in
`Package.swift`. Install the matching Swift.org toolchain and WebAssembly SDK
(the URL and checksum are those on swift.org's macOS install page). swiftly needs
to be 1.1.4 or later: 1.1.3 asks for 6.4.0 under the name `swift-6.4-RELEASE`,
and swift.org names it `swift-6.4.0-RELEASE`.

```bash
swiftly self-update
swiftly install 6.4.0
swiftly use 6.4.0
swift sdk install https://download.swift.org/swift-6.4.0-release/wasm-sdk/swift-6.4.0-RELEASE/swift-6.4.0-RELEASE_wasm.artifactbundle.tar.gz --checksum f07b7be3c586d92d7a07051fc6d303b87ebea67eadc40640ba59d5a8b79aa86d
brew install binaryen
```

`wasm-opt` is required. The unoptimized Foundation build exceeds Cloudflare
Pages' per-file limit. The production target imports `FoundationEssentials` on
WASI and the normal `Foundation` module on Apple platforms.

The toolchain also compiles the package manifests and plugins for the Mac,
against the selected Xcode's macOS SDK, so the pinned Swift has to read that
SDK's Swift interfaces. Swift 6.3.3 could not read the Xcode 27.0 release's
(`27A266a`), whose interfaces' module flags carry `-target-arch-variant
arm64e.x1`: the build died on swift-syntax's `Package.swift` with *unknown
argument: '-target-arch-variant'* (the Command Line Tools' SDK did the same in
September), so until the pin moved to 6.4.0, the Xcode's own Swift, the website
was built against the Xcode 27 beta's SDK. Swift 6.4.0 reads the release's SDK
and the Command Line Tools 27.0 SDK alike. When an Xcode update brings that
error back, move the pin to the new Xcode's Swift: `.swift-version`, the
commands above with the new WebAssembly SDK's URL and checksum, and in
`docs-site/website/`, `SWIFT_VERSION` and `SWIFT_SDK` in
`scripts/build-site.mjs`, the `swiftVersion` that `test/swift-wasm.test.ts` and
`verify-deployment.mjs` expect, and the version `README.md` names.

The build script builds against Xcode's SDK when `xcode-select` points at the
Command Line Tools, and copies `.swift-version` into the package it builds, so
swiftly uses the pinned toolchain whatever `swiftly use` says. It also builds
with SwiftPM's native build system, which Swift 6.4 deprecates: under the new
default, Swift Build, the product lands in `out/Products/Release-webassembly-wasm32/`,
JavaScriptKit 0.57.0 reads the target triple off that path, and its generated
JavaScript leaves out the WASI shim the module needs. JavaScriptKit 0.58.0 reads
the module's imports instead, so moving to it lets the build drop
`--build-system native`.

## Build and test

From `docs-site/`:

```bash
npm ci
npm run website:check
```

The build compiles an optimized module, verifies its magic bytes, rejects any
module over 25 MiB, stages only public site files in `website/dist`, vendors the
pinned browser WASI shim, and writes a SHA-256 manifest. Node tests instantiate
the staged `.wasm` itself, so a missing or broken Swift build cannot be hidden by
a JavaScript fallback. Production packaging uses a dedicated temporary SwiftPM
scratch directory, one per pinned Swift, so native builds, Xcode indexing, and
iCloud-backed repository I/O cannot contend with the WebAssembly artifact graph.
