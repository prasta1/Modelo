import Foundation

/// `@AppStorage` keys for the opt-in filesystem/shell tools (all default off / empty).
enum FSToolSettings {
    static let enabledKey = "fsToolsEnabled"   // master switch for read/write/edit/grep/glob
    static let shellKey   = "fsToolsShell"     // extra switch for the bash tool
    static let rootKey    = "fsToolsRoot"      // workspace directory the tools are confined to

    /// Default workspace when the user hasn't picked one: an isolated, auto-created
    /// `~/.modelo` sandbox — never the home dir or `/`, so a stray call can't roam.
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".modelo")
    }

    /// The workspace folder in effect for a stored setting (default if unset).
    static func effectiveRoot(_ root: String) -> URL {
        root.isEmpty ? defaultRoot : URL(filePath: root)
    }

    /// Builds the enabled tool set, confined to the effective workspace (created if
    /// missing). Returns `[]` if disabled or the path can't be a directory.
    @MainActor
    static func tools(enabled: Bool, shell: Bool, root: String) -> [any Tool] {
        guard enabled else { return [] }
        let url = effectiveRoot(root)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            guard isDir.boolValue else { return [] }   // a file sits where the workspace should be
        } else {
            guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil
            else { return [] }
        }
        let scope = WorkspaceScope(root: url)
        var tools: [any Tool] = [
            ReadFileTool(scope: scope), WriteFileTool(scope: scope), EditFileTool(scope: scope),
            GrepTool(scope: scope), GlobTool(scope: scope)
        ]
        if shell { tools.append(BashTool(scope: scope)) }
        return tools
    }
}

/// Errors from the first-party filesystem/shell tools, phrased so a (possibly weak)
/// model gets an actionable message it can correct from on the next round.
enum FSToolError: LocalizedError {
    case outsideWorkspace(String)
    case notFound(String)
    case notReadable(String)
    case tooLarge(String, Int)
    case stringNotFound
    case stringNotUnique(Int)
    case badArguments(String)

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let p): "Path \"\(p)\" is outside the allowed workspace folder."
        case .notFound(let p):         "No file at \"\(p)\"."
        case .notReadable(let p):      "Could not read \"\(p)\" (not a UTF-8 text file?)."
        case .tooLarge(let p, let n):  "\"\(p)\" is too large (\(n) bytes); read a smaller file."
        case .stringNotFound:          "`old_string` was not found in the file. Read the file first and copy the exact text."
        case .stringNotUnique(let n):  "`old_string` matches \(n) places; add surrounding context so it's unique (or set replace_all)."
        case .badArguments(let why):   "Invalid arguments: \(why)"
        }
    }
}

/// Confines tool file access to a single user-chosen root, blocking path traversal.
/// Not a hardened sandbox — a deliberate guardrail plus the opt-in + approval gates.
struct WorkspaceScope: Sendable {
    let root: URL

    init(root: URL) { self.root = root.standardizedFileURL.resolvingSymlinksInPath() }

    /// Resolve a model-supplied path (absolute or relative to root) to a URL proven to
    /// sit inside the workspace. Works for not-yet-existing files (writes).
    func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw FSToolError.badArguments("empty path") }
        let raw = trimmed.hasPrefix("/") ? URL(filePath: trimmed) : root.appending(path: trimmed)
        // Resolve symlinks before the boundary check — a link *inside* the workspace can
        // otherwise point outside it and smuggle reads/writes past the guard. For a
        // not-yet-existing target (writes), resolve the nearest existing ancestor and
        // re-attach the missing tail.
        let resolved = Self.resolvingSymlinks(raw.standardizedFileURL)
        let rootPath = root.path
        guard resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/") else {
            throw FSToolError.outsideWorkspace(path)
        }
        return resolved
    }

    /// Symlink-resolve `url`, tolerating a path that doesn't exist yet by resolving the
    /// deepest existing ancestor and re-appending the remaining components.
    private static func resolvingSymlinks(_ url: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath() }
        var missing: [String] = []
        var dir = url
        while dir.path != "/" && !fm.fileExists(atPath: dir.path) {
            missing.append(dir.lastPathComponent)
            dir = dir.deletingLastPathComponent()
        }
        var base = dir.resolvingSymlinksInPath()
        for comp in missing.reversed() { base.append(path: comp) }
        return base.standardizedFileURL
    }

    /// A workspace-relative display path for results/previews.
    func relative(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        if p == root.path { return "." }
        if p.hasPrefix(root.path + "/") { return String(p.dropFirst(root.path.count + 1)) }
        return p
    }
}

// MARK: - Decoding helper

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    do { return try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
    catch { throw FSToolError.badArguments("expected \(T.self) — \(error.localizedDescription)") }
}

// MARK: - Read (read-only)

struct ReadFileTool: Tool {
    let scope: WorkspaceScope
    let name = "read_file"
    var description: String {
        "Read a UTF-8 text file inside the workspace and return its contents with line numbers. Paths are relative to the workspace root."
    }
    var parameters: JSONSchema {
        JSONSchema(properties: ["path": .init("string", "File path, relative to the workspace root.")],
                   required: ["path"])
    }

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let path: String }
        let url = try scope.resolve(try decode(Args.self, argumentsJSON).path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FSToolError.notFound(scope.relative(url)) }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > 1_000_000 { throw FSToolError.tooLarge(scope.relative(url), size) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw FSToolError.notReadable(scope.relative(url)) }
        return text.components(separatedBy: "\n").enumerated()
            .map { "\($0 + 1)\t\($1)" }
            .joined(separator: "\n")
    }
}

// MARK: - Write (mutating)

struct WriteFileTool: Tool {
    let scope: WorkspaceScope
    let name = "write_file"
    let isMutating = true
    var description: String {
        "Create or overwrite a text file inside the workspace. Requires user approval. Paths are relative to the workspace root."
    }
    var parameters: JSONSchema {
        JSONSchema(properties: [
            "path": .init("string", "File path, relative to the workspace root."),
            "content": .init("string", "The full new contents of the file.")
        ], required: ["path", "content"])
    }

    private struct Args: Decodable { let path: String; let content: String }

    func approvalPreview(argumentsJSON: String) -> ToolApprovalPreview? {
        guard let args = try? decode(Args.self, argumentsJSON),
              let url = try? scope.resolve(args.path) else { return nil }
        let exists = FileManager.default.fileExists(atPath: url.path)
        let body = args.content.count > 4000 ? String(args.content.prefix(4000)) + "\n… (truncated)" : args.content
        return ToolApprovalPreview(kind: .write,
                                   title: "\(exists ? "Overwrite" : "Create") \(scope.relative(url))",
                                   detail: body)
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = try decode(Args.self, argumentsJSON)
        let url = try scope.resolve(args.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try args.content.write(to: url, atomically: true, encoding: .utf8)
        return "Wrote \(args.content.utf8.count) bytes to \(scope.relative(url))."
    }
}

// MARK: - Edit (mutating)

struct EditFileTool: Tool {
    let scope: WorkspaceScope
    let name = "edit_file"
    let isMutating = true
    var description: String {
        "Replace an exact string in a workspace file with new text. Requires user approval. `old_string` must match exactly and be unique unless replace_all is true."
    }
    var parameters: JSONSchema {
        JSONSchema(properties: [
            "path": .init("string", "File path, relative to the workspace root."),
            "old_string": .init("string", "Exact text to replace."),
            "new_string": .init("string", "Replacement text."),
            "replace_all": .init("boolean", "Replace every occurrence (default false).")
        ], required: ["path", "old_string", "new_string"])
    }

    private struct Args: Decodable {
        let path: String; let old_string: String; let new_string: String; let replace_all: Bool?
    }

    /// Returns the edited file contents, or throws an actionable error.
    private func apply(_ args: Args, to text: String) throws -> String {
        // An empty old_string would "match" between every character and produce a
        // surprising mass edit; reject it with an actionable error instead.
        guard !args.old_string.isEmpty else {
            throw FSToolError.badArguments("old_string must not be empty")
        }
        let count = text.components(separatedBy: args.old_string).count - 1
        if count == 0 { throw FSToolError.stringNotFound }
        if count > 1 && args.replace_all != true { throw FSToolError.stringNotUnique(count) }
        return text.replacingOccurrences(of: args.old_string, with: args.new_string)
    }

    func approvalPreview(argumentsJSON: String) -> ToolApprovalPreview? {
        guard let args = try? decode(Args.self, argumentsJSON),
              let url = try? scope.resolve(args.path) else { return nil }
        func clip(_ s: String) -> String { s.count > 600 ? String(s.prefix(600)) + "…" : s }
        let diff = "- " + clip(args.old_string).replacingOccurrences(of: "\n", with: "\n- ")
                 + "\n+ " + clip(args.new_string).replacingOccurrences(of: "\n", with: "\n+ ")
        return ToolApprovalPreview(kind: .edit, title: "Edit \(scope.relative(url))", detail: diff)
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args = try decode(Args.self, argumentsJSON)
        let url = try scope.resolve(args.path)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw FSToolError.notFound(scope.relative(url)) }
        let updated = try apply(args, to: text)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return "Edited \(scope.relative(url))."
    }
}

// MARK: - Glob (read-only)

struct GlobTool: Tool {
    let scope: WorkspaceScope
    let name = "glob"
    var description: String {
        "List files in the workspace matching a glob pattern (e.g. \"**/*.swift\", \"src/*.ts\"). Returns workspace-relative paths."
    }
    var parameters: JSONSchema {
        JSONSchema(properties: ["pattern": .init("string", "Glob pattern, e.g. **/*.md")], required: ["pattern"])
    }

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let pattern: String }
        let pattern = try decode(Args.self, argumentsJSON).pattern
        let regex = GlobMatch.regex(for: pattern)
        var hits: [String] = []
        for url in FileWalker.files(under: scope.root) {
            let rel = scope.relative(url)
            if rel.range(of: regex, options: .regularExpression) != nil { hits.append(rel) }
            if hits.count >= 500 { break }
        }
        if hits.isEmpty { return "No files match \"\(pattern)\"." }
        return hits.sorted().joined(separator: "\n")
    }
}

// MARK: - Grep (read-only)

struct GrepTool: Tool {
    let scope: WorkspaceScope
    let name = "grep"
    var description: String {
        "Search file contents in the workspace for a regular expression. Returns matching \"path:line: text\" lines (capped)."
    }
    var parameters: JSONSchema {
        JSONSchema(properties: [
            "pattern": .init("string", "Regular expression to search for."),
            "path": .init("string", "Optional subdirectory to limit the search to.")
        ], required: ["pattern"])
    }

    func execute(argumentsJSON: String) async throws -> String {
        struct Args: Decodable { let pattern: String; let path: String? }
        let args = try decode(Args.self, argumentsJSON)
        let base = try args.path.map { try scope.resolve($0) } ?? scope.root
        var out: [String] = []
        outer: for url in FileWalker.files(under: base) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                if line.range(of: args.pattern, options: .regularExpression) != nil {
                    let trimmed = line.count > 200 ? String(line.prefix(200)) + "…" : line
                    out.append("\(scope.relative(url)):\(i + 1): \(trimmed.trimmingCharacters(in: .whitespaces))")
                    if out.count >= 200 { out.append("… (more matches; refine the pattern)"); break outer }
                }
            }
        }
        return out.isEmpty ? "No matches for /\(args.pattern)/." : out.joined(separator: "\n")
    }
}

// MARK: - Bash (mutating; separately gated)

struct BashTool: Tool {
    let scope: WorkspaceScope
    let timeout: TimeInterval
    let name = "bash"
    let isMutating = true

    init(scope: WorkspaceScope, timeout: TimeInterval = 30) {
        self.scope = scope; self.timeout = timeout
    }

    var description: String {
        "Run a shell command in the workspace directory and return its combined stdout/stderr. Requires user approval. Use for build/test/git and other CLI tasks."
    }
    var parameters: JSONSchema {
        JSONSchema(properties: ["command": .init("string", "The shell command to run.")], required: ["command"])
    }

    private struct Args: Decodable { let command: String }

    func approvalPreview(argumentsJSON: String) -> ToolApprovalPreview? {
        guard let args = try? decode(Args.self, argumentsJSON) else { return nil }
        return ToolApprovalPreview(kind: .shell, title: "Run in \(scope.root.lastPathComponent)", detail: args.command)
    }

    func execute(argumentsJSON: String) async throws -> String {
        let command = try decode(Args.self, argumentsJSON).command
        let (output, code) = await Shell.run(command, cwd: scope.root, timeout: timeout)
        let trimmed = output.count > 30_000 ? String(output.prefix(30_000)) + "\n… (output truncated)" : output
        let body = trimmed.isEmpty ? "(no output)" : trimmed
        return code == 0 ? body : "Exit code \(code).\n\(body)"
    }
}

// MARK: - Support: file walking, glob, shell

/// Recursively lists regular files under a root, skipping noise dirs and hidden files.
enum FileWalker {
    static let skipDirs: Set<String> = [".git", "node_modules", ".build", "build", "build-release",
                                        ".venv", "venv", "__pycache__", "DerivedData", ".next", "dist"]

    static func files(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if vals?.isDirectory == true {
                if skipDirs.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            if vals?.isRegularFile == true { out.append(url) }
            if out.count >= 20_000 { break }   // safety cap on huge trees
        }
        return out
    }
}

/// Translates a shell glob to an anchored regex (`*`, `**`, `?` supported).
enum GlobMatch {
    static func regex(for pattern: String) -> String {
        var re = "^"
        var chars = Array(pattern)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "*":
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    re += ".*"; i += 1                 // ** → any depth
                    if i + 1 < chars.count && chars[i + 1] == "/" { i += 1 }
                } else {
                    re += "[^/]*"                       // * → within a path segment
                }
            case "?": re += "[^/]"
            case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
                re += "\\\(c)"
            default: re.append(c)
            }
            i += 1
        }
        return re + "$"
    }
}

/// Runs a shell command off the main actor with a hard timeout, draining output
/// continuously so large output can't deadlock on a full pipe buffer.
enum Shell {
    static func run(_ command: String, cwd: URL, timeout: TimeInterval) async -> (output: String, code: Int32) {
        await withCheckedContinuation { (cont: CheckedContinuation<(String, Int32), Never>) in
            let proc = Process()
            proc.executableURL = URL(filePath: "/bin/zsh")
            proc.arguments = ["-lc", command]
            proc.currentDirectoryURL = cwd
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            let lock = NSLock()
            var buffer = Data()
            var finished = false
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                lock.lock(); buffer.append(chunk); lock.unlock()
            }
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if !finished {
                    finished = true
                    buffer.append(rest)
                    let text = String(decoding: buffer, as: UTF8.self)
                    lock.unlock()
                    cont.resume(returning: (text, p.terminationStatus))
                } else { lock.unlock() }
            }
            do { try proc.run() } catch {
                cont.resume(returning: ("Failed to start command: \(error.localizedDescription)", -1))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard proc.isRunning else { return }
                proc.terminate()   // SIGTERM
                // Escalate if the command ignores SIGTERM, so the continuation always
                // resumes (terminationHandler fires once the process actually dies).
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}
