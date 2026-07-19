import ArgumentParser
import BuildServerProtocol
import Darwin
import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport
import SourceKitXcodeBSP

@main
struct SourcekitXcodeBspCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "A Build Server Protocol server for Xcode projects, for usage with SourceKit-LSP.",
        version: "0.1.0",
        subcommands: [Serve.self, InitCommand.self],
        // The LSP client launches the bare binary (no subcommand) per buildServer.json's
        // `argv`, so running the server must remain the default behavior.
        defaultSubcommand: Serve.self
    )
}

/// Runs the BSP server over stdio. Invoked by the LSP client via `argv`.
struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the BSP server over stdio (default; invoked by the LSP client)."
    )

    func run() async throws {
        // BSP servers communicate over pipes; a broken pipe during shutdown should
        // not crash the process. Ignore SIGPIPE so writes return EPIPE instead.
        signal(SIGPIPE, SIG_IGN)

        // Load configuration
        let cwd = FileManager.default.currentDirectoryPath
        let config = try ConfigLoader.load(from: cwd)
        let workspacePath = try ConfigLoader.resolveWorkspacePath(config: config, relativeTo: cwd)
        let buildRoot = ConfigLoader.resolveBuildRoot(config: config, relativeTo: cwd)

        let serviceProvider = try await BuildServiceProviderFactory(
            serviceBundlePath: ConfigLoader.resolveServiceBundlePath(config: config, relativeTo: cwd),
            synchronousBuildDescriptionSerialization: config.synchronousBuildDescriptionSerialization ?? true
        ).make()

        // Create JSON-RPC connection
        let connection = JSONRPCConnection(
            name: "sourcekit-xcode-bsp",
            protocol: MessageRegistry.bspProtocol,
            receiveFD: .standardInput,
            sendFD: .standardOutput
        )

        // Start server
        let bootstrap = BuildServerBootstrap()
        try await bootstrap.start(
            config: config,
            workspacePath: workspacePath,
            buildRoot: buildRoot,
            connection: connection,
            serviceProvider: serviceProvider
        )
    }
}