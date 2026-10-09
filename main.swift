// agent-notify: runs inside a generated source bundle (one per sender, own icon).
//   send:  agent-notify --title T [--subtitle S] [--body B] [--sound NAME|default|none]
//                       [--image PATH] [--id KEY] [--focus auto|none|TARGET]
//   hook:  agent-notify --hook PAYLOAD  (empty PAYLOAD: read it from stdin)
//          Codex notify, Claude Code, Gemini CLI and agy hook payloads become a notification.
//   other: --authorize (asks for permission, waits for the answer) | --jump TARGET
//          --dry-run (print title | body | sound | id instead of sending)
//   none:  launched by macOS after a click on one of our notifications.
// TARGET: iterm:<session-uuid> | url:<url> | app:<bundle-id>[:<folder>]
// Exit codes: 0 ok, 1 usage, 2 not authorized, 3 delivery failed; always 0 in hook mode.

import AppKit
import SQLite3
import UserNotifications

let center = UNUserNotificationCenter.current()
// Claude Code and Gemini treat a hook's exit code 2 as "block", so hooks must never fail.
var hookMode = false

func finish(_ code: Int32, _ message: String? = nil) -> Never {
    if let message { FileHandle.standardError.write(Data("agent-notify: \(message)\n".utf8)) }
    exit(hookMode ? 0 : code)
}

func parse(_ args: [String]) -> [String: String] {
    let valued: Set = ["--title", "--subtitle", "--body", "--sound", "--image", "--id", "--focus", "--jump", "--hook"]
    var opts: [String: String] = [:]
    var it = args.makeIterator()
    while let key = it.next() {
        if key == "--authorize" || key == "--dry-run" { opts[key] = "1"; continue }
        guard valued.contains(key) else { finish(1, "unknown option \(key)") }
        guard let value = it.next() else { finish(1, "\(key) needs a value") }
        opts[key] = value
    }
    return opts
}

// TERM_PROGRAM first: an editor started from iTerm2 inherits a stale ITERM_SESSION_ID.
func autoFocus() -> String {
    let env = ProcessInfo.processInfo.environment
    switch env["TERM_PROGRAM"] {
    case "iTerm.app":
        if let uuid = env["ITERM_SESSION_ID"]?.split(separator: ":").last { return "iterm:\(uuid)" }
    case "vscode":
        if let app = env["__CFBundleIdentifier"] { return "app:\(app):\(FileManager.default.currentDirectoryPath)" }
    default:
        if let app = env["__CFBundleIdentifier"] { return "app:\(app)" }
    }
    return "none"
}

func activate(_ bundleID: String, folder: String? = nil, done: @escaping () -> Void) {
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return done() }
    let config = NSWorkspace.OpenConfiguration()
    if let folder, FileManager.default.fileExists(atPath: folder) {
        // VS Code-like editors focus the window that already has this folder open.
        NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: appURL, configuration: config) { _, _ in done() }
    } else {
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in done() }
    }
}

func jump(_ target: String, done: @escaping () -> Void) {
    let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return done() }
    switch parts[0] {
    case "iterm":
        // The UUID is embedded in the script, so only canonical UUIDs pass.
        guard parts[1].range(of: "^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$", options: .regularExpression) != nil else {
            return activate("com.googlecode.iterm2", done: done)
        }
        let script = """
        tell application id "com.googlecode.iterm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if unique ID of s is "\(parts[1])" then
                            select w
                            select t
                            select s
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
            activate
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error { FileHandle.standardError.write(Data("agent-notify: iTerm2 \(error)\n".utf8)) }
        done()
    case "url":
        if let url = URL(string: parts[1]), url.scheme != nil { NSWorkspace.shared.open(url) }
        done()
    case "app":
        let app = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
        activate(app[0], folder: app.count > 1 ? app[1] : nil, done: done)
    default:
        done()
    }
}

func content(_ opts: [String: String]) -> UNNotificationContent {
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
            FileHandle.standardError.write(Data("agent-notify: image skipped: \(error.localizedDescription)\n".utf8))
        }
    }
    let focus = opts["--focus"] ?? "auto"
    c.userInfo = ["focus": focus == "auto" ? autoFocus() : focus]
    return c
}

// Codex runs notify for subagent turns too; only its own state DB tells them apart.
// ponytail: hardcoded state_5 schema name, the filter silently stops when Codex bumps it.
func isCodexSubagent(_ threadID: String) -> Bool {
    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    guard !threadID.isEmpty,
          sqlite3_open_v2(NSHomeDirectory() + "/.codex/state_5.sqlite", &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return false }
    sqlite3_busy_timeout(db, 1000)
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "select thread_source from threads where id = ?", -1, &stmt, nil) == SQLITE_OK else { return false }
    sqlite3_bind_text(stmt, 1, threadID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    guard sqlite3_step(stmt) == SQLITE_ROW, let source = sqlite3_column_text(stmt, 0) else { return false }
    return String(cString: source) == "subagent"
}

// Final agent answer -> (status, body): a "Status: X" line or a JSON verdict, plus the remaining text.
func summarize(_ text: String) -> (String, String) {
    if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] {
        let pick = { (keys: [String]) in keys.lazy.compactMap { json[$0] as? String }.first { !$0.isEmpty } ?? "" }
        return (pick(["Status", "status", "verdict", "result"]), pick(["summary_de", "summary", "message"]))
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
    let source = Bundle.main.bundleIdentifier?.components(separatedBy: ".").last ?? "agent"
    let event = [str("hook_event_name"), str("type"), p["toolCall"] != nil ? "PreToolUse" : ""].first { !$0.isEmpty } ?? ""

    if event == "agent-turn-complete", isCodexSubagent(str("thread-id")) { return nil }
    if p["fullyIdle"] as? Bool == false || str("terminationReason") == "USER_CANCELED" { return nil }  // agy: background work still running or the user cancelled

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
            "--sound": sound, "--id": "\(source)-\(session)"]
}

final class ClickHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let focus = response.notification.request.content.userInfo["focus"] as? String ?? "none"
        jump(focus) { completionHandler(); exit(0) }
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
if let payload = opts["--hook"] {
    hookMode = true
    let raw = payload.isEmpty && isatty(0) == 0 ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : payload
    guard let hook = hookOptions(raw) else {
        if opts["--dry-run"] != nil { print("silent") }
        exit(0)
    }
    opts.merge(hook) { _, new in new }
}
if opts["--dry-run"] != nil {
    print(["--title", "--body", "--sound", "--id"].map { opts[$0] ?? "" }.joined(separator: " | "))
    exit(0)
}
if let target = opts["--jump"] {
    jump(target) { exit(0) }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 10))
    exit(0)
}
if opts["--authorize"] != nil {
    // The permission prompt vanishes when the process exits, so wait for the answer.
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in finish(granted ? 0 : 2) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 300) { finish(2, "no answer to the permission prompt") }
    dispatchMain()
}
guard let title = opts["--title"], !title.isEmpty else { finish(1, "--title is required") }
let request = UNNotificationRequest(identifier: opts["--id"] ?? UUID().uuidString, content: content(opts), trigger: nil)
center.getNotificationSettings { settings in
    guard [.authorized, .provisional].contains(settings.authorizationStatus) else {
        finish(2, "notifications not allowed for \(Bundle.main.bundleIdentifier ?? "?"); run: agent-notify authorize <source>")
    }
    center.add(request) { error in finish(error == nil ? 0 : 3, error?.localizedDescription) }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { finish(3, "timeout") }
dispatchMain()
