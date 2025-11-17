import Foundation
import SwiftUI
import Observation
import AVFoundation
import Darwin

@Observable
class EmulatorCore {

    // MARK: - Nested Types

    enum AudioLatency {
        case low      // ~50ms
        case medium   // ~100ms (default)
        case high     // ~200ms
    }

    // MARK: - Public Configuration

    var vsyncEnabledHint: Bool = true
    var desiredFPS: Int = 60

    var turboEnabled: Bool = false
    var audioLatencyLevel: AudioLatency = .medium

    // MARK: - Timing

    private var lastFrameTick: UInt64 = 0
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
    private var audioSampleRate: Double = 44_100
    // Initial buffer, replaced on start() based on audioLatencyLevel
    private var audioRB = CircularFloatBuffer(capacity: 44_100 * 4)

    private let apuHz: Double = 1_789_773.0
    private var apuToAudioStep: Double { apuHz / audioSampleRate }
    private var apuToAudioAccum: Double = 0.0

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
        qos: .userInitiated
    )

    // MARK: - Init / Deinit

    init() {
        mach_timebase_info(&timebaseInfo)
        lastFrameTick = mach_absolute_time()
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
    }

    func setTurboEnabled(_ enabled: Bool) {
        turboEnabled = enabled
    }

    func setAudioLatency(_ level: AudioLatency) {
        audioLatencyLevel = level
        // If running, we shrink/expand the ring buffer; audio continuity might glitch briefly,
        // but it avoids full engine restart or CPU reset.
        if isRunning {
            audioRB = CircularFloatBuffer(capacity: audioBufferSize())
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
            self.lastFrameTick = mach_absolute_time()
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
        // Configure audio engine if not already running
        if engine == nil {
            let engine = AVAudioEngine()

            // Detect hardware output sample rate
            let outputFormat = engine.outputNode.outputFormat(forBus: 0)
            let detectedRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : audioSampleRate
            audioSampleRate = detectedRate

            // Recreate audio ring buffer according to selected latency & detected rate
            audioRB = CircularFloatBuffer(capacity: audioBufferSize())

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

            engine.attach(src)
            engine.connect(src, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
            } catch {
                print("AVAudioEngine start error: \(error)")
            }
            self.engine = engine
            self.sourceNode = src
        } else {
            // Even if engine already exists, keep buffer in sync with chosen latency
            audioRB = CircularFloatBuffer(capacity: audioBufferSize())
            apu?.setOutputSampleRate(Float(audioSampleRate))
        }
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
            Thread.current.threadPriority = 0.95

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

        ppu?.clearFrame()
        ppu?.frameReady = false
        frameSerial = 0

        // Persist SRAM if needed, but keep cartridge/components
        cartridge?.saveBatteryRAM()
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
        guard let ppu = self.ppu else { return }

        ppu.frameReady = false
        var cycleChunk = 0

        while !ppu.frameReady {
            if !isRunning { return }

            // 3 PPU ticks per CPU master cycle
            ppu.tick(); ppu.tick(); ppu.tick()

            if let mmc3 = self.mmc3Mapper {
                _ = mmc3 // Mapper handles IRQs via PPU callbacks
            }

            apu?.tick()

            // Downsample APU to audio sample rate
            apuToAudioAccum += 1.0
            if apuToAudioAccum >= apuToAudioStep {
                apuToAudioAccum -= apuToAudioStep
                if let s = apu?.outputSample() {
                    safeAudioPush(s)
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
                        let value = bus!.cpuRead(address: addr)
                        let oamIdx = dmaOamIndex &+ UInt8(truncatingIfNeeded: dmaByteIndex)
                        ppu.writeOAM(index: oamIdx, value: value)
                        dmaByteIndex += 1
                    }

                    if dmaCyclesLeft == 0 {
                        dmaActive = false
                    }
                }
            } else if cpuCycleCounter == 0 {
                if let cpu = self.cpu {
                    cpuCycleCounter = cpu.step()

                    if let apu = self.apu {
                        cpuCycleCounter &+= apu.consumeDMCStallCycles()
                    }
                }
            }

            if cpuCycleCounter > 0 {
                cpuCycleCounter &-= 1
            }

            // Interrupts
            if ppu.nmiPending {
                ppu.nmiPending = false
                cpu?.nmi()
            }
            if apu?.irqPending ?? false {
                apu?.irqPending = false
                cpu?.irq()
            }
            if let cart = cartridge, cart.mapper.mapperIRQAsserted() {
                cpu?.irq()
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
            lastFrameTick = mach_absolute_time()
            return
        }

        // --- Normal frame pacing with vsync hint, using mach time ---
        if vsyncEnabledHint && desiredFPS > 0 {
            let now = mach_absolute_time()
            let targetNanos = UInt64(1_000_000_000) / UInt64(desiredFPS)
            let targetTicks = nanosToAbsoluteTime(targetNanos)
            let elapsedTicks = now &- lastFrameTick

            if elapsedTicks < targetTicks {
                let deadline = lastFrameTick &+ targetTicks
                mach_wait_until(deadline)
            }

            lastFrameTick = mach_absolute_time()
        } else {
            lastFrameTick = mach_absolute_time()
        }
    }

    // MARK: - Audio Helpers

    private func safeAudioPush(_ sample: Float) {
        audioRB.push(sample)
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
