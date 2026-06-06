import Foundation

func formatSize(_ bytes: Int64) -> String {
    let mb = Double(bytes) / 1_000_000
    if mb >= 1000 { return String(format: "%.1f GB", mb / 1000) }
    if mb >= 1    { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1_000)
}

final class CleanerUI {
    private let scanner = AppScanner()
    private let terminal = Terminal()
    private var apps: [AppInfo] = []
    private var rows: [DisplayRow] = []   // flattened: vendor headers + app rows
    private var cursor = 0                 // index into `rows`, always on an .app row
    private var scrollOffset = 0
    private let useTrash: Bool
    private let skipConfirm: Bool
    private let showSystem: Bool

    // Layout constants
    private let leftMargin = 2
    private let appIndentW = 2        // app rows indent under their vendor header
    private let sizeColW = 9
    private let assocColW = 12
    private let prefixW = 6           // "> [x] "

    /// One visible line: either a vendor group header or an app row.
    private enum DisplayRow {
        case vendor(name: String, appCount: Int, bytes: Int64)
        case app(Int)                // index into `apps`
    }

    /// Files shared by all of a vendor's apps (login items / updater folders).
    private struct VendorShared { let vendor: String; let urls: [URL] }

    /// Everything a delete action will remove, computed once when D is pressed.
    private struct DeletionPlan {
        let apps: [AppInfo]
        let shared: [VendorShared]
    }

    init(useTrash: Bool, skipConfirm: Bool, showSystem: Bool = false) {
        self.useTrash = useTrash
        self.skipConfirm = skipConfirm
        self.showSystem = showSystem
    }

    func start() {
        terminal.hideCursor()
        terminal.enableRawMode()
        defer {
            terminal.disableRawMode()
            terminal.showCursor()
        }

        // Scan phase
        terminal.clearScreen()
        printHeader()
        print("\n  Scanning installed apps…", terminator: "")
        terminal.flush()
        apps = scanner.scan(includeSystemApps: showSystem)

        if apps.isEmpty {
            terminal.clearScreen()
            if showSystem {
                print("\n  No apps found in /Applications or ~/Applications.\n")
            } else {
                print("\n  No third-party apps found.")
                print("  (Apple system apps are hidden — run with --show-system to include them.)\n")
            }
            return
        }

        buildRows()
        cursor = firstAppRow() ?? 0
        render()
        runLoop()
    }

    // MARK: - Grouping model

    private func buildRows() {
        var byVendor: [String: [Int]] = [:]
        for (i, app) in apps.enumerated() { byVendor[app.vendor, default: []].append(i) }

        rows = []
        for vendor in byVendor.keys.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            let idxs = byVendor[vendor]!.sorted { apps[$0].name.lowercased() < apps[$1].name.lowercased() }
            let bytes = idxs.reduce(Int64(0)) { $0 + apps[$1].sizeBytes }
            rows.append(.vendor(name: vendor, appCount: idxs.count, bytes: bytes))
            for i in idxs { rows.append(.app(i)) }
        }
    }

    private func isAppRow(_ i: Int) -> Bool {
        if case .app = rows[i] { return true }
        return false
    }
    private func firstAppRow() -> Int? { rows.indices.first(where: isAppRow) }
    private func nextAppRow(after i: Int) -> Int? { ((i + 1)..<rows.count).first(where: isAppRow) }
    private func prevAppRow(before i: Int) -> Int? {
        stride(from: i - 1, through: 0, by: -1).first(where: isAppRow)
    }

    private var cursorAppIndex: Int? {
        guard cursor < rows.count, case .app(let i) = rows[cursor] else { return nil }
        return i
    }

    // MARK: - Main loop

    private func runLoop() {
        while true {
            switch terminal.readKey() {
            case .up:
                if let p = prevAppRow(before: cursor) { cursor = p; adjustScroll() }
            case .down:
                if let n = nextAppRow(after: cursor) { cursor = n; adjustScroll() }
            case .space:
                if let i = cursorAppIndex { apps[i].isSelected.toggle() }
            case .selectAll:
                let allOn = apps.allSatisfy { $0.isSelected }
                for i in apps.indices { apps[i].isSelected = !allOn }
            case .deleteKey:
                let selected = apps.filter { $0.isSelected }
                guard !selected.isEmpty else { break }
                let plan = buildPlan(selected)
                if showConfirm(plan) {
                    terminal.disableRawMode()
                    terminal.showCursor()
                    performDelete(plan)
                    return
                }
            case .resize:
                adjustScroll()
            case .quit, .eof:
                terminal.clearScreen()
                print("\n  Bye! Nothing was deleted.\n")
                return
            default:
                break
            }
            render()
        }
    }

    // MARK: - Deletion planning

    private func buildPlan(_ selected: [AppInfo]) -> DeletionPlan {
        var installed: [String: Int] = [:]
        for a in apps { installed[a.vendor, default: 0] += 1 }
        var chosen: [String: Int] = [:]
        for a in selected { chosen[a.vendor, default: 0] += 1 }

        var shared: [VendorShared] = []
        for (vendor, count) in chosen where count == installed[vendor] {
            // Every installed app from this vendor is being removed → its shared
            // login items / updaters are safe to remove too.
            let urls = scanner.vendorSharedItems(vendor: vendor)
            if !urls.isEmpty { shared.append(VendorShared(vendor: vendor, urls: urls)) }
        }
        shared.sort { $0.vendor.lowercased() < $1.vendor.lowercased() }
        return DeletionPlan(apps: selected, shared: shared)
    }

    // MARK: - Geometry

    private var contentWidth: Int { max(20, terminal.width - leftMargin - 1) }
    private var showAssocColumn: Bool { contentWidth >= 56 }
    private var compactBanner: Bool { contentWidth < 34 }

    private var nameColW: Int {
        let assoc = showAssocColumn ? assocColW + 2 : 0
        let w = contentWidth - appIndentW - prefixW - 1 - sizeColW - assoc
        return max(8, w)
    }

    private var viewportSize: Int {
        let bannerLines = compactBanner ? 1 : 4
        let topChrome = 1 + bannerLines + 1 + 1 + 1 + 1 + 1 + 1 + 1 + 1
        let bottomChrome = 2
        return max(3, terminal.height - topChrome - bottomChrome - 1)
    }

    private func adjustScroll() {
        let vp = viewportSize
        if cursor < scrollOffset { scrollOffset = cursor }
        else if cursor >= scrollOffset + vp { scrollOffset = cursor - vp + 1 }
        // Keep the vendor header just above the cursor visible when possible.
        if scrollOffset > 0, scrollOffset == cursor, cursor > 0 { scrollOffset -= 1 }
    }

    // MARK: - Rendering

    private func render() {
        terminal.clearScreen()
        printHeader()

        let selected = apps.filter { $0.isSelected }
        let selectedBytes = selected.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let vendorCount = Set(apps.map { $0.vendor }).count

        emit("")
        emit("\(apps.count) apps · \(vendorCount) vendors · \(selected.count) selected · \(formatSize(selectedBytes)) to free")
        emit("")
        emit("↑↓ Navigate   Space Toggle   A All/None   D Delete   Q Quit")
        emit("")

        let sep = String(repeating: "─", count: contentWidth)
        emit(sep)
        emitColumnHeader()
        emit(sep)

        let vp = viewportSize
        let end = min(scrollOffset + vp, rows.count)
        for i in scrollOffset..<end { emitDisplayRow(i) }
        if end - scrollOffset < vp {
            for _ in 0..<(vp - (end - scrollOffset)) { emit("") }
        }

        emit(sep)
        if rows.count > vp {
            let denom = max(1, rows.count - vp)
            let pct = min(100, scrollOffset * 100 / denom)
            emit("[rows \(scrollOffset + 1)–\(end) of \(rows.count)]   scroll \(pct)%")
        } else {
            emit("")
        }

        terminal.flush()
    }

    private func emitColumnHeader() {
        let name = padRight("App Name", nameColW)
        let size = padLeft("Size", sizeColW)
        var s = String(repeating: " ", count: appIndentW + prefixW) + name + " " + size
        if showAssocColumn { s += "  " + padRight("Assoc. Files", assocColW) }
        emit(s)
    }

    private func emitDisplayRow(_ rowIndex: Int) {
        switch rows[rowIndex] {
        case .vendor(let name, let count, let bytes):
            let left = "▾ \(name)"
            let right = "\(count) app\(count == 1 ? "" : "s")   \(formatSize(bytes))"
            let line = String(repeating: " ", count: leftMargin) + justify(left, right, contentWidth)
            print("\u{1B}[1;36m\(line)\u{1B}[0m")     // bold cyan
        case .app(let i):
            emitAppRow(rowIndex: rowIndex, appIndex: i)
        }
    }

    private func emitAppRow(rowIndex: Int, appIndex i: Int) {
        let app = apps[i]
        let isCursor = rowIndex == cursor
        let marker = isCursor ? ">" : " "
        let check  = app.isSelected ? "x" : " "
        let prefix = "\(marker) [\(check)] "
        let nameCell = padRight(app.name, nameColW)
        let sizeCell = padLeft(app.sizeString, sizeColW)
        var content = String(repeating: " ", count: appIndentW) + prefix + nameCell + " " + sizeCell
        if showAssocColumn {
            let fcount = app.associatedFiles.isEmpty ? "—" : "\(app.associatedFiles.count) file(s)"
            content += "  " + padRight(fcount, assocColW)
        }
        content = padRight(content, contentWidth)

        let line = String(repeating: " ", count: leftMargin) + content
        if isCursor {
            print("\u{1B}[7m\(line)\u{1B}[0m")
        } else if app.isSelected {
            print("\u{1B}[32m\(line)\u{1B}[0m")
        } else {
            print(line)
        }
    }

    private func printHeader() {
        let title1 = "CLAPP Cleaner  v1.0.0"
        let title2 = "Command Line-based APP Cleaner"
        print()
        if compactBanner {
            emit(title1)
            return
        }
        let inner = min(contentWidth - 2, 54)
        let bar = String(repeating: "═", count: inner)
        print(String(repeating: " ", count: leftMargin) + "╔\(bar)╗")
        print(String(repeating: " ", count: leftMargin) + "║\(center(title1, inner))║")
        print(String(repeating: " ", count: leftMargin) + "║\(center(title2, inner))║")
        print(String(repeating: " ", count: leftMargin) + "╚\(bar)╝")
    }

    // MARK: - Confirm screen (resize-aware)

    private func showConfirm(_ plan: DeletionPlan) -> Bool {
        renderConfirm(plan)
        while true {
            switch terminal.readByteOrResize() {
            case .resize:        renderConfirm(plan)
            case .eof:           return false
            case .byte(let b):   return b == 121 || b == 89   // y / Y
            }
        }
    }

    private func renderConfirm(_ plan: DeletionPlan) {
        terminal.clearScreen()
        printHeader()
        emit("")

        let appBytes = plan.apps.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let assocBytes = plan.apps.reduce(Int64(0)) { acc, app in
            acc + app.associatedFiles.reduce(Int64(0)) { $0 + scanner.directorySize(url: $1) }
        }
        let sharedBytes = plan.shared.reduce(Int64(0)) { acc, vs in
            acc + vs.urls.reduce(Int64(0)) { $0 + scanner.directorySize(url: $1) }
        }
        let assocCount = plan.apps.reduce(0) { $0 + $1.associatedFiles.count }
        let action = useTrash ? "move to Trash" : "permanently delete"

        emit("About to \(action) \(plan.apps.count) app(s):")
        emit("")
        for app in plan.apps {
            let fcount = app.associatedFiles.isEmpty ? "" : " + \(app.associatedFiles.count) assoc. file(s)"
            emit("  • \(app.name)  (\(app.sizeString)\(fcount)) — \(app.vendor)")
        }
        emit("")
        if assocCount > 0 {
            emit("\(assocCount) app-specific support file(s) will also be removed.")
        }

        if !plan.shared.isEmpty {
            emit("")
            emit("Shared vendor items (all of these vendors' apps are being removed):")
            for vs in plan.shared {
                for url in vs.urls {
                    emit("  • [\(vs.vendor)] \(sharedItemLabel(url)) — \(abbreviatePath(url))")
                }
            }
        }

        emit("")
        emit("Estimated space freed: \(formatSize(appBytes + assocBytes + sharedBytes))")
        emit("")
        emit(useTrash ? "Press Y to confirm, any other key to cancel."
                      : "Press Y to permanently delete, any other key to cancel.")
        terminal.flush()
    }

    private func sharedItemLabel(_ url: URL) -> String {
        let p = url.path
        if p.contains("/LaunchAgents/") || p.contains("/LaunchDaemons/") { return "login item" }
        return "support/updater folder"
    }

    private func abbreviatePath(_ url: URL) -> String {
        let home = NSHomeDirectory()
        let p = url.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    // MARK: - Deletion

    private func performDelete(_ plan: DeletionPlan) {
        terminal.clearScreen()
        let action = useTrash ? "Trashing" : "Deleting"
        print("\n  \(action) \(plan.apps.count) app(s)…\n")

        var totalFreed: Int64 = 0

        for app in plan.apps {
            var freed: Int64 = 0
            var errors: [String] = []

            for file in app.associatedFiles {
                let fileSize = scanner.directorySize(url: file)
                do { try remove(file); freed += fileSize }
                catch { errors.append(file.lastPathComponent) }
            }

            do {
                let appSize = app.sizeBytes
                try remove(app.path)
                freed += appSize
                totalFreed += freed
                let errNote = errors.isEmpty ? "" : "  (\(errors.count) assoc. item(s) skipped)"
                emit("✓  \(padRight(app.name, 28))  \(formatSize(freed)) freed\(errNote)")
            } catch {
                emit("✗  \(padRight(app.name, 28))  \(error.localizedDescription)")
                if error.localizedDescription.contains("permission") || (error as NSError).code == 513 {
                    emit("   Tip: run with sudo for system-level apps")
                }
            }
        }

        if !plan.shared.isEmpty {
            emit("")
            for vs in plan.shared {
                for url in vs.urls {
                    let size = scanner.directorySize(url: url)
                    do {
                        try remove(url)
                        totalFreed += size
                        emit("✓  [\(vs.vendor)] \(abbreviatePath(url))  \(formatSize(size)) freed")
                    } catch {
                        emit("✗  [\(vs.vendor)] \(abbreviatePath(url))  \(error.localizedDescription)")
                    }
                }
            }
        }

        emit("")
        emit("Done!  Total freed: \(formatSize(totalFreed))")
        if useTrash { emit("Removed items are in the Trash.") }
        print()
    }

    private func remove(_ url: URL) throws {
        if useTrash {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Output helpers

    private func emit(_ s: String) {
        print(String(repeating: " ", count: leftMargin) + clip(s, contentWidth))
    }

    private func clip(_ s: String, _ w: Int) -> String {
        if w <= 0 { return "" }
        if s.count <= w { return s }
        if w == 1 { return "…" }
        return String(s.prefix(w - 1)) + "…"
    }

    private func padRight(_ s: String, _ w: Int) -> String {
        let c = clip(s, w)
        return c + String(repeating: " ", count: max(0, w - c.count))
    }

    private func padLeft(_ s: String, _ w: Int) -> String {
        let c = clip(s, w)
        return String(repeating: " ", count: max(0, w - c.count)) + c
    }

    private func center(_ s: String, _ w: Int) -> String {
        let c = clip(s, w)
        let total = max(0, w - c.count)
        let left = total / 2
        return String(repeating: " ", count: left) + c + String(repeating: " ", count: total - left)
    }

    /// Left text + right text on one line of the given width, right-aligned.
    private func justify(_ left: String, _ right: String, _ w: Int) -> String {
        let r = clip(right, w)
        let maxLeft = max(0, w - r.count - 1)
        let l = clip(left, maxLeft)
        let pad = max(1, w - l.count - r.count)
        return l + String(repeating: " ", count: pad) + r
    }
}
