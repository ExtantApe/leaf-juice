import CryptoKit
import Darwin
import Foundation
import LeafJuiceAdvisor

/// A stand-in for the Keychain. Every check that makes a PrivacyKey uses this, so the login Keychain is never touched.
final class CheckVault: KeyVault {
    enum Mode { case open, locked, denied, gone }
    nonisolated(unsafe) static let shared = CheckVault()
    var mode: Mode = .open
    private var stored: SymmetricKey?
    private(set) var created = 0
    private(set) var asked = 0

    init(key: SymmetricKey? = nil, mode: Mode = .open) { stored = key; self.mode = mode }

    func key(create: Bool) throws -> SymmetricKey {
        asked += 1
        switch mode {
        case .locked: throw KeyVaultProblem.needsAccess
        case .denied: throw KeyVaultProblem.denied
        case .gone: stored = nil; mode = .open; return try key(create: create)
        case .open:
            if let stored { return stored }
            guard create else { throw KeyVaultProblem.missing }
            let fresh = SymmetricKey(size: .bits256)
            stored = fresh
            created += 1
            return fresh
        }
    }
}

/// The token list in a key folder, opened with the stand-in's key. Empty if it can't be.
func sealedKeyText(_ home: URL, vault: CheckVault = .shared) -> String {
    guard let data = try? Data(contentsOf: home.appendingPathComponent("key.sealed")),
          let key = try? vault.key(create: false), let plain = SealedFile.open(data, with: key) else { return "" }
    return String(decoding: plain, as: UTF8.self)
}

/// A keychain file in the scratch folder with a made-up password, never added to the search list. It goes with the
/// scratch folder at exit.
func throwawayKeychain(_ name: String) -> (path: String, password: String) {
    let path = scratch.appendingPathComponent("\(name).keychain-db").path
    let password = UUID().uuidString
    for args in [["create-keychain", "-p", password, path], ["set-keychain-settings", path], ["unlock-keychain", "-p", password, path]] {
        runSecurity(args)
    }
    return (path, password)
}

/// The key the real helper program finds in its throwaway keychain, known here so its sealed file can be opened.
let testKeychainKey = SymmetricKey(size: .bits256)

/// The real helper program's keychain. Its key is put there trusting that program, as macOS's Always Allow would.
let testKeychainFile: String = {
    let (path, _) = throwawayKeychain("advisor-helper")
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("leafjuice-mcp").path
    let hex = testKeychainKey.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    runSecurity(["add-generic-password", "-s", KeychainVault.service, "-a", KeychainVault.account, "-l", "Leaf Juice Advisor key (check)", "-X", hex, "-T", helper, path])
    return path
}()

@discardableResult func runSecurity(_ args: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

@MainActor func keyVaultChecks() throws {
    section("Advisor: the key in the Keychain")
    func data(_ url: URL) -> Data? { try? Data(contentsOf: url) }
    func refusal(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch { return (error as? AdvisorError)?.description ?? "\(error)" }
    }

    // Sealed at rest, and opened again with the same key.
    let vault = CheckVault()
    let home = privateHome("vault-home")
    let key = try PrivacyKey(directory: home, vault: vault)
    let token = try key.player(name: "MadeUpSecretName", uuid: "aaaaaaaa-0000-4000-8000-00000000000a")
    let sealed = home.appendingPathComponent("key.sealed")
    let raw = data(sealed) ?? Data()
    check(raw.starts(with: Data("LJAK1".utf8)), "the token list is written sealed")
    check(!String(decoding: raw, as: UTF8.self).lowercased().contains("madeupsecretname") && !String(decoding: raw, as: UTF8.self).contains("aaaaaaaa"), "and the name and UUID can't be read from the file")
    check(!FileManager.default.fileExists(atPath: home.appendingPathComponent("key.json").path), "with no plain copy beside it")
    equal(vault.created, 1, "one key is made, the first time it's needed")
    equal(try PrivacyKey(directory: home, vault: vault).reveal(token), "MadeUpSecretName", "and the same key opens it after a restart")

    // Fail closed, with a plain reason, and nothing written.
    for (mode, words, label) in [(CheckVault.Mode.locked, "Allow Keychain Access", "locked, or waiting for your OK"), (.denied, "refused", "access denied")] {
        let shut = CheckVault(key: try vault.key(create: false), mode: mode)
        let said = refusal { try PrivacyKey(directory: home, vault: shut) }
        check(said.map { $0.contains(words) && $0.lowercased().contains("nothing was shared") } == true, "a Keychain that's \(label) stops it, saying why: \(said ?? "no refusal")")
        equal(data(sealed), raw, "and the sealed file is left alone (\(label))")
    }
    let otherKey = CheckVault()
    _ = try otherKey.key(create: true)
    check(refusal { try PrivacyKey(directory: home, vault: otherKey) }?.contains("couldn't be read") == true, "a different key can't open it")
    let forgetful = CheckVault()
    check(refusal { try PrivacyKey(directory: home, vault: forgetful) }?.contains("missing from your Keychain") == true, "a key gone from the Keychain stops it, and says Forget Everything starts afresh")
    equal(forgetful.created, 0, "and no new key is made over the old file")
    equal(data(sealed), raw, "which is left alone")
    var tampered = raw
    tampered[tampered.count - 1] ^= 0x01
    try tampered.write(to: sealed)
    check(refusal { try PrivacyKey(directory: home, vault: vault) }?.contains("couldn't be read") == true, "one changed byte is caught")
    try raw.write(to: sealed)

    // A running program whose Keychain locks keeps working only with the key it already read; a new one stops.
    let freshHome = privateHome("vault-fresh-locked")
    let lockedFresh = try PrivacyKey(directory: freshHome, vault: CheckVault(mode: .locked))
    check(refusal { try lockedFresh.player(name: "MadeUp", uuid: nil) }?.contains("Allow Keychain Access") == true, "with no key yet and a locked Keychain, no token is given out")
    check(!FileManager.default.fileExists(atPath: freshHome.appendingPathComponent("key.sealed").path) && !FileManager.default.fileExists(atPath: freshHome.appendingPathComponent("key.json").path), "and nothing is written, sealed or plain")

    // The plain key.json from before is sealed once, then deleted, and never used as it is.
    let plainJSON = #"{"version":2,"entries":[{"token":"Player-0123abcd","kind":"Player","display":"MadeUpOldFriend","lookups":["name:madeupoldfriend"]}]}"#
    func legacyHome(_ name: String) -> URL {
        let h = privateHome(name)
        try? FileManager.default.createDirectory(at: h, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        write(plainJSON, h.appendingPathComponent("key.json"))
        chmod(h.appendingPathComponent("key.json").path, 0o600)
        return h
    }
    let oldHome = legacyHome("vault-legacy")
    let locked = CheckVault(mode: .locked)
    check(refusal { try PrivacyKey(directory: oldHome, vault: locked) }?.contains("Allow Keychain Access") == true, "an old plain key isn't used while the Keychain is locked")
    equal(try? String(contentsOf: oldHome.appendingPathComponent("key.json"), encoding: .utf8), plainJSON, "and stays as it was until it can be sealed")
    let migrated = CheckVault()
    equal(try PrivacyKey(directory: oldHome, vault: migrated).reveal("Player-0123abcd"), "MadeUpOldFriend", "once the Keychain opens, its tokens carry over")
    check(!FileManager.default.fileExists(atPath: oldHome.appendingPathComponent("key.json").path), "and the plain file is deleted")
    check(sealedKeyText(oldHome, vault: migrated).contains("MadeUpOldFriend"), "after being sealed")
    let bothHome = privateHome("vault-both")
    let both = CheckVault()
    _ = try PrivacyKey(directory: bothHome, vault: both).player(name: "MadeUpNewer", uuid: nil)
    write(plainJSON, bothHome.appendingPathComponent("key.json"))
    chmod(bothHome.appendingPathComponent("key.json").path, 0o600)
    check(try PrivacyKey(directory: bothHome, vault: both).reveal("Player-0123abcd") == "Player-0123abcd", "a plain file left beside a sealed one is never read")
    check(!FileManager.default.fileExists(atPath: bothHome.appendingPathComponent("key.json").path), "and is deleted")
    let linkedHome = privateHome("vault-legacy-link")
    try FileManager.default.createDirectory(at: linkedHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    write(plainJSON, folder("vault-legacy-elsewhere").appendingPathComponent("k.json"))
    try FileManager.default.createSymbolicLink(at: linkedHome.appendingPathComponent("key.json"), withDestinationURL: folder("vault-legacy-elsewhere").appendingPathComponent("k.json"))
    check((try? PrivacyKey(directory: linkedHome, vault: CheckVault())) == nil, "an old plain key that's a symlink is refused, not sealed")

    // The real Keychain code, against a throwaway keychain file, with prompts off as the helper runs.
    let own = throwawayKeychain("advisor-vault")
    let real = try KeychainVault(keychainFile: own.path, interactive: false)
    check({ do { _ = try real.key(create: false); return false } catch { return (error as? KeyVaultProblem) == .missing } }(), "a real keychain with no key says it's missing")
    let made = try real.key(create: true)
    equal(made.bitCount, 256, "a real 256-bit key is made")
    equal(try real.key(create: true).withUnsafeBytes { Data($0) }, made.withUnsafeBytes { Data($0) }, "and the same one comes back, not a second")
    runSecurity(["lock-keychain", own.path])
    let lockedSaid: KeyVaultProblem? = { do { _ = try real.key(create: true); return nil } catch { return error as? KeyVaultProblem } }()
    equal(lockedSaid, .needsAccess, "a locked real keychain fails at once with no prompt, and no new key is made")
    runSecurity(["unlock-keychain", "-p", own.password, own.path])
    equal(try real.key(create: false).withUnsafeBytes { Data($0) }, made.withUnsafeBytes { Data($0) }, "unlocked again, the same key is read")

    // The helper's own checks, as the app runs them, against throwaway keychains.
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("leafjuice-mcp").path
    func helperCheck(_ keychainFile: String) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--keychain-check"]
        var environment = ProcessInfo.processInfo.environment
        environment[KeychainVault.keychainFileVariable] = keychainFile
        process.environment = environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, said)
    }
    equal(helperCheck(testKeychainFile).0, 0, "the helper reaches a key that trusts it")
    let shared = throwawayKeychain("advisor-shared")
    _ = try KeychainVault(keychainFile: shared.path, interactive: false, alsoTrusted: [helper]).key(create: true)
    equal(helperCheck(shared.path).0, 0, "a key the app makes for itself and its helper opens for the helper with no prompt")
    let ownOnly = throwawayKeychain("advisor-own-only")
    _ = try KeychainVault(keychainFile: ownOnly.path, interactive: false).key(create: true)
    let refusedHelper = helperCheck(ownOnly.path)
    check(refusedHelper.0 == 3 && refusedHelper.1 == KeyVaultProblem.denied.message, "one made only for the app is refused to the helper, quietly, saying why: \(refusedHelper)")
    runSecurity(["lock-keychain", shared.path])
    let lockedHelper = helperCheck(shared.path)
    check(lockedHelper.0 == 3 && lockedHelper.1 == KeyVaultProblem.needsAccess.message, "a locked keychain stops the helper, quietly, saying why: \(lockedHelper)")

    // An unlocked keychain whose key doesn't trust this program: refused, not prompted, and not replaced.
    let foreign = throwawayKeychain("advisor-foreign")
    runSecurity(["add-generic-password", "-s", KeychainVault.service, "-a", KeychainVault.account, "-X", String(repeating: "ab", count: 32), foreign.path])
    let untrusted = try KeychainVault(keychainFile: foreign.path, interactive: false)
    let refusedSaid: KeyVaultProblem? = { do { _ = try untrusted.key(create: true); return nil } catch { return error as? KeyVaultProblem } }()
    equal(refusedSaid, .denied, "a key that doesn't trust this program is refused at once, with no prompt")
}
