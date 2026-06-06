import Foundation

/// How an app got onto the machine — used for the Source column and to route
/// uninstalls through the right mechanism.
enum AppSource: Equatable {
    case brewCask(token: String)   // Homebrew cask (token is the cask name)
    case appStore                  // Mac App Store (has a _MASReceipt)
    case manual                    // dragged in / .dmg / .pkg — plain filesystem app

    /// Short label for the Source column.
    var label: String {
        switch self {
        case .brewCask: return "brew"
        case .appStore: return "App Store"
        case .manual:   return "—"
        }
    }
}

/// Builds (once) a map of installed Homebrew casks → the .app they install, so
/// scanned apps can be attributed to a cask and uninstalled via `brew`.
final class BrewIndex {
    let brewPath: String?
    private(set) var appToToken: [String: String] = [:]   // "Google Chrome.app" → "google-chrome"

    var isAvailable: Bool { brewPath != nil }

    init() {
        brewPath = BrewIndex.findBrew()
        if let brew = brewPath { build(brew: brew) }
    }

    /// Homebrew lives at a fixed prefix per architecture.
    static func findBrew() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        return nil
    }

    private func build(brew: String) {
        guard let listed = BrewIndex.run(brew, ["list", "--cask", "-1"]) else { return }
        let tokens = listed.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return }   // no casks → nothing to map (and skip the slow info call)

        guard let json = BrewIndex.run(brew, ["info", "--cask", "--json=v2"] + tokens),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]] else { return }

        for cask in casks {
            guard let token = cask["token"] as? String,
                  let artifacts = cask["artifacts"] as? [[String: Any]] else { continue }
            for artifact in artifacts {
                // App artifacts look like {"app": ["Google Chrome.app"]}.
                guard let apps = artifact["app"] as? [Any] else { continue }
                for entry in apps {
                    if let appName = entry as? String {
                        appToToken[appName] = token
                    }
                }
            }
        }
    }

    /// Non-interactive environment for brew subprocesses: never auto-update, no
    /// hints/colors. Crucially paired with a /dev/null stdin (see below) so brew
    /// can never block the TUI waiting on a prompt.
    private static func brewEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        return env
    }

    /// Run a subprocess and capture stdout. Returns nil on launch failure.
    /// stdin is /dev/null so the process can never hang waiting for input.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.environment = brewEnvironment()
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Run `brew uninstall --cask <token>` **interactively**, inheriting the real
    /// terminal so the user sees brew's progress and can answer any prompt.
    ///
    /// We deliberately do NOT capture stdout/stderr through a pipe: some casks
    /// remove a privileged helper via `sudo`, which prompts for a password on the
    /// controlling terminal (`/dev/tty`). Capturing the output hid that prompt and
    /// hung the app forever. Inheriting the terminal makes the prompt visible and
    /// answerable. The caller must have already left raw mode.
    ///
    /// Returns true on success (exit status 0).
    func uninstallCask(token: String) -> Bool {
        guard let brew = brewPath else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brew)
        proc.arguments = ["uninstall", "--cask", token]
        proc.environment = BrewIndex.brewEnvironment()
        // stdin/stdout/stderr are inherited from CLAPP (the live terminal).
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }
}
