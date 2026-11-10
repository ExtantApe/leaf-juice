import CryptoKit
import Foundation
import Security

// The advisor's token map is sealed with a key kept in the Keychain. Owner decision, 2026-11-10: "Use Keychain because
// I'm going to buy the Apple Developer stuff soon and then it will be signed". Until the app is signed, macOS asks again
// after each rebuild. Recorded in docs/PLAN.md.

/// Where the key that seals the token map lives.
public protocol KeyVault: AnyObject {
    /// The key. With `create`, a new one is made and kept if there's none yet. Throws a plain reason, never prompts
    /// unless the vault was made for a person at the app.
    func key(create: Bool) throws -> SymmetricKey
}

/// What went wrong, in words for the owner. These reach the AI too, so they say nothing specific.
public enum KeyVaultProblem: Error, Equatable, Sendable {
    /// The Keychain is locked, or macOS needs a person's OK and none was allowed.
    case needsAccess
    /// A person said no, or the Keychain refused this program.
    case denied
    /// There's no key, but there is a sealed file it would have opened.
    case missing
    case unavailable

    public var message: String {
        switch self {
        case .needsAccess: "The Advisor's key is in your Keychain, and macOS needs your OK before it can be used. Open Leaf Juice's Advisor page and press Allow Keychain Access. Nothing was shared."
        case .denied: "The Keychain refused the Advisor's key, so nothing was shared. Open Leaf Juice's Advisor page and press Allow Keychain Access, then choose Always Allow."
        case .missing: "The Advisor's key is missing from your Keychain, so its token list can't be opened. Nothing was shared. Forget Everything on the Advisor page starts afresh."
        case .unavailable: "The Keychain couldn't be used just now, so nothing was shared."
        }
    }
}

/// The real one: a generic password in the login Keychain, or in another keychain file for the checks.
public final class KeychainVault: KeyVault {
    public static let service = "io.github.mgilardi.leafjuice.advisor"
    public static let account = "token-map-key-v1"
    static let label = "Leaf Juice Advisor key"

    /// Set by a person's action in the app. Off, macOS is never allowed to show a prompt: the call fails instead.
    private let interactive: Bool
    private let keychain: SecKeychain?
    /// Programs trusted with a key this makes, besides itself: the app lists its helper, so neither is asked about the
    /// other's key. Until the app is signed, a rebuilt program is a new one to macOS, and is asked again.
    private let alsoTrusted: [String]

    /// The login Keychain. The helper program uses `interactive: false`.
    public init(interactive: Bool, alsoTrusted: [String] = []) {
        self.interactive = interactive
        self.keychain = nil
        self.alsoTrusted = alsoTrusted
    }

    /// A keychain file of its own, for checks with a throwaway keychain. Never the login Keychain.
    public init(keychainFile: String, interactive: Bool, alsoTrusted: [String] = []) throws {
        var ref: SecKeychain?
        guard SecKeychainOpen(keychainFile, &ref) == errSecSuccess, let ref else { throw KeyVaultProblem.unavailable }
        self.interactive = interactive
        self.keychain = ref
        self.alsoTrusted = alsoTrusted
    }

    /// Itself and `alsoTrusted`, or nil to take macOS's default (only itself).
    private func access() -> SecAccess? {
        guard !alsoTrusted.isEmpty else { return nil }
        var apps: [SecTrustedApplication] = []
        for path in [nil] + alsoTrusted.map(Optional.some) {
            var app: SecTrustedApplication?
            guard SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess, let app else { return nil }
            apps.append(app)
        }
        var access: SecAccess?
        guard SecAccessCreate(Self.label as CFString, apps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    /// The helper program reads this from its environment, so the checks can give it a throwaway keychain. The app
    /// never sets it, and `AdvisorLaunch` doesn't pass it on.
    public static let keychainFileVariable = "LEAFJUICE_ADVISOR_KEYCHAIN"

    public static func forHelper(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> KeychainVault {
        if let file = environment[keychainFileVariable], !file.isEmpty { return try KeychainVault(keychainFile: file, interactive: false) }
        return KeychainVault(interactive: false)
    }

    private func base() -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: Self.service,
                                kSecAttrAccount as String: Self.account]
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return q
    }

    /// Runs with macOS prompts switched off unless a person asked for this.
    private func quietly<T>(_ body: () -> T) -> T {
        guard !interactive else { return body() }
        var before: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&before)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(before.boolValue) }
        return body()
    }

    /// With prompts off, a locked keychain and one that hasn't trusted this program both answer errSecAuthFailed,
    /// so the lock is asked about separately.
    private func problem(_ status: OSStatus) -> KeyVaultProblem {
        if status == errSecAuthFailed || status == errSecInteractionNotAllowed, isLocked() { return .needsAccess }
        return Self.problem(status)
    }

    private func isLocked() -> Bool {
        var ref = keychain
        if ref == nil { SecKeychainCopyDefault(&ref) }
        var state: SecKeychainStatus = 0
        guard let ref, SecKeychainGetStatus(ref, &state) == errSecSuccess else { return false }
        return state & SecKeychainStatus(kSecUnlockStateStatus) == 0
    }

    static func problem(_ status: OSStatus) -> KeyVaultProblem {
        switch status {
        case errSecInteractionNotAllowed, errSecNotAvailable: .needsAccess
        case errSecAuthFailed, errSecUserCanceled, errSecNoAccessForItem, errSecWrPerm: .denied
        case errSecItemNotFound: .missing
        default: .unavailable
        }
    }

    public func key(create: Bool) throws -> SymmetricKey {
        var query = base()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var found: CFTypeRef?
        let status = quietly { SecItemCopyMatching(query as CFDictionary, &found) }
        if status == errSecSuccess {
            guard let data = found as? Data, data.count == 32 else { throw KeyVaultProblem.unavailable }
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound, create else { throw problem(status) }
        let fresh = SymmetricKey(size: .bits256)
        var add = base()
        add[kSecValueData as String] = fresh.withUnsafeBytes { Data($0) }
        add[kSecAttrLabel as String] = Self.label
        add[kSecAttrDescription as String] = "Seals the Advisor's token list. Not a password."
        if let keychain { add[kSecUseKeychain as String] = keychain }
        if let access = access() { add[kSecAttrAccess as String] = access }
        let added = quietly { SecItemAdd(add as CFDictionary, nil) }
        guard added == errSecSuccess else { throw problem(added) }
        return fresh
    }
}

/// The token map's file format: `LJAK1` then an AES-GCM sealed box (nonce, ciphertext, tag) of the JSON.
public enum SealedFile {
    static let magic = Data("LJAK1".utf8)

    public static func seal(_ plain: Data, with key: SymmetricKey) throws -> Data {
        guard let combined = try? AES.GCM.seal(plain, using: key).combined else { throw KeyVaultProblem.unavailable }
        return magic + combined
    }

    /// Nil for anything that isn't a file this key sealed, including one that was changed.
    public static func open(_ data: Data, with key: SymmetricKey) -> Data? {
        guard data.starts(with: magic), let box = try? AES.GCM.SealedBox(combined: data.dropFirst(magic.count)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

/// A key that lives only in memory, for throwaway token lists such as the preview. Never for the real one.
public final class EphemeralVault: KeyVault {
    private let stored = SymmetricKey(size: .bits256)
    public init() {}
    public func key(create: Bool) throws -> SymmetricKey { stored }
}

extension KeyVaultProblem {
    /// Whether a message is one of the two that a press of Allow Keychain Access can fix.
    public static func needsAllowing(_ message: String) -> Bool {
        message == KeyVaultProblem.needsAccess.message || message == KeyVaultProblem.denied.message
    }
}
