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
        case low       // not used in audio-driven mode
        case medium
        case high
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

    private let cpuHz: Double = 1_789_773.0
    private var cpuCyclesPerSample: Double = 1_789_773.0 / 44_100.0
    private var cpuCycleAccumulator: Double = 0.0

    private var smoothedAudioSample: Float = 0.0
    private var maxSampleDelta: Float = 0.08

    // DC blocker (high-pass)
    private var dcBlockerPrevInput: Float = 0.0
    private var dcBlockerPrevOutput: Float = 0.0
    private var dcBlockerCoeff: Float = 0.995

    // Warmup gate
    private var emulationActive: Bool = false

    // MARK: - DMA

    var dmaActive = false
    var dmaCyclesLeft = 0
    var dmaSourceAddr: UInt16 = 0
    var dmaByteIndex: Int = 0
    var dmaOamIndex: UInt8 = 0

    // MARK: - CPU Timing

    private var cpuCycleCounter = 0

    // MARK: - Init / Deinit

    init() {
        mach_timebase_info(&timebaseInfo)
        updateFrameDurationTicks()
        resetFrameSync()
    }

    deinit {
        cartridge?.saveBatteryRAM()
    }

    // MARK: - ROM Management

    @inline(__always) func unload() {
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
        emulationActive = false
        resetAudioSmoothers()
    }

    @inline(__always) func loadROM(data: Data) throws {
        if isRunning { stop() }
        cartridge?.saveBatteryRAM()
        unload()

        let cart = try Cartridge(data: data)
        cartridge = cart

        apu = APU(sampleRate: Float(audioSampleRate))
        ppu = PPU(cartridge: cart)
        controller = Controller()
        let bus = Bus(cartridge: cart, ppu: ppu!, apu: apu!, controller: controller!, core: self)
        self.bus = bus
        apu?.bus = bus
        cpu = CPU(bus: bus)
        self.mmc3Mapper = cart.mapper as? MMC3Mapper
    }

    // MARK: - Public Configuration Helpers

    @inline(__always) func setVSync(_ enabled: Bool) {
        self.vsyncEnabledHint = enabled
    }

    @inline(__always) func setFrameLimit(_ fps: Int) {
        self.desiredFPS = max(0, fps)
        updateFrameDurationTicks()
    }

    @inline(__always) func setTurboEnabled(_ enabled: Bool) {
        turboEnabled = enabled
        resetFrameSync()
    }

    @inline(__always) func setAudioLatency(_ level: AudioLatency) {
        audioLatencyLevel = level
    }

    // MARK: - Start / Stop / Reset

    @inline(__always) func start() {
        guard !isRunning, cartridge != nil else { return }
        isRunning = true
        emulationActive = false

        // Run ALL AVAudioEngine setup + warmup on a low-priority background queue
        // so no User-interactive thread ever waits on Default-QoS internals.
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            self.configureAudioEngineIfNeeded()
            self.startAudioEngine()

            self.warmUpChipsForStableStart()
            self.emulationActive = true
        }
    }

    @inline(__always) func stop() {
        guard isRunning else { return }
        isRunning = false
        emulationActive = false

        engine?.stop()
        cartridge?.saveBatteryRAM()
        resetAudioSmoothers()
    }

    @inline(__always) func reset() {
        cartridge?.saveBatteryRAM()
        cpu?.reset()
        ppu?.reset()
        apu?.reset()

        apu?.setOutputSampleRate(Float(audioSampleRate))

        cpuCycleAccumulator = 0.0
        dmaActive = false
        dmaCyclesLeft = 0
        cpuCycleCounter = 0
        emulationActive = false
        resetAudioSmoothers()
    }

    // MARK: - Audio Engine Setup

    @inline(__always) private func configureAudioEngineIfNeeded() {
        if engine != nil { return }

        let engine = AVAudioEngine()

        // This line was where the QoS warning pointed:
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)

        let detectedRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : audioSampleRate
        audioSampleRate = detectedRate
        updateAudioResampleStep()

        apu?.setOutputSampleRate(Float(audioSampleRate))

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
                let produced = self.renderSamples(into: dst, frames: frames)
                if produced < frames {
                    self.renderSilence(into: dst.advanced(by: produced), frames: frames - produced)
                }
                abl[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }
            return noErr
        }

        buildAudioChain(engine: engine, source: src, format: format)

        self.engine = engine
        self.sourceNode = src
    }

    @inline(__always) private func buildAudioChain(engine: AVAudioEngine, source: AVAudioSourceNode, format: AVAudioFormat) {
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        if let band = eq.bands.first {
            band.filterType = .lowPass
            band.frequency = 14_000
            band.bandwidth = 0.5
            band.bypass = false
            band.gain = 0
        }

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
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: engine.outputNode.outputFormat(forBus: 0))
        engine.mainMixerNode.outputVolume = 0.8

        self.eqNode = eq
        self.limiterNode = limiter
    }

    @inline(__always) private func startAudioEngine() {
        guard let engine = engine else { return }
        do {
            
            engine.prepare()
            try engine.start()
        } catch {
            print("AVAudioEngine start error: \(error)")
        }
    }

    // MARK: - Warmup

    @inline(__always) private func warmUpChipsForStableStart() {
        guard let cpu = cpu, let ppu = ppu, let apu = apu, let bus = bus else { return }

        cpuCycleAccumulator = 0.0

        for _ in 0..<20_000 {
            stepOneCPUCycle(cpu: cpu, ppu: ppu, apu: apu, bus: bus)
        }
    }

    // MARK: - Audio-Driven Emulation

    @inline(__always) private func renderSamples(into dst: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        guard isRunning, emulationActive,
              let cpu = self.cpu,
              let ppu = self.ppu,
              let apu = self.apu,
              let bus = self.bus else {
            return 0
        }

        var accumulator = cpuCycleAccumulator

        for i in 0..<frames {
            accumulator += cpuCyclesPerSample
            var cyclesToRun = Int(accumulator)
            accumulator -= Double(cyclesToRun)

            while cyclesToRun > 0 {
                stepOneCPUCycle(cpu: cpu, ppu: ppu, apu: apu, bus: bus)
                cyclesToRun -= 1
            }

            dst[i] = smoothAndLimit(apu.outputSample())
        }

        cpuCycleAccumulator = accumulator
        return frames
    }

    @inline(__always) private func renderSilence(into dst: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            dst[i] = smoothAndLimit(0.0)
        }
    }

    @inline(__always) private func stepOneCPUCycle(cpu: CPU, ppu: PPU, apu: APU, bus: Bus) {
        apu.tick()
        ppu.tick(); ppu.tick(); ppu.tick()

        if dmaActive {
            if dmaCyclesLeft > 0 {
                dmaCyclesLeft -= 1

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
            cpuCycleCounter += apu.consumeDMCStallCycles()
        }

        if cpuCycleCounter > 0 {
            cpuCycleCounter -= 1
        }

        if ppu.nmiPending {
            ppu.nmiPending = false
            cpu.nmi()
        }
        if apu.irqPending {
            apu.irqPending = false
            cpu.irq()
        }
        if let cart = cartridge, cart.mapper.mapperIRQAsserted() {
            cpu.irq()
        }

        if ppu.frameReady {
            ppu.frameReady = false
            frameSerial += 1

            let img = ppu.getFrameImage()
            DispatchQueue.main.async { [weak self] in
                self?.screenImage = img
            }
        }
    }

    // MARK: - Audio Helpers

    @inline(__always) private func updateAudioResampleStep() {
        cpuCyclesPerSample = cpuHz / audioSampleRate
        maxSampleDelta = Float(0.28 * (44_100.0 / max(8_000.0, audioSampleRate)))
        dcBlockerCoeff = Float(exp(-2.0 * .pi * 12.0 / max(8_000.0, audioSampleRate)))
        resetAudioSmoothers()
    }

    @inline(__always) private func smoothAndLimit(_ rawSample: Float) -> Float {
        let highPassed = rawSample - dcBlockerPrevInput + dcBlockerCoeff * dcBlockerPrevOutput
        dcBlockerPrevInput = rawSample
        dcBlockerPrevOutput = highPassed

        var clamped = max(-1.25, min(1.25, highPassed))

        let delta = clamped - smoothedAudioSample
        if delta > maxSampleDelta {
            clamped = smoothedAudioSample + maxSampleDelta
        } else if delta < -maxSampleDelta {
            clamped = smoothedAudioSample - maxSampleDelta
        }
        smoothedAudioSample = clamped

        let limited = Float(tanh(Double(clamped) * 1.15)) * 0.92
        return limited
    }

    @inline(__always) private func resetAudioSmoothers() {
        smoothedAudioSample = 0.0
        dcBlockerPrevInput = 0.0
        dcBlockerPrevOutput = 0.0
    }

    @inline(__always) func runOneFrame() { }

    @inline(__always) func currentFrameCGImage() -> CGImage? {
        if let img = screenImage {
            return img.cgImage()
        }
        return nil
    }
}

// MARK: - Timing Helpers

extension EmulatorCore {
    @inline(__always) private func updateFrameDurationTicks() {
        guard desiredFPS > 0 else {
            frameDurationTicks = 0
            resetFrameSync()
            return
        }
        let nanos = UInt64(1_000_000_000) / UInt64(desiredFPS)
        frameDurationTicks = nanosToAbsoluteTime(nanos)
        resetFrameSync()
    }

    @inline(__always) private func resetFrameSync() {
        nextFrameTick = mach_absolute_time()
    }

    @inline(__always) fileprivate func nanosToAbsoluteTime(_ nanos: UInt64) -> UInt64 {
        if timebaseInfo.denom == 0 || timebaseInfo.numer == 0 { return nanos }
        return nanos &* UInt64(timebaseInfo.denom) / UInt64(timebaseInfo.numer)
    }
}

// MARK: - Image → CGImage

extension Image {
    @inline(__always) func cgImage() -> CGImage? {
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

