import Foundation
import SwiftUI
import Observation
import AVFoundation
import Darwin

@Observable
class EmulatorCore {
    var vsyncEnabledHint: Bool = true
    var desiredFPS: Int = 60
    private var lastFrameTick = DispatchTime.now()
    var isRunning = false
    var screenImage: Image? = nil
    var frameSerial: UInt64 = 0
    private(set) var cartridge: Cartridge?
    private var bus: Bus?
    var cpu: CPU?
    var ppu: PPU?
    private var apu: APU?
    private var controller: Controller?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var audioSampleRate: Double = 44_100
    private var audioRB = CircularFloatBuffer(capacity: 44_100 * 4)
    private let apuHz: Double = 1_789_773.0
    private var apuToAudioStep: Double { apuHz / audioSampleRate }
    private var apuToAudioAccum: Double = 0.0
    var dmaActive = false
    var dmaCyclesLeft = 0
    var dmaSourceAddr: UInt16 = 0
    var dmaByteIndex: UInt8 = 0
    var dmaOamIndex: UInt8 = 0
    private var cpuCycleCounter = 0
    
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
    }
    
    func start() {
        guard !isRunning, cartridge != nil else { return }
        isRunning = true
        lastFrameTick = DispatchTime.now()
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
        if let cpu = cpu, let ppu = ppu {
            for _ in 0..<20_000 {
                ppu.tick(); ppu.tick(); ppu.tick()
                apu?.tick()
                _ = cpu.step()
            }
        }

    }
    
    func stop() {
        guard isRunning else { return }
        cartridge?.saveBatteryRAM()
        isRunning = false
        if let engine = engine { engine.stop() }
        engine = nil
        sourceNode = nil
        ppu?.clearFrame()
        ppu?.frameReady = false
        frameSerial = 0
    }
    
    func reset() {
        cartridge?.saveBatteryRAM()
        cpu?.reset()
        ppu?.status = 0
        apuToAudioAccum = 0.0
        if let cpu = cpu, let ppu = ppu {
            for _ in 0..<20_000 {
                ppu.tick(); ppu.tick(); ppu.tick()
                apu?.tick()
                _ = cpu.step()
            }
        }

        ppu?.clearFrame()
        ppu?.frameReady = false
        dmaActive = false
        dmaCyclesLeft = 0
        cpuCycleCounter = 0
    }
    
    func runOneFrame() {
        guard isRunning else { return }
        ppu?.frameReady = false
        var cycleChunk = 0
        while !(ppu?.frameReady ?? false) {
            ppu?.tick(); ppu?.tick(); ppu?.tick()
            apu?.tick()
            apuToAudioAccum += 1.0
            if apuToAudioAccum >= apuToAudioStep {
                apuToAudioAccum -= apuToAudioStep
                if let s = apu?.outputSample() { audioRB.push(s) } else { audioRB.push(0.0) }
            }
            
            if dmaActive {
                if dmaCyclesLeft > 0 {
                    dmaCyclesLeft &-= 1
                    if dmaCyclesLeft == 0 {
                        dmaActive = false
                        
                    }
                }
            } else {
                if cpuCycleCounter == 0 {
                    if let cpu = cpu {
                        cpuCycleCounter = cpu.step()
                    }
                }
                cpuCycleCounter &-= 1
            }
            
            if ppu?.nmiPending ?? false { ppu?.nmiPending = false; cpu?.nmi() }
            if apu?.irqPending ?? false { apu?.irqPending = false; cpu?.irq() }
            if let cart = cartridge, cart.mapper.mapperIRQAsserted() {
                cpu?.irq()
            }
            
            cycleChunk &+= 1
            if cycleChunk >= 600_000 {
                cycleChunk = 0
                _ = sched_yield()
            }
        }
        
        self.frameSerial &+= 1
        self.ppu?.frameReady = false
        if !vsyncEnabledHint && desiredFPS > 0 {
            let targetNs = UInt64(1_000_000_000 / UInt64(desiredFPS))
            let now = DispatchTime.now()
            let elapsed = now.uptimeNanoseconds &- lastFrameTick.uptimeNanoseconds
            if elapsed < targetNs {
                let remain = targetNs - elapsed
                let us = max(0, Int(remain / UInt64(1_000)))
                if us > 0 { usleep(useconds_t(us)) }
            }
            lastFrameTick = DispatchTime.now()
        }
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
