import Foundation
import AppKit
import CoreAudio
import Darwin

/// Одно приложение в микшере. Может отвечать сразу за НЕСКОЛЬКО реальных
/// процессов (главный процесс + скрытые дочерние хелперы со звуком).
@MainActor
final class AudioAppItem: ObservableObject, Identifiable {
    /// Стабильный ключ группы: путь к .app бандлу / бинарнику / "pid:N".
    let id: String
    /// Меняется со временем (браузер открыл новую вкладку = новый хелпер).
    @Published var pids: Set<pid_t> {
        didSet { if oldValue != pids { tapUnavailable = false } }
    }
    let bundleID: String?
    let name: String
    let icon: NSImage

    /// 0...1 — положение слайдера
    @Published var volume: Double = 1.0 {
        didSet {
            guard oldValue != volume else { return }
            // Потянули ползунок вверх у заглушённого приложения — снимаем mute.
            if isMuted && volume > 0.001 { isMuted = false }
            onChange?()
        }
    }
    /// Громкость до нажатия mute — чтобы вернуть её при повторном нажатии.
    private var volumeBeforeMute: Double = 1.0

    /// Mute: ползунок уезжает в 0. Повторно — возвращается на прежнее место.
    func toggleMute() { setMuted(!isMuted) }

    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        if muted {
            volumeBeforeMute = volume > 0.001 ? volume : 1.0
            isMuted = true
            volume = 0
        } else {
            isMuted = false
            volume = volumeBeforeMute
        }
    }
    @Published var isMuted: Bool = false {
        didSet { if oldValue != isMuted { onChange?() } }
    }
    @Published var isPlayingAudio: Bool = false
    /// Регулировка не заработала для этого приложения — звук оставлен как есть.
    @Published var tapUnavailable: Bool = false

    var onChange: (() -> Void)?

    /// Громкость → усиление. Слух логарифмичен, поэтому линейный gain
    /// ощущается так, будто «ничего не происходит» до ~30%. Квадратичная
    /// кривая даёт ровное ощущение по всей длине слайдера.
    var gain: Double { isMuted ? 0 : volume * volume }
    var needsProcessing: Bool { isMuted || volume < 0.995 }

    init(groupKey: String, pids: Set<pid_t>, bundleID: String?, name: String, icon: NSImage) {
        self.id = groupKey
        self.pids = pids
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
    }
}

/// Находит процессы для показа в микшере и группирует их по "родительскому"
/// приложению.
///
/// ИСТОРИЯ ФИКСОВ (по порядку):
/// 1. NSWorkspace-список "обычных" приложений упускал скрытые дочерние
///    процессы-рендереры браузеров, где реально идёт звук.
/// 2. Переключились на прямой опрос Core Audio
///    (`kAudioHardwarePropertyProcessObjectList`) — поймали реальные
///    аудио-процессы, но (а) поймали и себя же, (б) каждый хелпер — отдельная
///    строка в интерфейсе.
/// 3. Пробовали группировать по дереву родительских процессов (ppid) — не
///    сработало: macOS часто "переродительствует" дочерние/XPC-процессы на
///    launchd (pid 1) вскоре после запуска, обрывая цепочку.
/// 4. СЕЙЧАС: группируем по ПУТИ к исполняемому файлу. У любого хелпера путь
///    физически лежит ВНУТРИ бандла родительского приложения
///    ("/Applications/Opera GX.app/Contents/Frameworks/....Helper.app/...") —
///    это не ломается никогда, независимо от того, кто сейчас родитель.
enum RunningAppsProvider {
    struct Candidate {
        let groupKey: String
        let pids: Set<pid_t>
        let bundleID: String?
        let name: String
        let icon: NSImage
    }

    @MainActor
    static func currentCandidates() -> [Candidate] {
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // Только ОТКРЫТЫЕ приложения (те, что видны в Dock).
        var appsByPID: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            appsByPID[app.processIdentifier] = app
        }

        struct GroupInfo {
            var pids: Set<pid_t> = []
            let app: NSRunningApplication
        }
        var groups: [String: GroupInfo] = [:]

        for pid in AudioProcessDiscovery.audioCapableProcessPIDs() where pid != selfPID {
            // Звук часто играет не само приложение, а его служебный процесс
            // (com.apple.WebKit.GPU у Safari/Telegram/Claude, хелперы
            // Chrome/Opera). macOS знает, какое приложение «отвечает» за
            // такой процесс — привязываем звук к нему, а не показываем
            // отдельной строкой.
            let owner = responsiblePID(for: pid)
            guard let app = appsByPID[owner] ?? appsByPID[pid],
                  app.processIdentifier != selfPID else { continue }
            let key = app.bundleURL?.path ?? "pid:\(app.processIdentifier)"
            groups[key, default: GroupInfo(app: app)].pids.insert(pid)
        }

        // DAW (FL Studio, Ableton, Logic и т.п.) работают с аудиоустройством
        // напрямую — их не трогаем вообще и не показываем.
        let proAudio = ["com.image-line", "com.ableton", "com.apple.logic", "com.bitwig",
                        "com.presonus", "com.cockos.reaper", "com.steinberg", "com.avid",
                        "com.apple.garageband", "com.apple.mainstage", "com.native-instruments",
                        // плееры с эксклюзивным (hog mode) доступом к устройству
                        "com.audirvana", "com.roon", "com.colibri"]

        return groups.compactMap { key, info in
            let id = info.app.bundleIdentifier?.lowercased() ?? ""
            if proAudio.contains(where: { id.hasPrefix($0) }) || key.lowercased().contains("fl studio") {
                return nil
            }
            return Candidate(
                groupKey: key,
                pids: info.pids,
                bundleID: info.app.bundleIdentifier,
                name: info.app.localizedName ?? (key as NSString).lastPathComponent,
                icon: info.app.icon ?? fallbackIcon()
            )
        }
    }

    /// pid «ответственного» приложения для служебного процесса.
    /// Функция есть в libSystem, но не в публичных заголовках — берём через dlsym.
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private nonisolated(unsafe) static let responsibleFn: ResponsibleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = responsibleFn else { return pid }
        let r = fn(pid)
        return r > 0 ? r : pid
    }

    private static func groupKey(forExecutablePath path: String?, pid: pid_t) -> String {
        guard let path else { return "pid:\(pid)" }
        if let appPath = topLevelAppPath(from: path) { return appPath }
        return path
    }

    /// Первое вхождение ".app/" в пути — это и есть путь до "внешнего"
    /// бандла приложения, даже если дальше идут вложенные Framework/Helper.app.
    private static func topLevelAppPath(from path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    private static func fallbackIcon() -> NSImage {
        NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage()
    }

    /// Имя процесса через libproc — работает для ЛЮБОГО pid, не только для
    /// зарегистрированных .app приложений.
    private static func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return string(from: buffer, length: length)
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return string(from: buffer, length: length)
    }

    private static func string(from buffer: [CChar], length: Int32) -> String? {
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Отсекаем откровенно системные процессы (демоны звукового стека,
    /// системный сервер окон и т.п.), которые технически всегда есть в
    /// списке Core Audio, но не имеют смысла как "приложение" для микшера.
    private static func isNoisySystemProcess(pid: pid_t) -> Bool {
        guard let path = executablePath(for: pid) else { return false }
        let noisyPrefixes = [
            "/System/Library/",
            "/usr/libexec/",
            "/usr/sbin/",
        ]
        return noisyPrefixes.contains { path.hasPrefix($0) }
    }
}

/// Спрашивает у Core Audio список реальных аудио-процессов системы, и умеет
/// дёшево (без создания тапа/агрегатного устройства) проверить, действительно
/// ли процесс ПРЯМО СЕЙЧАС выводит звук.
enum AudioProcessDiscovery {
    static func audioCapableProcessPIDs() -> [pid_t] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &objectIDs
        ) == noErr else {
            return []
        }

        var pids = Set<pid_t>()
        for objectID in objectIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let status = AudioObjectGetPropertyData(objectID, &pidAddress, 0, nil, &pidSize, &pid)
            guard status == noErr, pid > 0 else { continue }
            pids.insert(pid)
        }
        return Array(pids)
    }

    /// ВАЖНО ДЛЯ СОВМЕСТИМОСТИ С ДРУГИМИ ПРИЛОЖЕНИЯМИ (например, FL Studio):
    /// раньше мы создавали настоящий tap + агрегатное устройство для КАЖДОГО
    /// аудио-процесса в системе просто чтобы узнать, играет он звук или нет.
    /// Это означало десятки одновременно открытых приватных агрегатных
    /// устройств почти всегда, даже когда реально играло только одно
    /// приложение — что и создавало конфликты с другими программами,
    /// претендующими на прямой/эксклюзивный доступ к аудио-устройству.
    /// Теперь мы сначала дёшево спрашиваем у Core Audio (без создания
    /// какого-либо устройства), реально ли процесс СЕЙЧАС выводит звук, и
    /// создаём tap только для таких процессов.
    static func isCurrentlyPlaying(pids: Set<pid_t>) -> Bool {
        for pid in pids {
            guard let objectID = CoreAudioUtils.processObjectID(for: pid) else { continue }

            var address = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectHasProperty(objectID, &address) else { continue }

            var isRunning: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
            if status == noErr, isRunning != 0 { return true }
        }
        return false
    }

    /// Находит и уничтожает "осиротевшие" агрегатные устройства от прошлых
    /// аварийно завершённых запусков нашего приложения (например, если
    /// процесс был убит через Force Quit / из Xcode до того как успел
    /// вызвать stop()). Без этого такие устройства продолжают висеть в
    /// системе и мешать другим приложениям (в первую очередь — Bluetooth
    /// устройствам вроде AirPods, которые куда чувствительнее к количеству
    /// одновременных агрегатных конструкций, чем встроенные динамики).
    static func destroyOrphanedAggregateDevices() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return }

        for deviceID in deviceIDs {
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameRef: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &nameRef) { ptr -> OSStatus in
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, ptr)
            }
            guard status == noErr, let nameRef else { continue }
            let name = nameRef.takeRetainedValue() as String
            if name.hasPrefix("PurpleMixer-") || name.hasPrefix("BLANK3.0-") {
                _ = AudioHardwareDestroyAggregateDevice(deviceID)
            }
        }
    }
}
