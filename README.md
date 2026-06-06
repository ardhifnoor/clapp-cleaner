# CLAPP Cleaner

**C**ommand **L**ine-based **APP** Cleaner — a lightweight, interactive macOS app uninstaller written in Swift.

CLAPP scans your installed applications, shows their size and any associated support files, and lets you remove apps *together with* the library files they leave behind — the way a tool like CleanMyMac does, but as a single tiny terminal binary with no background processes, no telemetry, and no subscription.

```
  ╔══════════════════════════════════════════════════════╗
  ║                CLAPP Cleaner  v1.0.0                 ║
  ║            Command Line-based APP Cleaner            ║
  ╚══════════════════════════════════════════════════════╝

  3 apps · 3 vendors · 1 selected · 716 MB to free

  ↑↓ Navigate   Space Toggle   A All/None   D Delete   Q Quit

  ──────────────────────────────────────────────────────────────────────────
          App Name                        Size  Source     Assoc. Files
  ──────────────────────────────────────────────────────────────────────────
  ▾ Google                                1 app                      716 MB
    > [x] Google Chrome                 716 MB  brew       —
  ▾ Mozilla                               1 app                      412 MB
      [ ] Firefox                       412 MB  —          5 file(s)
  ▾ Sublime HQ                            1 app                       98 MB
      [ ] Sublime Text                   98 MB  App Store  3 file(s)
  ──────────────────────────────────────────────────────────────────────────
```

Apps are **grouped by vendor** (derived from each app's code-signing identity),
sorted vendor-then-name. The interface is **responsive**: column widths, the
banner, and the number of visible rows are computed from your terminal size on
every redraw — including live reflow when you resize the window mid-session (both
the list and the confirmation screen). Long names/paths are truncated with `…`,
and on narrow terminals the "Assoc. Files" column drops automatically. Wrap-free
down to ~40 columns.

---

## How it works

1. **Scan** — CLAPP enumerates `.app` bundles in `/Applications` and `~/Applications`.
2. **Protect system apps** — Apple's first-party apps are detected and hidden automatically (see below). You can't accidentally delete something macOS depends on.
3. **Identify vendor** — each app's code-signing identity is read to determine its vendor (e.g. `Developer ID Application: Google LLC` → **Google**), used for grouping and for finding shared items. Falls back to the bundle ID (`com.google.Chrome` → Google).
4. **Measure** — each app's on-disk size is calculated by walking the bundle.
5. **Find leftovers** — for each app, CLAPP looks through your `~/Library` for matching support files:
   - `Application Support`, `Preferences`, `Caches`, `Logs`, `Containers`
   - `Saved Application State`, `HTTPStorages`, `WebKit`, `LaunchAgents`
6. **Remove** — when you confirm, the associated files are removed first, then the `.app` bundle itself, then any vendor-shared items (see below).

### System-app protection

CLAPP never lists apps it considers essential to macOS. It uses a two-layer check:

1. **Path** — anything under `/System/` lives on the sealed, read-only system volume (SIP-protected) and is skipped.
2. **Code signature** — CLAPP reads the app's embedded signing certificate chain (via the macOS Security framework). An app is treated as Apple first-party only if its chain roots at **Apple Root CA** *and* its leaf certificate is Apple's own system signing identity (`Software Signing`). Third-party Developer ID and Mac App Store apps use a different leaf and are *not* hidden.

This is signature-based rather than a hardcoded name list, so it keeps working across macOS updates with no maintenance. (Reading the certificates is fast and offline — CLAPP deliberately avoids a full `SecStaticCodeCheckValidity` trust evaluation, which can stall for seconds per app on a cold cache.)

### Vendor-shared items: login items & updaters

Many vendors install **shared** helpers that aren't tied to a single app — login
items / background agents (`~/Library/LaunchAgents/com.google.keystone.agent.plist`,
`com.google.GoogleUpdater.wake.plist`, …) and updater/support folders
(`~/Library/Google/GoogleSoftwareUpdate`). Because these are shared, CLAPP only
removes them when **every installed app from that vendor is being uninstalled** in
the same operation — otherwise the remaining apps would lose their updater. When
applicable they're listed explicitly on the confirmation screen, labelled as
`login item` or `support/updater folder` with their full path.

> **Note:** these are exactly the entries you see under **System Settings → General
> → Login Items → "Allow in the Background"**. Modern login items registered via
> `SMAppService` (stored in a private database) are *not* file-based and are not
> detected by CLAPP.

### Package-manager awareness (Source column)

CLAPP shows **how each app was installed** in a `Source` column:

| Source | Meaning | Uninstall behaviour |
|--------|---------|---------------------|
| `brew` | Homebrew **cask** (GUI app) | Removed via `brew uninstall --cask <token>` so Homebrew's records stay consistent — no stale "still installed" entries. brew runs **interactively** on the terminal and may prompt for your password (to remove privileged helpers); CLAPP also cleans the user-level support files it finds. |
| `App Store` | Has a Mac App Store receipt (`_MASReceipt`) | Removed from disk like a normal app. |
| `—` | Manual install (drag-to-Applications, `.dmg`, `.pkg`) | Removed from disk (or moved to Trash with `--trash`). |

Homebrew casks are matched by reading `brew info --cask --json` and mapping each
cask's `.app` artifact to its token. If Homebrew isn't installed, the column
simply shows `—`/`App Store` and nothing changes.

#### Non-blocking startup

Querying Homebrew takes a couple of seconds, so CLAPP **does not block on it**.
The app list appears immediately (~0.4s); the Homebrew index builds on a
background thread. While it loads, the header shows a small **`checking
Homebrew…`** note and brew-managed apps appear as `—`. The moment the index is
ready the screen redraws on its own and the `brew` labels fill in — no keypress
needed. (If you start a delete before it finishes, CLAPP briefly waits for the
index so casks are still routed through `brew uninstall --cask`.)

> **Scope — CLI tools (npm, brew *formulae*):** CLAPP is an **app** cleaner — it
> scans `.app` bundles. Command-line tools installed with `npm install -g` or
> `brew install <formula>` are not `.app` bundles (they live under a Node prefix
> or Homebrew's Cellar as binaries/symlinks), so they are **not** listed. Use
> `npm uninstall -g <pkg>` / `brew uninstall <formula>` for those. Only Homebrew
> **casks**, which install real GUI apps, are surfaced here.

---

## Installation

Requires the Xcode Command Line Tools (`xcode-select --install`) — no full Xcode needed.

```bash
git clone <repo> ~/clapp-cleaner      # or copy the source there
cd ~/clapp-cleaner
swift build -c release
cp .build/release/clapp /usr/local/bin/clapp
```

Verify:

```bash
clapp --version      # 1.0.0
clapp --help
```

### Uninstalling CLAPP itself

```bash
rm /usr/local/bin/clapp        # remove the binary
rm -rf ~/clapp-cleaner         # remove the source/build dir
```

CLAPP stores no preferences, caches, or background agents — those two commands remove it completely.

---

## Usage

```bash
clapp [--trash] [--yes] [--show-system]
```

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--trash` | `-t` | Move removed apps to the Trash instead of deleting permanently. **Recommended** — it's reversible. |
| `--yes` | `-y` | Skip the confirmation prompt before deleting. |
| `--show-system` | | Include Apple first-party system apps in the list (hidden by default). |
| `--version` | | Print the version. |
| `--help` | `-h` | Show help. |

### Controls

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move the cursor |
| `Space` | Toggle selection of the highlighted app |
| `A` | Select all / deselect all |
| `D` | Delete the selected apps (shows a confirmation summary) |
| `Q` / `Ctrl-C` | Quit without deleting |

### Examples

```bash
clapp                 # browse and permanently delete (with confirmation)
clapp --trash         # safer: selected apps go to the Trash
clapp --show-system   # also show Apple system apps (still hard to delete due to SIP)
```

---

## Notes & caveats

- **Permissions** — some apps or their support files may be owned by another user or protected; CLAPP reports those as skipped rather than failing the whole run. Re-running with `sudo` can help for stubborn system-level locations.
- **Associated-file matching** is name/bundle-ID based and intentionally conservative. Review the per-app file counts on the confirmation screen before deleting.
- **Universal binary** — the build produces a native binary for your Mac's architecture. On Apple Silicon an Intel build runs transparently via Rosetta 2; for a native arm64 + x86_64 universal binary, build with full Xcode installed:
  ```bash
  swift build -c release --arch arm64 --arch x86_64
  ```

---

## License

MIT — do whatever you like.
