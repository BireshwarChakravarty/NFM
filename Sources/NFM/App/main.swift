import AppKit

// CI: check the loudness meter against calibrated test tones, then quit.
if ProcessInfo.processInfo.environment["NFM_SELFTEST_METER"] != nil {
    var report = LoudnessMeter.calibrationReport()
    report.merge(EnhancerDSP.calibrationReport()) { $1 }
    // Tap filter: never NFM itself, only WebKit helpers NFM is responsible for.
    let me: pid_t = 100
    let filterCases: [(pid_t, pid_t, String?, Bool)] = [
        (100, 100, nil, false),                      // NFM itself
        (100, 100, "app.nfm.mac", false),            // NFM itself, with bundle ID
        (200, 100, "com.apple.WebKit.GPU", true),    // our WebKit GPU process
        (201, 100, "com.apple.WebKit.WebContent", true),
        (300, 999, "com.apple.WebKit.GPU", false),   // Safari's WebKit
        (400, 100, "com.example.other", false),      // something else we spawned
        (202, 100, nil, true),                       // our helper, bundle ID unreadable
    ]
    let filterOK = filterCases.allSatisfy { test in
        AudioHelpers.shouldTap(pid: test.0, me: me, responsible: test.1, bundleID: test.2) == test.3
    }
    report["tap_filter_ok"] = filterOK ? 1 : 0
    let data = (try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])) ?? Data()
    print("NFM_METER " + String(decoding: data, as: UTF8.self))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
