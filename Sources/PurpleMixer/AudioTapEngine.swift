import Foundation
import CoreAudio
import OSLog
import Synchronization

/// Захватывает звук приложения (группы процессов) через Core Audio Process Tap
/// и выводит его, уже с применённой громкостью, прямо в реальное устройство
/// вывода — внутри ОДНОГО IO-колбэка агрегатного устройства.
///
/// Почему так (и что было не так раньше):
/// - Раньше звук шёл цепочкой tap → RingBuffer → отдельный AVAudioEngine →
///   системный вывод. Это два независимых аудио-клока, лишняя задержка и
///   второй поток звука. Если оригинал не глушился мгновенно — слышно
///   «эхо/дабл», а при изменении громкости менялась только копия.
/// - Кроме того, при подключённой гарнитуре во входных буферах агрегата
///   первым идёт МИКРОФОН, а не тап — код брал `abl[0]` и регулировал не то.
/// Теперь: вход тапа → gain → выходные буферы того же агрегата. Одна копия
/// звука, без AVAudioEngine и без кольцевого буфера.
///
/// Требования: macOS 15+.
final class AppAudioTap: @unchecked Sendable {
    private let log = Logger(subsystem: "com.yourname.blank3", category: "AudioTap")

    let pids: Set<pid_t>
    /// UID устройства вывода, на котором построен агрегат. Если системный
    /// вывод сменился (наушники) — тап нужно пересоздать.
    private(set) var outputDeviceUID: String = ""

    private var primaryPID: pid_t { pids.min() ?? 0 }
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    /// Целевой коэффициент усиления (bit pattern Double). Пишется с главного
    /// потока, читается на realtime-потоке — атомарно и без локов.
    private let targetGainBits = Atomic<UInt64>(Double(1).bitPattern)
    /// Текущий (сглаженный) gain — трогается ТОЛЬКО из IO-потока.
    private var currentGain: Float = 1

    init(pids: Set<pid_t>) {
        self.pids = pids
    }

    /// 0...1, уже с учётом mute и кривой громкости.
    func setGain(_ gain: Double) {
        targetGainBits.store(max(0, min(1, gain)).bitPattern, ordering: .relaxed)
    }

    func start(initialGain: Double) throws {
        setGain(initialGain)
        currentGain = Float(max(0, min(1, initialGain)))

        let processObjectIDs = pids.sorted().compactMap { CoreAudioUtils.processObjectID(for: $0) }
        guard !processObjectIDs.isEmpty else { throw TapError.processObjectNotFound }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.uuid = UUID()
        description.name = "BLANK3.0 tap \(primaryPID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr else { throw TapError.creationFailed(tapStatus) }
        tapID = newTapID

        do {
            guard let outputUID = CoreAudioUtils.defaultOutputDeviceUID() else {
                throw TapError.outputDeviceNotFound
            }
            outputDeviceUID = outputUID

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "BLANK3.0-\(primaryPID)",
                kAudioAggregateDeviceUIDKey: "com.yourname.blank3.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: description.uuid.uuidString
                    ]
                ]
            ]

            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
            guard aggStatus == noErr else { throw TapError.aggregateFailed(aggStatus) }
            aggregateDeviceID = newAggregateID

            try installIOProc()
            log.notice("Tap started for pids \(self.pids.sorted()) on \(outputUID, privacy: .public)")
        } catch {
            stop()
            throw error
        }
    }

    private func installIOProc() throws {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) {
            [unowned self] _, inputData, _, outputData, _ in
            self.render(input: inputData, output: outputData)
        }
        guard status == noErr, let procID else { throw TapError.ioProcFailed(status) }
        ioProcID = procID

        // ФИКС КОНФЛИКТА С AIRPODS / FL STUDIO:
        // агрегат содержит устройство вывода как sub-device. Если у него есть
        // МИКРОФОН (AirPods, гарнитуры), то без этой настройки наш IOProc
        // открывал и микрофон тоже. У AirPods открытие микрофона = переход в
        // режим гарнитуры (HFP): частота падает до 16/24 кГц, устройство
        // пересоздаётся — и FL Studio теряет своё аудиоустройство
        // («Could not enable the CoreAudio device», транспорт стоит).
        // Включаем для нашего IOProc ТОЛЬКО входные потоки тапа.
        disableSubDeviceInputs(procID: procID)

        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else { throw TapError.deviceStartFailed(startStatus) }
    }

    private func disableSubDeviceInputs(procID: AudioDeviceIOProcID) {
        guard let outputDevice = CoreAudioUtils.defaultOutputDevice() else { return }
        let micStreams = CoreAudioUtils.streamCount(of: outputDevice, scope: kAudioObjectPropertyScopeInput)
        guard micStreams > 0 else { return } // у устройства нет микрофона — всё ок

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateDeviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        memset(raw, 0, Int(size))
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateDeviceID, &addr, 0, nil, &size, raw) == noErr else { return }

        let countOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams) ?? 8
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn) ?? 12
        let n = Int(raw.load(fromByteOffset: countOffset, as: UInt32.self))
        for i in 0..<n {
            // Сначала идут входы sub-device (микрофон), потом — потоки тапа.
            let on: UInt32 = i >= micStreams ? 1 : 0
            raw.storeBytes(of: on, toByteOffset: flagsOffset + i * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        let st = AudioObjectSetPropertyData(aggregateDeviceID, &addr, 0, nil, size, raw)
        log.notice("IOProcStreamUsage: mic streams off=\(micStreams) total=\(n) status=\(st)")
    }

    /// Realtime-поток: никаких аллокаций, локов и логов.
    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outABL = UnsafeMutableAudioBufferListPointer(output)

        // Сначала обнуляем выход — если входа нет, будет тишина, а не мусор.
        for buffer in outABL {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard inABL.count > 0, outABL.count > 0 else { return }

        // Потоки тапа в агрегате идут ПОСЛЕ входных потоков sub-device
        // (например, микрофона гарнитуры) — поэтому берём последние буферы.
        let lastIn = inABL[inABL.count - 1]
        let leftPtr: UnsafeMutablePointer<Float>
        let rightPtr: UnsafeMutablePointer<Float>
        let inStride: Int
        let inFrames: Int
        let rightOffset: Int

        if lastIn.mNumberChannels >= 2 {
            guard let d = lastIn.mData?.assumingMemoryBound(to: Float.self) else { return }
            inStride = Int(lastIn.mNumberChannels)
            inFrames = Int(lastIn.mDataByteSize) / (MemoryLayout<Float>.size * inStride)
            leftPtr = d; rightPtr = d; rightOffset = 1
        } else if inABL.count >= 2 {
            let lBuf = inABL[inABL.count - 2]
            guard let l = lBuf.mData?.assumingMemoryBound(to: Float.self),
                  let r = lastIn.mData?.assumingMemoryBound(to: Float.self) else { return }
            inStride = 1
            inFrames = min(Int(lBuf.mDataByteSize), Int(lastIn.mDataByteSize)) / MemoryLayout<Float>.size
            leftPtr = l; rightPtr = r; rightOffset = 0
        } else {
            guard let d = lastIn.mData?.assumingMemoryBound(to: Float.self) else { return }
            inStride = 1
            inFrames = Int(lastIn.mDataByteSize) / MemoryLayout<Float>.size
            leftPtr = d; rightPtr = d; rightOffset = 0
        }
        guard inFrames > 0 else { return }

        // Плавно ведём gain к цели, чтобы не было щелчков при движении слайдера.
        let target = Float(Double(bitPattern: targetGainBits.load(ordering: .relaxed)))
        let start = currentGain
        let step = (target - start) / Float(inFrames)

        var channelBase = 0
        for buffer in outABL {
            guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let chs = max(1, Int(buffer.mNumberChannels))
            let outFrames = min(inFrames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * chs))
            for frame in 0..<outFrames {
                let g = start + step * Float(frame)
                let l = leftPtr[frame * inStride] * g
                let r = rightPtr[frame * inStride + rightOffset] * g
                for c in 0..<chs {
                    out[frame * chs + c] = ((channelBase + c) % 2 == 0) ? l : r
                }
            }
            channelBase += chs
        }
        currentGain = target
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    deinit { stop() }

    enum TapError: Error {
        case processObjectNotFound
        case outputDeviceNotFound
        case creationFailed(OSStatus)
        case aggregateFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case deviceStartFailed(OSStatus)
    }
}

/// Мелкие обёртки над Core Audio, общие для всех файлов.
enum CoreAudioUtils {
    static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &objectID
        )
        return (status == noErr && objectID != kAudioObjectUnknown) ? objectID : nil
    }

    /// Устройство вывода по умолчанию (то, куда играет музыка). Важно: НЕ
    /// DefaultSystemOutputDevice — то устройство для системных алертов.
    static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return (status == noErr && device != kAudioObjectUnknown) ? device : nil
    }

    static func streamCount(of device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func defaultOutputDeviceUID() -> String? {
        guard let device = defaultOutputDevice() else { return nil }
        return stringProperty(kAudioDevicePropertyDeviceUID, of: device)
    }

    static func stringProperty(_ selector: AudioObjectPropertySelector, of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }
}
