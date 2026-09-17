import Foundation

/// Starts the installed provider CLI without a Terminal window so its official
/// OAuth flow can open in the default browser. Codex writes into a temporary,
/// isolated home and does not touch the currently active CLI credential.
enum CLIBrowserLoginService {
    enum LoginResult: Sendable {
        /// Valid credential bytes produced inside an isolated temporary home.
        case stagedCredential(Data)
        /// The provider CLI committed its credential to its normal live store.
        case liveCredential
    }

    enum LoginError: Error {
        case executableNotFound
        case launchFailed
        case runtimeNotFound
        case stagingUnavailable
        case credentialNotCreated
        case unsuccessfulExit(Int32)
    }

    private struct ProcessResult: Sendable {
        let status: Int32
        let standardError: String
    }

    /// Thread-safe registry that lets application shutdown cancel every login.
    private final class ProcessRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var controllers: [ObjectIdentifier: ProcessController] = [:]

        func insert(_ controller: ProcessController) {
            lock.lock()
            controllers[ObjectIdentifier(controller)] = controller
            lock.unlock()
        }

        func remove(_ controller: ProcessController) {
            lock.lock()
            controllers.removeValue(forKey: ObjectIdentifier(controller))
            lock.unlock()
        }

        func cancelAll() {
            lock.lock()
            let activeControllers = Array(controllers.values)
            lock.unlock()
            for controller in activeControllers { controller.cancel() }
        }
    }

    /// Thread-safe handle used by the task-cancellation handler.
    private final class ProcessController: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancellationRequested = false

        func install(_ process: Process) {
            lock.lock()
            self.process = process
            let shouldTerminate = cancellationRequested
            lock.unlock()
            if shouldTerminate, process.isRunning { process.terminate() }
        }

        func cancel() {
            lock.lock()
            cancellationRequested = true
            let process = process
            lock.unlock()
            if let process, process.isRunning {
                terminateDirectChildren(of: process.processIdentifier)
                process.terminate()
            }
        }

        /// Terminate CLI children before their wrapper is allowed to exit and reparent them.
        ///
        /// - Parameter processID: PID of the launched Node or shell wrapper.
        /// - Side effects: Sends SIGTERM only to direct descendants of that exact PID.
        private func terminateDirectChildren(of processID: Int32) {
            let terminator = Process()
            terminator.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            terminator.arguments = ["-TERM", "-P", String(processID)]
            terminator.standardInput = FileHandle.nullDevice
            terminator.standardOutput = FileHandle.nullDevice
            terminator.standardError = FileHandle.nullDevice
            do {
                try terminator.run()
                terminator.waitUntilExit()
            } catch {
                // The wrapper may have no child yet; terminating it remains sufficient.
            }
        }
    }

    private static let processRegistry = ProcessRegistry()

    /// Cancel every browser-login wrapper and its direct provider CLI child.
    ///
    /// This method has no parameters or return value. It is safe to call more than
    /// once and is used by application termination to prevent orphaned login tasks.
    static func cancelAll() {
        processRegistry.cancelAll()
    }

    /// Run the provider's browser login and wait for the CLI to finish.
    ///
    /// - Parameter provider: Codex or Claude.
    /// - Returns: Staged Codex credential bytes, or an indication that the
    ///   provider wrote its normal live credential store.
    /// - Throws: `LoginError` when the CLI is missing, cannot launch, or exits unsuccessfully.
    /// - Side effects: Opens the default browser. Codex receives a private temporary
    ///   `CODEX_HOME`, removed on every exit path; Claude still uses its normal store.
    static func login(provider: Provider) async throws -> LoginResult {
        guard let executableURL = executableURL(named: provider.cliExecutableName) else {
            throw LoginError.executableNotFound
        }

        let isolatedHome = try makeIsolatedHome(for: provider)
        defer {
            if let isolatedHome {
                try? FileManager.default.removeItem(at: isolatedHome)
            }
        }

        let controller = ProcessController()
        processRegistry.insert(controller)
        defer { processRegistry.remove(controller) }
        let result: ProcessResult = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                let errorPipe = Pipe()
                process.executableURL = executableURL
                process.arguments = provider.cliLoginArguments
                var environment = processEnvironment(
                    executableURL: executableURL,
                    inherited: ProcessInfo.processInfo.environment
                )
                if let isolatedHome,
                    let variable = isolatedHomeEnvironmentVariable(for: provider)
                {
                    environment[variable] = isolatedHome.path
                }
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errorPipe
                process.terminationHandler = { finishedProcess in
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    continuation.resume(
                        returning: ProcessResult(
                            status: finishedProcess.terminationStatus,
                            standardError: String(decoding: data, as: UTF8.self)
                        )
                    )
                }
                controller.install(process)
                do {
                    try process.run()
                    if Task.isCancelled { controller.cancel() }
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: LoginError.launchFailed)
                }
            }
        } onCancel: {
            controller.cancel()
        }

        try Task.checkCancellation()
        guard result.status == 0 else {
            let diagnostic = result.standardError.lowercased()
            if diagnostic.contains("node")
                && (diagnostic.contains("not found") || diagnostic.contains("no such file"))
            {
                throw LoginError.runtimeNotFound
            }
            throw LoginError.unsuccessfulExit(result.status)
        }

        guard let isolatedHome else { return .liveCredential }
        let credentialURL = isolatedHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: credentialURL), !data.isEmpty else {
            throw LoginError.credentialNotCreated
        }
        return .stagedCredential(data)
    }

    /// Environment variable used to isolate a provider's browser-login credential.
    ///
    /// - Parameter provider: Provider whose CLI will be launched.
    /// - Returns: `CODEX_HOME` for Codex; `nil` while Claude continues to use its
    ///   Keychain-backed live login and rollback protection.
    static func isolatedHomeEnvironmentVariable(for provider: Provider) -> String? {
        switch provider {
        case .codex: return "CODEX_HOME"
        case .claude: return nil
        }
    }

    /// Create a private, single-use credential home for providers that support it.
    ///
    /// - Parameter provider: Provider about to begin OAuth.
    /// - Returns: Owner-only temporary directory, or `nil` when isolation is not used.
    /// - Throws: `LoginError.stagingUnavailable` if secure staging cannot be created.
    /// - Side effects: Creates one uniquely named directory that the caller must remove.
    private static func makeIsolatedHome(for provider: Provider) throws -> URL? {
        guard isolatedHomeEnvironmentVariable(for: provider) != nil else { return nil }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AISwitcher-OAuth-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            return directory
        } catch {
            try? fileManager.removeItem(at: directory)
            throw LoginError.stagingUnavailable
        }
    }

    /// Build a GUI-safe environment for scripts that use `/usr/bin/env node`.
    ///
    /// - Parameters:
    ///   - executableURL: Resolved provider CLI path.
    ///   - inherited: Environment inherited by the menu-bar application.
    /// - Returns: Environment whose PATH starts with the CLI's own bin directory,
    ///   followed by common Homebrew/system locations and the inherited entries.
    static func processEnvironment(
        executableURL: URL,
        inherited: [String: String]
    ) -> [String: String] {
        var environment = inherited
        var directories = [
            executableURL.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        directories.append(
            contentsOf: (inherited["PATH"] ?? "")
                .split(separator: ":")
                .map(String.init)
        )

        var visited = Set<String>()
        environment["PATH"] =
            directories
            .filter { !$0.isEmpty && visited.insert($0).inserted }
            .joined(separator: ":")
        return environment
    }

    /// Locate an executable in the GUI process PATH and common Homebrew/NVM paths.
    ///
    /// - Parameter name: Fixed provider executable name (`codex` or `claude`).
    /// - Returns: First executable URL found, preferring the inherited PATH.
    /// GUI apps commonly have a minimal PATH, so NVM versions are checked explicitly.
    static func executableURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        directories.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"])

        let home = fileManager.homeDirectoryForCurrentUser
        directories.append(home.appendingPathComponent(".local/bin").path)

        let nvmRoot = home.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        if let versions = try? fileManager.contentsOfDirectory(
            at: nvmRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            directories.append(
                contentsOf: versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                    .map { $0.appendingPathComponent("bin").path }
            )
        }

        var visited = Set<String>()
        for directory in directories where visited.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
