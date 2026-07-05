import ArgumentParser
import BuildServerProtocol
import Foundation
import LanguageServerProtocol
import LanguageServerProtocolTransport
import SwiftBuild
import XcodeBSP

@main
struct XcodeBSPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcode-bsp",
        abstract: "A Build Server Protocol server for Xcode projects",
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
        // Load configuration
        let cwd = FileManager.default.currentDirectoryPath
        let config = try ConfigLoader.load(from: cwd)
        let workspacePath = try ConfigLoader.resolveWorkspacePath(config: config, relativeTo: cwd)
        let buildRoot = ConfigLoader.resolveBuildRoot(config: config, relativeTo: cwd)

        // Create service provider. Use the SWBBuildService path from config if set,
        // otherwise fall back to the co-located service.
        let serviceBundlePath = ConfigLoader.resolveServiceBundlePath(config: config, relativeTo: cwd)
        let serviceProvider = try await RealBuildServiceProvider.makeDefault(serviceBundlePath: serviceBundlePath)

        // Create JSON-RPC connection
        let connection = JSONRPCConnection(
            name: "xcode-bsp",
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
