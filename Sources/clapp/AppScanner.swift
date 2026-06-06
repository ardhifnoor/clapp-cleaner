import Foundation
import Security

struct AppInfo {
    let name: String
    let path: URL
    let bundleID: String?
    let vendor: String
    let source: AppSource
    var sizeBytes: Int64
    var associatedFiles: [URL]
    var isSelected: Bool = false

    var sizeString: String {
        let mb = Double(sizeBytes) / 1_000_000
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
        if mb >= 1    { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(sizeBytes) / 1_000)
    }
}

final class AppScanner {

    // MARK: - Public scan

    /// Returns only user-removable apps. Pass `includeSystemApps: true` for --show-system mode.
    /// `brew` (if supplied) attributes apps to their Homebrew cask.
    func scan(includeSystemApps: Bool = false, brew: BrewIndex? = nil) -> [AppInfo] {
        var apps: [AppInfo] = []
        let searchPaths = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
        ]
        for dir in searchPaths {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for url in contents where url.pathExtension == "app" {
                guard includeSystemApps || !isAppleFirstParty(at: url) else { continue }
                if let info = makeAppInfo(url: url, brew: brew) { apps.append(info) }
            }
        }
        return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Determine how an app was installed.
    func appSource(at url: URL, brew: BrewIndex?) -> AppSource {
        if let token = brew?.appToToken[url.lastPathComponent] { return .brewCask(token: token) }
        let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt")
        if FileManager.default.fileExists(atPath: receipt.path) { return .appStore }
        return .manual
    }

    // MARK: - Apple first-party detection

    /// Returns true if the app is a first-party Apple app that should not be listed for deletion.
    ///
    /// Two-layer check:
    ///   1. Path prefix — /System/ is the sealed read-only volume (SIP-protected, never deletable).
    ///   2. Code signing — inspect the (cached, fast) signing certificates: the chain must root at
    ///      "Apple Root CA" and the leaf must be Apple's own system signing identity ("Software
    ///      Signing" / "Apple Mac OS X …"). Third-party Developer ID and Mac App Store apps use a
    ///      different leaf CN and so are NOT hidden.
    ///
    /// We deliberately avoid `SecStaticCodeCheckValidity(… "anchor apple" …)`: that performs a full
    /// online trust/notarization evaluation that can take several seconds per app on a cold cache,
    /// which froze the scan. Reading the embedded certs is ~0.02s and needs no network.
    func isAppleFirstParty(at url: URL) -> Bool {
        if url.path.hasPrefix("/System/") { return true }
        guard let certs = signingCertificates(at: url), !certs.isEmpty,
              let leafCN = commonName(certs.first!) else { return false }
        let rootCN = commonName(certs.last!) ?? ""
        guard rootCN.contains("Apple Root") else { return false }
        return leafCN == "Software Signing" || leafCN.hasPrefix("Apple Mac OS X")
    }

    /// Reads an app's embedded signing certificate chain (leaf first, root last).
    /// Fast and offline — uses kSecCSSigningInformation, no trust evaluation.
    private func signingCertificates(at url: URL) -> [SecCertificate]? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] else { return nil }
        return certs
    }

    private func commonName(_ cert: SecCertificate) -> String? {
        var cn: CFString?
        guard SecCertificateCopyCommonName(cert, &cn) == errSecSuccess else { return nil }
        return cn as String?
    }

    // MARK: - App info builders

    private func makeAppInfo(url: URL, brew: BrewIndex?) -> AppInfo? {
        let name = url.deletingPathExtension().lastPathComponent
        let bundleID = readBundleID(appURL: url)
        let size = directorySize(url: url)
        let associated = findAssociatedFiles(name: name, bundleID: bundleID)
        let vendor = vendorName(at: url, bundleID: bundleID)
        let source = appSource(at: url, brew: brew)
        return AppInfo(name: name, path: url, bundleID: bundleID, vendor: vendor,
                       source: source, sizeBytes: size, associatedFiles: associated)
    }

    // MARK: - Vendor identification

    /// Human-readable vendor for grouping. Prefers the code-signing authority
    /// (e.g. "Developer ID Application: Google LLC (TEAM)" → "Google"), and
    /// falls back to the second component of the reverse-DNS bundle ID
    /// (com.google.Chrome → "Google").
    func vendorName(at url: URL, bundleID: String?) -> String {
        if let cn = leafCommonName(at: url), let org = Self.orgFromSigningCommonName(cn) {
            return org
        }
        if let bid = bundleID, let v = Self.vendorFromBundleID(bid) {
            return v
        }
        return "Other"
    }

    private func leafCommonName(at url: URL) -> String? {
        guard let certs = signingCertificates(at: url), let leaf = certs.first else { return nil }
        return commonName(leaf)
    }

    static func orgFromSigningCommonName(_ cn: String) -> String? {
        // Only Developer-ID / Mac Developer certs carry the real org in the CN.
        // Generic App Store ("Apple Mac OS Application Signing") and Apple system
        // ("Software Signing") CNs do not, so we return nil to use the fallback.
        let prefixes = [
            "Developer ID Application: ",
            "3rd Party Mac Developer Application: ",
            "Mac Developer: ",
            "Apple Development: ",
        ]
        guard let prefix = prefixes.first(where: { cn.hasPrefix($0) }) else { return nil }
        var s = String(cn.dropFirst(prefix.count))
        if let r = s.range(of: " (", options: .backwards) {     // drop trailing " (TEAMID)"
            s = String(s[..<r.lowerBound])
        }
        return stripCompanySuffix(s.trimmingCharacters(in: .whitespaces))
    }

    static func stripCompanySuffix(_ name: String) -> String {
        let suffixes: Set<String> = [
            "llc", "l.l.c.", "inc", "inc.", "incorporated", "corporation", "corp",
            "corp.", "co", "co.", "ltd", "ltd.", "limited", "gmbh", "pbc", "s.a.",
            "ab", "ag", "b.v.", "bv", "s.r.l.", "plc", "oy", "kk", "software",
        ]
        var tokens = name.split(separator: " ").map(String.init)
        var changed = true
        while changed, tokens.count > 1 {
            changed = false
            if tokens.count >= 2 {
                let two = (tokens[tokens.count - 2] + " " + tokens[tokens.count - 1]).lowercased()
                if two == "pty ltd" || two == "pty. ltd." {
                    tokens.removeLast(2); changed = true; continue
                }
            }
            if suffixes.contains(tokens[tokens.count - 1].lowercased()) {
                tokens.removeLast(); changed = true
            }
        }
        let result = tokens.joined(separator: " ")
        return result.isEmpty ? name : result
    }

    static func vendorFromBundleID(_ bid: String) -> String? {
        let parts = bid.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let v = String(parts[1])
        guard !v.isEmpty else { return nil }
        return v.prefix(1).uppercased() + v.dropFirst()
    }

    /// Short lowercase token used to match a vendor's shared files (first word).
    static func vendorToken(_ vendor: String) -> String {
        (vendor.split(separator: " ").first.map(String.init) ?? vendor).lowercased()
    }

    // MARK: - Vendor-shared items (login items / updaters)

    /// Finds files SHARED across all of a vendor's apps — login items / background
    /// agents (LaunchAgents/LaunchDaemons) and vendor-named support/update folders
    /// (e.g. ~/Library/Google/GoogleSoftwareUpdate). These update *all* of a
    /// vendor's apps, so the UI only removes them when every installed app from
    /// that vendor is being uninstalled.
    func vendorSharedItems(vendor: String) -> [URL] {
        let token = Self.vendorToken(vendor)
        guard token.count >= 3 else { return [] }   // too-short tokens are unsafe to match

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let lib = home.appendingPathComponent("Library")
        var found: [URL] = []

        // 1. Login items / background agents — match the vendor token anywhere in
        //    the filename (catches com.google.keystone.*, com.google.GoogleUpdater.*).
        let agentDirs = [
            lib.appendingPathComponent("LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
        ]
        for dir in agentDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in contents where item.lastPathComponent.lowercased().contains(token) {
                found.append(item)
            }
        }

        // 2. Vendor-named top-level folders (exact match on the vendor token).
        let parents = [
            lib,
            lib.appendingPathComponent("Application Support"),
            lib.appendingPathComponent("Caches"),
        ]
        for parent in parents {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil) else { continue }
            for item in contents where item.lastPathComponent.lowercased() == token {
                found.append(item)
            }
        }
        return found
    }

    private func readBundleID(appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    // MARK: - Size & associated files

    func directorySize(url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let vals = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  vals.isRegularFile == true,
                  let size = vals.fileSize else { continue }
            total += Int64(size)
        }
        return total
    }

    func findAssociatedFiles(name: String, bundleID: String?) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let lib = home.appendingPathComponent("Library")
        let searchDirs: [URL] = [
            lib.appendingPathComponent("Application Support"),
            lib.appendingPathComponent("Preferences"),
            lib.appendingPathComponent("Caches"),
            lib.appendingPathComponent("Logs"),
            lib.appendingPathComponent("Containers"),
            lib.appendingPathComponent("Saved Application State"),
            lib.appendingPathComponent("HTTPStorages"),
            lib.appendingPathComponent("WebKit"),
            lib.appendingPathComponent("LaunchAgents"),
        ]
        let nameLower = name.lowercased()
        var found: [URL] = []
        for dir in searchDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for item in contents {
                let itemName = item.lastPathComponent.lowercased()
                let match: Bool
                if let bid = bundleID {
                    match = itemName.contains(bid.lowercased()) || itemName.contains(nameLower)
                } else {
                    match = itemName.contains(nameLower)
                }
                if match { found.append(item) }
            }
        }
        return found
    }
}
