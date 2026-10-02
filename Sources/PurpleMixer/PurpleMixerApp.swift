import SwiftUI
import AppKit

@main
struct BlankMixerApp: App {
    // Микшер живёт в AppDelegate в ЕДИНСТВЕННОМ экземпляре.
    // БАГ был здесь: `@StateObject mixer` + обращение к нему в init() App
    // создавало ВТОРОЙ AppAudioMixer (SwiftUI предупреждает: "Accessing
    // StateObject's object without being installed on a View"). Два микшера =
    // два таймера = два набора тапов на одно приложение → дабл-звук/эхо.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MixerView()
                .environmentObject(appDelegate.mixer)
        } label: {
            Image(systemName: "slider.horizontal.below.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Гарантирует, что при штатном завершении (Cmd+Q, «Выйти», logout, SIGTERM
/// из Xcode) все приватные агрегатные устройства будут уничтожены.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let mixer = AppAudioMixer()
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Раньше внутри signal() запускался Task — в обработчике сигнала это
        // небезопасно и часто просто не успевало выполниться. DispatchSource
        // доставляет сигнал на обычную очередь, где можно спокойно чистить.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.mixer.stopAllTaps()
                exit(0)
            }
        }
        source.resume()
        sigtermSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        mixer.stopAllTaps()
    }
}
