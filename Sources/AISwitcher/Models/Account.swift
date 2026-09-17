import Foundation

/// Which AI provider an account belongs to.
enum Provider: String, Codable, CaseIterable, Identifiable {
    case codex  // OpenAI Codex / ChatGPT
    case claude  // Anthropic Claude / Claude Code

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }

    /// SF Symbol used for the menu bar icon / provider badge.
    var symbolName: String {
        switch self {
        case .codex: return "gamecontroller.fill"
        case .claude: return "sparkles"
        }
    }

    /// Executable used to start this provider's OAuth login flow.
    var cliExecutableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        }
    }

    /// Arguments that make the provider CLI open its browser OAuth flow.
    var cliLoginArguments: [String] {
        switch self {
        case .codex: return ["login"]
        case .claude: return ["auth", "login"]
        }
    }

    /// Human-readable command shown in the manual-login fallback.
    var loginCommand: String {
        ([cliExecutableName] + cliLoginArguments).joined(separator: " ")
    }
}

/// A subscription plan tier as reported by the provider.
enum PlanTier: String, Codable {
    case free
    case plus
    case pro
    case max
    case team
    case enterprise
    case unknown

    /// Human label shown in the card, e.g. "(Pro)".
    var displayName: String {
        switch self {
        case .free: return "Free"
        case .plus: return "Plus"
        case .pro: return "Pro"
        case .max: return "Max"
        case .team: return "Team"
        case .enterprise: return "Enterprise"
        case .unknown: return "—"
        }
    }

    static func parse(_ raw: String?) -> PlanTier {
        guard let raw = raw?.lowercased() else { return .unknown }
        if raw.contains("pro") { return .pro }
        if raw.contains("plus") { return .plus }
        if raw.contains("max") { return .max }
        if raw.contains("team") { return .team }
        if raw.contains("enterprise") || raw.contains("business") { return .enterprise }
        if raw.contains("free") { return .free }
        return .unknown
    }
}

/// A single usage window (5-hour session, or 7-day weekly).
struct UsageWindow: Codable, Equatable {
    /// Fraction used, 0.0...1.0. `nil` = unknown ("--%").
    var usedFraction: Double?
    /// When the window resets. `nil` = unknown ("--").
    var resetsAt: Date?

    static let unknown = UsageWindow(usedFraction: nil, resetsAt: nil)

    /// A finite usage fraction constrained to the range accepted by the UI.
    /// Invalid provider values stay unknown instead of producing a broken bar.
    var normalizedUsedFraction: Double? {
        guard let usedFraction, usedFraction.isFinite else { return nil }
        return min(1, max(0, usedFraction))
    }

    /// Remaining quota derived from the provider's used fraction.
    /// The reference switcher displays remaining—not consumed—capacity.
    var remainingFraction: Double? {
        normalizedUsedFraction.map { 1 - $0 }
    }

    /// Rounded remaining percentage shared by the label and risk classification.
    ///
    /// Using one integer value keeps boundary colors consistent with the number
    /// the user sees, including provider fractions affected by floating-point
    /// subtraction near 10% and 50%.
    var remainingPercent: Int? {
        guard let f = remainingFraction else { return nil }
        return Int((f * 100).rounded())
    }

    /// Remaining quota formatted as "22%" or "--%".
    var remainingPercentText: String {
        guard let remainingPercent else { return "--%" }
        return "\(remainingPercent)%"
    }

    /// Classify the remaining quota for the compact menu's risk colors.
    ///
    /// Unknown provider values remain unavailable. A remaining fraction below
    /// 10% is critical, 10% through 50% is a warning, and values above 50% are
    /// healthy. The boundary rules intentionally operate on the normalized
    /// fraction used by the percentage label and progress bar.
    var remainingQuotaLevel: RemainingQuotaLevel {
        guard let remainingPercent else { return .unavailable }
        if remainingPercent < 10 { return .critical }
        if remainingPercent <= 50 { return .warning }
        return .healthy
    }
}

/// Semantic risk level for a usage window's remaining provider quota.
enum RemainingQuotaLevel: Equatable {
    case unavailable
    case critical
    case warning
    case healthy
}

/// One available manual Codex reset credit eligible for confirmed redemption.
struct ResetCredit: Identifiable, Codable, Equatable {
    var id: String
    var title: String?
    var expiresAt: Date?
}

/// Usage snapshot for both the 5h and 7d windows plus reset-credit info.
struct Usage: Codable, Equatable {
    var fiveHour: UsageWindow
    var sevenDay: UsageWindow
    /// Number of manual limit resets the account still has available.
    var resetsAvailable: Int?
    var fetchedAt: Date?
    /// Available credit metadata. `nil` means the provider did not return details.
    var resetCredits: [ResetCredit]? = nil

    static let empty = Usage(
        fiveHour: .unknown,
        sevenDay: .unknown,
        resetsAvailable: nil,
        fetchedAt: nil
    )
}

/// One AI account managed by the switcher.
struct Account: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var provider: Provider
    /// Display handle, e.g. "tmtdeveloper1".
    var label: String
    /// Optional user override. Provider discovery only updates the generated label.
    var customLabel: String? = nil
    /// Full email, if known.
    var email: String?
    var plan: PlanTier

    /// Opaque provider account identifier (chatgpt_account_id, etc.).
    var accountID: String?

    /// Path to the saved credential snapshot for this account
    /// (relative to the switcher's app-support directory).
    var credentialSnapshot: String?

    var usage: Usage = .empty

    /// User-facing account name, preserving an explicit settings override.
    var displayLabel: String {
        customLabel ?? label
    }

    static func == (lhs: Account, rhs: Account) -> Bool {
        lhs.id == rhs.id
    }
}
