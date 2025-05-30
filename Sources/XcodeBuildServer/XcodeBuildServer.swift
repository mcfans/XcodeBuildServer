import BuildServerProtocol
import Foundation
import LanguageServerProtocol
import LanguageServerProtocolJSONRPC
import SWBCore
import SWBUtil
import SwiftBuild
import os
import Semaphore

enum XcodeBuildServerError: Error {
    case targetInvalid
    case configurationInvalid
    case sessionNotLoaded
}

actor Session {
    let workspace: Path
    let configuration: String?
    let outputDir: Path
    let target: String
    let platform: Platform?
    let architecture: String?

    var session: SWBBuildServiceSession?
    var selectedConfiguration: String?
    var targets: [Target] = []
    var files: [FileInfo] = []

    var targetBuildSettings: [String: SWBIndexingFileSettings] = [:]
    
    let semaphore = AsyncSemaphore(value: 1)

    var initialized: Bool {
        session != nil
    }

    init(
        workspace: Path, configuration: String?, outputDir: Path, target: String,
        platform: Platform?, architecture: String?
    ) {
        self.workspace = workspace
        self.configuration = configuration
        self.outputDir = outputDir
        self.target = target
        self.platform = platform
        self.architecture = architecture
    }

    func arenaInfo() -> SWBArenaInfo {
        let derivedDataPath = outputDir.join("DerivedData").str
        let buildProductsPath = outputDir.join("BuildProducts").str
        let buildIntermediatesPath = outputDir.join("BuildIntermediates").str
        let pchPath = outputDir.join("PCH").str
        let indexRegularBuildProductsPath = outputDir.join("IndexBuildProducts").str
        let indexRegularBuildIntermediatesPath = outputDir.join("IndexBuildIntermediates").str
        let indexPCHPath = outputDir.join("IndexPCH").str
        let indexDataStoreFolderPath = outputDir.join("IndexDataStore").str
        let indexEnableDataStore = true
        let arenaInfo = SWBArenaInfo.init(
            derivedDataPath: derivedDataPath, buildProductsPath: buildProductsPath,
            buildIntermediatesPath: buildIntermediatesPath, pchPath: pchPath,
            indexRegularBuildProductsPath: indexRegularBuildProductsPath,
            indexRegularBuildIntermediatesPath: indexRegularBuildIntermediatesPath,
            indexPCHPath: indexPCHPath, indexDataStoreFolderPath: indexDataStoreFolderPath,
            indexEnableDataStore: indexEnableDataStore)
        return arenaInfo
    }

    func initialize() async throws -> InitializeBuildResponse {
        let service = try await SWBBuildService(connectionMode: .inProcess)
        let env = ProcessInfo.processInfo.environment

        let session = try await service.createSession(
            name: "Session", cachePath: outputDir.join("bsp_cache").str,
            inferiorProductsPath: outputDir.join("products").str, environment: env
        ).0.get()
        self.session = session

        let pif = try await pifJSONData(projectPath: workspace.str)
        let propertyList = try PropertyList.fromJSONData(pif)
        let configurations = extractBuildConfigurations(from: propertyList)

        let selected: String
        if let configuration = configuration {
            guard configurations.contains(configuration) else {
                throw XcodeBuildServerError.configurationInvalid
            }
            selected = configuration
        } else {
            selected = configurations.first ?? "Debug"
        }
        self.selectedConfiguration = selected

        let swbPropertyList = try SWBPropertyListItem.init(propertyList)
        try await session.sendPIF(swbPropertyList)
        
        let defaultUserInfo = SWBUserInfo.default
        try await session.setUserInfo(.init(userName: defaultUserInfo.userName, groupName: defaultUserInfo.groupName, uid: defaultUserInfo.uid, gid: defaultUserInfo.gid, homeDirectory: defaultUserInfo.homeDirectory, processEnvironment: ProcessInfo.processInfo.environment, buildSystemEnvironment: ProcessInfo.processInfo.environment))

        let targetInfos = try await session.workspaceInfo().targetInfos
        let containsTarget = targetInfos.contains { $0.targetName == target }

        guard containsTarget else {
            throw XcodeBuildServerError.targetInvalid
        }

        targets = PropertyListParser().extractTargetsFromArray(plist: propertyList)
        files = PropertyListParser().extractFilePath(from: propertyList)

        var capabilities = BuildServerCapabilities()
        capabilities.canReload = true

        let arenaInfo = self.arenaInfo()

        var data = SourceKitInitializeBuildResponseData.init()
        data.outputPathsProvider = true
        data.prepareProvider = true
        data.sourceKitOptionsProvider = true
        data.indexDatabasePath = arenaInfo.indexDataStoreFolderPath
        data.indexStorePath = arenaInfo.indexDataStoreFolderPath

        return InitializeBuildResponse.init(
            displayName: "Xcode Build Server", version: "1.0.0", bspVersion: "2.1.0",
            capabilities: capabilities, data: data.encodeToLSPAny())
    }

    func pifJSONData(projectPath: String) async throws -> Data {
        let fs = localFS

        let containerPath = Path(projectPath)

        func dumpPIF(path: Path, isProject: Bool) async throws -> Path {
            let dir = Path.temporaryDirectory.join("org.swift.swift-build").join("PIF")
            try fs.createDirectory(dir, recursive: true)
            let pifPath = dir.join(Foundation.UUID().description + ".json")
            let argument = isProject ? "-project" : "-workspace"
            let result = try await Process.getOutput(
                url: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["xcodebuild", "-dumpPIF", pifPath.str, argument, path.str],
                currentDirectoryURL: URL(
                    fileURLWithPath: containerPath.dirname.str, isDirectory: true),
                environment: Environment.current)
            if !result.exitStatus.isSuccess {
                throw StubError.error(
                    "Could not dump PIF for '\(path.str)': \(String(decoding: result.stderr, as: UTF8.self))"
                )
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
                throw StubError.error(
                    "Unknown file format of container at path: \(containerPath.str)")
            }
        }

        return Data.init(try fs.read(pifPath).bytes)
    }
    
    func extraConfigurations(from single: PropertyListItem) -> [String] {
        // Extract configurations from the property list
        guard case .plDict(let rootDict) = single else {
            return []
        }
        
        // Navigate to the contents dictionary
        guard case .plDict(let contentsDict) = rootDict["contents"] else {
            return []
        }
        
        // Find the buildConfigurations array
        guard case .plArray(let buildConfigsArray) = contentsDict["buildConfigurations"] else {
            return []
        }
        
        // Extract configuration names from each item in the array
        var configNames: [String] = []
        
        for config in buildConfigsArray {
            if case .plDict(let configDict) = config,
               case .plString(let name) = configDict["name"]
            {
                configNames.append(name)
            }
        }
        
        return configNames
    }
    
    func convertGuidToURI(string: String) -> URI {
        let uri = URL.init(string: "target://uri")!.appending(queryItems: [URLQueryItem.init(name: "guid", value: string)])
        return URI(uri)
    }
    
    func convertURIToGUID(uri: URI) -> String {
        if uri.stringValue.hasPrefix("target://uri") {
            if let components = URLComponents.init(string: uri.stringValue) {
                if components.queryItems?.first?.name == "guid" {
                    if let value = components.queryItems?.first?.value {
                        return value
                    }
                }
            }
        }
        return uri.stringValue
    }

    func extractBuildConfigurations(from propertyList: PropertyListItem) -> [String] {
        guard case let .plArray(items) = propertyList else {
            return []
        }
        var sets: Set<String> = []
        for item in items {
            let list = extraConfigurations(from: item)
            for i in list {
                sets.insert(i)
            }
        }
        
        return Array(sets)
    }

    func fetchTargets() -> [BuildTarget] {
        var buildTargets: [BuildTarget] = []
        for target in targets {
            if target.name != self.target {
                continue
            }
            var tags: [String] = []
            if target.guid.starts(with: "PACKAGE") {
                tags.append("dependency")
            }

            let targetTags: [BuildTargetTag]
            targetTags = tags.map { BuildTargetTag(rawValue: $0) }

            let buildTarget = BuildTarget(
                id: BuildTargetIdentifier(uri: convertGuidToURI(string: target.guid)),
                displayName: target.name, baseDirectory: nil, tags: targetTags,
                capabilities: .init(
                    canCompile: true, canTest: false, canRun: false, canDebug: false),
                languageIds: target.langs(from: self.files),
                dependencies: target.dependencies.map {
                    BuildTargetIdentifier(uri: convertGuidToURI(string: $0.guid))
                }, dataKind: nil, data: nil)

            buildTargets.append(buildTarget)
        }
        return buildTargets
    }

    func fetchSources(targetId: BuildTargetIdentifier) async throws -> [SourceItem] {
        let settings = try await self.fetchTargetBuildSettings(buildTargetId: targetId)
        let outputPath = settings.extractOutputPath()
        var sourceItems: [SourceItem] = []
        let id = convertURIToGUID(uri: targetId.uri)
        if let target = targets.first(where: { $0.guid == id }) {
            for file in target.files {
                if let fileInfo = self.files.first(where: { $0.guid == file.fileReference }) {
                    var path = Path.init(fileInfo.path)
                    if !path.isAbsolute {
                        path = Path.currentDirectory.join(path)
                    }
                    let url = URL(fileURLWithPath: path.str)
                    let uri = URI.init(url)
                    let output = outputPath[path.str]
                    sourceItems.append(SourceItem(uri: uri, kind: .file, generated: false, dataKind: .sourceKit, data: SourceKitSourceItemData.init(outputPath: output).encodeToLSPAny()))
                }
            }
        }
        return sourceItems
    }

    func fetchTargetBuildSettings(buildTargetId: BuildTargetIdentifier) async throws -> SWBIndexingFileSettings {
        logger.info("Fetch sources")
        await semaphore.wait()
        defer {
            semaphore.signal()
            logger.info("Fetch sources done")
        }
        let id = convertURIToGUID(uri: buildTargetId.uri)
        if let settings = targetBuildSettings[id] {
            return settings
        }
        guard let session = session else {
            throw XcodeBuildServerError.sessionNotLoaded
        }

        let uri = convertGuidToURI(string: id)

        let req = buildRequest(for: [BuildTargetIdentifier(uri: uri)])

        let settings = try await session.generateIndexingFileSettings(
            for: req, targetID: id, filePath: nil, outputPathOnly: false, delegate: Indexing())

        targetBuildSettings[id] = settings
        return settings
    }

    func compilerArgument(targetId: BuildTargetIdentifier, sourceFile: URI) async throws -> [String] {
        let settings = try await fetchTargetBuildSettings(buildTargetId: targetId)
        return settings.extractBuildSettings(uri: sourceFile) ?? []
    }
    
    let logger = Logger.init(subsystem: "aaa", category: "bbb")

    func prepare(targetId: [BuildTargetIdentifier], jsonRRC: JSONRPCConnection) async throws {
        guard let session = session else {
            throw XcodeBuildServerError.sessionNotLoaded
        }
        logger.info("Prepare \(targetId)")
        await semaphore.wait()
        defer {
            semaphore.signal()
            logger.info("Prepare done")
        }

        let req = buildRequest(for: targetId)

        let buildOperation = try await session.createBuildOperation(
            request: req, delegate: Indexing())
        let stream = try await buildOperation.start()
        for await message in stream {
            switch message {
            case .diagnostic(let diagnostic):
                let messageType: BuildServerProtocol.MessageType
                switch diagnostic.kind {
                case .error:
                    messageType = .error
                case .warning:
                    messageType = .warning
                case .note:
                    messageType = .info
                default:
                    messageType = .info
                }
//                logger.info("\(diagnostic.message)")
                let notification = OnBuildLogMessageNotification.init(
                    type: messageType, message: diagnostic.message, structure: nil)
                jsonRRC.send(notification)
            case .targetDiagnostic(let targetDiagnostic):
//                logger.info("\(targetDiagnostic.message)")
                let notification = OnBuildLogMessageNotification.init(
                    type: .info, message: targetDiagnostic.message, structure: nil)
                jsonRRC.send(notification)
            case .buildDiagnostic(let buildDiagnostic):
//                logger.info("\(buildDiagnostic.message)")
                let notification = OnBuildLogMessageNotification.init(
                    type: .info, message: buildDiagnostic.message, structure: nil)
                jsonRRC.send(notification)
            case .buildCompleted(let info):
                logger.info("Build done \(info.result.rawValue)")
            default:
                continue
            }
        }
        await buildOperation.waitForCompletion()
    }

    func buildRequest(for targets: [BuildTargetIdentifier]) -> SWBBuildRequest {
        var req = SWBBuildRequest()
        var param = SWBBuildParameters()
        param.action = "build"
        param.arenaInfo = self.arenaInfo()
        param.configurationName = selectedConfiguration
        param.activeRunDestination = SWBRunDestinationInfo(
            platform: platform?.rawValue ?? "iphoneos", sdk: platform?.rawValue ?? "iphoneos",
            sdkVariant: platform?.rawValue ?? "iphoneos",
            targetArchitecture: architecture ?? "arm64",
            supportedArchitectures: [architecture ?? "arm64"], disableOnlyActiveArch: false)

        req.parameters = param
        req.useImplicitDependencies = true
        req.enableIndexBuildArena = true
        req.hideShellScriptEnvironment = false
        for target in targets {
            req.add(target: SWBConfiguredTarget(guid: convertURIToGUID(uri: target.uri), parameters: param))
        }
        return req
    }
}

class Indexing: SWBIndexingDelegate {
    func provisioningTaskInputs(
        targetGUID: String, provisioningSourceData: SwiftBuild.SWBProvisioningTaskInputsSourceData
    ) async -> SwiftBuild.SWBProvisioningTaskInputs {
        SWBProvisioningTaskInputs()
    }

    func executeExternalTool(
        commandLine: [String], workingDirectory: String?, environment: [String: String]
    ) async throws -> SwiftBuild.SWBExternalToolResult {
        return .deferred
    }
}

extension SWBPropertyListItem {
    init(_ propertyListItem: PropertyListItem) throws {
        switch propertyListItem {
        case let .plBool(value):
            self = .plBool(value)
        case let .plInt(value):
            self = .plInt(value)
        case let .plString(value):
            self = .plString(value)
        case let .plData(value):
            self = .plData(value)
        case let .plDate(value):
            self = .plDate(value)
        case let .plDouble(value):
            self = .plDouble(value)
        case let .plArray(value):
            self = try .plArray(value.map { try .init($0) })
        case let .plDict(value):
            self = try .plDict(value.mapValues { try .init($0) })
        case let .plOpaque(value):
            throw StubError.error("Invalid property list object: \(value)")
        }
    }
}

struct Target {
    let name: String
    let guid: String
    let type: String
    let files: [FileReference]
    let dependencies: [Dependency]

    init(name: String, guid: String, type: String) {
        self.name = name
        self.guid = guid
        self.type = type
        self.files = []
        self.dependencies = []
    }

    init(
        name: String, guid: String, type: String, files: [FileReference], dependencies: [Dependency]
    ) {
        self.name = name
        self.guid = guid
        self.type = type
        self.files = files
        self.dependencies = dependencies
    }

    func langs(from files: [FileInfo]) -> [Language] {
        var langs: Set<Language> = []
        for file in self.files  {
            if let info = files.first(where: { $0.guid == file.guid }) {
                let type = info.fileType
                if type == "sourcecode.swift" {
                    langs.insert(.swift)
                } else if type == "sourcecode.c" {
                    langs.insert(.c)
                } else if type == "sourcecode.cpp" {
                    langs.insert(.cpp)
                }
            }
        }

        return Array(langs)
    }
}

struct FileReference {
    let guid: String
    let fileReference: String?
    let phase: String
}

// 定义一个结构体来存储文件信息
struct FileInfo: Hashable {
    let path: String
    let fileType: String
    let guid: String
}


struct Dependency {
    let name: String
    let guid: String
}
class PropertyListParser {
    // 从 PropertyListItem 中提取文件路径的函数
    func extractFilePath(from list: PropertyListItem) -> [FileInfo] {
        var fileInfos: Set<FileInfo> = []
        guard case .plArray(let array) = list else {
            return []
        }
        for i in array {
            let infos = extractFilePaths(from: i)
            for info in infos {
                fileInfos.insert(info)
            }
        }
        return Array(fileInfos)
    }
    
    func extractFilePaths(from single: PropertyListItem) -> [FileInfo] {
        guard case .plDict(let dict) = single,
              let contents = dict["contents"],
              case .plDict(let contentsDict) = contents,
              let groupTree = contentsDict["groupTree"],
              case .plDict(let groupTreeDict) = groupTree else {
            print("无法找到 groupTree 结构")
            return []
        }
        
        var fileInfos = [FileInfo]()
        
        // 递归处理 groupTree
        processGroup(groupTreeDict, parentPath: "", fileInfos: &fileInfos)
        
        return fileInfos
    }
    
    // 递归处理组并提取文件路径
    func processGroup(_ groupDict: [String: PropertyListItem], parentPath: String, fileInfos: inout [FileInfo]) {
        // 获取该组的路径
        let groupPath = getString(from: groupDict["path"]) ?? ""
        
        // 计算当前路径
        var currentPath = parentPath
        if !groupPath.isEmpty {
            if currentPath.isEmpty {
                currentPath = groupPath
            } else {
                currentPath = "\(currentPath)/\(groupPath)"
            }
        }
        
        // 处理当前组的文件
        if let type = getString(from: groupDict["type"]), type == "file" {
            if let fileType = getString(from: groupDict["fileType"]) {
                if let guid = getString(from: groupDict["guid"]) {
                    fileInfos.append(FileInfo.init(path: currentPath, fileType: fileType, guid: guid))
                }
            }
        }
        
        // 递归处理子项
        if let children = groupDict["children"], case .plArray(let childrenArray) = children {
            for child in childrenArray {
                if case .plDict(let childDict) = child {
                    processGroup(childDict, parentPath: currentPath, fileInfos: &fileInfos)
                }
            }
        }
    }

    func extractTargetsFromArray(plist: PropertyListItem) -> [Target] {
        var allTargets: [Target] = []

        // 确保顶层是数组
        guard case .plArray(let items) = plist else { return [] }

        // 处理数组中的每个项目
        for item in items {
            if case .plDict(let rootDict) = item {
                if let targetsFromItem = tryExtractTargetFromDict(rootDict) {
                    allTargets.append(contentsOf: targetsFromItem)
                }
            }
        }

        return allTargets
    }

    private func tryExtractTargetFromDict(_ rootDict: [String: PropertyListItem]) -> [Target]? {
        // 不同层次的尝试
        if let contentsItem = rootDict["contents"],
            case .plDict(let contentsDict) = contentsItem, let type = rootDict["type"],
            type == .plString("target")
        {
            return extractTargetFromContents(contentsDict)
        }

        // 也许就是顶层内容
        return nil
    }

    private func extractTargetFromContents(_ contentsDict: [String: PropertyListItem]) -> [Target]?
    {
        // 提取target名称、GUID和类型
        guard let nameItem = contentsDict["name"], case .plString(let name) = nameItem,
            let guidItem = contentsDict["guid"], case .plString(let guid) = guidItem
        else {
            return nil
        }

        let type =
            getString(from: contentsDict["productTypeIdentifier"]) ?? getString(
                from: contentsDict["type"]) ?? "Unknown"

        // 提取所有文件引用
        var files: [FileReference] = []
        if let buildPhasesItem = contentsDict["buildPhases"],
            case .plArray(let buildPhases) = buildPhasesItem
        {

            for phaseItem in buildPhases {
                if case .plDict(let phaseDict) = phaseItem {
                    let phaseType = getString(from: phaseDict["type"]) ?? "unknown"

                    if let buildFilesItem = phaseDict["buildFiles"],
                        case .plArray(let buildFiles) = buildFilesItem
                    {

                        for fileItem in buildFiles {
                            if case .plDict(let fileDict) = fileItem {
                                let fileGuid = getString(from: fileDict["guid"]) ?? "Unknown"
                                let fileRef = getString(from: fileDict["fileReference"])

                                files.append(
                                    FileReference(
                                        guid: fileGuid, fileReference: fileRef, phase: phaseType))
                            }
                        }
                    }
                }
            }
        }

        // 提取依赖关系
        var dependencies: [Dependency] = []
        if let dependenciesItem = contentsDict["dependencies"],
            case .plArray(let dependenciesArray) = dependenciesItem
        {

            for depItem in dependenciesArray {
                if case .plDict(let depDict) = depItem {
                    let depName = getString(from: depDict["name"]) ?? "Unknown"
                    let depGuid = getString(from: depDict["guid"]) ?? "Unknown"

                    dependencies.append(Dependency(name: depName, guid: depGuid))
                }
            }
        }

        let target = Target(
            name: name, guid: guid, type: type, files: files, dependencies: dependencies)
        return [target]
    }

    // 辅助函数：从PropertyListItem中提取String值
    private func getString(from item: PropertyListItem?) -> String? {
        guard let item = item else { return nil }

        if case .plString(let string) = item {
            return string
        }
        return nil
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
    func extractBuildSettings(uri: URI) -> [String]? {
        // Find the source file info that matches the provided URI
        for item in self.sourceFileBuildInfos {
            let path = item["sourceFilePath"]?.stringValue
            var arr: [String] = []
            if let path {
                let filePath = URL.init(fileURLWithPath: path)
                let fileURI = URI.init(filePath)
                if fileURI == uri {
                    if let arguments = item["swiftASTCommandArguments"]
                        ?? item["clangASTCommandArguments"]
                    {
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
    
    func extractOutputPath() -> [String: String] {
        // Find the source file info that matches the provided URI
        var dict: [String: String] = [:]
        for item in self.sourceFileBuildInfos {
            let path = item["sourceFilePath"]?.stringValue
            let output = item["outputFilePath"]?.stringValue
            if let path, let output {
                dict[path] = output
            }
        }
        return dict
    }
}
