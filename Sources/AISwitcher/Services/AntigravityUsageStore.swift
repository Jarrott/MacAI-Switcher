import Foundation

/// One quota bucket exported by Antigravity CLI (`agy`) via its documented `statusLine` JSON payload.
struct AntigravityQuotaBucket: Codable, Equatable, Sendable {
    var remainingFraction: Double?
    var remainingAmount: Double?
    var resetTime: String?
    var resetInSeconds: Double?
    var disabled: Bool?

    enum CodingKeys: String, CodingKey {
        case remainingFraction = "remaining_fraction"
        case remainingAmount = "remaining_amount"
        case resetTime = "reset_time"
        case resetInSeconds = "reset_in_seconds"
        case disabled
    }
}

/// Sanitized usage snapshot captured for one signed-in Antigravity (`agy`) account.
/// Contains no credentials, tokens, workspace paths, or conversation contents.
struct AntigravityUsageSnapshot: Codable, Equatable, Sendable {
    var email: String
    var planTier: String?
    var quota: [String: AntigravityQuotaBucket]
    var recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case email
        case planTier = "plan_tier"
        case quota
        case recordedAt = "recorded_at"
    }
}

/// Multi-account local usage cache written by the `agy` `statusLine` hook.
struct AntigravityUsageFile: Codable, Equatable, Sendable {
    var activeEmail: String?
    var accounts: [String: AntigravityUsageSnapshot]

    enum CodingKeys: String, CodingKey {
        case activeEmail = "active_email"
        case accounts
    }
}

/// Integrates with Antigravity CLI (`agy`) via its documented `statusLine` hook.
///
/// `agy` manages authentication in the OS keyring and does not write plaintext OAuth
/// tokens. Instead, its official `statusLine` contract pipes signed-in account `email`,
/// `plan_tier`, and `quota` buckets as JSON into a configured script. This store installs
/// a minimal recorder script (preserving existing settings and chaining any prior custom
/// status line) and reads the sanitized local usage cache.
final class AntigravityUsageStore: Sendable {
    static let shared = AntigravityUsageStore()

    static let accountIDPrefix = "agy-"

    let usageFileURL: URL
    let settingsURL: URL
    let hookScriptURL: URL
    private let lock = NSLock()

    /// Override paths only for isolated tests; production uses standard user directories.
    init(
        usageFileURL: URL? = nil,
        settingsURL: URL? = nil,
        hookScriptURL: URL? = nil
    ) {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AISwitcher", isDirectory: true)
        self.usageFileURL =
            usageFileURL ?? support.appendingPathComponent("antigravity-usage.json")
        self.hookScriptURL =
            hookScriptURL ?? support.appendingPathComponent("agy-statusline-hook.sh")
        self.settingsURL =
            settingsURL
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/antigravity-cli/settings.json")
    }

    /// Stable managed account ID for an Antigravity (`agy`) email identity.
    static func accountID(forEmail email: String) -> String {
        accountIDPrefix + email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Whether a managed account ID belongs to an Antigravity (`agy`) recorded account.
    static func isAntigravityAccountID(_ accountID: String?) -> Bool {
        guard let accountID else { return false }
        return accountID.hasPrefix(accountIDPrefix) && accountID.count > accountIDPrefix.count
    }

    /// Extract the normalized email from an `agy-` account identifier.
    static func email(fromAccountID accountID: String?) -> String? {
        guard let accountID, isAntigravityAccountID(accountID) else { return nil }
        return String(accountID.dropFirst(accountIDPrefix.count))
    }

    /// Whether the `agy` CLI executable is installed on this Mac.
    func isCLIInstalled() -> Bool {
        CLIBrowserLoginService.executableURL(named: "agy") != nil
    }

    /// Whether `settings.json` is already configured to invoke AI Switcher's recorder hook.
    func isRecorderInstalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.isExecutableFile(atPath: hookScriptURL.path),
            let data = try? Data(contentsOf: settingsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let statusLine = root["statusLine"] as? [String: Any],
            let command = statusLine["command"] as? String
        else { return false }
        let enabled = (statusLine["enabled"] as? Bool) ?? true
        return enabled && command.contains(hookScriptURL.path)
    }

    /// Install the `agy` `statusLine` hook and register it in `settings.json`.
    ///
    /// - Preserves every unrelated key in `settings.json`.
    /// - Sets `stack_with_default: true` so `agy`'s built-in status line remains visible.
    /// - If the user already configured a different `statusLine.command`, chains it so their
    ///   custom status line keeps working alongside usage recording.
    func installRecorder() throws {
        lock.lock()
        defer { lock.unlock() }

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: hookScriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: usageFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
            let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            settings = existing
        }

        let existingStatusLine = settings["statusLine"] as? [String: Any]
        var chainedCommand: String? = nil
        if let existingCommand = existingStatusLine?["command"] as? String {
            let trimmed = existingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.contains(hookScriptURL.path) {
                chainedCommand = trimmed
            }
        }
        // Preserve a previously captured chained command on idempotent reinstall.
        if chainedCommand == nil,
            let priorChained = existingStatusLine?["aiSwitcherPreviousCommand"] as? String,
            !priorChained.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            chainedCommand = priorChained
        }

        let script = Self.makeHookScript(
            usageFilePath: usageFileURL.path,
            chainedCommand: chainedCommand
        )
        try Data(script.utf8).write(to: hookScriptURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: hookScriptURL.path
        )

        var updatedStatusLine = existingStatusLine ?? [:]
        updatedStatusLine["type"] = "command"
        updatedStatusLine["command"] = Self.shellQuoted(hookScriptURL.path)
        updatedStatusLine["enabled"] = true
        if chainedCommand == nil {
            updatedStatusLine["stack_with_default"] =
                (existingStatusLine?["stack_with_default"] as? Bool) ?? true
        }
        if let chainedCommand {
            updatedStatusLine["aiSwitcherPreviousCommand"] = chainedCommand
        }
        settings["statusLine"] = updatedStatusLine

        let encoded = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try encoded.write(to: settingsURL, options: .atomic)
    }

    /// Load all recorded Antigravity account snapshots from the local cache file.
    func loadFile() -> AntigravityUsageFile? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: usageFileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(AntigravityUsageFile.self, from: data)
    }

    /// Return the latest recorded snapshot for one Antigravity account email.
    func snapshot(forEmail email: String) -> AntigravityUsageSnapshot? {
        guard let file = loadFile() else { return nil }
        return file.accounts[email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
    }

    /// Remove one recorded account from the local cache after UI confirmation.
    @discardableResult
    func removeAccount(email: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let data = try? Data(contentsOf: usageFileURL) else { return true }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard var file = try? decoder.decode(AntigravityUsageFile.self, from: data) else {
            return true
        }
        file.accounts.removeValue(forKey: key)
        if file.activeEmail?.lowercased() == key {
            file.activeEmail = nil
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        do {
            let updated = try encoder.encode(file)
            try SecureFileWriter.write(updated, to: usageFileURL)
            return true
        } catch {
            return false
        }
    }

    /// Quote a filesystem path safely for `/bin/sh -c`.
    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Build the minimal, self-contained `statusLine` recorder script.
    /// Never stores secrets, conversation text, or workspace paths.
    static func makeHookScript(usageFilePath: String, chainedCommand: String?) -> String {
        let targetB64 = Data(usageFilePath.utf8).base64EncodedString()
        let chainedB64 = chainedCommand.map { Data($0.utf8).base64EncodedString() } ?? ""
        return """
            #!/usr/bin/python3
            # AI Switcher Antigravity (agy) usage recorder hook.
            # Reads the documented statusLine JSON from stdin and records only email,
            # plan_tier, and quota metrics locally.
            import base64
            import json
            import os
            import subprocess
            import sys
            import tempfile
            import time

            TARGET = base64.b64decode("\(targetB64)").decode("utf-8")
            CHAINED = base64.b64decode("\(chainedB64)").decode("utf-8")

            raw = sys.stdin.read()

            try:
                payload = json.loads(raw) if raw.strip() else {}
            except Exception:
                payload = {}

            email = payload.get("email") if isinstance(payload, dict) else None
            if isinstance(email, str):
                email = email.strip()
            else:
                email = ""

            if email:
                key = email.lower()
                plan_tier = payload.get("plan_tier")
                if not isinstance(plan_tier, str) or not plan_tier.strip():
                    plan_tier = None
                raw_quota = payload.get("quota")
                sanitized_quota = {}
                if isinstance(raw_quota, dict):
                    for bucket_id, entry in raw_quota.items():
                        if not isinstance(bucket_id, str) or not isinstance(entry, dict):
                            continue
                        cleaned = {}
                        for field in ("remaining_fraction", "remaining_amount", "reset_in_seconds"):
                            val = entry.get(field)
                            if isinstance(val, (int, float)) and not isinstance(val, bool):
                                cleaned[field] = float(val)
                        rt = entry.get("reset_time")
                        if isinstance(rt, str) and rt.strip():
                            cleaned["reset_time"] = rt.strip()
                        dis = entry.get("disabled")
                        if isinstance(dis, bool):
                            cleaned["disabled"] = dis
                        if cleaned:
                            sanitized_quota[bucket_id] = cleaned

                try:
                    with open(TARGET, "r", encoding="utf-8") as f:
                        store = json.load(f)
                    if not isinstance(store, dict):
                        store = {}
                except Exception:
                    store = {}

                accounts = store.get("accounts")
                if not isinstance(accounts, dict):
                    accounts = {}

                existing = accounts.get(key) if isinstance(accounts.get(key), dict) else {}
                if not sanitized_quota and isinstance(existing.get("quota"), dict):
                    sanitized_quota = existing["quota"]
                if plan_tier is None and isinstance(existing.get("plan_tier"), str):
                    plan_tier = existing["plan_tier"]

                accounts[key] = {
                    "email": email,
                    "plan_tier": plan_tier,
                    "quota": sanitized_quota,
                    "recorded_at": time.time(),
                }
                store["active_email"] = email
                store["accounts"] = accounts

                try:
                    parent = os.path.dirname(TARGET)
                    os.makedirs(parent, mode=0o700, exist_ok=True)
                    fd, tmp_path = tempfile.mkstemp(dir=parent, prefix=".agy-usage-")
                    try:
                        os.fchmod(fd, 0o600)
                        with os.fdopen(fd, "w", encoding="utf-8") as f:
                            json.dump(store, f, sort_keys=True)
                        os.replace(tmp_path, TARGET)
                    except Exception:
                        try:
                            os.unlink(tmp_path)
                        except Exception:
                            pass
                except Exception:
                    pass

            if CHAINED:
                try:
                    proc = subprocess.run(["/bin/sh", "-c", CHAINED], input=raw, text=True)
                    sys.exit(proc.returncode)
                except Exception:
                    pass
            """
    }
}
