import Foundation
import Security

/// Opt-in integration check using a uniquely named synthetic item in the default Keychain.
/// Compile alongside ClaudeKeychainStore.swift; deletes only its synthetic item on exit.
@main
enum VerifyClaudeKeychain {
    enum Failure: Error { case check(String) }

    /// Verify missing-item refusal and preservation of CLI-created ACLs after system-tool writes.
    /// No parameters; nonzero exit means a contract failed. Never reads existing credentials.
    static func main() async {
        if CommandLine.arguments.count == 4,
            CommandLine.arguments[1] == "--claude-keychain-metadata",
            CommandLine.arguments[2].hasPrefix("AISwitcher-Synthetic-")
        {
            guard
                let data = ClaudeKeychainStore.metadataOutput(
                    service: CommandLine.arguments[2],
                    keychainPath: CommandLine.arguments[3])
            else { exit(1) }
            FileHandle.standardOutput.write(data)
            exit(0)
        }
        do { try await Task.detached { try verify() }.value } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Create a unique synthetic fixture, exercise production I/O and clean up only that item.
    /// Throws on contract failure; never opens or reads an existing credential's secret.
    private static func verify() throws {
        var defaultKeychain: SecKeychain?
        guard SecKeychainCopyDefault(&defaultKeychain) == errSecSuccess,
            let keychain = defaultKeychain
        else {
            throw Failure.check("Default Keychain unavailable")
        }
        var length: UInt32 = 4096
        var pathBytes = [CChar](repeating: 0, count: Int(length))
        guard SecKeychainGetPath(keychain, &length, &pathBytes) == errSecSuccess else {
            throw Failure.check("Default Keychain path unavailable")
        }
        let path = String(cString: pathBytes)
        let service = "AISwitcher-Synthetic-\(UUID().uuidString) Claude Code"
        guard
            !ClaudeKeychainStore.update(
                Data("synthetic".utf8), service: service, keychain: keychain)
        else {
            throw Failure.check("A missing item must not be created")
        }
        let original = Data("synthetic-before".utf8)
        let updated = Data("synthetic-after".utf8)
        let creator = Process()
        creator.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        creator.arguments = [
            "add-generic-password", "-a", "synthetic", "-s", service,
            "-w", String(decoding: original, as: UTF8.self), "-T", CommandLine.arguments[0],
            "-T", "/usr/bin/security", path,
        ]
        creator.standardOutput = FileHandle.nullDevice
        creator.standardError = FileHandle.nullDevice
        try creator.run()
        creator.waitUntilExit()
        guard creator.terminationStatus == 0 else {
            throw Failure.check("Synthetic fixture creation failed")
        }
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            cleanup.arguments = ["delete-generic-password", "-a", "synthetic", "-s", service, path]
            cleanup.standardOutput = FileHandle.nullDevice
            cleanup.standardError = FileHandle.nullDevice
            do {
                try cleanup.run()
                cleanup.waitUntilExit()
                if cleanup.terminationStatus != 0 {
                    print("FAIL: synthetic item cleanup")
                    exit(1)
                }
            } catch {
                print("FAIL: synthetic item cleanup")
                exit(1)
            }
        }
        let before = try inspectPartitions(path: path, service: service)
        guard before.contains("apple-tool:") else {
            throw Failure.check("Expected system-reader partition")
        }
        try readWithSystemTool(path: path, service: service, expected: original)
        guard ClaudeKeychainStore.update(updated, service: service, keychain: keychain) else {
            throw Failure.check("Synthetic credential update failed")
        }
        guard try inspectPartitions(path: path, service: service) == before else {
            throw Failure.check("Updating credential bytes changed the partition ACL")
        }
        guard ClaudeKeychainStore.read(service: service, keychain: keychain) == updated else {
            throw Failure.check("Production reader failed after write")
        }
        try readWithSystemTool(path: path, service: service, expected: updated)
        let deniedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchSearchList as String: [keychain],
        ]
        guard
            SecItemUpdate(
                deniedQuery as CFDictionary,
                [kSecValueData as String: original] as CFDictionary) == errSecSuccess
        else {
            throw Failure.check("Unable to reproduce the original native-writer regression")
        }
        guard ClaudeKeychainStore.read(service: service, keychain: keychain) == nil,
            !ClaudeKeychainStore.update(updated, service: service, keychain: keychain)
        else {
            throw Failure.check("Incompatible ACL should fail preflight without a system reader")
        }
        print(
            "PASS: missing-item refusal, CLI creation, system-reader access, production update, preserved partitions, second read, incompatible ACL rejection"
        )
    }

    /// Inspect the actual stored ACL in a fresh process, avoiding legacy reference caches.
    private static func inspectPartitions(path: String, service: String) throws -> Set<String> {
        let helper = Process()
        let output = Pipe()
        helper.executableURL = Bundle.main.executableURL
        helper.arguments = ["--claude-keychain-metadata", service, path]
        helper.standardOutput = output
        try helper.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        helper.waitUntilExit()
        guard helper.terminationStatus == 0,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let partitions = object["partitions"] as? [String]
        else { throw Failure.check("Unable to inspect synthetic item permissions") }
        return Set(partitions)
    }

    /// Use the same system executable as Claude, with a five-second bound and synthetic output.
    private static func readWithSystemTool(path: String, service: String, expected: Data) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-a", "synthetic", "-s", service, "-w", path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw Failure.check("System reader timed out")
        }
        process.waitUntilExit()
        let actual = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0, actual == expected + Data([10]) else {
            throw Failure.check("System reader failed or returned different synthetic data")
        }
    }
}
