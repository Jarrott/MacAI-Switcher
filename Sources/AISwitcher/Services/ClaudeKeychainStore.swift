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
        var failedPermissions: Set<String> = []
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
    /// - Returns: Bytes of the first candidate holding a Claude OAuth login, or nil on
    ///   missing/locked/denied/failed access or when no candidate holds one.
    /// - Side effects: Runs bounded system readers; a failed permission state is not retried
    ///   until its metadata changes or the app restarts. Never displays or logs the contents.
    static func read(service: String = service, keychain: SecKeychain? = nil) -> Data? {
        state.lock.lock()
        defer { state.lock.unlock() }
        return loginItem(service: service, keychain: keychain)?.data
    }

    /// Select the item holding Claude's OAuth login; newer Claude Code versions can leave
    /// several items under one service (for example an MCP-only blob under another account).
    /// - Returns: The first candidate, in `candidateOrder`, whose bytes contain `claudeAiOauth`.
    /// - Side effects: Latches candidates whose read fails; caller must hold `state.lock`.
    private static func loginItem(service: String, keychain: SecKeychain?) -> (
        item: Item, data: Data
    )? {
        for item in inspectItems(service: service, keychain: keychain)
        where !state.failedPermissions.contains(item.permission) {
            guard
                var data = run(arguments: [
                    "find-generic-password", "-a", item.account, "-s", service, "-w", item.path,
                ]), !data.isEmpty
            else {
                state.failedPermissions.insert(item.permission)
                continue
            }
            if data.last == 10 { data.removeLast() }
            if containsClaudeLogin(data) { return (item, data) }
        }
        return nil
    }

    /// Whether credential bytes carry a non-empty Claude OAuth access token.
    /// - Parameter data: Raw Keychain payload; never logged.
    /// - Returns: False for MCP-only, malformed or empty logins.
    static func containsClaudeLogin(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = object["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else { return false }
        return !token.isEmpty
    }

    /// Order same-service items: the current macOS user's account first (Claude Code's
    /// default), then by newest modification date; undated items keep their original order last.
    /// - Parameters: `rows` are item account names and modification dates; `user` is the login name.
    /// - Returns: Indices into `rows` in preference order.
    static func candidateOrder(_ rows: [(account: String, modified: Date?)], user: String)
        -> [Int]
    {
        rows.indices.sorted { lhs, rhs in
            let left = rows[lhs]
            let right = rows[rhs]
            if (left.account == user) != (right.account == user) { return left.account == user }
            switch (left.modified, right.modified) {
            case (.some(let l), .some(let r)) where l != r: return l > r
            case (.some, .none): return true
            case (.none, .some): return false
            default: return lhs < rhs
            }
        }
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
            let item = loginItem(service: service, keychain: keychain)?.item,
            let account = quoted(item.account), let serviceArgument = quoted(service),
            let path = quoted(item.path)
        else { return false }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let command =
            "add-generic-password -U -a \(account) -s \(serviceArgument) -X \"\(hex)\" \(path)\n"
        // The interactive security driver can exit successfully after an individual
        // command error. Read back the exact bytes before reporting persistence success.
        guard run(arguments: ["-i"], input: Data(command.utf8)) != nil,
            inspectItems(service: service, keychain: keychain).contains(where: {
                $0.account == item.account && $0.path == item.path
            }),
            run(arguments: [
                "find-generic-password", "-a", item.account, "-s", service,
                "-w", item.path,
            ]) == data + Data([10])
        else {
            state.failedPermissions.insert(item.permission)
            return false
        }
        return true
    }

    /// Emit permission metadata in a short-lived copy of the app, never credential bytes.
    /// - Parameters: Exact service and optional Keychain path for the synthetic integration check.
    /// - Returns: Encoded metadata of every permitted item in `candidateOrder`, or nil when
    ///   none is already accessible.
    /// - Side effects: Read-only, noninteractive Security.framework queries. A fresh process
    ///   avoids stale SecKeychainItem references after an external writer replaces a record.
    static func metadataOutput(service: String = service, keychainPath: String? = nil) -> Data? {
        var keychain: SecKeychain?
        if let keychainPath, SecKeychainOpen(keychainPath, &keychain) != errSecSuccess {
            return nil
        }
        let items = accessibleItems(service: service, keychain: keychain)
        guard !items.isEmpty else { return nil }
        return try? JSONEncoder().encode(items)
    }

    /// Inspect ACLs in a fresh process because the legacy framework caches stale record handles
    /// after security updates. The helper entry point exits before app startup or account loading.
    private static func inspectItems(service: String, keychain: SecKeychain?) -> [Item] {
        guard let executable = Bundle.main.executableURL else { return [] }
        var arguments = ["--claude-keychain-metadata", service]
        if let keychain {
            var length: UInt32 = 4096
            var bytes = [CChar](repeating: 0, count: Int(length))
            guard SecKeychainGetPath(keychain, &length, &bytes) == errSecSuccess else { return [] }
            arguments.append(String(cString: bytes))
        }
        guard let data = run(arguments: arguments, executable: executable),
            let items = try? JSONDecoder().decode([Item].self, from: data)
        else { return [] }
        return items
    }

    /// Inspect every same-service item's metadata, lock state and both layers of read permission.
    /// Items needing authentication are skipped without spawning security. A concurrent
    /// external ACL/lock change may still fail the subsequent command; that failure is latched.
    private static func accessibleItems(service: String, keychain: SecKeychain?) -> [Item] {
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
            let rows = result as? [[String: Any]]
        else { return [] }
        let order = candidateOrder(
            rows.map {
                (
                    account: $0[kSecAttrAccount as String] as? String ?? "",
                    modified: $0[kSecAttrModificationDate as String] as? Date
                )
            }, user: NSUserName())
        return order.compactMap { accessibleItem(service: service, row: rows[$0]) }
    }

    /// Validate one row's lock state and ACLs; nil when reading would need authentication.
    private static func accessibleItem(service: String, row: [String: Any]) -> Item? {
        guard let account = row[kSecAttrAccount as String] as? String,
            let reference = row[kSecValueRef as String],
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
