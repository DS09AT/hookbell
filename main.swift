// hookbell: runs inside a generated source bundle (one per sender, own name and icon).
//   send:  hookbell --title T [--subtitle S] [--body B] [--sound NAME|default|none]
//                   [--image PATH] [--id KEY] [--focus auto|none|TARGETS] [--dry-run]
//   hook:  hookbell --hook PAYLOAD [--dry-run]   (empty PAYLOAD: read the JSON from stdin)
//          Codex notify, Claude Code, Gemini CLI and Antigravity (agy) hook payloads.
//   other: --authorize (asks for permission, waits for the answer) | --jump TARGETS
//   none:  launched by macOS after a click on one of our notifications.
// TARGETS: ";"-separated, tried in order until one focuses a window:
//   iterm:<session-uuid> | tty:<device> | tmux:<pane>:<socket>:<tmux-binary> | url:<url> | app:<bundle-id>[:<folder>]
// --dry-run prints "title | body | sound | id | targets" instead of sending.
// Exit codes: 0 ok, 1 usage, 2 not authorized, 3 delivery failed; always 0 in hook mode.

import AppKit
import SQLite3
import UserNotifications

let center = UNUserNotificationCenter.current()
// Claude Code and Gemini treat a hook's exit code 2 as "block", so hooks must never fail.
var hookMode = false

func warn(_ message: String) {
    FileHandle.standardError.write(Data("hookbell: \(message)\n".utf8))
}

func finish(_ code: Int32, _ message: String? = nil) -> Never {
    if let message { warn(message) }
    exit(hookMode ? 0 : code)
}

func parse(_ args: [String]) -> [String: String] {
    let flags: Set = ["--authorize", "--dry-run"]
    let valued: Set = ["--title", "--subtitle", "--body", "--sound", "--image", "--id", "--focus", "--jump", "--hook"]
    var opts: [String: String] = [:]
    var it = args.makeIterator()
    while let key = it.next() {
        if flags.contains(key) { opts[key] = "1"; continue }
        guard valued.contains(key) else { finish(1, "unknown option \(key)") }
        guard let value = it.next() else { finish(1, "\(key) needs a value") }
        opts[key] = value
    }
    return opts
}

// MARK: - Click targets

func controllingTTY() -> String? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, info.kp_eproc.e_tdev != -1,
          let name = devname(info.kp_eproc.e_tdev, S_IFCHR) else { return nil }
    return "/dev/" + String(cString: name)
}

func executable(_ name: String, in path: String?) -> String? {
    (path ?? "").split(separator: ":").map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
}

// The caller's terminal decides the target. TERM_PROGRAM comes first because an editor or tmux
// started from iTerm2 inherits a stale ITERM_SESSION_ID.
func autoFocus(dir: String) -> [String] {
    let env = ProcessInfo.processInfo.environment
    let app = env["__CFBundleIdentifier"] ?? ""
    var targets: [String] = []
    if let pane = env["TMUX_PANE"], let socket = env["TMUX"]?.split(separator: ",").first,
       let tmux = executable("tmux", in: env["PATH"]) {
        targets.append("tmux:\(pane):\(socket):\(tmux)")
    }
    switch env["TERM_PROGRAM"] {
    case "iTerm.app":
        if let uuid = env["ITERM_SESSION_ID"]?.split(separator: ":").last { targets.append("iterm:\(uuid)") }
    case "Apple_Terminal":
        if let tty = controllingTTY() { targets.append("tty:\(tty)") }
    case "vscode" where !app.isEmpty:
        // VS Code-like editors focus the window that already has this folder open.
        return targets + ["app:\(app):\(dir)"]
    default:
        break
    }
    return app.isEmpty ? targets : targets + ["app:\(app)"]
}

func runAppleScript(_ source: String) -> Bool {
    var error: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
    if let error { warn("AppleScript: \(error[NSAppleScript.errorMessage] ?? error)") }
    return result?.booleanValue ?? false
}

func isRunning(_ bundleID: String) -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
}

// Values are embedded in AppleScript source, so callers pass only validated UUIDs and tty paths.
func focusITerm(where property: String, is value: String) -> Bool {
    isRunning("com.googlecode.iterm2") && runAppleScript("""
    tell application id "com.googlecode.iterm2"
        repeat with w in windows
            repeat with t in tabs of w
                repeat with s in sessions of t
                    if \(property) of s is "\(value)" then
                        select w
                        select t
                        select s
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end repeat
        return false
    end tell
    """)
}

func focusTTY(_ tty: String) -> Bool {
    guard tty.range(of: "^/dev/ttys[0-9]+$", options: .regularExpression) != nil else { return false }
    return focusITerm(where: "tty", is: tty) || isRunning("com.apple.Terminal") && runAppleScript("""
    tell application id "com.apple.Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return true
                end if
            end repeat
        end repeat
        return false
    end tell
    """)
}

func run(_ binary: String, _ args: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = args
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: output, as: UTF8.self)
}

// Selects the pane, moves an attached client there and focuses that client's terminal tab.
func focusTmux(_ spec: String) -> Bool {
    let parts = spec.split(separator: ":", maxSplits: 2).map(String.init)
    guard parts.count == 3, parts[0].range(of: "^%[0-9]+$", options: .regularExpression) != nil,
          FileManager.default.isExecutableFile(atPath: parts[2]) else { return false }
    let (pane, socket, tmux) = (parts[0], parts[1], parts[2])
    let select = ["select-window", "-t", pane, ";", "select-pane", "-t", pane]
    guard let client = run(tmux, ["-S", socket, "list-clients", "-F", "#{client_tty}"]).split(separator: "\n").first else {
        _ = run(tmux, ["-S", socket] + select)
        return false
    }
    _ = run(tmux, ["-S", socket, "switch-client", "-c", String(client), "-t", pane, ";"] + select)
    return focusTTY(String(client))
}

func activate(_ bundleID: String, folder: String?) -> Bool {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return false }
    let done = DispatchSemaphore(value: 0)
    let config = NSWorkspace.OpenConfiguration()
    if let folder, FileManager.default.fileExists(atPath: folder) {
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: appURL, configuration: config) { _, _ in done.signal() }
    } else {
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in done.signal() }
    }
    return done.wait(timeout: .now() + 5) == .success
}

func jump(_ target: String) -> Bool {
    let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return false }
    switch parts[0] {
    case "iterm":
        let uuid = "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$"
        return parts[1].range(of: uuid, options: .regularExpression) != nil && focusITerm(where: "unique ID", is: parts[1])
    case "tty":
        return focusTTY(parts[1])
    case "tmux":
        return focusTmux(parts[1])
    case "url":
        guard let url = URL(string: parts[1]), url.scheme != nil else { return false }
        return NSWorkspace.shared.open(url)
    case "app":
        let app = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
        return activate(app[0], folder: app.count > 1 ? app[1] : nil)
    default:
        return false
    }
}

func jump(all targets: [String]) {
    _ = targets.first { jump($0) }
}

// MARK: - Hook payloads

// Codex runs notify for subagent turns too; only its newest state DB tells them apart.
func isCodexSubagent(_ threadID: String) -> Bool {
    let home = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
    let version = { (name: String) in Int(name.dropFirst(6).dropLast(7)) ?? -1 }
    guard !threadID.isEmpty,
          let state = (try? FileManager.default.contentsOfDirectory(atPath: home))?
            .filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }).max(by: { version($0) < version($1) }) else { return false }
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard sqlite3_open_v2("\(home)/\(state)", &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
    sqlite3_busy_timeout(db, 1000)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "select thread_source from threads where id = ?", -1, &stmt, nil) == SQLITE_OK else { return false }
    sqlite3_bind_text(stmt, 1, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW, let source = sqlite3_column_text(stmt, 0) else { return false }
    return String(cString: source) == "subagent"
}

// Final agent answer -> (status, body): a "Status: X" line or a JSON status/verdict, plus the remaining text.
func summarize(_ text: String) -> (String, String) {
    if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
        let status = ["Status", "status", "verdict", "result"].lazy.compactMap { json[$0] as? String }.first ?? ""
        let summary = json.keys.sorted().filter { $0.hasPrefix("summary") || $0 == "message" }.lazy.compactMap { json[$0] as? String }.first
        return (status, summary ?? "")
    }
    var status = ""
    var lines: [String] = []
    for line in text.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if status.isEmpty, let r = t.range(of: #"^\**Status\**\s*:\s*"#, options: [.regularExpression, .caseInsensitive]) {
            status = t[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "*` "))
        } else if !t.isEmpty, !t.hasPrefix("```") {
            lines.append(t)
        }
    }
    return (status, lines.joined(separator: "\n"))
}

// Maps a hook payload to send options; nil means the event is deliberately silent.
func hookOptions(_ raw: String) -> [String: String]? {
    guard let p = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else { return nil }
    let str = { (key: String) in p[key] as? String ?? "" }
    let source = Bundle.main.bundleIdentifier?.components(separatedBy: ".").last ?? "hookbell"
    let event = [str("hook_event_name"), str("type"), p["toolCall"] != nil ? "PreToolUse" : ""].first { !$0.isEmpty } ?? ""

    if event == "agent-turn-complete", isCodexSubagent(str("thread-id")) { return nil }
    // Antigravity: background work is still running, or the user cancelled.
    if p["fullyIdle"] as? Bool == false || str("terminationReason") == "USER_CANCELED" { return nil }

    let dir = [str("cwd"), (p["workspacePaths"] as? [String])?.first ?? ""].first { !$0.isEmpty } ?? ""
    let repo = dir.isEmpty ? source : URL(fileURLWithPath: dir).lastPathComponent
    let session = [str("thread-id"), str("session_id"), str("conversationId")].first { !$0.isEmpty } ?? "unknown"

    var (status, body, sound) = ("Done", "", "Hero")
    switch event {
    case "PreToolUse", "BeforeTool":
        (status, body, sound) = ("Question", "Waiting for your answer", "Glass")
    case "Notification":
        (status, body, sound) = ("Input needed", str("message"), "Glass")
    default:
        if !str("error").isEmpty {
            (status, body, sound) = ("Error", str("error"), "Basso")
        } else {
            let answer = [str("last-assistant-message"), str("last_assistant_message"), str("prompt_response")].first { !$0.isEmpty } ?? ""
            let (found, rest) = summarize(answer)
            (status, body) = (found.isEmpty ? "Done" : found, rest)
        }
    }
    return ["--title": "\(repo) · \(status)", "--body": String((body.isEmpty ? "\(status)." : body).prefix(300)),
            "--sound": sound, "--id": "\(source)-\(session)", "dir": dir]
}

// MARK: - Notification

func content(_ opts: [String: String], focus: [String]) -> UNNotificationContent {
    let c = UNMutableNotificationContent()
    c.title = opts["--title"] ?? ""
    c.subtitle = opts["--subtitle"] ?? ""
    c.body = opts["--body"] ?? ""
    switch opts["--sound"] ?? "default" {
    case "none": break
    case let name where Bundle.main.url(forResource: name, withExtension: "aiff") != nil:
        c.sound = UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
    default: c.sound = .default
    }
    if let path = opts["--image"] {
        // The system moves attachment files into its store, so hand it a copy.
        let src = URL(fileURLWithPath: path)
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + src.pathExtension)
        do {
            try FileManager.default.copyItem(at: src, to: copy)
            c.attachments = [try UNNotificationAttachment(identifier: "image", url: copy)]
        } catch {
            warn("image skipped: \(error.localizedDescription)")
        }
    }
    c.userInfo = ["focus": focus]
    return c
}

final class ClickHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        jump(all: response.notification.request.content.userInfo["focus"] as? [String] ?? [])
        completionHandler()
        exit(0)
    }
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty {
    let handler = ClickHandler()
    center.delegate = handler
    NSApplication.shared.setActivationPolicy(.accessory)
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) { exit(0) }
    NSApplication.shared.run()
}

var opts = parse(args)
if let targets = opts["--jump"] {
    jump(all: targets.split(separator: ";").map(String.init))
    exit(0)
}
if opts["--authorize"] != nil {
    // The permission prompt vanishes when the process exits, so wait for the answer.
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in finish(granted ? 0 : 2) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish(2, "no answer to the permission prompt") }
    dispatchMain()
}
if let payload = opts["--hook"] {
    hookMode = true
    let raw = payload.isEmpty && isatty(0) == 0 ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : payload
    guard let hook = hookOptions(raw) else {
        if opts["--dry-run"] != nil { print("silent") }
        exit(0)
    }
    opts.merge(hook) { _, new in new }
}
guard let title = opts["--title"], !title.isEmpty else { finish(1, "--title is required") }
let focus: [String] = switch opts["--focus"] ?? "auto" {
case "auto": autoFocus(dir: opts["dir"].flatMap { $0.isEmpty ? nil : $0 } ?? FileManager.default.currentDirectoryPath)
case "none": []
case let list: list.split(separator: ";").map(String.init)
}
if opts["--dry-run"] != nil {
    print((["--title", "--body", "--sound", "--id"].map { opts[$0] ?? "" } + [focus.joined(separator: ";")]).joined(separator: " | "))
    exit(0)
}
let request = UNNotificationRequest(identifier: opts["--id"] ?? UUID().uuidString, content: content(opts, focus: focus), trigger: nil)
center.getNotificationSettings { settings in
    guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
        finish(2, "notifications not allowed for \(Bundle.main.bundleIdentifier ?? "?"); run: hookbell authorize <source>")
    }
    center.add(request) { error in finish(error == nil ? 0 : 3, error?.localizedDescription) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(3, "timeout") }
dispatchMain()
