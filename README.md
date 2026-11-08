# sourcekit-xcode-bsp

A [Build Server Protocol](https://build-server-protocol.github.io/) server that connects [sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp) to native Xcode projects (`.xcodeproj` / `.xcworkspace`). It uses [swift-build](https://github.com/swiftlang/swift-build), the same build engine as Xcode, so Swift code intelligence works in Cursor, VS Code, and other LSP editors.

The server reloads when project metadata changes, such as `project.pbxproj` or `Package.resolved`.

> [!IMPORTANT]
> For native Xcode projects only. For Bazel, use [sourcekit-bazel-bsp](https://github.com/spotify/sourcekit-bazel-bsp).

> [!NOTE]
> Early-stage. APIs and setup may change.

## Requirements

- macOS 15+
- Xcode 26+, selected with `xcode-select` (or `DEVELOPER_DIR`). You still need Xcode installed for SDKs and toolchains.
- Swift 6.2+ to build from source

## Install

Homebrew:

```bash
brew tap slime-studio/tap
brew install sourcekit-xcode-bsp
```

From source:

```bash
git clone https://github.com/slime-studio/sourcekit-xcode-bsp.git
cd sourcekit-xcode-bsp
swift build -c release
cp .build/release/sourcekit-xcode-bsp .build/release/SWBBuildServiceBundle /usr/local/bin/
```

`SWBBuildServiceBundle` must stay next to the `sourcekit-xcode-bsp` binary.

## Setup

From your Xcode project root:

```bash
sourcekit-xcode-bsp init
```

This writes `buildServer.json` in the current directory. It detects a `.xcworkspace` or `.xcodeproj`, defaults the platform to `iphonesimulator`, and sets `argv` to the binary you just ran.

Then in Cursor or VS Code:

1. Install the [Swift](https://marketplace.visualstudio.com/items?itemName=swiftlang.swift-vscode) extension.
2. Open the folder that contains `buildServer.json`.
3. Run **Swift: Restart LSP Server** from the command palette (`Cmd+Shift+P`), or reload the window.

sourcekit-lsp reads `buildServer.json` and launches this server over stdio. Bare `sourcekit-xcode-bsp` and `sourcekit-xcode-bsp serve` both run the server.

## Configuration

`buildServer.json` lives at the workspace root. Minimal example:

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

| Field | Required | Description |
|-------|----------|-------------|
| `workspace` | Yes | Path to `.xcodeproj` or `.xcworkspace`, relative to this file or absolute |
| `buildRoot` | No | Build artifacts directory. Defaults to Xcode's own DerivedData root for the workspace, resolved by asking `xcodebuild` — so it follows Xcode's **Settings → Locations → Derived Data** setting, including a custom location. The module cache is then shared and Xcode's build products are reusable. Writes go to the `Index.noindex/Build` arena, never Xcode's regular build arena. Falls back to `.build/derived-data` (not shared) if the root can't be resolved; the server logs which source it used |
| `platform` | No | Run destination, such as `iphonesimulator`, `iphoneos`, or `macosx`. `init` defaults to `iphonesimulator`. If omitted, swift-build chooses one |
| `serviceBundlePath` | No | Path to `SWBBuildServiceBundle`. On Xcode 27+, defaults to the build service bundled inside the selected Xcode; otherwise defaults to the copy next to the binary |
| `synchronousBuildDescriptionSerialization` | No | Write the build description before notifying SourceKit-LSP, so the first diagnostics are not empty. Defaults to `true` |

## Development

```bash
swift build
swift test
swiftlint lint
```

Optional hook: `brew install pre-commit swiftlint && pre-commit install`. Commits then lint staged Swift files.

## Troubleshooting

In Cursor or VS Code, open **Output** and choose **SourceKit Language Server**. After you open a Swift file you should see the BSP start. Server logs go to stderr with a prefix like `[sourcekit-xcode-bsp:bootstrap]`.

- **`buildServer.json` not found**: put the file in the folder your editor opened as the workspace root.
- **Workspace not found**: `workspace` must point at a real `.xcodeproj` or `.xcworkspace`.
- **Xcode not found**: run `xcode-select -p` and confirm Xcode 26+ is selected. Override with `DEVELOPER_DIR` if needed.

## Related projects

- [sourcekit-lsp](https://github.com/swiftlang/sourcekit-lsp): Swift language server that consumes this BSP
- [sourcekit-bazel-bsp](https://github.com/spotify/sourcekit-bazel-bsp): same idea for Bazel
- [xcode-build-server](https://github.com/SolaWing/xcode-build-server): alternative BSP that parses `xcodebuild` logs

## License

Apache License 2.0. See [LICENSE](LICENSE).
