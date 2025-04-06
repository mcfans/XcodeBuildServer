// The Swift Programming Language
// https://docs.swift.org/swift-book

import SwiftBuild
import SWBCore
import Foundation
import SWBUtil

actor Session {
    var session: SWBBuildServiceSession?
    var db: XcodeProjectParser.XcodeTargetDB?
    var indexSettings: [String: SWBIndexingFileSettings] = [:]
    
    let yaml: String
    let outputDir: String
    
    init(yaml: String, outputDir: String) {
        self.yaml = yaml
        self.outputDir = outputDir
    }
    
    enum Error: Swift.Error {
        case invalidOutputDir
        case notLoaded
        case noTarget
        case generateWorkspaceFailed(String)
    }
    
    func load() async throws {
        logger.log("Loading session")
        let workspaceUrl = try await generateWorkspaceIfNeeded()
        let pif = try await pifJSONData(projectPath: workspaceUrl)
        self.db = XcodeProjectParser.parse(jsonData: pif)
        
        let service = try await SWBBuildService(connectionMode: .inProcess)
        let res = await service.createSession(name: "Session", cachePath: outputDir + "/bsp_cache", inferiorProductsPath: outputDir + "/indexPath", environment: nil).0
       
        switch res {
        case .success(let session):
            logger.info("Session \(session.name)")
            try await session.loadWorkspace(containerPath: workspaceUrl)
            self.session = session
        case .failure(let error):
            throw error
        }
    }
    
    func generateWorkspaceIfNeeded() async throws -> String {
        let outputDir = self.outputDir + "/project_cache"
        guard let dirUrl = URL(string: outputDir) else {
            throw Error.invalidOutputDir
        }
        var bool: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dirUrl.path, isDirectory: &bool) {
            try FileManager.default.createDirectory(atPath: dirUrl.path, withIntermediateDirectories: true)
        } else if bool.boolValue == false {
            throw Error.invalidOutputDir
        }
        let process = Process()
        let pipe = Pipe()
        let pipe2 = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "xcodegen -s \(yaml) --project \(dirUrl.path)"]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutputPipe = pipe
        process.standardError = pipe2
        try await process.run()
        let stdout = try pipe.fileHandleForReading.readToEnd()
        
        let stderr = try pipe2.fileHandleForReading.readToEnd()
        
        guard let output = stdout, let s = String.init(data: output, encoding: .utf8) else {
            let s: String
            if let stderr, let output = String.init(data: stderr, encoding: .utf8) {
                s = output
            } else {
                s = "Failed to read output"
            }
            throw Error.generateWorkspaceFailed(s)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Error.generateWorkspaceFailed(s)
        }
        guard let projectPath = extractProjectPath(from: s) else {
            throw Error.generateWorkspaceFailed("Failed to extract project path")
        }
        eprint(s: "Created project path: \(projectPath)")
        return projectPath
    }
    
    func extractProjectPath(from output: String) -> String? {
        // 使用正则表达式匹配"Created project at"后面的路径
        let pattern = "Created project at (.*\\.xcodeproj)"
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        
        let nsString = output as NSString
        let results = regex.matches(in: output, options: [], range: NSRange(location: 0, length: nsString.length))
        
        if let match = results.first {
            let pathRange = match.range(at: 1)
            if pathRange.location != NSNotFound {
                return nsString.substring(with: pathRange)
            }
        }
        return nil
    }
    
    func sourceItems(for targetId: String) throws -> [SourceItem] {
        guard let db else {
            throw Error.notLoaded
        }
        var sourceItem: [SourceItem] = []
        if let files = db.targets.first(where: { $0.id == targetId })?.files {
            for file in files {
                if let fileItem = db.files[file] {
                    if FileManager.default.fileExists(atPath: fileItem.path.str) {
                        let s = fileItem.path.normalize().str
                        let url = URL.init(fileURLWithPath: s)
                        sourceItem.append(SourceItem(uri: url.absoluteString, kind: 1, generated: false))
                    }
                }
            }
        }
        return sourceItem
    }
    
    func fetchTargets() async throws -> [BuildTarget] {
        guard let db else {
            throw Error.notLoaded
        }
        
        var buildTarget: [BuildTarget] = []
        for target in db.targets {
            var tags: [String] = []
            if target.id.starts(with: "PACKAGE") {
                tags.append("dependency")
                if target.id.starts(with: "PACKAGE-") {
                    tags.append("not-buildable")
                }
            }
            buildTarget.append(BuildTarget(id: BuildTargetIdentifier(uri: target.id), displayName: target.name, baseDirectory: nil, tags: tags, capabilities: .init(canCompile: true, canTest: false, canRun: false, canDebug: false), languageIds: target.langs(from: db.files), dependencies: target.dependencies.map(BuildTargetIdentifier.init(uri:)), dataKind: nil, data: nil))
        }
        return buildTarget
    }
    
    func index(targetIds: [String]) async throws {
         guard let session = session else {
            throw Error.notLoaded
        }
        var buildRequest = SWBBuildRequest()
        var param = SWBBuildParameters()
        param.action = "indexbuild"
        param.configurationName = "Debug"
        param.activeRunDestination = SWBRunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: nil, targetArchitecture: "arm64", supportedArchitectures: ["arm64"], disableOnlyActiveArch: false)
        buildRequest.parameters = param
        let targetInfos = try await session.workspaceInfo().targetInfos
        for targetInfo in targetInfos {
            if targetIds.contains(targetInfo.guid) {
                buildRequest.add(target: SWBConfiguredTarget.init(guid: targetInfo.guid, parameters: param))
            }
        }
        let operation = try await session.createBuildOperation(request: buildRequest, delegate: Indexing())
        _ = try await operation.start()
        await operation.waitForCompletion()
    }
    
    func fetchTargetBuildSettings(id: String) async throws -> SWBIndexingFileSettings {
        guard let session = session else {
            throw Error.notLoaded
        }
        if let index = self.indexSettings[id] {
            return index
        }
        var buildRequest = SWBBuildRequest()
        var param = SWBBuildParameters()
        param.action = "indexbuild"
        param.configurationName = "Debug"
        param.activeRunDestination = SWBRunDestinationInfo(platform: "iphoneos", sdk: "iphoneos", sdkVariant: nil, targetArchitecture: "arm64", supportedArchitectures: ["arm64"], disableOnlyActiveArch: false)
        buildRequest.parameters = param
        let targetInfos = try await session.workspaceInfo().targetInfos
        for targetInfo in targetInfos {
            buildRequest.add(target: SWBConfiguredTarget.init(guid: targetInfo.guid, parameters: param))
        }
        let settings = try await session.generateIndexingFileSettings(for: buildRequest, targetID: id, filePath: nil, outputPathOnly: false, delegate: Indexing())
        self.indexSettings[id] = settings
        return settings
    }
    
    func compilerArgument(targetId: String, sourceFile: String) async throws -> [String] {
        let settings = try await fetchTargetBuildSettings(id: targetId)
        return settings.extractBuildSettings(uri: sourceFile) ?? []
    }
    
    func pifJSONData(projectPath: String) async throws -> Data {
        let fs = localFS

        let containerPath = Path(projectPath)

        func dumpPIF(path: Path, isProject: Bool) async throws -> Path {
            let dir = Path.temporaryDirectory.join("org.swift.swift-build").join("PIF")
            try fs.createDirectory(dir, recursive: true)
            let pifPath = dir.join(Foundation.UUID().description + ".json")
            let argument = isProject ? "-project" : "-workspace"
            let result = try await Process.getOutput(url: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["xcodebuild", "-dumpPIF", pifPath.str, argument, path.str], currentDirectoryURL: URL(fileURLWithPath: containerPath.dirname.str, isDirectory: true), environment: Environment.current)
            if !result.exitStatus.isSuccess {
                throw StubError.error("Could not dump PIF for '\(path.str)': \(String(decoding: result.stderr, as: UTF8.self))")
            }
            return pifPath
        }

        let pifPath: Path
        do {
            switch containerPath.fileExtension {
            case "xcodeproj":
                pifPath = try await dumpPIF(path: containerPath, isProject: true)
            case "xcworkspace", "":
                pifPath = try await dumpPIF(path: containerPath, isProject: false)
            case "json", "pif":
                pifPath = containerPath
            default:
                throw StubError.error("Unknown file format of container at path: \(containerPath.str)")
            }
        }
        
        return Data.init(try fs.read(pifPath).bytes)
    }
}

class Indexing: SWBIndexingDelegate {
    func provisioningTaskInputs(targetGUID: String, provisioningSourceData: SwiftBuild.SWBProvisioningTaskInputsSourceData) async -> SwiftBuild.SWBProvisioningTaskInputs {
        SWBProvisioningTaskInputs()
    }
    
    func executeExternalTool(commandLine: [String], workingDirectory: String?, environment: [String : String]) async throws -> SwiftBuild.SWBExternalToolResult {
        .deferred
    }
}

struct XcodeTarget {
    let name: String
    let id: String
    let type: String
    let configurations: [String]
    let dependencies: [String]
    let files: [String]
    
    func langs(from db: [String: XcodeProjectParser.FileItem]) -> [String] {
        var set: Set<String> = []
        for file in files {
            if let fileItem = db[file] {
                switch fileItem.fileType {
                case "sourcecode.swift":
                  set.insert("swift")
                case "sourcecode.c.h":
                    set.insert("c")
                case "sourcecode.c.c":
                    set.insert("c")
                case "sourcecode.c.c++":
                    set.insert("cpp")
                case "sourcecode.c.objc":
                    set.insert("objc")
                case "sourcecode.c.objc++":
                    set.insert("objc++")
                default:
                    continue
                }
            }
        }
        return Array(set)
    }
}

// Main parser class
class XcodeProjectParser {
    
    struct FileItem {
        let path: Path
        let fileType: String
    }
    
    struct XcodeTargetDB {
        let files: [String: FileItem]
        let targets: [XcodeTarget]
    }
    
    static func visitGroupTree(dict: [String: Any], dir: Path, db: inout [String: FileItem]) {
        guard let path = dict["path"] as? String else {
            return
        }
        let type = dict["type"] as? String
        if type == "group" {
            guard let children = dict["children"] as? [[String: Any]] else {
                return
            }
            let s = dir.appendingFileNameSuffix(path).appendingFileNameSuffix("/")
            for child in children {
                visitGroupTree(dict: child, dir: s, db: &db)
            }
        } else if type == "file" {
            guard let guid = dict["guid"] as? String else {
                return
            }
            guard let fileType = dict["fileType"] as? String else {
                return
            }
            let s = dir.appendingFileNameSuffix(path)
            db[guid] = FileItem(path: s, fileType: fileType)
        }
    }
    
    
    // Parse the JSON content and extract target information
    static func parse(jsonData: Data) -> XcodeTargetDB? {
        var targets = [XcodeTarget]()
        
        // First, try to parse the JSON
        guard let json = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [Any] else {
            print("Error: Failed to parse JSON")
            return nil
        }
        
        var db: [String: FileItem] = [:]
        
        for item in json {
            guard let dict = item as? [String: Any],
                  let type = dict["type"] as? String,
                  type == "project",
                  let contents = dict["contents"] as? [String: Any],
                  let groupTree = contents["groupTree"] as? [String: Any],
                  let projectDirectory = contents["projectDirectory"] as? String else {
                continue
            }
            
            visitGroupTree(dict: groupTree, dir: Path(projectDirectory), db: &db)
        }
        
        // Find all target objects
        for item in json {
            guard let dict = item as? [String: Any],
                  let type = dict["type"] as? String,
                  type == "target",
                  let contents = dict["contents"] as? [String: Any],
                  let name = contents["name"] as? String,
                  let guid = contents["guid"] as? String else {
                continue
            }
            
            // Get target type
            let productType = contents["productTypeIdentifier"] as? String ?? "Unknown"
            
            // Extract configurations
            var configurations = [String]()
            if let buildConfigs = contents["buildConfigurations"] as? [[String: Any]] {
                for config in buildConfigs {
                    if let configName = config["name"] as? String {
                        configurations.append(configName)
                    }
                }
            }
            
            // Extract dependencies
            var dependencies = [String]()
            if let deps = contents["dependencies"] as? [[String: Any]] {
                for dep in deps {
                    if let depName = dep["guid"] as? String {
                        dependencies.append(depName)
                    }
                }
            }
            
            // Extract files
            var files = [String]()
            if let buildPhases = contents["buildPhases"] as? [[String: Any]] {
                for phase in buildPhases {
                    if let buildFiles = phase["buildFiles"] as? [[String: Any]] {
                        for file in buildFiles {
                            if let fileRef = file["fileReference"] as? String {
                                files.append(fileRef)
                            }
                        }
                    }
                }
            }
            
            let target = XcodeTarget(
                name: name,
                id: guid,
                type: productType,
                configurations: configurations,
                dependencies: dependencies,
                files: files
            )
            
            targets.append(target)
        }
        
        return XcodeTargetDB(files: db, targets: targets)
    }
}

extension SWBPropertyListItem {
    var stringValue: String? {
        switch self {
        case .plString(let s):
            return s
        default:
            return nil
        }
    }
}

extension SWBIndexingFileSettings {
    func extractBuildSettings(uri: String) -> [String]? {
        // Find the source file info that matches the provided URI
        for item in self.sourceFileBuildInfos {
            let path = item["sourceFilePath"]?.stringValue
            var arr: [String] = []
            if let path {
                let filePath = URL.init(fileURLWithPath: path)
                if filePath.absoluteString == uri {
                    if let arguments = item["swiftASTCommandArguments"] {
                        switch arguments {
                        case .plArray(let items):
                            for s in items {
                                if let v = s.stringValue {
                                    arr.append(v)
                                }
                            }
                        default:
                            continue
                        }
                    }
                    return arr
                }
            }
        }
        return nil
    }
}


