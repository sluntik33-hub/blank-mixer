import Foundation
import AppKit
import Combine
import CoreAudio
import OSLog

private let mixerLog = Logger(subsystem: "com.yourname.blank3", category: "AppAudioMixer")

@MainActor
final class AppAudioMixer: ObservableObject {
    /// ОДИН список в СТАБИЛЬНОМ порядке: приложение получает место при первом
    /// появлении и больше не прыгает. Раньше порядок брался из Dictionary
    /// (случайный при каждом обновлении) + строки перескакивали между
    /// секциями «играют/молчат» — поэтому Opera бегала с первой строки на
    /// последнюю каждые пару секунд.
    @Published private(set) var apps: [AudioAppItem] = []

    @Published var systemVolume: Double = SystemVolumeController.read() {
        didSet {
            guard !isApplyingExternalVolume, oldValue != systemVolume else { return }
            SystemVolumeController.write(systemVolume)
        }
    }
    @Published var permissionDenied: Bool = false

    private var taps: [String: AppAudioTap] = [:]
    private var itemsByKey: [String: AudioAppItem] = [:]
    private var order: [String] = []
    /// Сторож: последний увиденный heartbeat тапа и число неудачных попыток.
    private var lastHeartbeat: [String: UInt64] = [:]
    private var failures: [String: Int] = [:]
    private var lastHealthCheck: [String: Date] = [:]
    private var refreshTimer: Timer?
    private var isApplyingExternalVolume = false

    init() {
        AudioProcessDiscovery.destroyOrphanedAggregateDevices()
        refresh()

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common) // тикает и пока открыто меню
        refreshTimer = timer

        SystemVolumeController.start(
            onVolumeChange: { [weak self] value in
                guard let self else { return }
                self.isApplyingExternalVolume = true
                self.systemVolume = value
                self.isApplyingExternalVolume = false
            },
            onDeviceChange: { [weak self] in
                // Сменилось устройство вывода — агрегаты построены на старом,
                // их надо пересобрать, иначе звук «уходит» в старые колонки.
                guard let self else { return }
                self.stopAllTaps()
                self.failures.removeAll()
                for item in self.apps where item.tapUnavailable { item.tapUnavailable = false }
                self.refresh()
            }
        )
    }

    func refresh() {
        let candidates = RunningAppsProvider.currentCandidates()
        let candidateKeys = Set(candidates.map(\.groupKey))

        for key in Array(taps.keys) where !candidateKeys.contains(key) {
            taps.removeValue(forKey: key)?.stop()
        }
        for key in Array(itemsByKey.keys) where !candidateKeys.contains(key) {
            itemsByKey.removeValue(forKey: key)
        }
        order.removeAll { !candidateKeys.contains($0) }

        // Новые приложения — в конец, по алфавиту между собой (детерминированно).
        let newOnes = candidates
            .filter { itemsByKey[$0.groupKey] == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        for candidate in newOnes {
            let item = AudioAppItem(
                groupKey: candidate.groupKey,
                pids: candidate.pids,
                bundleID: candidate.bundleID,
                name: candidate.name,
                icon: candidate.icon
            )
            let key = candidate.groupKey
            item.onChange = { [weak self] in self?.syncTap(forKey: key) }
            itemsByKey[key] = item
            order.append(key)
        }

        for candidate in candidates {
            guard let item = itemsByKey[candidate.groupKey] else { continue }
            if item.pids != candidate.pids { item.pids = candidate.pids }
            let playing = AudioProcessDiscovery.isCurrentlyPlaying(pids: candidate.pids)
            if item.isPlayingAudio != playing { item.isPlayingAudio = playing }
            checkHealth(forKey: candidate.groupKey)
            syncTap(forKey: candidate.groupKey)
        }

        let newApps = order.compactMap { itemsByKey[$0] }
        if newApps.map(\.id) != apps.map(\.id) { apps = newApps }
    }

    /// Приводит тап приложения в соответствие с его громкостью/мьютом.
    /// Тап держим ТОЛЬКО пока громкость < 100% или включён мьют: на 100%
    /// оригинальный звук идёт напрямую и дублироваться просто нечему.
    private func syncTap(forKey key: String) {
        guard let item = itemsByKey[key] else { return }

        guard item.needsProcessing else {
            taps.removeValue(forKey: key)?.stop()
            failures[key] = 0
            if item.tapUnavailable { item.tapUnavailable = false }
            return
        }
        // Регулировка для этого приложения не заработала несколько раз
        // подряд — лучше оставить оригинальный звук, чем тишину.
        guard !item.tapUnavailable else {
            taps.removeValue(forKey: key)?.stop()
            return
        }

        if let tap = taps[key] {
            // Состав процессов изменился (новая вкладка браузера = новый
            // хелпер). Старый тап его не захватывает — этот процесс играл бы
            // мимо регулятора на полной громкости. Пересоздаём.
            let expectedDevice = CoreAudioUtils.outputDeviceUID(forPIDs: item.pids)
                ?? CoreAudioUtils.defaultOutputDeviceUID()
                ?? tap.outputDeviceUID
            if tap.pids == item.pids && tap.outputDeviceUID == expectedDevice {
                tap.setGain(item.gain)
                return
            }
            taps.removeValue(forKey: key)?.stop()
        }

        let tap = AppAudioTap(pids: item.pids)
        do {
            try tap.start(initialGain: item.gain)
            taps[key] = tap
            lastHeartbeat[key] = nil
            if permissionDenied { permissionDenied = false }
        } catch {
            mixerLog.error("tap for \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            if case AppAudioTap.TapError.creationFailed = error { permissionDenied = true }
            registerFailure(forKey: key)
        }
    }

    /// Если IO-колбэк тапа перестал вызываться (сменился профиль AirPods при
    /// звонке, устройство пересоздалось, звонилка перезапустила аудио), то
    /// оригинал заглушён, а копия не играет → тишина. Пересобираем тап.
    private func checkHealth(forKey key: String) {
        guard let tap = taps[key] else { return }
        // Судим только раз в ~секунду: IO вызывается каждые ~10 мс, но два
        // refresh() подряд (открытие окна + таймер) могут прийти почти разом.
        let now = Date()
        if let last = lastHealthCheck[key], now.timeIntervalSince(last) < 1.0 { return }
        lastHealthCheck[key] = now
        let beat = tap.heartbeatValue
        defer { lastHeartbeat[key] = beat }
        guard let previous = lastHeartbeat[key] else { return }
        if beat == previous {
            mixerLog.error("tap for \(key, privacy: .public) stalled — rebuilding")
            taps.removeValue(forKey: key)?.stop()
            lastHeartbeat[key] = nil
            registerFailure(forKey: key)
        } else {
            failures[key] = 0
        }
    }

    private func registerFailure(forKey key: String) {
        let count = (failures[key] ?? 0) + 1
        failures[key] = count
        if count >= 3, let item = itemsByKey[key] {
            item.tapUnavailable = true
            taps.removeValue(forKey: key)?.stop()
        }
    }

    func stopAllTaps() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }

    func muteAll(_ muted: Bool) {
        for item in apps { item.setMuted(muted) }
    }

    func resetAll() {
        for item in apps {
            item.setMuted(false)
            item.volume = 1.0
        }
    }
}

/// Читает/пишет громкость устройства вывода по умолчанию и следит за её
/// изменениями извне (клавиши, Control Center, смена наушников).
@MainActor
enum SystemVolumeController {
    private static var volumeListener: AudioObjectPropertyListenerBlock?
    private static var deviceListener: AudioObjectPropertyListenerBlock?
    private static var observedDevice: AudioObjectID?
    private static var observedElement: UInt32 = kAudioObjectPropertyElementMain

    private static func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }

    /// Многие наушники не имеют мастер-регулятора (element 0), только
    /// каналы 1/2 — откатываемся на них.
    private static func resolvedElement(for device: AudioObjectID) -> UInt32? {
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1] {
            var addr = volumeAddress(element)
            if AudioObjectHasProperty(device, &addr) { return element }
        }
        return nil
    }

    static func read() -> Double {
        guard let device = CoreAudioUtils.defaultOutputDevice(),
              let element = resolvedElement(for: device) else { return 1.0 }
        var address = volumeAddress(element)
        var value: Float32 = 1.0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? Double(max(0, min(1, value))) : 1.0
    }

    static func write(_ value: Double) {
        guard let device = CoreAudioUtils.defaultOutputDevice(),
              let element = resolvedElement(for: device) else { return }
        var scalar = Float32(max(0, min(1, value)))
        let size = UInt32(MemoryLayout<Float32>.size)
        let elements: [UInt32] = element == kAudioObjectPropertyElementMain ? [element] : [1, 2]
        for el in elements {
            var address = volumeAddress(el)
            guard AudioObjectHasProperty(device, &address) else { continue }
            AudioObjectSetPropertyData(device, &address, 0, nil, size, &scalar)
        }
    }

    /// Регистрирует слушатели ОДИН раз. Раньше при каждой смене устройства
    /// добавлялся ещё один слушатель смены устройства (они копились).
    static func start(onVolumeChange: @escaping @MainActor (Double) -> Void,
                      onDeviceChange: @escaping @MainActor () -> Void) {
        attachVolumeListener(onVolumeChange)

        guard deviceListener == nil else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated {
                detachVolumeListener()
                attachVolumeListener(onVolumeChange)
                onVolumeChange(read())
                onDeviceChange()
            }
        }
        deviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private static func attachVolumeListener(_ onChange: @escaping @MainActor (Double) -> Void) {
        guard let device = CoreAudioUtils.defaultOutputDevice(),
              let element = resolvedElement(for: device) else { return }
        var address = volumeAddress(element)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange(read()) }
        }
        observedDevice = device
        observedElement = element
        volumeListener = block
        AudioObjectAddPropertyListenerBlock(device, &address, DispatchQueue.main, block)
    }

    private static func detachVolumeListener() {
        guard let device = observedDevice, let block = volumeListener else { return }
        var address = volumeAddress(observedElement)
        AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        volumeListener = nil
        observedDevice = nil
    }
}
