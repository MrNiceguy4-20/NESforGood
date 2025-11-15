import Foundation
import SwiftUI
import Observation
import AVFoundation
import Darwin

@Observable
class EmulatorCore {
    // ===== Frame pacing =====
    var vsyncEnabledHint: Bool = true
    var desiredFPS: Int = 60
    private var lastFrameTick = DispatchTime.now()
    
    // ===== UI state =====
    var isRunning = false
    var screenImage: Image? = nil
    var frameSerial: UInt64 = 0
    
    // ===== Components =====
    private(set) var cartridge: Cartridge?
    private var bus: Bus?
    var cpu: CPU?
    var ppu: PPU?
    private var apu: APU?
    private var controller: Controller?
    private var mmc3Mapper: MMC3Mapper?
    
    // ===== Audio (AVAudioEngine + SourceNode) =====
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var audioSampleRate: Double = 44_100
    private var audioRB = CircularFloatBuffer(capacity: 44_100 * 4)
    
    // APU->Audio resampling
    private let apuHz: Double = 1_789_773.0
    private var apuToAudioStep: Double { apuHz / audioSampleRate }
    private var apuToAudioAccum: Double = 0.0
    
    // ===== DMA =====
    var dmaActive = false
    var dmaCyclesLeft = 0
    var dmaSourceAddr: UInt16 = 0
    var dmaByteIndex: Int = 0
    var dmaOamIndex: UInt8 = 0
    
    // ===== CPU multi-cycle =====
    private var cpuCycleCounter = 0
    
    // ---
    // --- Dedicated emulation thread ---
    // ---
    private var emulationThread: Thread?
    
    init() {}
    
    deinit {
        cartridge?.saveBatteryRAM()
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
    
    func setVSync(_ enabled: Bool) { self.vsyncEnabledHint = enabled }
    func setFrameLimit(_ fps: Int) { self.desiredFPS = max(0, fps) }
    
    func loadROM(data: Data) throws {
        if isRunning { stop() }
        cartridge?.saveBatteryRAM()
        unload()
        let cart = try Cartridge(data: data)
        cartridge = cart
        apu = APU()
        ppu = PPU(cartridge: cart)
        controller = Controller()
        bus = Bus(cartridge: cart, ppu: ppu!, apu: apu!, controller: controller!, core: self)
        apu?.bus = bus
        cpu = CPU(bus: bus!)
        self.mmc3Mapper = cart.mapper as? MMC3Mapper
    }
    
    func start() {
        guard !isRunning, cartridge != nil else { return }
        isRunning = true
        lastFrameTick = DispatchTime.now()
        
        // Setup audio engine
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: audioSampleRate, channels: 1)!
        let src = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let frames = Int(frameCount)
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            if let buf = abl.first, let mData = buf.mData {
                let dst = mData.bindMemory(to: Float.self, capacity: frames)
                let read = self.audioRB.pop(into: dst, count: frames)
                if read < frames {
                    let rem = frames - read
                    (dst + read).initialize(repeating: 0, count: rem)
                }
                abl[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }
            return noErr
        }
        engine.attach(src)
        engine.connect(src, to: engine.mainMixerNode, format: format)
        do { try engine.start() } catch { print("AVAudioEngine start error: \(error)") }
        self.engine = engine
        self.sourceNode = src
        
        apuToAudioAccum = 0.0
        // Warm up state a little to avoid initial crackles
        if let cpu = cpu, let ppu = ppu {
            for _ in 0..<20_000 {
                ppu.tick(); ppu.tick(); ppu.tick()
                apu?.tick()
                _ = cpu.step()
            }
        }
        
        // --- FIX: Use DispatchQueue with explicit .userInitiated QoS to prevent priority inversion ---
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            // Capture the current thread for reference/debugging, though DispatchQueue manages the pool.
            self.emulationThread = Thread.current
            
            while self.isRunning {
                self.runOneFrame()
            }
            self.emulationThread = nil
        }
    }
    
    func stop() {
        guard isRunning else { return }
        
        isRunning = false
        
        // Fade out audio for a short period (avoid audible clicks)
        if engine != nil {
            // push several zero samples (approx 100ms) to fade out
            let fadeSamples = Int(audioSampleRate * 0.10)
            for _ in 0..<fadeSamples {
                safeAudioPush(0.0)
            }
        }
        
        // Note: No manual thread waiting/joining needed with DispatchQueue.
        if let engine = engine { engine.stop() }
        engine = nil
        sourceNode = nil
        
        ppu?.clearFrame()
        ppu?.frameReady = false
        frameSerial = 0
        
        unload()
    }
    
    func reset() {
        cartridge?.saveBatteryRAM()
        cpu?.reset()
        ppu?.reset() // Use the PPU's own reset function
        apu?.reset() // Use the APU's own reset function
        
        apuToAudioAccum = 0.0
        dmaActive = false
        dmaCyclesLeft = 0
        cpuCycleCounter = 0
        
        // Run for a bit to stabilize
        if let cpu = cpu, let ppu = ppu {
            for _ in 0..<20_000 {
                ppu.tick(); ppu.tick(); ppu.tick()
                apu?.tick()
                _ = cpu.step()
            }
        }
    }
    
    func runOneFrame() {
        guard let ppu = self.ppu else { return }
        
        ppu.frameReady = false
        var cycleChunk = 0
        
        while !ppu.frameReady {
            if !isRunning { return }
            
            // PPU ticks: 3 ticks per CPU cycle
            ppu.tick(); ppu.tick(); ppu.tick()
            
            // Optional: MMC3 mapper PPU tick hook (restore if your MMC3 needs it)
            if let mmc3 = self.mmc3Mapper {
                // Note: The main clockScanlineCounter call is already in PPU.swift
            }
            
            apu?.tick()
            
            // Resample APU -> audio buffer
            apuToAudioAccum += 1.0
            if apuToAudioAccum >= apuToAudioStep {
                apuToAudioAccum -= apuToAudioStep
                if let s = apu?.outputSample() {
                    safeAudioPush(s)
                } else {
                    safeAudioPush(0.0)
                }
            }
            
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
            
            if ppu.nmiPending { ppu.nmiPending = false; cpu?.nmi() }
            if apu?.irqPending ?? false { apu?.irqPending = false; cpu?.irq() }
            if let cart = cartridge, cart.mapper.mapperIRQAsserted() {
                cpu?.irq()
            }
            
            cycleChunk &+= 1
            if cycleChunk >= 600_000 {
                cycleChunk = 0
                // --- FIX: Removed sched_yield() (was line 226) for stable audio timing ---
            }
        }
        
        // Frame completed
        frameSerial &+= 1
        ppu.frameReady = false
        
        // Frame pacing (v-sync / target FPS)
        if vsyncEnabledHint && desiredFPS > 0 {
            let now = DispatchTime.now()
            let targetNanos = UInt64(1_000_000_000 / UInt64(desiredFPS))
            let elapsed = now.uptimeNanoseconds - lastFrameTick.uptimeNanoseconds
            if elapsed < targetNanos {
                let sleepNanos = targetNanos - elapsed
                // Convert to seconds and sleep
                let sleepSec = Double(sleepNanos) / 1_000_000_000.0
                // Sleep is approximate but good enough for frame pacing
                Thread.sleep(forTimeInterval: sleepSec)
            }
            lastFrameTick = DispatchTime.now()
        } else {
            lastFrameTick = DispatchTime.now()
        }
    }
    
    // Best-effort safe push to audio ring buffer:
    // - try to discover free space via reflection if possible (freeCount/availableSpace/capacity/count)
    // - fallback to blind push if nothing discoverable
    private func safeAudioPush(_ sample: Float) {
        // Try to discover free space
        if let free = audioBufferFreeSpace() {
            if free > 0 {
                audioRB.push(sample)
            } else {
                // buffer full: drop sample to avoid blocking/overflow
            }
        } else {
            // Could not determine free space; fallback to blind push
            // If your CircularFloatBuffer exposes a boolean push(...) or a tryPush(...) prefer that.
            audioRB.push(sample)
        }
    }
    
    // Reflective helper that attempts to find free space in known CircularFloatBuffer fields.
    // Returns nil if not discoverable.
    private func audioBufferFreeSpace() -> Int? {
        // Attempt to read common fields using Mirror (best-effort only).
        let m = Mirror(reflecting: audioRB)
        var capacity: Int? = nil
        var count: Int? = nil
        var freeCount: Int? = nil
        var availableSpace: Int? = nil
        
        for child in m.children {
            if let label = child.label {
                let l = label.lowercased()
                if l.contains("capacity"), let v = child.value as? Int { capacity = v }
                if l.contains("count"), let v = child.value as? Int { count = v }
                if l.contains("free") || l.contains("freecount"), let v = child.value as? Int { freeCount = v }
                if (l.contains("available") || l.contains("availablespace")), let v = child.value as? Int { availableSpace = v }
            }
        }
        if let fc = freeCount { return fc }
        if let a = availableSpace { return a }
        if let cap = capacity, let c = count { return max(0, cap - c) }
        return nil
    }
    
    func currentFrameCGImage() -> CGImage? {
        if let img = ppu?.getFrameImage() as? Image {
            return img.cgImage()
        }
        return nil
    }
}

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
