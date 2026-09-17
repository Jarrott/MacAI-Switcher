import Darwin
import Foundation
import LocalAuthentication
import Security

/// Uses Claude's own system reader/writer identity for its legacy macOS Keychain item.
/// Native secret updates reset the item's partition ACL to the calling app's code hash.
/// Metadata inspection is noninteractive; credentials never enter process arguments or logs.
enum ClaudeKeychainStore {
    static let service = "Claude Code-credentials"

    /// Serializes this process's Keychain operations and stops retrying a failed permission state.
    private final class OperationState: @unchecked Sendable {
        let lock = NSLock()
        var failedPermission: String?
    }
    private static let state = OperationState()

    private struct Item: Codable {
        let account: String
        let path: String
        let permission: String
        let partitions: [String]
    }

    /// Read an existing credential only when the unlocked item's ACL already permits security.
    /// - Parameters: Exact service and optional isolated test Keychain.
    /// - Returns: Credential bytes, or nil on missing/locked/denied/ambiguous/failed access.
    /// - Side effects: Runs one bounded system reader; a failed permission state is not retried
    ///   until its metadata changes or the app restarts. Never displays or logs the contents.
    static func read(service: String = service, keychain: SecKeychain? = nil) -> Data? {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard let item = inspectItem(service: service, keychain: keychain),
            item.permission != state.failedPermission
        else { return nil }
        guard
            var data = run(
                arguments: [
                    "find-generic-password", "-a", item.account, "-s", service, "-w", item.path,
                ]
            ), !data.isEmpty
        else {
            state.failedPermission = item.permission
            return nil
        }
        if data.last == 10 { data.removeLast() }
        return data
    }

    /// Update an existing Claude item through the same Apple-signed writer as the CLI.
    /// - Parameters: Validated credential bytes, exact service and optional test Keychain.
    /// - Returns: False for missing/locked/denied/ambiguous items, oversized data or command failure.
    /// - Side effects: Writes the secret through stdin to `security -i`, retaining its
    ///   `apple-tool:` partition and trusted applications. No native secret update or deletion.
    ///   Initial creation remains the CLI login flow's responsibility.
    static func update(_ data: Data, service: String = service, keychain: SecKeychain? = nil)
        -> Bool
    {
        state.lock.lock()
        defer { state.lock.unlock() }
        guard !data.isEmpty, data.count <= 131_072,
            let item = inspectItem(service: service, keychain: keychain),
            item.permission != state.failedPermission,
            let account = quoted(item.account), let serviceArgument = quoted(service),
            let path = quoted(item.path)
        else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command =
            "add-generic-password -U -a \(account) -s \(serviceArgument) -X \"\(hex)\" \(path)\n"
        // The interactive security driver can exit successfully after an individual
        // command error. Read back the exact bytes before reporting persistence success.
        guard run(arguments: ["-i"], input: Data(command.utf8)) != nil,
            let updated = inspectItem(service: service, keychain: keychain),
            updated.account == item.account, updated.path == item.path,
            run(arguments: [
                "find-generic-password", "-a", item.account, "-s", service,
                "-w", item.path,
            ]) == data + Data([10])
        else {
            state.failedPermission = item.permission
            return false
        }
        return true
    }

    /// Emit permission metadata in a short-lived copy of the app, never credential bytes.
    /// - Parameters: Exact service and optional Keychain path for the synthetic integration check.
    /// - Returns: Encoded metadata, or nil when access is not already permitted.
    /// - Side effects: Read-only, noninteractive Security.framework queries. A fresh process
    ///   avoids stale SecKeychainItem references after an external writer replaces a record.
    static func metadataOutput(service: String = service, keychainPath: String? = nil) -> Data? {
        var keychain: SecKeychain?
        if let keychainPath, SecKeychainOpen(keychainPath, &keychain) != errSecSuccess {
            return nil
        }
        guard let item = accessibleItem(service: service, keychain: keychain) else { return nil }
        return try? JSONEncoder().encode(item)
    }

    /// Inspect ACLs in a fresh process because the legacy framework caches stale record handles
    /// after security updates. The helper entry point exits before app startup or account loading.
    private static func inspectItem(service: String, keychain: SecKeychain?) -> Item? {
        guard let executable = Bundle.main.executableURL else { return nil }
        var arguments = ["--claude-keychain-metadata", service]
        if let keychain {
            var length: UInt32 = 4096
            var bytes = [CChar](repeating: 0, count: Int(length))
            guard SecKeychainGetPath(keychain, &length, &bytes) == errSecSuccess else { return nil }
            arguments.append(String(cString: bytes))
        }
        guard let data = run(arguments: arguments, executable: executable),
            let item = try? JSONDecoder().decode(Item.self, from: data)
        else { return nil }
        return item
    }

    /// Inspect only the unique item's metadata, lock state and both layers of read permission.
    /// Returns nil without spawning security when authentication would be needed. A concurrent
    /// external ACL/lock change may still fail the subsequent command; that failure is latched.
    private static func accessibleItem(service: String, keychain: SecKeychain?) -> Item? {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnRef as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
        ]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let rows = result as? [[String: Any]], rows.count == 1,
            let account = rows[0][kSecAttrAccount as String] as? String,
            let reference = rows[0][kSecValueRef as String],
            CFGetTypeID(reference as CFTypeRef) == SecKeychainItemGetTypeID()
        else { return nil }
        let item = reference as! SecKeychainItem
        var container: SecKeychain?
        var status: SecKeychainStatus = 0
        var access: SecAccess?
        guard SecKeychainItemCopyKeychain(item, &container) == errSecSuccess, let container,
            SecKeychainGetStatus(container, &status) == errSecSuccess,
            status & kSecUnlockStateStatus != 0,
            SecKeychainItemCopyAccess(item, &access) == errSecSuccess, let access
        else { return nil }
        var length: UInt32 = 4096
        var bytes = [CChar](repeating: 0, count: Int(length))
        guard SecKeychainGetPath(container, &length, &bytes) == errSecSuccess else { return nil }
        let path = String(cString: bytes)
        guard
            let decrypt = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt)
                as? [SecACL], decrypt.count == 1,
            let partitions = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationPartitionID)
                as? [SecACL], partitions.count == 1
        else { return nil }
        var applications: CFArray?
        var description: CFString?
        var selector: SecKeychainPromptSelector = []
        guard
            SecACLCopyContents(decrypt[0], &applications, &description, &selector) == errSecSuccess,
            !selector.contains(.requirePassphase)
        else { return nil }
        let trusted = applications as? [SecTrustedApplication]
        let paths = trusted?.compactMap { application -> String? in
            var data: CFData?
            guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess, let data
            else {
                return nil
            }
            return String(decoding: data as Data, as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters)
        }
        guard applications == nil || paths?.contains("/usr/bin/security") == true else {
            return nil
        }
        guard
            SecACLCopyContents(partitions[0], &applications, &description, &selector)
                == errSecSuccess,
            let hex = description as String?, let partitionIDs = decodePartitions(hex),
            partitionIDs.contains("apple-tool:")
        else { return nil }
        return Item(
            account: account, path: path,
            permission: [service, account, path, hex, paths?.joined(separator: "|") ?? "*"].joined(
                separator: "\n"),
            partitions: partitionIDs)
    }

    /// Decode the legacy partition ACL's hex property list; malformed metadata fails closed.
    private static func decodePartitions(_ hex: String) -> [String]? {
        let characters = Array(hex.utf8)
        guard characters.count <= 65_536, characters.count.isMultiple(of: 2) else { return nil }
        var bytes = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard
                let byte = UInt8(
                    String(decoding: characters[index..<index + 2], as: UTF8.self), radix: 16)
            else { return nil }
            bytes.append(byte)
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: bytes, format: nil)
                as? [String: [String]]
        else { return nil }
        return plist["Partitions"]
    }

    /// Quote a value for security's interactive command parser (no shell is involved).
    /// Reject command separators and control characters; token data is separately hex encoded.
    private static func quoted(_ value: String) -> String? {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Run a fixed system executable with bounded output and a five-second deadline.
    /// Only stdin/stdout carry credentials. Stderr is discarded; OS errors are never exposed.
    private static func run(
        arguments: [String], input: Data? = nil,
        executable: URL = URL(fileURLWithPath: "/usr/bin/security")
    ) -> Data? {
        let process = Process()
        let output = Pipe()
        let inputPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input == nil ? FileHandle.nullDevice : inputPipe
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            return nil
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        defer {
            deadline.cancel()
            try? inputPipe.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        do {
            try process.run()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
            if let input { try inputPipe.fileHandleForWriting.write(contentsOf: input) }
            try inputPipe.fileHandleForWriting.close()
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 16_384),
                !chunk.isEmpty
            {
                data.append(chunk)
                if data.count > 1_048_576 {
                    if process.isRunning { process.terminate() }
                    process.waitUntilExit()
                    return nil
                }
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return data
        } catch {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            return nil
        }
    }
}
