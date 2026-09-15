import CryptoKit
import Foundation
import JavaScriptCore

public enum AsarPatcherError: LocalizedError {
    case invalidFileFormat(String)
    case headerParseFailed(String)
    case frontendNotFound
    case resourceMissing(String)
    case transformFailed(String)
    case stringDecodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidFileFormat(let message): return "Invalid ASAR file format: \(message)"
        case .headerParseFailed(let message): return "ASAR header parse failed: \(message)"
        case .frontendNotFound: return "Could not find Yaagl's Wine frontend script in resources.neu."
        case .resourceMissing(let name): return "Installer resource is missing: \(name)."
        case .transformFailed(let message): return "Could not update Yaagl's Wine frontend: \(message)"
        case .stringDecodingFailed: return "Could not decode Yaagl's frontend JavaScript as UTF-8."
        }
    }
}

public struct AsarPatcher {
    private struct ArchiveMember {
        let path: [String]
        let offset: Int
        let size: Int
    }

    public static func patch(sourcePath: String, outputPath: String, archivePath: String, displayName: String) throws {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let sourceData = try Data(contentsOf: sourceURL)
        let headerSize = try uint32(sourceData, at: 8, description: "header size")
        let headerLength = try uint32(sourceData, at: 12, description: "header JSON size")
        let payloadStart = try checkedAdd(12, Int(headerSize), description: "payload offset")
        let headerEnd = try checkedAdd(16, Int(headerLength), description: "header JSON end")
        guard payloadStart <= sourceData.count, headerEnd <= payloadStart else {
            throw AsarPatcherError.invalidFileFormat("Header exceeds file bounds.")
        }

        var header: [String: Any]
        do {
            header = try JSONSerialization.jsonObject(with: sourceData.subdata(in: 16..<headerEnd)) as? [String: Any] ?? [:]
        } catch {
            throw AsarPatcherError.headerParseFailed(error.localizedDescription)
        }
        guard header["files"] is [String: Any] else {
            throw AsarPatcherError.headerParseFailed("Missing files dictionary.")
        }

        let members = try javascriptMembers(in: header)
        let context = try transformContext()
        let archiveURL = localArchiveURL(for: archivePath)
        var frontendMatched = false
        var replacement: (member: ArchiveMember, source: Data)?

        for member in members.sorted(by: { $0.offset < $1.offset }) {
            let start = try checkedAdd(payloadStart, member.offset, description: "JavaScript member offset")
            let end = try checkedAdd(start, member.size, description: "JavaScript member end")
            guard end <= sourceData.count else {
                throw AsarPatcherError.invalidFileFormat("JavaScript member \(member.path.joined(separator: "/")) exceeds file bounds.")
            }
            guard let javascript = String(data: sourceData.subdata(in: start..<end), encoding: .utf8) else {
                throw AsarPatcherError.stringDecodingFailed
            }
            guard javascript.contains("doStreamingDownload"), javascript.contains("remoteUrl"), javascript.contains("wine_state") else {
                continue
            }
            frontendMatched = true

            let transformed = try transform(javascript, in: context, archiveURL: archiveURL, archivePath: archivePath, displayName: displayName)
            if transformed != javascript {
                guard replacement == nil else {
                    throw AsarPatcherError.transformFailed("Multiple frontend scripts matched the Wine installer.")
                }
                replacement = (member, Data(transformed.utf8))
            }
        }

        guard frontendMatched else {
            throw AsarPatcherError.frontendNotFound
        }
        guard let replacement else {
            if sourcePath != outputPath {
                try atomicallyWrite(sourceData, to: outputPath)
            }
            return
        }

        let oldMetadata = try metadata(for: replacement.member.path, in: header)
        let replacementSize = replacement.source.count
        let sizeDelta = replacementSize - replacement.member.size
        var replacementMetadata = oldMetadata
        replacementMetadata["size"] = replacementSize
        replacementMetadata["integrity"] = integrity(for: replacement.source, preserving: oldMetadata["integrity"])
        try replaceMetadata(replacementMetadata, at: replacement.member.path, in: &header)
        try adjustOffsets(in: &header, after: replacement.member.offset, by: sizeDelta)

        let replacementHeader: Data
        do {
            replacementHeader = try JSONSerialization.data(withJSONObject: header)
        } catch {
            throw AsarPatcherError.headerParseFailed(error.localizedDescription)
        }
        let padding = (4 - (replacementHeader.count % 4)) % 4
        let newHeaderSize = replacementHeader.count + padding + 4
        guard newHeaderSize <= Int(UInt32.max), replacementHeader.count <= Int(UInt32.max) else {
            throw AsarPatcherError.invalidFileFormat("Updated ASAR header is too large.")
        }

        let replacementStart = try checkedAdd(payloadStart, replacement.member.offset, description: "replacement member offset")
        let replacementEnd = try checkedAdd(replacementStart, replacement.member.size, description: "replacement member end")
        var output = Data()
        append(UInt32(4), to: &output)
        append(UInt32(newHeaderSize + 4), to: &output)
        append(UInt32(newHeaderSize), to: &output)
        append(UInt32(replacementHeader.count), to: &output)
        output.append(replacementHeader)
        output.append(Data(repeating: 0, count: padding))
        output.append(sourceData.subdata(in: payloadStart..<replacementStart))
        output.append(replacement.source)
        output.append(sourceData.subdata(in: replacementEnd..<sourceData.count))
        try atomicallyWrite(output, to: outputPath)
    }

    private static func uint32(_ data: Data, at offset: Int, description: String) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else {
            throw AsarPatcherError.invalidFileFormat("Missing \(description).")
        }
        return UInt32(data[offset])
            | UInt32(data[offset + 1]) << 8
            | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    private static func checkedAdd(_ left: Int, _ right: Int, description: String) throws -> Int {
        let (result, overflow) = left.addingReportingOverflow(right)
        guard !overflow, result >= 0 else {
            throw AsarPatcherError.invalidFileFormat("Invalid \(description).")
        }
        return result
    }

    private static func javascriptMembers(in header: [String: Any]) throws -> [ArchiveMember] {
        func members(in directory: [String: Any], path: [String]) throws -> [ArchiveMember] {
            guard let files = directory["files"] as? [String: Any] else { return [] }
            var result: [ArchiveMember] = []
            for (name, value) in files {
                guard let entry = value as? [String: Any] else {
                    throw AsarPatcherError.headerParseFailed("Invalid entry at \((path + [name]).joined(separator: "/")).")
                }
                if entry["files"] != nil {
                    result += try members(in: entry, path: path + [name])
                } else if name.hasSuffix(".js"), let offset = integer(entry["offset"]), let size = integer(entry["size"]), offset >= 0, size >= 0 {
                    result.append(ArchiveMember(path: path + [name], offset: offset, size: size))
                }
            }
            return result
        }
        return try members(in: header, path: [])
    }

    private static func integer(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func metadata(for path: [String], in header: [String: Any]) throws -> [String: Any] {
        guard let name = path.first, let files = header["files"] as? [String: Any], let entry = files[name] as? [String: Any] else {
            throw AsarPatcherError.headerParseFailed("Missing metadata for \(path.joined(separator: "/")).")
        }
        if path.count == 1 { return entry }
        return try metadata(for: Array(path.dropFirst()), in: entry)
    }

    private static func replaceMetadata(_ metadata: [String: Any], at path: [String], in directory: inout [String: Any]) throws {
        guard let name = path.first, var files = directory["files"] as? [String: Any] else {
            throw AsarPatcherError.headerParseFailed("Missing metadata path \(path.joined(separator: "/")).")
        }
        if path.count == 1 {
            files[name] = metadata
        } else {
            guard var child = files[name] as? [String: Any] else {
                throw AsarPatcherError.headerParseFailed("Missing metadata path \(path.joined(separator: "/")).")
            }
            try replaceMetadata(metadata, at: Array(path.dropFirst()), in: &child)
            files[name] = child
        }
        directory["files"] = files
    }

    private static func adjustOffsets(in directory: inout [String: Any], after offset: Int, by delta: Int) throws {
        guard delta != 0, var files = directory["files"] as? [String: Any] else { return }
        for (name, value) in files {
            guard var entry = value as? [String: Any] else {
                throw AsarPatcherError.headerParseFailed("Invalid ASAR entry \(name).")
            }
            if entry["files"] != nil {
                try adjustOffsets(in: &entry, after: offset, by: delta)
            } else if let originalOffset = integer(entry["offset"]), originalOffset > offset {
                let adjusted = try checkedAdd(originalOffset, delta, description: "member offset")
                entry["offset"] = String(adjusted)
            }
            files[name] = entry
        }
        directory["files"] = files
    }

    private static func integrity(for data: Data, preserving original: Any?) -> [String: Any] {
        let original = original as? [String: Any]
        let blockSize = max(integer(original?["blockSize"]) ?? 4 * 1024 * 1024, 1)
        let hash = hexadecimal(SHA256.hash(data: data))
        var blocks: [String] = []
        for start in stride(from: 0, to: data.count, by: blockSize) {
            let end = min(start + blockSize, data.count)
            blocks.append(hexadecimal(SHA256.hash(data: data.subdata(in: start..<end))))
        }
        return ["algorithm": "SHA256", "hash": hash, "blockSize": blockSize, "blocks": blocks]
    }

    private static func hexadecimal(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func atomicallyWrite(_ data: Data, to outputPath: String) throws {
        let destination = URL(fileURLWithPath: outputPath)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).tmp.\(UUID().uuidString)")
        try data.write(to: temporary, options: .withoutOverwriting)
        if FileManager.default.fileExists(atPath: outputPath) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    private static func localArchiveURL(for archivePath: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let path = URL(fileURLWithPath: archivePath).path
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "file://\(encodedPath)"
    }

    private static func transformContext() throws -> JSContext {
        guard let context = JSContext() else {
            throw AsarPatcherError.transformFailed("Could not create a JavaScript context.")
        }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        for resource in ["typescript.js", "AsarTransform.js"] {
            let contents = try String(contentsOf: try resourceURL(resource), encoding: .utf8)
            _ = context.evaluateScript(contents, withSourceURL: URL(fileURLWithPath: resource))
            if let exception {
                throw AsarPatcherError.transformFailed("\(resource): \(exception)")
            }
        }
        guard context.objectForKeyedSubscript("__asarTransform") != nil else {
            throw AsarPatcherError.transformFailed("Bundled transform did not load.")
        }
        return context
    }

    private static func resourceURL(_ resource: String) throws -> URL {
        let fileManager = FileManager.default
        if let bundleResource = Bundle.main.resourceURL?.appendingPathComponent(resource), fileManager.isReadableFile(atPath: bundleResource.path) {
            return bundleResource
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let cliResource = executable.deletingLastPathComponent().appendingPathComponent("resources", isDirectory: true).appendingPathComponent(resource)
        if fileManager.isReadableFile(atPath: cliResource.path) {
            return cliResource
        }
        throw AsarPatcherError.resourceMissing(resource)
    }

    private static func transform(_ source: String, in context: JSContext, archiveURL: String, archivePath: String, displayName: String) throws -> String {
        let archive = URL(fileURLWithPath: archivePath).standardizedFileURL
        let helper = archive.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".zzz-wine-registration/zzz-wine-register")
        let options: [String: Any] = [
            "registrationHelperPath": helper.path,
            "archivePath": archive.path,
            "protectedRuntimeIds": RuntimePackage.protectedRuntimeIds,
        ]
        guard let function = context.objectForKeyedSubscript("__asarTransform"), let result = function.call(withArguments: [source, RuntimePackage.targetRuntimeId, displayName, archiveURL, options]) else {
            throw AsarPatcherError.transformFailed("Bundled transform did not return a result.")
        }
        if let errorValue = result.forProperty("error"), !errorValue.isUndefined, !errorValue.isNull, let error = errorValue.toString(), !error.isEmpty {
            throw AsarPatcherError.transformFailed(error)
        }
        guard let transformed = result.forProperty("source")?.toString() else {
            throw AsarPatcherError.transformFailed("Bundled transform returned no JavaScript source.")
        }
        return transformed
    }
}
