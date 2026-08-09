import Foundation

// The `bilakh` command-line tool. Lets AI coding agents (Claude Code, Codex,
// Gemini CLI, or anything scriptable) ping Bilakh so the locked screen glows and
// a notification fires when they need you.
//
// Transport: a DistributedNotificationCenter message — NOT the bilakh:// URL
// scheme — so a background ping never launches the app when it isn't running.

let pingNotificationName = "in.pooya.bilakh.ping"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Error: " + message + "\n").utf8))
    exit(1)
}

/// Resolve the user's home via $HOME (the convention agent CLIs use to locate their
/// own config), falling back to the account home. NOT homeDirectoryForCurrentUser
/// alone — that ignores $HOME.
func homeDirectory() -> URL {
    if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
        return URL(fileURLWithPath: home, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

func printUsage() {
    print("""
    bilakh — tap Bilakh when your AI agent needs you

    USAGE:
      bilakh ping                  Signal Bilakh (locked screen glows + notification)
      bilakh install-cli           Symlink this tool into your PATH (~/.local/bin)
      bilakh install-hook <tool>   Wire up an agent. <tool>: claude | codex | gemini
                                    Add --print to show the snippet without writing it.
      bilakh --help                Show this help

    EXAMPLES:
      bilakh install-cli
      bilakh install-hook claude
      bilakh install-hook codex --print

    Bilakh stays locked while you're away; ping just lets you know it's time to look.
    """)
}

// MARK: - ping

func sendPing() {
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name(pingNotificationName),
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

// MARK: - install-cli

/// The real on-disk path of this running binary (inside Bilakh.app), resolving
/// through any symlink it was invoked via so the install target points at the app.
func currentBinaryURL() -> URL? {
    let arg0 = CommandLine.arguments[0]
    if arg0.hasPrefix("/") {
        return URL(fileURLWithPath: arg0).resolvingSymlinksInPath()
    }
    if let path = Bundle.main.executablePath, path.hasSuffix("bilakh") {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath()
    }
    return nil
}

/// Create or refresh `~/.local/bin/bilakh` → this binary. Idempotent; re-running
/// picks up a moved app. Returns the symlink URL.
@discardableResult
func ensureCLISymlink() throws -> URL {
    let fm = FileManager.default
    guard let exec = currentBinaryURL() else {
        throw NSError(domain: "Bilakh", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not determine the bilakh binary path."
        ])
    }
    let binDir = homeDirectory().appendingPathComponent(".local/bin", isDirectory: true)
    let link = binDir.appendingPathComponent("bilakh")
    try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    if (try? link.checkResourceIsReachable()) == true || fm.fileExists(atPath: link.path) {
        try? fm.removeItem(at: link)
    }
    try fm.createSymbolicLink(at: link, withDestinationURL: exec)
    return link
}

func installCLI() {
    let link: URL
    do {
        link = try ensureCLISymlink()
        print("✓ Linked bilakh → \(link.path)")
    } catch {
        fail("Could not create symlink: \(error.localizedDescription)")
    }

    let binDir = link.deletingLastPathComponent()

    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let onPath = path.split(separator: ":").contains { $0 == binDir.path }
    if onPath {
        print("  You can now run `bilakh ping` from anywhere.")
    } else {
        print("""

        ⚠️  \(binDir.path) is not on your PATH. Add this to your shell profile
            (~/.zshrc or ~/.bashrc), then restart your shell:
                export PATH="$HOME/.local/bin:$PATH"
        """)
    }
}

// MARK: - install-hook

func writeJSON(_ object: [String: Any], to url: URL, label: String) {
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("bak")
            try? fm.removeItem(at: backup)
            try? fm.copyItem(at: url, to: backup)
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: url)
        print("✓ Updated \(label) config at \(url.path)")
    } catch {
        fail("Could not write \(label) config: \(error.localizedDescription)")
    }
}

/// Claude Code's config directory: $CLAUDE_CONFIG_DIR if set (users running multiple
/// profiles point it elsewhere), otherwise ~/.claude.
func claudeConfigDirectory() -> URL {
    if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }
    return homeDirectory().appendingPathComponent(".claude", isDirectory: true)
}

/// The hook command we write. `$HOME/.local/bin/bilakh` rather than bare `bilakh`
/// so the hook works even when `~/.local/bin` isn't on the agent's PATH; the shell
/// that runs hook commands expands `$HOME`. The symlink (not the app bundle path)
/// keeps the hook valid when the app moves or updates.
let claudePingCommand = "\"$HOME/.local/bin/bilakh\" ping"

/// Matches any hook that runs a bilakh ping, in whatever form a past version wrote it.
func isBilakhPingCommand(_ command: String) -> Bool {
    command.contains("bilakh") && command.contains("ping")
}

func installClaudeHook(printOnly: Bool) {
    let url = claudeConfigDirectory().appendingPathComponent("settings.json")
    let escaped = claudePingCommand.replacingOccurrences(of: "\"", with: "\\\"")
    let snippet = """
    Add to \(url.path):

      "hooks": {
        "Notification": [{ "hooks": [{ "type": "command", "command": "\(escaped)" }] }],
        "Stop":         [{ "hooks": [{ "type": "command", "command": "\(escaped)" }] }]
      }
    """
    if printOnly { print(snippet); return }

    // The command points at the ~/.local/bin symlink, so make sure it exists.
    do {
        try ensureCLISymlink()
    } catch {
        fail("Could not install the bilakh command: \(error.localizedDescription)")
    }

    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: url),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        root = obj
    }

    var hooks = root["hooks"] as? [String: Any] ?? [:]
    for event in ["Notification", "Stop"] {
        var groups = hooks[event] as? [[String: Any]] ?? []
        var present = false
        // Upgrade any existing bilakh entry in place — older versions wrote a bare
        // `bilakh ping`, which silently fails when ~/.local/bin isn't on PATH.
        for g in groups.indices {
            guard var inner = groups[g]["hooks"] as? [[String: Any]] else { continue }
            for h in inner.indices {
                if let cmd = inner[h]["command"] as? String, isBilakhPingCommand(cmd) {
                    inner[h]["command"] = claudePingCommand
                    present = true
                }
            }
            groups[g]["hooks"] = inner
        }
        if !present {
            groups.append(["hooks": [["type": "command", "command": claudePingCommand]]])
        }
        hooks[event] = groups
    }
    root["hooks"] = hooks
    writeJSON(root, to: url, label: "Claude Code")
}

func installCodexHook(printOnly: Bool) {
    // Codex executes `notify` as an argv array (no shell), so the path must be
    // literal — the ~/.local/bin symlink keeps it stable across app moves/updates.
    let linkPath = homeDirectory().appendingPathComponent(".local/bin/bilakh").path
    let line = "notify = [\"\(linkPath)\", \"ping\"]"
    if printOnly {
        print("Add to ~/.codex/config.toml (user-level — `notify` is ignored in project configs):\n\n  \(line)")
        return
    }

    do {
        try ensureCLISymlink()
    } catch {
        fail("Could not install the bilakh command: \(error.localizedDescription)")
    }

    let fm = FileManager.default
    let url = homeDirectory().appendingPathComponent(".codex/config.toml")
    var contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

    if let existing = contents.range(of: #"(?m)^\s*notify\s*=.*$"#, options: .regularExpression) {
        // Upgrade an older bilakh notify in place; never clobber someone else's.
        if isBilakhPingCommand(String(contents[existing])) {
            if contents[existing] != Substring(line) {
                contents.replaceSubrange(existing, with: line)
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url.appendingPathExtension("bak"))
                    try? fm.copyItem(at: url, to: url.appendingPathExtension("bak"))
                }
                do {
                    try contents.write(to: url, atomically: true, encoding: .utf8)
                    print("✓ Updated notify hook in Codex config at \(url.path)")
                } catch {
                    fail("Could not write Codex config: \(error.localizedDescription)")
                }
            } else {
                print("✓ Codex config already routes notify through Bilakh.")
            }
            return
        }
        print("""
        ⚠️  ~/.codex/config.toml already defines `notify` — leaving it untouched.
        To route Codex through Bilakh, set it to:
            \(line)
        """)
        return
    }

    do {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            try? fm.copyItem(at: url, to: url.appendingPathExtension("bak"))
        }
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += line + "\n"
        try contents.write(to: url, atomically: true, encoding: .utf8)
        print("✓ Added notify hook to Codex config at \(url.path)")
    } catch {
        fail("Could not write Codex config: \(error.localizedDescription)")
    }
}

func installGeminiHook() {
    // Gemini CLI's hook schema is still stabilizing, so we print rather than write.
    print("""
    Gemini CLI hooks live in ~/.gemini/settings.json. Add a hook on a completion or
    notification event that runs:

        bilakh ping

    See https://geminicli.com/docs/hooks/ for the current schema, then point the hook
    command at `bilakh ping`.
    """)
}

// MARK: - dispatch

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "ping":
    // Ignore any trailing args — Codex appends a JSON payload to the notify program.
    sendPing()
case "install-cli":
    installCLI()
case "install-hook":
    guard args.count >= 2 else {
        fail("Usage: bilakh install-hook <claude|codex|gemini> [--print]")
    }
    let printOnly = args.contains("--print")
    switch args[1] {
    case "claude": installClaudeHook(printOnly: printOnly)
    case "codex": installCodexHook(printOnly: printOnly)
    case "gemini": installGeminiHook()
    default: fail("Unknown tool '\(args[1])'. Use claude, codex, or gemini.")
    }
case "--help", "-h", "help", nil:
    printUsage()
case .some(let command):
    fail("Unknown command '\(command)'. Run `bilakh --help`.")
}
