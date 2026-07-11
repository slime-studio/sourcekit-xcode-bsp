# Apple platform development in IDEs like Cursor and VSCode, for native Xcode projects

**sourcekit-xcode-bsp** is a [Build Server Protocol](https://build-server-protocol.github.io/) implementation that bridges [sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp) (Swift's official [Language Server Protocol](https://microsoft.github.io/language-server-protocol/) server) and native Xcode projects (`.xcodeproj` / `.xcworkspace`). It uses [swift-build](https://github.com/swiftlang/swift-build) under the hood so you can get code intelligence for Swift and Apple-platform projects in any LSP-capable editor — Cursor, VSCode, and others — without relying on the Xcode IDE itself.

> [!IMPORTANT]
> sourcekit-xcode-bsp is designed for **native Xcode projects**. It is not a Bazel integration. For Bazel-based projects, see [sourcekit-bazel-bsp](https://github.com/spotify/sourcekit-bazel-bsp) by Spotify.

> [!NOTE]
> This project is early-stage (v0.0.1). APIs and setup flows may change.

## Features

- Code completion, jump to definition, diagnostics, and other indexing features powered by [sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp)
- Works with standard `.xcodeproj` and `.xcworkspace` projects via swift-build
- Interactive `init` command to generate a `buildServer.json` configuration
- Workspace file watching for incremental rebuilds

## Requirements

- **macOS 15+**
- **Xcode 26+** installed and selected via `xcode-select` (platform SDKs and toolchains come from Xcode)
- **Swift 6.2+** to build from source

You still need Xcode installed for Apple platform SDKs and build tooling, even when developing in another editor.

## Quick start

### 1. Install

**Homebrew** (recommended):

```bash
brew tap tideline-studio/tap
brew install sourcekit-xcode-bsp
```

**Build from source** (requires Swift 6.2+):

```bash
git clone https://github.com/tideline-studio/sourcekit-xcode-bsp.git
cd sourcekit-xcode-bsp
swift build -c release
cp .build/release/sourcekit-xcode-bsp /usr/local/bin/
```

### 2. Generate `buildServer.json`

From your Xcode project root:

```bash
/path/to/sourcekit-xcode-bsp init
```

This interactively writes a `buildServer.json` that tells sourcekit-lsp how to launch the BSP server. You can also create the file by hand — see [Configuration](#configuration) below.

### 3. Open your project in an LSP-capable editor

#### Cursor / VSCode

1. Install the official [Swift](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode) extension.
2. Open the folder containing your `buildServer.json`.
3. Restart the language server (`Cmd+Shift+P` → **Swift: Restart LSP Server**) or reload the window.

sourcekit-lsp discovers `buildServer.json` automatically and launches `sourcekit-xcode-bsp` using the `argv` entry.

## Configuration

`buildServer.json` lives at the root of the workspace you open in your editor. A minimal example:

```json
{
  "argv": ["/usr/local/bin/sourcekit-xcode-bsp"],
  "bspVersion": "2.1.0",
  "languages": ["swift"],
  "name": "sourcekit-xcode-bsp",
  "version": "0.1.0",
  "workspace": "MyApp.xcodeproj"
}
```

### Project-specific fields

| Field | Required | Description |
|-------|----------|-------------|
| `workspace` | Yes | Path to `.xcodeproj` or `.xcworkspace` (relative to `buildServer.json` or absolute) |
| `buildRoot` | No | Build artifacts directory. Defaults to `.build/derived-data` |
| `platform` | No | Target platform, e.g. `iphonesimulator`, `iphoneos`, `macosx`. If omitted, swift-build chooses a default |
| `indexingEnabled` | No | Enable index store. Defaults to `true` |
| `serviceBundlePath` | No | Path to `SWBBuildServiceBundle`. If omitted, uses the service bundled alongside the binary |

### CLI reference

```bash
# Run the BSP server (default; invoked by sourcekit-lsp via argv)
sourcekit-xcode-bsp
sourcekit-xcode-bsp serve

# Generate buildServer.json interactively
sourcekit-xcode-bsp init
```

## Development

```bash
# Build
swift build

# Run tests
swift test

# Build release binary
swift build -c release
```

### Project layout

```
Sources/
  sourcekit-xcode-bsp/     # CLI executable (serve, init)
  SourceKitXcodeBSP/       # Core BSP server library
  test-ipc/                # Internal IPC debugging tool (not shipped)
Tests/
  SourceKitXcodeBSPTests/
```

## Troubleshooting

### Verify the BSP is running

In Cursor / VSCode, open the **Output** panel and select **SourceKit Language Server**. After opening a Swift file you should see the LSP activate and the BSP bootstrap. Server logs are written to **stderr** with the prefix `[sourcekit-xcode-bsp:…]` — check your editor's LSP or task output for these lines.

### Common issues

- **`buildServer.json` not found** — the file must live in the workspace root that your editor opens.
- **Workspace not found** — confirm the `workspace` path in `buildServer.json` points to a valid `.xcodeproj` or `.xcworkspace`.
- **Xcode not found** — run `xcode-select -p` and ensure Xcode 26+ is installed. You can override with `DEVELOPER_DIR`.

## Related projects

- [sourcekit-bazel-bsp](https://github.com/spotify/sourcekit-bazel-bsp) — BSP for Bazel-based Apple development (reference implementation)
- [xcode-build-server](https://github.com/SolaWing/xcode-build-server) — alternative BSP approach using `xcodebuild` logs
- [sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp) — Swift language server that consumes BSP configuration

## License

Apache License 2.0. See [LICENSE](LICENSE).