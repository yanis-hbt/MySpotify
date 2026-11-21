import Foundation
import CoreAudio
import AudioToolbox
import Accelerate
import QuartzCore

/// Capture le son de Spotify via un « process tap » Core Audio (macOS 14.2+)
/// et le transforme en bandes de fréquences pour l'onde autour du disque.
/// Si Spotify n'émet pas encore de son, on écoute tout le système en attendant.
final class AudioCapture {
    static let bandCount = 48

    // Partagé avec l'UI
    private let lock = NSLock()
    private var sharedBands = [Float](repeating: 0, count: AudioCapture.bandCount)
    private var sharedLevel: Float = 0
    private var everReceivedSignal = false
    private var sharedLastBeat = Date.distantPast

    struct Snapshot {
        var bands: [Float]
        var level: Float
        var hasSignal: Bool
        var lastBeat: Date

        /// 1 au moment d'un kick, retombe à 0 en ~0,3 s.
        func pulse(at date: Date) -> Double {
            let t = date.timeIntervalSince(lastBeat)
            return t < 0 ? 0 : exp(-t * 7)
        }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(bands: sharedBands, level: sharedLevel, hasSignal: everReceivedSignal, lastBeat: sharedLastBeat)
    }

    // Détection des kicks
    private var bassAverage: Float = 0
    private var lastBeatTime: CFTimeInterval = 0

    // Core Audio
    private let controlQueue = DispatchQueue(label: "myspotify.audio.control")
    private let ioQueue = DispatchQueue(label: "myspotify.audio.io", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tappedProcesses: [AudioObjectID] = []
    private var started = false

    // Analyse
    private let fftSize = 2048
    private let hop = 1024
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private var ring: [Float]
    private var writeIndex = 0
    private var sinceLast = 0
    private var hann: [Float]
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var smooth = [Float](repeating: 0, count: AudioCapture.bandCount)
    private var bandRanges: [Range<Int>] = []

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        ring = [Float](repeating: 0, count: fftSize)
        frame = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        mags = [Float](repeating: 0, count: fftSize / 2)
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: fftSize, isHalfWindow: false)
        configureBands(sampleRate: 48_000)
    }

    // MARK: - Cycle de vie

    func start() {
        controlQueue.async {
            guard !self.started else { return }
            self.started = true
            self.rebuild()
            self.installListeners()
        }
    }

    func stop() {
        controlQueue.sync { self.teardown() }
    }

    /// Re-cible le tap si les processus audio de Spotify ont changé (lancement, relance…).
    func retarget() {
        controlQueue.async {
            guard self.started else { return }
            let procs = Self.spotifyProcesses()
            if procs != self.tappedProcesses || self.aggregateID == kAudioObjectUnknown {
                self.rebuild()
            }
        }
    }

    private func installListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var outAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(system, &outAddr, controlQueue) { [weak self] _, _ in
            self?.rebuild() // casque/AirPods branchés → on reconstruit sur la nouvelle sortie
        }
        var procAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(system, &procAddr, controlQueue) { [weak self] _, _ in
            self?.retarget()
        }
    }

    private func rebuild() {
        teardown()

        let procs = Self.spotifyProcesses()
        let desc = procs.isEmpty
            ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            : CATapDescription(stereoMixdownOfProcesses: procs)
        desc.uuid = UUID()
        desc.name = "MySpotify Visualizer"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { log("Création du tap impossible (\(err))"); return }
        tapID = tap
        tappedProcesses = procs

        guard let outputUID = Self.defaultOutputUID() else { log("Pas de sortie audio"); teardown(); return }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MySpotify Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else { log("Création du périphérique agrégé impossible (\(err))"); teardown(); return }
        aggregateID = agg

        var fmt = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(tap, &fmtAddr, 0, nil, &size, &fmt) == noErr, fmt.mSampleRate > 0 {
            let sr = fmt.mSampleRate
            ioQueue.sync { self.configureBands(sampleRate: sr) }
        }

        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, ioQueue) { [weak self] _, input, _, _, _ in
            self?.process(input)
        }
        guard err == noErr, let proc else { log("IOProc impossible (\(err))"); teardown(); return }
        ioProcID = proc

        err = AudioDeviceStart(agg, proc)
        if err != noErr { log("Démarrage audio impossible (\(err))"); teardown(); return }
        log(procs.isEmpty ? "Écoute du son système (Spotify silencieux pour l'instant)" : "Écoute de Spotify")
    }

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let p = ioProcID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcesses = []
    }

    private func log(_ s: String) { NSLog("[MySpotify] %@", s) }

    // MARK: - Helpers Core Audio

    static func spotifyProcesses() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter { (bundleID(of: $0) ?? "").hasPrefix(SpotifyMonitor.bundleID) }.sorted()
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        stringProperty(process, kAudioProcessPropertyBundleID)
    }

    private static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr else { return nil }
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard err == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: - Analyse (sur ioQueue)

    private func configureBands(sampleRate: Double) {
        let n = Self.bandCount
        let binHz = sampleRate / Double(fftSize)
        let fMin = 45.0, fMax = 15_000.0
        bandRanges = (0..<n).map { b in
            let lo = fMin * pow(fMax / fMin, Double(b) / Double(n))
            let hi = fMin * pow(fMax / fMin, Double(b + 1) / Double(n))
            let l = max(1, Int(lo / binHz))
            let h = min(fftSize / 2, max(l + 1, Int(hi / binHz)))
            return l..<h
        }
    }

    private func process(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard abl.count > 0 else { return }
        if abl.count == 1 {
            let buf = abl[0]
            let ch = Int(max(buf.mNumberChannels, 1))
            guard let data = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
            let inv = 1 / Float(ch)
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += data[f * ch + c] }
                push(s * inv)
            }
        } else {
            let channels = abl.compactMap { $0.mData?.assumingMemoryBound(to: Float.self) }
            guard !channels.isEmpty else { return }
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            let inv = 1 / Float(channels.count)
            for f in 0..<frames {
                var s: Float = 0
                for c in channels { s += c[f] }
                push(s * inv)
            }
        }
    }

    @inline(__always) private func push(_ sample: Float) {
        ring[writeIndex] = sample
        writeIndex = (writeIndex + 1) % fftSize
        sinceLast += 1
        if sinceLast >= hop {
            sinceLast = 0
            analyze()
        }
    }

    private func analyze() {
        let n = fftSize
        for i in 0..<n { frame[i] = ring[(writeIndex + i) % n] * hann[i] }

        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(n))

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                split.imagp[0] = 0 // Nyquist rangé dans imag[0]
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        let count = Self.bandCount
        var bass: Float = 0
        for b in 0..<count {
            var peak: Float = 0
            for k in bandRanges[b] { peak = max(peak, mags[k]) }
            let amp = sqrt(peak) / Float(n)
            var db = 20 * log10(amp + 1e-9)
            db += Float(b) / Float(count) * 12 // les aigus ont naturellement moins d'énergie
            let v = min(max((db + 64) / 52, 0), 1)
            if b < 6 { bass += v / 6 }
            let s = smooth[b]
            smooth[b] = v > s ? s + (v - s) * 0.6 : s + (v - s) * 0.14 // attaque rapide, retombée douce
        }

        let now = CACurrentMediaTime()
        let beat = bass - bassAverage > 0.09 && bass > 0.42 && now - lastBeatTime > 0.27
        if beat { lastBeatTime = now }
        bassAverage = bassAverage * 0.92 + bass * 0.08

        lock.lock()
        if beat { sharedLastBeat = Date() }
        sharedBands = smooth
        sharedLevel = sharedLevel * 0.7 + min(rms * 5, 1) * 0.3
        if rms > 1e-4 { everReceivedSignal = true }
        lock.unlock()
    }
}
