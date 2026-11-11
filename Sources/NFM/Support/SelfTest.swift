import AppKit
import WebKit

/// `NFM_SELFTEST=1 NFM.app/Contents/MacOS/NFM` loads Netflix, checks that the
/// page bridge is injected, which identity Netflix sees, and whether FairPlay
/// is available to the web view — then prints one JSON line and quits.
/// Used by CI; handy for diagnosing "it won't play" reports too.
enum SelfTest {
    static let isEnabled = ProcessInfo.processInfo.environment["NFM_SELFTEST"] != nil
    private static var started = false

    static func armTimeout(seconds: Double = 60) {
        guard isEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            finish("{\"error\":\"timeout waiting for the Netflix page\"}", code: 2)
        }
    }

    static func pageReady(in webView: WKWebView) {
        guard isEnabled, !started else { return }
        started = true
        // Let Netflix's own scripts settle (redirects, app context) first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { run(in: webView) }
    }

    private static func run(in webView: WKWebView) {
        let script = """
        const out = {
          url: location.href,
          title: document.title,
          userAgent: navigator.userAgent,
          bridge: typeof window.__nfm,
          fullscreenPolyfill: document.fullscreenEnabled === true,
          eme: typeof navigator.requestMediaKeySystemAccess,
          legacyFairPlay: (typeof WebKitMediaKeys !== 'undefined' && WebKitMediaKeys.isTypeSupported)
            ? WebKitMediaKeys.isTypeSupported('com.apple.fps.1_0', 'video/mp4') : 'n/a',
        };
        try {
          await navigator.requestMediaKeySystemAccess('com.apple.fps', [{
            initDataTypes: ['sinf', 'skd'],
            videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.640028"' }],
          }]);
          out.fairPlay = 'supported';
        } catch (e) {
          out.fairPlay = 'unavailable: ' + e.name;
        }
        try { out.bridgeState = window.__nfm.run('state') === true; } catch (e) { out.bridgeState = String(e); }
        try { out.audioInfo = window.__nfm.run('audioInfo'); } catch (e) { out.audioInfo = String(e); }
        try {
          window.__nfm.configure({ subtitleScale: 0.8 });
          const html = document.documentElement;
          out.subtitles = { on: html.classList.contains('nfm-subs'),
                            scale: getComputedStyle(html).getPropertyValue('--nfm-sub-scale').trim() };
          window.__nfm.configure({ subtitleScale: 1 });
          out.subtitles.offAgain = !html.classList.contains('nfm-subs');
        } catch (e) { out.subtitles = String(e); }
        // TV mode: switch it on, move the highlight, and check the ring is drawn.
        try {
          const on = window.__nfm.run('setTV', true);
          await new Promise((r) => setTimeout(r, 600));
          const moved = window.__nfm.run('tvMove', 'down');
          await new Promise((r) => setTimeout(r, 400));
          const ring = document.getElementById('nfm-tv-ring');
          out.tvMode = { on, moved, ring: !!ring, ringVisible: !!ring && getComputedStyle(ring).opacity !== '0' };
          window.__nfm.run('setTV', false);
        } catch (e) { out.tvMode = String(e); }
        return JSON.stringify(out);
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                finish((value as? String) ?? "{\"error\":\"no result\"}", code: 0)
            case .failure(let error):
                finish("{\"error\":\(PlayerBridge.json(String(describing: error)))}", code: 3)
            }
        }
    }

    private static func finish(_ json: String, code: Int32) {
        print("NFM_SELFTEST \(json)")
        fflush(stdout)
        exit(code)
    }
}
