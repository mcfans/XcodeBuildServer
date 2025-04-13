//
//  main.swift
//  XcodeBuildServer
//
//  Created by 杨学思 on 2025/3/30.
//
//

import Foundation
import BuildServerProtocol
import LanguageServerProtocolJSONRPC
import LanguageServerProtocol
import ArgumentParser
import SWBUtil

enum Platform: String, ExpressibleByArgument {
    case macOS = "macosx"
    case iOS = "iphoneos"
    case iOSSimulator = "iphonesimulator"
    case tvOS = "appletvos"
    case tvOSSimulator = "appletvsimulator"
    case watchOS = "watchos"
    case watchOSSimulator = "watchsimulator"
    case visionOS = "xros"
    case visionOSSimulator = "xrsimulator"
}

struct InitCommand: ParsableCommand {
    @Option(name: .shortAndLong, help: "Workspace")
    var workspace: String

    @Option(name: .shortAndLong, help: "Target")
    var target: String

    @Option(name: .shortAndLong, help: "Configuration")
    var configuration: String?

    @Option(name: .shortAndLong, help: "Output Directory")
    var outputDir: String?

    @Option(name: .shortAndLong, help: "Platform")
    var platform: Platform?

    @Option(name: .shortAndLong, help: "Architecture")
    var architecture: String?
    
    func run() throws {
        let jsonRPCConnection = JSONRPCConnection(name: "Server", protocol: bspRegistry, inFD: .standardInput, outFD: .standardOutput)
        let outputDirPath: Path
        if let outputDir {
            outputDirPath = Path(outputDir)
        } else {
            outputDirPath = Path.currentDirectory.join("output")
        }
        let session = Session(workspace: Path(workspace), configuration: configuration, outputDir: outputDirPath, target: target, platform: platform, architecture: architecture)
        let handler = Handler(session: session, jsonRPCConnection: jsonRPCConnection)
        
        jsonRPCConnection.start(receiveHandler: handler, closeHandler: {
            quit()
        })
        RunLoop.main.run()
    }
}

func quit() {
    exit(0)
}

final class Handler: LanguageServerProtocol.MessageHandler {
    let session: Session
    let jsonRPCConnection: JSONRPCConnection
    
    init(session: Session, jsonRPCConnection: JSONRPCConnection) {
        self.session = session
        self.jsonRPCConnection = jsonRPCConnection
    }
    
    func handle(_ notification: some LanguageServerProtocol.NotificationType) {
    }
    
    func handle<Request>(_ request: Request, id: LanguageServerProtocol.RequestID, reply: @escaping @Sendable (LanguageServerProtocol.LSPResult<Request.Response>) -> Void) where Request : LanguageServerProtocol.RequestType {
        switch request {
        case _ as BuildServerProtocol.InitializeBuildRequest:
            Task {
                do {
                    let resp = try await self.session.initialize()
                    reply(.success(resp as! Request.Response))
                } catch {
                    reply(.failure(.invalidParams(error.localizedDescription)))
                }
            }
        case _ as BuildServerProtocol.WorkspaceBuildTargetsRequest:
            Task {
                do {
                    let targets = await self.session.fetchTargets()
                    let resp = WorkspaceBuildTargetsResponse.init(targets: targets)
                    reply(.success(resp as! Request.Response))
                }
            }
        case let request as BuildServerProtocol.BuildTargetSourcesRequest:
            Task {
                do {
                    var sourceItems: [SourcesItem] = []
                    for target in request.targets {
                        let sources = try await self.session.fetchSources(targetId: target)
                        let sourcesItem = SourcesItem.init(target: target, sources: sources)
                        sourceItems.append(sourcesItem)
                    }
                    let resp = BuildTargetSourcesResponse.init(items: sourceItems)
                    reply(.success(resp as! Request.Response))
                } catch {
                    reply(.failure(.internalError(error.localizedDescription)))
                }
            }
        case let req as BuildServerProtocol.TextDocumentSourceKitOptionsRequest:
            Task {
                do {
                    let result = try await self.session.compilerArgument(targetId: req.target, sourceFile: req.textDocument.uri)

                    let resp = BuildServerProtocol.TextDocumentSourceKitOptionsResponse(compilerArguments: result)

                    reply(.success(resp as! Request.Response))
                } catch {
                    reply(.failure(.internalError(error.localizedDescription)))
                }
            }
        case let req as BuildServerProtocol.BuildTargetPrepareRequest:
            Task {
                do {
                    try await self.session.prepare(targetId: req.targets, jsonRRC: self.jsonRPCConnection)
                    let resp = VoidResponse()
                    reply(.success(resp as! Request.Response))
                } catch {
                    reply(.failure(.internalError(error.localizedDescription)))
                }
            }
        case _ as BuildServerProtocol.BuildShutdownRequest:
            reply(.success(VoidResponse() as! Request.Response))
            exit(0)
        case _ as BuildServerProtocol.OnBuildExitNotification:
            exit(0)
        default:
            reply(.failure(.methodNotFound(Request.method)))
            return
        }
    }
}

InitCommand.main()
