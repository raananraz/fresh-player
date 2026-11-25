import Cocoa
import WebKit
import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import MediaPlayer

/// Per-app playback. Routes only this process's audio by setting
/// kAudioOutputUnitProperty_CurrentDevice on our output unit. Never writes
/// kAudioHardwarePropertyDefaultOutputDevice (the Mac-wide default).
final class FMPEngine {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    let tapMixer = AVAudioMixerNode()

    private var file: AVAudioFile?
    private var demoBuffer: AVAudioPCMBuffer?
    private var format: AVAudioFormat?
    private var fileLength: AVAudioFramePosition = 0
    private var sampleRate: Double = 44100
    private var startFrame: AVAudioFramePosition = 0
    private var schedGen = 0
    private var tapInstalled = false
    private var wantPlaying = false
    private var demoMode = false
    private var lastAnalyserPush: CFTimeInterval = 0
    private var silentTicks = 0
    private var lastEnergy: Float = 0

    var volume: Float = 0.8 {
        didSet { engine.mainMixerNode.outputVolume = max(0, min(1, volume)) }
    }
    var duration: TimeInterval = 0
    var isPlaying: Bool { wantPlaying && (player.isPlaying || engine.isRunning && wantPlaying) }
    var isDemo: Bool { demoMode }

    var onEnded: (() -> Void)?
    var onAnalyser: ((_ freq: Data, _ time: Data, _ energy: Int, _ t: Double, _ d: Double, _ playing: Bool) -> Void)?
    var onLog: ((String) -> Void)?

    let analyser = AnalyserTap()

    var currentTime: TimeInterval {
        if demoMode { return 0 }
        guard sampleRate > 0 else { return 0 }
        if let nodeTime = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nodeTime) {
            let t = Double(startFrame) / sampleRate + Double(pt.sampleTime) / pt.sampleRate
            return max(0, min(duration, t))
        }
        return max(0, min(duration, Double(startFrame) / sampleRate))
    }

    init() {
        engine.attach(player)
        engine.attach(tapMixer)
        engine.connect(player, to: tapMixer, format: nil)
        engine.connect(tapMixer, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = volume
        NotificationCenter.default.addObserver(self, selector: #selector(engineConfigChanged), name: .AVAudioEngineConfigurationChange, object: engine)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func engineConfigChanged(_ n: Notification) {
        onLog?("engine config change")
        DispatchQueue.main.async { [weak self] in self?.recover(why: "config-change") }
    }

    func prepare() {
        applyOutputDevice()
        engine.prepare()
    }

    @discardableResult
    func ensureRunning() -> Bool {
        if engine.isRunning { return true }
        applyOutputDevice()
        do {
            engine.prepare()
            try engine.start()
            installTapIfNeeded()
            onLog?("engine started out=\(outputDescription())")
            return true
        } catch {
            onLog?("engine start failed: \(error)")
            return false
        }
    }

    func loadFile(url: URL, play: Bool, at time: TimeInterval = 0) {
        stopPlayback(ended: false)
        demoMode = false
        demoBuffer = nil
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            format = f.processingFormat
            sampleRate = f.processingFormat.sampleRate
            fileLength = f.length
            duration = sampleRate > 0 ? Double(f.length) / sampleRate : 0
            reconnect(format: f.processingFormat)
            let start = time > 0 ? min(time, max(0, duration - 0.05)) : 0
            scheduleFile(from: start, play: play)
            onLog?("engine load \(url.lastPathComponent) dur=\(String(format: "%.1f", duration)) play=\(play)")
        } catch {
            onLog?("engine load failed: \(error)")
            file = nil
            duration = 0
        }
    }

    func startDemo() {
        stopPlayback(ended: false)
        demoMode = true
        file = nil
        duration = 0
        let sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        sampleRate = sr > 0 ? sr : 44100
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) ?? AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        format = fmt
        demoBuffer = FMPEngine.makeDemoBuffer(format: fmt)
        reconnect(format: fmt)
        guard ensureRunning(), let buf = demoBuffer else { return }
        wantPlaying = true
        schedGen += 1
        player.stop()
        player.scheduleBuffer(buf, at: nil, options: [.loops], completionHandler: nil)
        player.play()
        onLog?("engine demo started")
    }

    func play() {
        if demoMode {
            if !player.isPlaying { startDemo() }
            return
        }
        guard file != nil else { return }
        if player.isPlaying { wantPlaying = true; return }
        let t = currentTime
        if duration > 0 && t >= duration - 0.05 {
            scheduleFile(from: 0, play: true)
        } else {
            scheduleFile(from: t, play: true)
        }
    }

    func pause() {
        wantPlaying = false
        if player.isPlaying {
            let t = currentTime
            player.pause()
            startFrame = AVAudioFramePosition(t * sampleRate)
        }
    }

    func stop() {
        stopPlayback(ended: false)
        file = nil
        demoBuffer = nil
        demoMode = false
        duration = 0
        startFrame = 0
    }

    func seek(to time: TimeInterval) {
        if demoMode { return }
        guard file != nil, duration > 0 else { return }
        let t = max(0, min(duration, time))
        scheduleFile(from: t, play: wantPlaying)
    }

    func seekBy(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    func recover(why: String) {
        onLog?("engine recover \(why) running=\(engine.isRunning) want=\(wantPlaying)")
        let t = currentTime
        let play = wantPlaying
        let demo = demoMode
        let url = file?.url
        if engine.isRunning { engine.stop() }
        applyOutputDevice()
        if demo {
            startDemo()
        } else if let url = url {
            loadFile(url: url, play: play, at: t)
        } else {
            _ = ensureRunning()
        }
    }

    /// Pin this app's output unit to a device, or to the current system default
    /// when `preferredUID` is empty. Does not change the system default.
    func applyOutputDevice() {
        let pref = AudioOutputs.preferredUID
        let devices = AudioOutputs.list()
        let id: AudioDeviceID
        if !pref.isEmpty, let dev = devices.first(where: { $0.uid == pref }) {
            id = dev.id
        } else {
            id = AudioOutputs.defaultDeviceID()
        }
        guard id != 0, let au = engine.outputNode.audioUnit else { return }
        var dev = id
        let err = AudioUnitSetProperty(au,
                                       kAudioOutputUnitProperty_CurrentDevice,
                                       kAudioUnitScope_Global,
                                       0,
                                       &dev,
                                       UInt32(MemoryLayout<AudioDeviceID>.size))
        if err != noErr { onLog?("engine set CurrentDevice err=\(err)") }
    }

    func outputDescription() -> String {
        let pref = AudioOutputs.preferredUID
        if !pref.isEmpty, let dev = AudioOutputs.list().first(where: { $0.uid == pref }) {
            return dev.name
        }
        if let dev = AudioOutputs.list().first(where: { $0.isDefault }) {
            return "system default (\(dev.name))"
        }
        return "system default"
    }

    /// If playing but the engine died or the tap is silent, restart.
    func watchdog() {
        guard wantPlaying else { silentTicks = 0; return }
        if !engine.isRunning || (!player.isPlaying && !demoMode) {
            recover(why: "watch-not-running")
            silentTicks = 0
            return
        }
        if lastEnergy < 0.5 { silentTicks += 1 } else { silentTicks = 0 }
        if silentTicks >= 3 {
            silentTicks = 0
            recover(why: "watch-silent")
        }
    }

    private func reconnect(format: AVAudioFormat) {
        if tapInstalled {
            tapMixer.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(tapMixer)
        engine.connect(player, to: tapMixer, format: format)
        engine.connect(tapMixer, to: engine.mainMixerNode, format: format)
        installTapIfNeeded()
    }

    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        let bufSize: AVAudioFrameCount = 2048
        tapMixer.installTap(onBus: 0, bufferSize: bufSize, format: nil) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }
        tapInstalled = true
    }

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        analyser.ingest(buffer)
        lastEnergy = analyser.energy
        let now = CACurrentMediaTime()
        guard now - lastAnalyserPush >= 1.0 / 45.0 else { return }
        lastAnalyserPush = now
        let (freq, time) = analyser.bytes()
        let energy = Int(min(255, lastEnergy.rounded()))
        let t = currentTime
        let d = duration
        let playing = wantPlaying
        DispatchQueue.main.async { [weak self] in
            self?.onAnalyser?(freq, time, energy, t, d, playing)
        }
    }

    private func scheduleFile(from time: TimeInterval, play: Bool) {
        guard let file = file else { return }
        guard ensureRunning() else { return }
        schedGen += 1
        let gen = schedGen
        player.stop()
        let start = AVAudioFramePosition(max(0, time) * sampleRate)
        startFrame = min(start, fileLength)
        wantPlaying = play
        if startFrame >= fileLength {
            if play { DispatchQueue.main.async { [weak self] in self?.finishSegment(gen: gen) } }
            return
        }
        let remaining = AVAudioFrameCount(fileLength - startFrame)
        file.framePosition = startFrame
        player.scheduleSegment(file, startingFrame: startFrame, frameCount: remaining, at: nil) { [weak self] in
            DispatchQueue.main.async { self?.finishSegment(gen: gen) }
        }
        if play { player.play() }
    }

    private func finishSegment(gen: Int) {
        guard gen == schedGen, wantPlaying, !demoMode else { return }
        wantPlaying = false
        onEnded?()
    }

    private func stopPlayback(ended: Bool) {
        let gen = schedGen
        schedGen += 1
        wantPlaying = false
        if player.isPlaying || player.engine != nil { player.stop() }
        startFrame = 0
        if ended && gen == schedGen - 1 { onEnded?() }
    }

    static func makeDemoBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sr = format.sampleRate
        let frames = AVAudioFrameCount(sr * 2)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let chans = Int(format.channelCount)
        guard let chdata = buf.floatChannelData else { return nil }
        let freqs: [Float] = [110, 220, 277.18, 329.63, 440, 659.25, 880]
        for i in 0..<Int(frames) {
            let t = Float(i) / Float(sr)
            var s: Float = 0
            for (j, f) in freqs.enumerated() {
                let amp: Float = j == 0 ? 0.22 : 0.09 / (1 + Float(j) * 0.3)
                s += amp * sinf(2 * .pi * f * t)
            }
            // beat
            let env: Float = (t.truncatingRemainder(dividingBy: 0.5) < 0.08) ? 1 : 0
            s += 0.35 * env * sinf(2 * .pi * 55 * t)
            s = max(-1, min(1, s * 0.7))
            for c in 0..<chans { chdata[c][i] = s }
        }
        return buf
    }
}

/// Matches Web Audio AnalyserNode getByteFrequencyData / getByteTimeDomainData
/// (fftSize 2048, minDecibels -100, maxDecibels -30, smoothing 0.8).
final class AnalyserTap {
    let fftSize = 2048
    private var window: [Float]
    private var samples: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mag: [Float]
    private var prev: [Float]
    private var timeDomain: [Float]
    private let setup: FFTSetup
    private let log2n: vDSP_Length
    var energy: Float = 0

    init() {
        log2n = vDSP_Length(round(log2(Double(fftSize))))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        samples = [Float](repeating: 0, count: fftSize)
        real = [Float](repeating: 0, count: fftSize / 2)
        imag = [Float](repeating: 0, count: fftSize / 2)
        mag = [Float](repeating: 0, count: fftSize / 2)
        prev = [Float](repeating: 0, count: fftSize / 2)
        timeDomain = [Float](repeating: 0, count: fftSize)
        vDSP_blkman_window(&window, vDSP_Length(fftSize), 0)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        var count = 0
        var i = 0
        while i < n && count < fftSize {
            var s: Float = 0
            if chans <= 1 { s = ch[0][i] }
            else { s = 0.5 * (ch[0][i] + ch[1][i]) }
            samples[count] = s
            count += 1
            i += 1
        }
        if count < fftSize {
            for j in count..<fftSize { samples[j] = 0 }
        }
        timeDomain = samples
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        // Real-to-complex split
        real.withUnsafeMutableBufferPointer { rBuf in
            imag.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                windowed.withUnsafeMutableBufferPointer { wBuf in
                    wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                var halves = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&split, 1, &halves, 1, vDSP_Length(fftSize / 2))
                mag = halves
            }
        }
        // magnitude from packed real FFT: scale, then dB
        // zvmags after zrip is already squared magnitude; take sqrt
        var nOver2 = Float(fftSize / 2)
        vDSP_vsmul(mag, 1, [1 / nOver2], &mag, 1, vDSP_Length(fftSize / 2))
        var countBins = vDSP_Length(fftSize / 2)
        var tmp = mag
        vvsqrtf(&mag, &tmp, [Int32(fftSize / 2)])
        // smoothing on linear mag
        let s: Float = 0.8
        for i in 0..<mag.count { prev[i] = prev[i] * s + mag[i] * (1 - s) }
        var e: Float = 0
        vDSP_sve(prev, 1, &e, countBins)
        energy = min(255, e * 8)
        _ = countBins
    }

    func bytes() -> (Data, Data) {
        let minDb: Float = -100
        let maxDb: Float = -30
        var freq = [UInt8](repeating: 0, count: fftSize / 2)
        for i in 0..<prev.count {
            var db: Float = -160
            if prev[i] > 1e-12 { db = 20 * log10f(prev[i]) }
            var x = (db - minDb) / (maxDb - minDb)
            if x < 0 { x = 0 }
            if x > 1 { x = 1 }
            freq[i] = UInt8((x * 255).rounded())
        }
        var time = [UInt8](repeating: 128, count: fftSize)
        for i in 0..<timeDomain.count {
            var v = timeDomain[i] * 128 + 128
            if v < 0 { v = 0 }
            if v > 255 { v = 255 }
            time[i] = UInt8(v.rounded())
        }
        return (Data(freq), Data(time))
    }
}

final class FMPWebView: WKWebView {
    var onFileDrop: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if fileURLs(from: sender).isEmpty { return super.draggingEntered(sender) }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if fileURLs(from: sender).isEmpty { return super.draggingUpdated(sender) }
        return .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        if !urls.isEmpty {
            onFileDrop?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] ?? []
        return urls.filter { $0.isFileURL }
    }
}

enum NowPlaying {
    static func setup(play: @escaping () -> Void, pause: @escaping () -> Void,
                      toggle: @escaping () -> Void, next: @escaping () -> Void,
                      prev: @escaping () -> Void, skip: @escaping (TimeInterval) -> Void,
                      seek: @escaping (TimeInterval) -> Void) {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.isEnabled = true
        c.pauseCommand.isEnabled = true
        c.togglePlayPauseCommand.isEnabled = true
        c.nextTrackCommand.isEnabled = true
        c.previousTrackCommand.isEnabled = true
        c.skipForwardCommand.isEnabled = true
        c.skipBackwardCommand.isEnabled = true
        c.skipForwardCommand.preferredIntervals = [15]
        c.skipBackwardCommand.preferredIntervals = [15]
        c.changePlaybackPositionCommand.isEnabled = true
        c.playCommand.addTarget { _ in play(); return .success }
        c.pauseCommand.addTarget { _ in pause(); return .success }
        c.togglePlayPauseCommand.addTarget { _ in toggle(); return .success }
        c.nextTrackCommand.addTarget { _ in next(); return .success }
        c.previousTrackCommand.addTarget { _ in prev(); return .success }
        c.skipForwardCommand.addTarget { _ in skip(15); return .success }
        c.skipBackwardCommand.addTarget { _ in skip(-15); return .success }
        c.changePlaybackPositionCommand.addTarget { ev in
            if let e = ev as? MPChangePlaybackPositionCommandEvent { seek(e.positionTime) }
            return .success
        }
    }

    static func update(title: String, elapsed: TimeInterval, duration: TimeInterval, playing: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title.isEmpty ? "Fresh Music Player" : title,
            MPMediaItemPropertyArtist: "Fresh Music Player",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0
        ]
        if duration <= 0 { info[MPMediaItemPropertyPlaybackDuration] = 0 }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = playing ? .playing : .paused
    }
}
