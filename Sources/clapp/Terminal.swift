import Darwin

/// Set from the SIGWINCH handler when the terminal window is resized.
/// `sig_atomic_t` is the only type safe to touch inside a signal handler.
var clappResizePending: sig_atomic_t = 0

/// Set from the SIGUSR1 handler — used by background work (the Homebrew index)
/// to ask the main loop to redraw.
var clappRefreshPending: sig_atomic_t = 0

enum KeyPress {
    case up, down, space, enter
    case quit       // q / Q / Ctrl-C
    case deleteKey  // d / D
    case selectAll  // a / A
    case resize     // terminal window was resized (SIGWINCH)
    case refresh    // background work finished (SIGUSR1) — redraw
    case eof        // stdin closed
    case unknown
}

final class Terminal {
    private var saved = termios()
    private var isRaw = false

    func enableRawMode() {
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_cflag |= tcflag_t(CS8)
        // NOTE: We intentionally leave OPOST enabled. Disabling it stops the
        // terminal from translating "\n" into "\r\n", which makes every printed
        // line start at the column where the previous one ended (staircasing).
        // Keeping OPOST on lets ordinary print() calls render line-by-line.
        // VMIN=1, VTIME=0
        withUnsafeMutableBytes(of: &raw.c_cc) { bytes in
            bytes[Int(VMIN)]  = 1
            bytes[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true
        installSignalHandlers()
    }

    /// Install SIGWINCH (resize) and SIGUSR1 (background-refresh) handlers so they
    /// interrupt the blocking read() in readKey(). We deliberately use sigaction
    /// with sa_flags = 0 (no SA_RESTART): the default BSD signal() would
    /// auto-restart the interrupted read(), so the event would never surface
    /// until the next keypress.
    private func installSignalHandlers() {
        var winch = sigaction()
        winch.sa_flags = 0
        sigemptyset(&winch.sa_mask)
        winch.__sigaction_u.__sa_handler = { _ in clappResizePending = 1 }
        sigaction(SIGWINCH, &winch, nil)

        var usr1 = sigaction()
        usr1.sa_flags = 0
        sigemptyset(&usr1.sa_mask)
        usr1.__sigaction_u.__sa_handler = { _ in clappRefreshPending = 1 }
        sigaction(SIGUSR1, &usr1, nil)
    }

    func disableRawMode() {
        guard isRaw else { return }
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &saved)
        isRaw = false
    }

    func readKey() -> KeyPress {
        var c: UInt8 = 0
        while true {
            let n = Darwin.read(STDIN_FILENO, &c, 1)
            if n == 1 { break }                       // got a byte
            if clappResizePending != 0 {              // SIGWINCH interrupted us
                clappResizePending = 0
                return .resize
            }
            if clappRefreshPending != 0 {             // SIGUSR1: background work done
                clappRefreshPending = 0
                return .refresh
            }
            if n == 0 { return .eof }                 // stdin closed
            // n == -1 from a different signal (EINTR): just retry
        }

        if c == 27 {
            // Try to read escape sequence in non-blocking mode
            let flags = fcntl(STDIN_FILENO, F_GETFL, 0)
            _ = fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
            var b1: UInt8 = 0, b2: UInt8 = 0
            let n1 = Darwin.read(STDIN_FILENO, &b1, 1)
            let n2 = Darwin.read(STDIN_FILENO, &b2, 1)
            _ = fcntl(STDIN_FILENO, F_SETFL, flags)
            if n1 > 0 && b1 == 91 && n2 > 0 {
                switch b2 {
                case 65: return .up
                case 66: return .down
                default: break
                }
            }
            return .unknown
        }

        switch c {
        case 32:       return .space
        case 13, 10:   return .enter
        case 113, 81:  return .quit       // q, Q
        case  97,  65: return .selectAll  // a, A
        case 100,  68: return .deleteKey  // d, D
        case 3:        return .quit       // Ctrl-C
        default:       return .unknown
        }
    }

    /// Result of reading a single byte while also watching for resize/EOF.
    enum ByteOrResize { case byte(UInt8); case resize; case eof }

    /// Blocking read of one raw byte, but surfaces SIGWINCH resizes and EOF so
    /// callers (e.g. the confirm prompt) can redraw or bail instead of blocking.
    func readByteOrResize() -> ByteOrResize {
        var c: UInt8 = 0
        while true {
            let n = Darwin.read(STDIN_FILENO, &c, 1)
            if n == 1 { return .byte(c) }
            if clappResizePending != 0 { clappResizePending = 0; return .resize }
            if n == 0 { return .eof }
            // n == -1 from another signal (EINTR): retry
        }
    }

    // ANSI helpers
    func clearScreen()         { print("\u{1B}[2J\u{1B}[H", terminator: ""); flush() }
    func hideCursor()          { print("\u{1B}[?25l", terminator: ""); flush() }
    func showCursor()          { print("\u{1B}[?25h", terminator: ""); flush() }
    func flush()               { fflush(stdout) }

    var width: Int {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
        return ws.ws_col > 0 ? Int(ws.ws_col) : 80
    }

    var height: Int {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
        return ws.ws_row > 0 ? Int(ws.ws_row) : 24
    }
}
