import Foundation
import SwiftBuild

private final class NopDelegate: SWBPlanningOperationDelegate, @unchecked Sendable {
    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SWBProvisioningTaskInputsSourceData) async -> SWBProvisioningTaskInputs { .init() }
    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> SWBExternalToolResult {
        print("  executeExternalTool: \(commandLine.first ?? "?") (returning .deferred)")
        return .deferred
    }
}

let workspacePath = "/Users/java.sdk/Desktop/test/test.xcodeproj"
let buildRoot = "/Users/java.sdk/Desktop/test/.build/derived-data"
let targetGUIDs = ["1899DBE02FE2216A00170740", "1899DBF32FE2219500170740", "1899DC062FE221C100170740"]

print("Creating service...")
let service: SWBBuildService
do {
    service = try await SWBBuildService(connectionMode: .outOfProcess, serviceBundleURL: nil)
} catch {
    print("Service failed: \(error)"); exit(1)
}

print("Creating session...")
let session: SWBBuildServiceSession
let (result, _) = await service.createSession(name: "test-ipc", cachePath: nil, inferiorProductsPath: nil, environment: nil)
guard case .success(let s) = result else {
    print("Session failed: \(result)"); await service.close(); exit(1)
}
session = s

// Use withTaskCancellationHandler to guarantee close on exit
do {
    print("loadWorkspace...")
    try await session.loadWorkspace(containerPath: workspacePath)
    print("loadWorkspace done")

    // Get correct PIF GUIDs from the service (not raw project file GUIDs)
    let info = try await session.workspaceInfo()
    let guids = info.targetInfos.map(\.guid)
    print("workspaceInfo: \(info.targetInfos.count) targets")
    for t in info.targetInfos { print("  \(t.targetName) → \(t.guid)") }

    print("setSystemInfo...")
    try await session.setSystemInfo(.default())

    var buildRequest = SWBBuildRequest()
    buildRequest.parameters.arenaInfo = SWBArenaInfo(
        derivedDataPath: buildRoot,
        buildProductsPath: buildRoot + "/Products",
        buildIntermediatesPath: buildRoot + "/Intermediates.noindex",
        pchPath: buildRoot,
        indexRegularBuildProductsPath: nil,
        indexRegularBuildIntermediatesPath: nil,
        indexPCHPath: buildRoot,
        indexDataStoreFolderPath: buildRoot,
        indexEnableDataStore: true
    )
    buildRequest.parameters.activeRunDestination = SWBRunDestinationInfo(
        platform: "iphonesimulator", sdk: "iphonesimulator", sdkVariant: nil,
        targetArchitecture: "arm64", supportedArchitectures: ["arm64"],
        disableOnlyActiveArch: false
    )
    // Only add the 3 user-visible targets (not package targets)
    let userTargetNames = ["test", "Dependency", "Dependency2"]
    for t in info.targetInfos where userTargetNames.contains(t.targetName) {
        buildRequest.add(target: SWBConfiguredTarget(guid: t.guid))
    }
    print("Build request: added \(buildRequest.configuredTargets.count) targets")

    print("createBuildOperationForBuildDescriptionOnly...")
    let op = try await session.createBuildOperationForBuildDescriptionOnly(request: buildRequest, delegate: NopDelegate())
    print("operation created, calling start()...")

    var eventCount = 0
    for try await event in try await op.start() {
        eventCount += 1
        if case .reportBuildDescription(let info) = event {
            print("✓ BUILD DESCRIPTION: \(info.buildDescriptionID)")
            break
        }
        if case .buildCompleted(let info) = event {
            print("buildCompleted: \(info)")
            break
        }
        if eventCount <= 5 || eventCount % 20 == 0 {
            print("  event[\(eventCount)]: \(String(describing: event).prefix(120))")
        }
        if eventCount > 500 { print("too many events, stopping"); break }
    }
    print("Stream ended. Total events: \(eventCount)")
} catch {
    print("Error: \(error)")
}

try? await session.close()
await service.close()
print("done")
