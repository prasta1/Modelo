import Foundation

// MARK: - Path guard

enum ProjectFSError: Error, LocalizedError {
    case outsideRoot(String)
    case fileTooLarge(Int)
    case notUTF8
    case oldStringNotFound
    case oldStringAmbiguous(Int)

    var errorDescription: String? {
        switch self {
        case .outsideRoot(let p): return "Path '\(p)' is outside the project root."
        case .fileTooLarge(let bytes): return "File is too large to read (\(bytes / 1024) KB). Use search_files to locate specific content."
        case .notUTF8: return "File appears to be binary and cannot be read as text."
        case .oldStringNotFound: return "old_string not found in file — no changes made."
        case .oldStringAmbiguous(let n): return "old_string matches \(n) locations; provide more context to make it unique."
        }
    }
}

/// Resolves model-supplied paths against a fixed project root and rejects
/// anything that escapes it (path-traversal guard, including symlinks).
struct ProjectFS: Sendable {
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Resolves `path` (relative or absolute) against the root and verifies it
    /// stays within the root. Empty string / "." resolves to the root itself.
    func resolve(_ path: String) throws -> URL {
        let base: URL
        if path.isEmpty || path == "." {
            base = root
        } else if path.hasPrefix("/") {
            base = URL(fileURLWithPath: path)
        } else {
            base = root.appendingPathComponent(path)
        }
        let resolved = base.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw ProjectFSError.outsideRoot(path)
        }
        return resolved
    }

    /// Prettifies an absolute URL back to a project-relative path for display.
    func relativize(_ url: URL) -> String {
        let p = url.path
        let rootPath = root.path
        if p == rootPath { return "." }
        if p.hasPrefix(rootPath + "/") { return String(p.dropFirst(rootPath.count + 1)) }
        return p
    }
}

// MARK: - list_directory

/// Lists the entries of a directory within the project root.
struct ListDirectoryTool: Tool {
    let name = "list_directory"
    let description = "List the contents of a directory within the project. Returns entry names annotated with / for directories. Paths are relative to the project root."
    let parameters = JSONSchema(
        properties: [
            "path": .init("string", "Directory to list, relative to project root (default: project root)"),
            "show_hidden": .init("boolean", "Include dotfiles (default: false)")
        ],
        required: [])
    let fs: ProjectFS

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let path: String?; let show_hidden: Bool? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let dir = try fs.resolve(args.path ?? "")
        let showHidden = args.show_hidden ?? false
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return "Error: '\(args.path ?? ".")' is not a directory."
        }
        let entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        let filtered = entries.filter { showHidden || !$0.lastPathComponent.hasPrefix(".") }
        let sorted = filtered.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if sorted.isEmpty { return "(empty directory)" }
        return sorted.map { url -> String in
            var isD: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isD)
            return isD.boolValue ? url.lastPathComponent + "/" : url.lastPathComponent
        }.joined(separator: "\n")
    }
}

// MARK: - read_file

private let maxReadBytes = 256 * 1024  // 256 KB

/// Reads a file within the project and returns its text content.
struct ReadFileTool: Tool {
    let name = "read_file"
    let description = "Read the text content of a file within the project. Paths are relative to the project root."
    let parameters = JSONSchema(
        properties: ["path": .init("string", "File path relative to project root")],
        required: ["path"])
    let fs: ProjectFS

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let path: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let url = try fs.resolve(args.path)
        let data = try Data(contentsOf: url)
        if data.count > maxReadBytes { throw ProjectFSError.fileTooLarge(data.count) }
        guard let text = String(data: data, encoding: .utf8) else { throw ProjectFSError.notUTF8 }
        return text
    }
}

// MARK: - search_files

private let maxSearchResults = 200

/// Recursively searches files for a string or regex pattern, returning matching lines.
struct SearchFilesTool: Tool {
    let name = "search_files"
    let description = "Recursively search files in the project for a string or regex pattern. Returns matching lines as 'relative/path:line: content'. Paths are relative to the project root."
    let parameters = JSONSchema(
        properties: [
            "query": .init("string", "Search string or regex pattern"),
            "path": .init("string", "Subdirectory to search within (default: project root)"),
            "case_sensitive": .init("boolean", "Case-sensitive match (default: false)")
        ],
        required: ["query"])
    let fs: ProjectFS

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let query: String; let path: String?; let case_sensitive: Bool? }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let searchRoot = try fs.resolve(args.path ?? "")
        let caseSensitive = args.case_sensitive ?? false
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        let regex = try NSRegularExpression(pattern: args.query, options: options)
        var results: [String] = []
        searchDirectory(searchRoot, regex: regex, results: &results)
        if results.isEmpty { return "No matches found for '\(args.query)'." }
        return results.joined(separator: "\n")
    }

    private func searchDirectory(_ dir: URL, regex: NSRegularExpression, results: inout [String]) {
        guard results.count < maxSearchResults else { return }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: []) else { return }
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            if entry.lastPathComponent.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: entry.path, isDirectory: &isDir)
            if isDir.boolValue {
                searchDirectory(entry, regex: regex, results: &results)
            } else {
                guard let data = try? Data(contentsOf: entry), data.count <= maxReadBytes,
                      let text = String(data: data, encoding: .utf8) else { continue }
                let lines = text.components(separatedBy: "\n")
                for (i, line) in lines.enumerated() {
                    guard results.count < maxSearchResults else { break }
                    let range = NSRange(line.startIndex..., in: line)
                    if regex.firstMatch(in: line, range: range) != nil {
                        results.append("\(fs.relativize(entry)):\(i + 1): \(line)")
                    }
                }
            }
        }
    }
}

// MARK: - write_file

/// Creates or overwrites a file within the project root.
struct WriteFileTool: Tool {
    let name = "write_file"
    let description = "Create or overwrite a file within the project with the given text content. Intermediate directories are created as needed. Paths are relative to the project root."
    let parameters = JSONSchema(
        properties: [
            "path": .init("string", "File path relative to project root"),
            "content": .init("string", "Text content to write")
        ],
        required: ["path", "content"])
    let fs: ProjectFS

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let path: String; let content: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let url = try fs.resolve(args.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try args.content.write(to: url, atomically: true, encoding: .utf8)
        return "Written \(args.content.utf8.count) bytes to \(fs.relativize(url))."
    }
}

// MARK: - edit_file

/// Performs an exact-string replacement within a file, requiring the match to be unique.
struct EditFileTool: Tool {
    let name = "edit_file"
    let description = "Replace an exact string in a file. old_string must appear exactly once in the file; if it appears zero or more than once the edit is rejected. Paths are relative to the project root."
    let parameters = JSONSchema(
        properties: [
            "path": .init("string", "File path relative to project root"),
            "old_string": .init("string", "The exact text to find and replace"),
            "new_string": .init("string", "The replacement text")
        ],
        required: ["path", "old_string", "new_string"])
    let fs: ProjectFS

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let path: String; let old_string: String; let new_string: String }
        let args = try JSONDecoder().decode(Args.self, from: Data(argumentsJSON.utf8))
        let url = try fs.resolve(args.path)
        let data = try Data(contentsOf: url)
        guard let original = String(data: data, encoding: .utf8) else { throw ProjectFSError.notUTF8 }
        let count = original.components(separatedBy: args.old_string).count - 1
        if count == 0 { throw ProjectFSError.oldStringNotFound }
        if count > 1  { throw ProjectFSError.oldStringAmbiguous(count) }
        let updated = original.replacingOccurrences(of: args.old_string, with: args.new_string)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return "Edited \(fs.relativize(url))."
    }
}
