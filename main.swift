// agent-notify: runs inside a generated source bundle (one per sender, own icon).
//   send:  agent-notify --title T [--subtitle S] [--body B] [--sound NAME|default|none]
//                       [--image PATH] [--id KEY] [--focus auto|none|TARGET]
//   other: --authorize (asks for permission, waits for the answer) | --jump TARGET
//   none:  launched by macOS after a click on one of our notifications.
// TARGET: iterm:<session-uuid> | url:<url> | app:<bundle-id>[:<folder>]
// Exit codes: 0 ok, 1 usage, 2 not authorized, 3 delivery failed.

import AppKit
import UserNotifications

let center = UNUserNotificationCenter.current()

func finish(_ code: Int32, _ message: String? = nil) -> Never {
    if let message { FileHandle.standardError.write(Data("agent-notify: \(message)\n".utf8)) }
    exit(code)
}

func parse(_ args: [String]) -> [String: String] {
    let valued: Set = ["--title", "--subtitle", "--body", "--sound", "--image", "--id", "--focus", "--jump"]
    var opts: [String: String] = [:]
    var it = args.makeIterator()
    while let key = it.next() {
        if key == "--authorize" { opts[key] = "1"; continue }
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

let opts = parse(args)
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
