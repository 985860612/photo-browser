import AppKit
import Darwin
import Foundation

func fail(_ message: String, code: Int32 = 70) -> Never {
    fputs(message + "\n", stderr)
    exit(code)
}
var arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print("Usage: swift quit-app.swift [--check-only] APP_PATH [TIMEOUT_SECONDS]")
    exit(0)
}
let checkOnly = arguments.first == "--check-only"
if checkOnly { arguments.removeFirst() }
guard (1...2).contains(arguments.count) else { fail("Expected an application path and optional timeout.", code: 64) }
let timeout = arguments.count == 2 ? Double(arguments[1]) : 45
guard let timeout, timeout.isFinite, timeout > 0, timeout <= 300 else { fail("Timeout must be between 0 and 300 seconds.", code: 64) }
let target = URL(fileURLWithPath: arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
guard target.pathExtension == "app", let bundle = Bundle(url: target),
      let identifier = bundle.bundleIdentifier, let executable = bundle.executableURL,
      FileManager.default.isExecutableFile(atPath: executable.path) else {
    fail("Expected an existing executable app bundle: \(target.path)", code: 64)
}
func hasExited(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter {
    $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == target
}
if apps.isEmpty { print("No running application at: \(target.path)") }
for app in apps {
    let pid = app.processIdentifier
    if checkOnly { print("Running PID \(pid): \(target.path)"); continue }
    if hasExited(pid) { continue }
    guard app.terminate() else { fail("Application refused normal termination; no files were replaced.") }
    let deadline = Date().addingTimeInterval(timeout)
    while !hasExited(pid) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    guard hasExited(pid) else { fail("PID \(pid) is still running; stop deployment without force termination.") }
    print("Closed PID \(pid): \(target.path)")
}
