# sourcekit-xcode-bsp

A [Build Server Protocol](https://build-server-protocol.github.io) server for Xcode projects, enabling SourceKit-LSP to provide IDE features (code completion, jump-to-definition, diagnostics) for `.xcodeproj` and `.xcworkspace` based projects.

## Requirements

- macOS 15 or later
- Xcode 16 or later

## Installation

### Homebrew

```sh
brew tap tideline-studio/tap
brew install sourcekit-xcode-bsp
```

### Build from source

Requires Swift 6 and Xcode 16+.

```sh
git clone https://github.com/tideline-studio/sourcekit-xcode-bsp.git
cd sourcekit-xcode-bsp
swift build -c release
```

The binary will be at `.build/release/sourcekit-xcode-bsp`. Copy it to a directory on your `PATH`:

```sh
cp .build/release/sourcekit-xcode-bsp /usr/local/bin/
```

## Setup

Run `init` in your project directory to generate a `buildServer.json`:

```sh
cd /path/to/your/project
sourcekit-xcode-bsp init
```

Your LSP client will pick up `buildServer.json` automatically and launch the server.
