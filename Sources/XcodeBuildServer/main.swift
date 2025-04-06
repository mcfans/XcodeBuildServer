//
//  main.swift
//  XcodeBuildServer
//
//  Created by 杨学思 on 2025/3/30.
//
//

import Foundation
import OSLog
import SwiftBuild
import SWBCore

let logger = Logger(subsystem: "com.yangxuesi.XcodeBuildServer", category: "main")

// BSP Protocol Constants
enum BSPProtocol {
    static let version = "2.1.0"
    
    enum Methods {
        static let buildInitialize = "build/initialize"
        static let buildInitialized = "build/initialized"
        static let buildShutdown = "build/shutdown"
        static let workspaceBuildTargets = "workspace/buildTargets"
        static let buildTargetSources = "buildTarget/sources"
        static let buildTargetDependencySources = "buildTarget/dependencySources"
        static let buildTargetCompile = "buildTarget/compile"
        static let buildTargetRun = "buildTarget/run"
        static let buildTargetTest = "buildTarget/test"
        static let showMessage = "window/showMessage"
        static let cancelRequest = "$/cancelRequest"
        static let textDocumentRegisterForChanges = "textDocument/registerForChanges"
        static let sourceKitOptions = "textDocument/sourceKitOptions"
        static let prepare = "buildTarget/prepare"
    }
}

// BSP Response Types
struct BSPResponse<T: Encodable>: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int
    let result: T?
    
    func toJSON() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}

struct BSPErrorResponse: Encodable {
    let jsonrpc: String = "2.0"
    let id: Int
    let error: BSPError
    
    func toJSON() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}

struct BSPError: Codable {
    let code: Int
    let message: String
    let data: String?
}

// BSP Data Types
struct InitializeBuildParams: Codable {
    let displayName: String
    let version: String
    let bspVersion: String
    let rootUri: String
    let capabilities: ClientCapabilities
    let data: [String: String]?
}

struct ClientCapabilities: Codable {
    let languageIds: [String]?
}

struct InitialData: Encodable {
    let sourceKitOptionsProvider: Bool
    let prepareProvider: Bool
    let outputPathsProvider: Bool
}

struct InitializeBuildResult: Encodable {
    let displayName: String = "Xcode Build Server"
    let version: String = "1.0.0"
    let bspVersion: String = BSPProtocol.version
    let capabilities: ServerCapabilities
    let dataKind: String = "sourceKit"
    let data: InitialData
}

struct ServerCapabilities: Encodable {
    let languageIds: [String] = ["swift", "objective-c", "objective-c++"]
//    let compileProvider: CompileProvider
//    let testProvider: TestProvider?
//    let runProvider: RunProvider?
//    let dependencySourcesProvider: Bool
//    let resourcesProvider: Bool
//    let buildTargetChangedProvider: Bool
}

struct CompileProvider: Encodable {
    let languageIds: [String] = ["swift", "objective-c", "objective-c++"]
}

struct TestProvider: Encodable {
    let languageIds: [String] = ["swift", "objective-c", "objective-c++"]
}

struct RunProvider: Encodable {
    let languageIds: [String] = ["swift", "objective-c", "objective-c++"]
}

struct BuildTarget: Codable {
    let id: BuildTargetIdentifier
    let displayName: String?
    let baseDirectory: String?
    let tags: [String]
    let capabilities: BuildTargetCapabilities
    let languageIds: [String]
    let dependencies: [BuildTargetIdentifier]
    let dataKind: String?
    let data: [String: String]?
}

struct BuildTargetIdentifier: Codable {
    let uri: String
}

struct TextDocumentIdentifier: Codable {
    let uri: String
}

struct TextDocumentSourceKitOptionsRequest: Codable {
    let textDocument: TextDocumentIdentifier
    let target: BuildTargetIdentifier
    let language: String
}

struct TextDocumentSourceKitOptionsResult: Codable {
    let compilerArguments: [String]
    let workingDirectory: String?
}

struct BuildTargetCapabilities: Codable {
    let canCompile: Bool
    let canTest: Bool
    let canRun: Bool
    let canDebug: Bool
}

struct WorkspaceBuildTargetsResult: Codable {
    let targets: [BuildTarget]
}

struct SourcesParams: Codable {
    let targets: [BuildTargetIdentifier]
}

struct SourcesResult: Codable {
    let items: [SourcesItem]
}

struct SourcesItem: Codable {
    let target: BuildTargetIdentifier
    let sources: [SourceItem]
}

struct SourceItem: Codable, Hashable {
    let uri: String
    let kind: Int
    let generated: Bool
}

struct DependencySourcesParams: Codable {
    let targets: [BuildTargetIdentifier]
}

struct DependencySourcesResult: Codable {
    let items: [DependencySourcesItem]
}

struct DependencySourcesItem: Codable {
    let target: BuildTargetIdentifier
    let sources: [String]
}

struct CompileParams: Codable {
    let targets: [BuildTargetIdentifier]
    let originId: String?
    let arguments: [String]?
}

struct CompileResult: Codable {
    let originId: String?
    let statusCode: Int
    let data: String?
}

struct TestParams: Codable {
    let targets: [BuildTargetIdentifier]
    let originId: String?
    let arguments: [String]?
    let dataKind: String?
    let data: String?
}

struct TestResult: Codable {
    let originId: String?
    let statusCode: Int
    let data: String?
}

struct RunParams: Codable {
    let target: BuildTargetIdentifier
    let originId: String?
    let arguments: [String]?
    let environmentVariables: [String: String]?
    let dataKind: String?
    let data: String?
}

struct RunResult: Codable {
    let originId: String?
    let statusCode: Int
    let data: String?
}

struct ShowMessage: Codable {
    let message: String
}

struct CancelParams: Codable {
    let id: String
}

struct PrepareParams: Codable {
    let targets: [BuildTargetIdentifier]
    let originId: Int?
    
}

// Add TextDocument Register For Changes types
struct TextDocumentRegisterForChangesParams: Codable {
    let uri: String
    let action: String  // "register" or "unregister"
}

struct TextDocumentRegisterForChangesResult: Codable {
    let statusCode: Int
}

struct SaveOptions: Codable {
    let includeText: Bool?
}

func eprint(s: String) {
    FileHandle.standardError.write(s.data(using: .utf8)!)
}

class BSPServer {
    private var initialized = false
    private var targets: [BuildTarget] = []
    var uri: String?
    
    let session: Session

    init(yaml: String, outputDir: String) {
        session = Session(yaml: yaml, outputDir: outputDir)
    }
    
    @MainActor
    func handleRequest(json: [String: Any]) async -> Data? {
        guard let method = json["method"] as? String else {
            logger.error("Missing method in JSON")
            return nil
        }
        
        let id = json["id"] as? Int
        
        guard let params = json["params"] as? [String: Any] else {
            logger.error("Missing params in JSON")
            return nil
        }
        
        let paramsData = try? JSONSerialization.data(withJSONObject: params)
        
        switch method {
        case BSPProtocol.Methods.buildInitialize:
            logger.log("Init")
            guard let id else { return nil }
            return await handleInitialize(id: id, paramsData: paramsData)
            
        case BSPProtocol.Methods.buildShutdown:
            logger.log("shutdown")
            guard let id else { return nil }
            return handleShutdown(id: id)
            
        case BSPProtocol.Methods.workspaceBuildTargets:
            logger.log("targets")
            guard let id else { return nil }
            return await handleWorkspaceBuildTargets(id: id)
            
        case BSPProtocol.Methods.buildTargetSources:
            logger.log("sources")
            guard let id else { return nil }
            return await handleBuildTargetSources(id: id, paramsData: paramsData)
            
        case BSPProtocol.Methods.buildTargetDependencySources:
            logger.log("dependency")
            guard let id else { return nil }
            return handleBuildTargetDependencySources(id: id, paramsData: paramsData)
            
        case BSPProtocol.Methods.buildTargetCompile:
            logger.log("compile")
            guard let id else { return nil }
            return handleBuildTargetCompile(id: id, paramsData: paramsData)
            
        case BSPProtocol.Methods.buildTargetRun:
            logger.log("run")
            guard let id else { return nil }
            return handleBuildTargetRun(id: id, paramsData: paramsData)
            
        case BSPProtocol.Methods.buildTargetTest:
            logger.log("test")
            guard let id else { return nil }
            return handleBuildTargetTest(id: id, paramsData: paramsData)
            
        case BSPProtocol.Methods.cancelRequest:
            logger.log("cancel")
            guard let id else { return nil }
            return handleCancelRequest(id: id, paramsData: paramsData)
            
        case BSPProtocol.Methods.showMessage:
            guard let id else { return nil }
            return handleShowMessage(id: id, paramsData: paramsData)
            
        case BSPProtocol.Methods.textDocumentRegisterForChanges:
            guard let id else { return nil }
            return handleTextDocumentRegisterForChanges(id: id, paramsData: paramsData)
        
        case BSPProtocol.Methods.sourceKitOptions:
            logger.log("sourcekit options")
            guard let id else { return nil }
            return await handleSourceKitOptions(id: id, paramsData: paramsData)

        case BSPProtocol.Methods.buildInitialized:
            return nil
        case BSPProtocol.Methods.prepare:
            guard let id else { return nil }
            return await handlePrepare(id: id, paramsData: paramsData)
            
        default:
            logger.error("Unsupported method: \(method)")
            let error = BSPError(code: -32601, message: "Method not found", data: nil)
            guard let id else { return nil }
            let response = BSPErrorResponse(id: id, error: error)
            return response.toJSON()
        }
    }
    
    private func handleShowMessage(id: Int, paramsData: Data?) -> Data? {
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(ShowMessage.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        eprint(s: params.message)
        return nil
    }
    
    @MainActor
    private func handleInitialize(id: Int, paramsData: Data?) async -> Data? {
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(InitializeBuildParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        logger.info("Initializing build server for \(params.displayName) at \(params.rootUri)")
        uri = params.rootUri

        do {
            try await loadSession()
        } catch {
            logger.error("Failed to load session: \(error)")
            return createErrorResponse(id: id, code: -32603, message: "Failed to load session: \(error.localizedDescription)")
        }
        
        initialized = true
        let capabilities = ServerCapabilities()
        
        let result = InitializeBuildResult(capabilities: capabilities, data: InitialData(sourceKitOptionsProvider: true, prepareProvider: true, outputPathsProvider: true))
        return BSPResponse(id: id, result: result).toJSON()
    }

    @MainActor
    private func loadSession() async throws {
        try await session.load()
    }
    
    private func handleShutdown(id: Int) -> Data? {
        logger.info("Shutting down build server")
        initialized = false
        let result: [String: String] = [:]
        return BSPResponse(id: id, result: result).toJSON()
    }
    
    @MainActor
    func handlePrepare(id: Int, paramsData: Data?) async -> Data? {
         if !initialized {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(PrepareParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        struct Empty: Codable {}
        
        do {
            try await session.index(targetIds: params.targets.map(\.uri))
            return BSPResponse<Empty>(id: params.originId ?? id, result: nil).toJSON()
        } catch {
            return createErrorResponse(id: id, code: -32803, message: "Index failed")
        }
    }
    
    private func handleTextDocumentRegisterForChanges(id: Int, paramsData: Data?) -> Data? {
        if !initialized {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(TextDocumentRegisterForChangesParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        logger.info("Document change action: \(params.action) for URI: \(params.uri)")
        
        // Handle the register or unregister action
        if params.action == "register" {
            // Here you would add the document to a list of watched files
            logger.info("Registered document for change notifications: \(params.uri)")
        } else if params.action == "unregister" {
            // Here you would remove the document from the list of watched files
            logger.info("Unregistered document from change notifications: \(params.uri)")
        } else {
            logger.error("Unknown action: \(params.action)")
            return createErrorResponse(id: id, code: -32602, message: "Unknown action: \(params.action)")
        }
        
        let result = TextDocumentRegisterForChangesResult(statusCode: 0) // 0 for success
        return BSPResponse(id: id, result: result).toJSON()
    }
    
    @MainActor
    private func handleSourceKitOptions(id: Int, paramsData: Data?) async -> Data? {
        if !initialized {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(TextDocumentSourceKitOptionsRequest.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        do {
            let result = try await session.compilerArgument(targetId: params.target.uri, sourceFile: params.textDocument.uri)
            return BSPResponse(id: id, result: TextDocumentSourceKitOptionsResult(compilerArguments: result, workingDirectory: nil)).toJSON()
        } catch {
            return createErrorResponse(id: id, code: -32803, message: "Fetch target wrong")
        }
        
    }
    
    @MainActor
    private func handleWorkspaceBuildTargets(id: Int) async -> Data? {
        guard initialized else {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        do {
            let targets = try await session.fetchTargets()
            let result = WorkspaceBuildTargetsResult(targets: targets)
            return BSPResponse(id: id, result: result).toJSON()
        } catch {
            return createErrorResponse(id: id, code: -32803, message: "Fetch target wrong")
        }
    }
    
    @MainActor
    private func handleBuildTargetSources(id: Int, paramsData: Data?) async -> Data? {
        if !initialized {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(SourcesParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        var set: Array<SourcesItem> = []
        for target in params.targets {
            do {
                let items = try await self.session.sourceItems(for: target.uri)
                set.append(SourcesItem.init(target: BuildTargetIdentifier(uri: target.uri), sources: items))
            } catch {
                continue
            }
        }
        
        let result = SourcesResult(items: Array(set))
        return BSPResponse(id: id, result: result).toJSON()
    }
    
    private func handleBuildTargetDependencySources(id: Int, paramsData: Data?) -> Data? {
        if !initialized {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(DependencySourcesParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        var items: [DependencySourcesItem] = []
        
        for targetIdentifier in params.targets {
            // Here you would find dependency sources for each target
            // This is a simplified example
            let sources: [String] = [
                "file:///Users/yangxuesi/Projects/MyApp/Frameworks/Dependency1",
                "file:///Users/yangxuesi/Projects/MyApp/Frameworks/Dependency2"
            ]
            
            items.append(DependencySourcesItem(target: targetIdentifier, sources: sources))
        }
        
        let result = DependencySourcesResult(items: items)
        return BSPResponse(id: id, result: result).toJSON()
    }
    
    private func handleBuildTargetCompile(id: Int, paramsData: Data?) -> Data? {
        if !initialized {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(CompileParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        logger.info("Compiling targets: \(params.targets)")
        
        // Here you would initiate an Xcode build for the specified targets
        // This is a simplified example
        
        let result = CompileResult(
            originId: params.originId,
            statusCode: 0, // 0 for success
            data: nil
        )
        
        return BSPResponse(id: id, result: result).toJSON()
    }
    
    private func handleBuildTargetTest(id: Int, paramsData: Data?) -> Data? {
        if !initialized {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(TestParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        logger.info("Testing targets: \(params.targets)")
        
        // Here you would run Xcode tests for the specified targets
        // This is a simplified example
        
        let result = TestResult(
            originId: params.originId,
            statusCode: 0, // 0 for success
            data: nil
        )
        
        return BSPResponse(id: id, result: result).toJSON()
    }
    
    private func handleBuildTargetRun(id: Int, paramsData: Data?) -> Data? {
        if !initialized {
            return createErrorResponse(id: id, code: -32803, message: "Server not initialized")
        }
        
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(RunParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        // Here you would run the Xcode target
        // This is a simplified example
        
        let result = RunResult(
            originId: params.originId,
            statusCode: 0, // 0 for success
            data: nil
        )
        
        return BSPResponse(id: id, result: result).toJSON()
    }
    
    private func handleCancelRequest(id: Int, paramsData: Data?) -> Data? {
        guard let paramsData = paramsData,
              let params = try? JSONDecoder().decode(CancelParams.self, from: paramsData) else {
            return createErrorResponse(id: id, code: -32602, message: "Invalid params")
        }
        
        logger.info("Cancelling request with id: \(params.id)")
        
        // Here you would cancel an ongoing operation associated with the specified id
        // This is a simplified example
        
        let result: [String: String] = [:]
        return BSPResponse(id: id, result: result).toJSON()
    }
    
    private func createErrorResponse(id: Int, code: Int, message: String) -> Data? {
        let error = BSPError(code: code, message: message, data: nil)
        let response = BSPErrorResponse(id: id, error: error)
        return response.toJSON()
    }
}


@MainActor func processData(data: Data) {
    guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
        logger.error("Failed to parse JSON")
        return
    }

    Task {
        guard let responseData = await bspServer.handleRequest(json: json) else {
            logger.error("Failed to handle request")
            return
        }
        
        // Write response back to stdout
        let contentLength = responseData.count
        
        if let responseString = String(data: responseData, encoding: .utf8) {
            let s = "Content-Length: \(contentLength)\r\n\r\n\(responseString)"
            do {
                try FileHandle.standardOutput.write(contentsOf: s.data(using: .utf8)!)
            } catch {
                logger.error("Failed to encode response failed")
            }
        } else {
            logger.error("Failed to encode response as string")
        }
    }
}

logger.info("Begin")

let path = ProcessInfo.processInfo.arguments[1]
let outputDir = ProcessInfo.processInfo.arguments[2]

// Main entry point
let bspServer = BSPServer(yaml: path, outputDir: outputDir)

let reader = BSPInputReader { messageData in
    processData(data: messageData)
}

reader.start()

dispatchMain()


//let bspServer = BSPServer(yaml: "", outputDir: "")
//let session = Session(yaml: "/Users/yangxuesi/Documents/codebase/VPNApp/Neo/project.yml", outputDir: "/Users/yangxuesi/Documents/codebase/VPNApp/Neo/output")
//try await session.load()
//let targets = try await session.fetchTargets()
//print(await session.db)
