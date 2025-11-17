import Foundation
import SwiftUI
import Observation
import AVFoundation
import Darwin
import AudioUnit
import CoreAudio
import AudioToolbox

@Observable
class EmulatorCore {

    // MARK: - Nested Types

    enum AudioLatency {
        case low       // ~50ms
        case medium    // ~100ms (default)
        case high      // ~200ms
    }

    // MARK: - Public Configuration

    var vsyncEnabledHint: Bool = true
    var desiredFPS: Int = 60

    var turboEnabled: Bool = false
    var audioLatencyLevel: AudioLatency = .medium

    // MARK: - Timing

    private var nextFrameTick: UInt64 = 0
    private var frameDurationTicks: UInt64 = 0
    private var timebaseInfo = mach_timebase_info_data_t(numer: 0, denom: 0)

    // MARK: - Public State

    var isRunning = false
    var screenImage: Image? = nil
    var frameSerial: UInt64 = 0

    // MARK: - Core Components

    private(set) var cartridge: Cartridge?
    private var bus: Bus?
    var cpu: CPU?
    var ppu: PPU?
    private var apu: APU?
    private var controller: Controller?
    private var mmc3Mapper: MMC3Mapper?

    // MARK: - Audio

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var eqNode: AVAudioUnitEQ?
    private var limiterNode: AVAudioUnit?
    private var audioSampleRate: Double = 44_100
    // Initial buffer, replaced on start() based on audioLatencyLevel
    private var audioRB = CircularFloatBuffer(capacity: 44_100 * 4)

    private let apuHz: Double = 1_789_773.0
    private var apuToAudioStep: Double = 1_789_773.0 / 44_100.0
    private var apuToAudioAccum: Double = 0.0
    private var lastAudioSample: Float = 0.0
    private var smoothedAudioSample: Float = 0.0
    private var maxSampleDelta: Float = 0.08

    // MARK: - DMA

    var dmaActive = false
    var dmaCyclesLeft = 0
    var dmaSourceAddr: UInt16 = 0
    var dmaByteIndex: Int = 0
    var dmaOamIndex: UInt8 = 0

    // MARK: - CPU Timing

    private var cpuCycleCounter = 0
    private var emulationThread: Thread?

    // MARK: - Emulation Queue

    private let emulationQueue = DispatchQueue(
        label: "com.nesforgood.emulation",
        qos: .userInitiated // HIGH PRIORITY
    )

    // MARK: - Init / Deinit

    init() {
        mach_timebase_info(&timebaseInfo)
        updateFrameDurationTicks()
        resetFrameSync()
    }

    deinit {
        cartridge?.saveBatteryRAM()
    }

    // MARK: - Helpers

    private func audioBufferSize() -> Int {
        switch audioLatencyLevel {
        case .low:
            return Int(audioSampleRate * 0.05)  // ~50ms
        case .medium:
            return Int(audioSampleRate * 0.10)  // ~100ms
        case .high:
            return Int(audioSampleRate * 0.20)  // ~200ms
        }
    }

    func unload() {
        cartridge?.saveBatteryRAM()
        cpu = nil
        ppu = nil
        apu = nil
        controller = nil
        bus = nil
        cartridge = nil
        dmaActive = false
        cpuCycleCounter = 0
        mmc3Mapper = nil
    }

    func setVSync(_ enabled: Bool) {
        self.vsyncEnabledHint = enabled
    }

    func setFrameLimit(_ fps: Int) {
        self.desiredFPS = max(0, fps)
        updateFrameDurationTicks()
    }

    func setTurboEnabled(_ enabled: Bool) {
        turboEnabled = enabled
        resetFrameSync()
    }

    func setAudioLatency(_ level: AudioLatency) {
        audioLatencyLevel = level
        // If running, we shrink/expand the ring buffer; audio continuity might glitch briefly,
        // but it avoids full engine restart or CPU reset.
        if isRunning {
            audioRB = CircularFloatBuffer(capacity: audioBufferSize())
            prefillAudioBuffer()
        }
    }

    // MARK: - ROM Management

    func loadROM(data: Data) throws {
        if isRunning { stop() }
        cartridge?.saveBatteryRAM()
        unload()

        let cart = try Cartridge(data: data)
        cartridge = cart
        // Use current core sample rate to tune APU filters
        apu = APU(sampleRate: Float(audioSampleRate))
        ppu = PPU(cartridge: cart)
        controller = Controller()
        let bus = Bus(cartridge: cart, ppu: ppu!, apu: apu!, controller: controller!, core: self)
        self.bus = bus
        apu?.bus = bus
        cpu = CPU(bus: bus)
        self.mmc3Mapper = cart.mapper as? MMC3Mapper
    }

    // MARK: - Start / Stop / Reset

    func start() {
        guard !isRunning, cartridge != nil else { return }
        isRunning = true

        let startWork = { [weak self] in
            guard let self = self else { return }
            self.resetFrameSync()
            self.configureAudioEngineIfNeeded()
            self.warmUpChipsForStableStart()
            self.launchEmulationLoop()
        }

        if Thread.isMainThread {
            DispatchQueue.global(qos: .userInitiated).async(execute: startWork)
        } else {
            startWork()
        }
    }

    private func configureAudioEngineIfNeeded() {
        let configureBlock = { [weak self] in
            self?.configureAudioEngineOnMainThread()
        }

        if Thread.isMainThread {
            configureBlock()
        } else {
            DispatchQueue.main.sync(execute: configureBlock)
        }
    }

    private func configureAudioEngineOnMainThread() {
        // Configure audio engine if not already running
        if engine == nil {
            let engine = AVAudioEngine()

            // Detect hardware output sample rate
            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            let detectedRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : audioSampleRate
            audioSampleRate = detectedRate
            updateAudioResampleStep()

            // Recreate audio ring buffer according to selected latency & detected rate
            audioRB = CircularFloatBuffer(capacity: audioBufferSize())
            prefillAudioBuffer()

            // Retune APU filters to match output sample rate
            apu?.setOutputSampleRate(Float(audioSampleRate))

            var lastSample: Float = 0.0 // Hold last sample to mask buffer underrun clicks

            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: audioSampleRate,
                channels: 1,
                interleaved: false
            )!

            let src = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
                guard let self = self else { return noErr }
                let frames = Int(frameCount)
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                if let buf = abl.first, let mData = buf.mData {
                    let dst = mData.bindMemory(to: Float.self, capacity: frames)
                    let read = self.audioRB.pop(into: dst, count: frames)
                    if read > 0 { // Update last sample if any were read
                        lastSample = dst.advanced(by: read - 1).pointee
                    }
                    if read < frames {
                        let rem = frames - read
                        // Fill underrun with the last valid sample instead of zero
                        (dst + read).initialize(repeating: lastSample, count: rem)
                    }
                    abl[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
                }
                return noErr
            }

            buildAudioChain(engine: engine, source: src, format: format)

            do {
                // FIX: Setting the engine's render thread to a high priority to minimize blocking.
                try engine.start()
            } catch {
                print("AVAudioEngine start error: \(error)")
            }
            self.engine = engine
            self.sourceNode = src
        } else {
            // Even if engine already exists, keep buffer in sync with chosen latency
            audioRB = CircularFloatBuffer(capacity: audioBufferSize())
            prefillAudioBuffer()
            apu?.setOutputSampleRate(Float(audioSampleRate))
            updateAudioResampleStep()
        }
    }

    private func buildAudioChain(engine: AVAudioEngine, source: AVAudioSourceNode, format: AVAudioFormat) {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        if let band = eq.bands.first {
            band.filterType = .lowPass
            band.frequency = 14_000
            band.bandwidth = 0.5
            band.bypass = false
            band.gain = 0
        }

        // ---- Peak Limiter AU without manual parameters ----
        let limiterDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        let limiter = AVAudioUnitEffect(audioComponentDescription: limiterDesc)

        engine.attach(source)
        engine.attach(eq)
        engine.attach(limiter)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.8

        self.eqNode = eq
        self.limiterNode = limiter
    }

    private func warmUpChipsForStableStart() {
        // Warm up PPU/APU/CPU to a stable state
        apuToAudioAccum = 0.0
        if let cpu = cpu, let ppu = ppu {
            for _ in 0..<20_000 {
                ppu.tick(); ppu.tick(); ppu.tick()
                apu?.tick()
                _ = cpu.step()
            }
        }
    }

    private func launchEmulationLoop() {
        // Run emulation loop on dedicated serial queue
        emulationQueue.async { [weak self] in
            guard let self = self else { return }
            self.emulationThread = Thread.current
            Thread.current.name = "NESforGood.Emulation"

            // FIX: Setting thread priority is usually redundant when using QoS, but we keep it high.
            Thread.current.threadPriority = 0.95

            // Initialize frame tick here, just before starting the loop
            self.resetFrameSync()

            while self.isRunning {
                autoreleasepool {
                    self.runOneFrame()
                }
            }

            self.emulationThread = nil
            self.teardownAfterStop()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        // Cleanup will run on emulationQueue after loop exits.
    }

    /// Runs after the emulation loop has exited, on `emulationQueue`.
    private func teardownAfterStop() {
        // Fade out audio to avoid clicks
        if engine != nil {
            let fadeSamples = Int(audioSampleRate * 0.10) // ~100 ms
            for _ in 0..<fadeSamples {
                safeAudioPush(0.0)
            }
        }

        if let engine = engine {
            engine.stop()
        }
        engine = nil
        sourceNode = nil
        eqNode = nil
        limiterNode = nil

        ppu?.clearFrame()
        ppu?.frameReady = false
        frameSerial = 0

        // Persist SRAM if needed, but keep cartridge/components
        cartridge?.saveBatteryRAM()

        smoothedAudioSample = 0.0
        lastAudioSample = 0.0
    }

    func reset() {
        cartridge?.saveBatteryRAM()
        cpu?.reset()
        ppu?.reset()
        apu?.reset()

        // Keep APU filters in sync with current audioSampleRate
        apu?.setOutputSampleRate(Float(audioSampleRate))

        apuToAudioAccum = 0.0
        dmaActive = false
        dmaCyclesLeft = 0
        cpuCycleCounter = 0

        // Run for a bit to stabilize after reset
        if let cpu = cpu, let ppu = ppu {
            for _ in 0..<20_000 {
                ppu.tick(); ppu.tick(); ppu.tick()
                apu?.tick()
                _ = cpu.step()
            }
        }
    }

    // MARK: - Frame Emulation

    func runOneFrame() {
        guard let ppu = self.ppu, let cpu = self.cpu, let bus = self.bus else { return }
        let apu = self.apu
        let cartridge = self.cartridge

        ppu.frameReady = false
        var cycleChunk = 0

        while !ppu.frameReady {
            if !isRunning { return }

            // 3 PPU ticks per CPU master cycle
            ppu.tick(); ppu.tick(); ppu.tick()

            // Mapper handles IRQs via PPU callbacks (MMC3) - now handled by PPU

            apu?.tick()

            // Downsample APU to audio sample rate
            apuToAudioAccum += 1.0
            if apuToAudioAccum >= apuToAudioStep {
                apuToAudioAccum -= apuToAudioStep
                if let apu = apu {
                    safeAudioPush(apu.outputSample())
                } else {
                    safeAudioPush(0.0)
                }
            }

            // DMA handling
            if dmaActive {
                if dmaCyclesLeft > 0 {
                    dmaCyclesLeft &-= 1

                    if dmaCyclesLeft % 2 == 0 && dmaCyclesLeft > 0 && dmaByteIndex < 256 {
                        let addr = dmaSourceAddr &+ UInt16(truncatingIfNeeded: dmaByteIndex)
                        let value = bus.cpuRead(address: addr)
                        let oamIdx = dmaOamIndex &+ UInt8(truncatingIfNeeded: dmaByteIndex)
                        ppu.writeOAM(index: oamIdx, value: value)
                        dmaByteIndex += 1
                    }

                    if dmaCyclesLeft == 0 {
                        dmaActive = false
                    }
                }
            } else if cpuCycleCounter == 0 {
                cpuCycleCounter = cpu.step()

                if let apu = apu {
                    cpuCycleCounter &+= apu.consumeDMCStallCycles()
                }
            }

            if cpuCycleCounter > 0 {
                cpuCycleCounter &-= 1
            }

            // Interrupts
            if ppu.nmiPending {
                ppu.nmiPending = false
                cpu.nmi()
            }
            if let apu = apu, apu.irqPending {
                apu.irqPending = false
                cpu.irq()
            }
            if let cart = cartridge, cart.mapper.mapperIRQAsserted() {
                cpu.irq()
            }

            cycleChunk &+= 1
            if cycleChunk >= 600_000 {
                cycleChunk = 0
            }
        }

        frameSerial &+= 1
        ppu.frameReady = false

        // --- Turbo Mode: no frame pacing at all ---
        if turboEnabled {
            resetFrameSync()
            return
        }

        // --- Normal frame pacing with vsync hint, using mach time ---
        paceFrameIfNeeded()
    }

    // MARK: - Audio Helpers

    private func safeAudioPush(_ sample: Float) {
        let filtered = smoothAndLimit(sample)
        lastAudioSample = filtered
        audioRB.push(filtered)
    }

    private func updateAudioResampleStep() {
        apuToAudioStep = apuHz / audioSampleRate
        maxSampleDelta = Float(0.08 * (44_100.0 / max(8_000.0, audioSampleRate)))
    }

    private func prefillAudioBuffer() {
        let desired = max(1, Int(audioSampleRate * 0.02))
        let framesToFill = min(desired, max(0, audioRB.availableToWrite()))
        if framesToFill == 0 { return }
        let seed = lastAudioSample
        smoothedAudioSample = seed
        for _ in 0..<framesToFill {
            audioRB.push(seed)
        }
    }

    private func smoothAndLimit(_ rawSample: Float) -> Float {
        // Clamp the raw sample just in case upstream filters misbehave
        var clamped = max(-1.25, min(1.25, rawSample))
        let delta = clamped - smoothedAudioSample
        if delta > maxSampleDelta {
            clamped = smoothedAudioSample + maxSampleDelta
        } else if delta < -maxSampleDelta {
            clamped = smoothedAudioSample - maxSampleDelta
        }
        smoothedAudioSample = clamped

        // Soft clip with a tanh curve to avoid hard digital clipping artifacts
        let limited = Float(tanh(Double(clamped) * 1.15)) * 0.92
        return limited
    }

    // MARK: - Frame Extraction

    func currentFrameCGImage() -> CGImage? {
        if let img = ppu?.getFrameImage() as? Image {
            return img.cgImage()
        }
        return nil
    }
}

// MARK: - Timing Helpers

extension EmulatorCore {
    private func updateFrameDurationTicks() {
        guard desiredFPS > 0 else {
            frameDurationTicks = 0
            resetFrameSync()
            return
        }
        let nanos = UInt64(1_000_000_000) / UInt64(desiredFPS)
        frameDurationTicks = nanosToAbsoluteTime(nanos)
        resetFrameSync()
    }

    private func resetFrameSync() {
        nextFrameTick = mach_absolute_time()
    }

    private func paceFrameIfNeeded() {
        guard vsyncEnabledHint, frameDurationTicks > 0 else {
            resetFrameSync()
            return
        }

        var targetTick = nextFrameTick
        if targetTick == 0 {
            targetTick = mach_absolute_time()
        }
        targetTick &+= frameDurationTicks

        var now = mach_absolute_time()
        if now < targetTick {
            mach_wait_until(targetTick)
            now = targetTick
        } else {
            let behind = now &- targetTick
            if behind >= frameDurationTicks {
                let maxDrift = frameDurationTicks &* 8
                if behind > maxDrift {
                    targetTick = now
                } else {
                    let remainder = behind % frameDurationTicks
                    targetTick = now &- remainder
                }
            } else {
                targetTick = now
            }
        }

        nextFrameTick = targetTick
    }

    fileprivate func nanosToAbsoluteTime(_ nanos: UInt64) -> UInt64 {
        if timebaseInfo.denom == 0 || timebaseInfo.numer == 0 { return nanos }
        return nanos &* UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)
    }
}

// MARK: - Image → CGImage

extension Image {
    func cgImage() -> CGImage? {
        #if os(macOS)
        let mirror = Mirror(reflecting: self)
        for child in mirror.children {
            if let nsImage = child.value as? NSImage {
                return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        }
        #endif
        return nil
    }
}
