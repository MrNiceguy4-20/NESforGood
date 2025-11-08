import Foundation
import AVFoundation

class APU {
    public var dmcStallCycles: Int = 0
    weak var bus: Bus?
    
    var pulse1 = PulseChannel(channel: 1)
    var pulse2 = PulseChannel(channel: 2)
    var triangle = TriangleChannel()
    var noise = NoiseChannel()
    var dmc = DMCChannel()
    
    private var cpuCycle: UInt64 = 0
    
    private var halfRateToggle: Bool = false
    private var frameCycle: UInt32 = 0
    private var frameMode5Step: Bool = false
    private var frameIRQInhibit: Bool = false
    private var frameIRQFlag: Bool = false
    private var pendingFrameIRQ: Bool = false
    
    var irqPending: Bool = false
    
    private var pulseTable = [Float](repeating: 0, count: 31)
    private var tndTable = [Float](repeating: 0, count: 203)

    private var lpY: Float = 0.0
    private var lpAlpha: Float = 0.0
    
    init() {
        for i in 0..<31 { pulseTable[i] = 95.52 / (8128.0 / Float(i) + 100.0) }
        for i in 0..<203 { tndTable[i] = 163.67 / (24329.0 / Float(i) + 100.0) }
        
        pulse1.apu = self
        pulse2.apu = self
        triangle.apu = self
        noise.apu = self
        dmc.apu = self
        let fc: Float = 14000.0
        let fs: Float = 44100.0
        let a = 1.0 - exp(-2.0 * Float.pi * fc / fs)
        self.lpAlpha = a
    }
    
    func read(address: UInt16) -> UInt8 {
        if address == 0x4015 {
            var val: UInt8 = 0
            if pulse1.lengthCounter > 0 { val |= 0x01 }
            if pulse2.lengthCounter > 0 { val |= 0x02 }
            if triangle.lengthCounter > 0 { val |= 0x04 }
            if noise.lengthCounter > 0 { val |= 0x08 }
            if dmc.bytesRemaining > 0 { val |= 0x10 }
            if frameIRQFlag { val |= 0x40 }
            if dmc.irqFlag   { val |= 0x80 }
            
            frameIRQFlag = false
            if pendingFrameIRQ {
            frameIRQFlag = true
            pendingFrameIRQ = false
        }
        irqPending = ((!frameIRQInhibit && frameIRQFlag) || dmc.irqFlag)
            return val
        }
        return 0
    }
    
    func write(address: UInt16, value: UInt8) {
        switch address {
        case 0x4000: pulse1.write(reg: 0, value: value)
        case 0x4001: pulse1.write(reg: 1, value: value)
        case 0x4002: pulse1.write(reg: 2, value: value)
        case 0x4003: pulse1.write(reg: 3, value: value)
        case 0x4004: pulse2.write(reg: 0, value: value)
        case 0x4005: pulse2.write(reg: 1, value: value)
        case 0x4006: pulse2.write(reg: 2, value: value)
        case 0x4007: pulse2.write(reg: 3, value: value)
        case 0x4008: triangle.write(reg: 0, value: value)
        case 0x400A: triangle.write(reg: 2, value: value)
        case 0x400B: triangle.write(reg: 3, value: value)
        case 0x400C: noise.write(reg: 0, value: value)
        case 0x400E: noise.write(reg: 2, value: value)
        case 0x400F: noise.write(reg: 3, value: value)
        case 0x4010: dmc.write(reg: 0, value: value)
        case 0x4011: dmc.write(reg: 1, value: value)
        case 0x4012: dmc.write(reg: 2, value: value)
        case 0x4013: dmc.write(reg: 3, value: value)
        case 0x4015:
            pulse1.enabled  = (value & 0x01) != 0
            pulse2.enabled  = (value & 0x02) != 0
            triangle.enabled = (value & 0x04) != 0
            noise.enabled   = (value & 0x08) != 0
            dmc.enabled     = (value & 0x10) != 0
            
            if !pulse1.enabled  { pulse1.lengthCounter  = 0 }
            if !pulse2.enabled  { pulse2.lengthCounter  = 0 }
            if !triangle.enabled { triangle.lengthCounter = 0 }
            if !noise.enabled   { noise.lengthCounter   = 0 }
            
            if !dmc.enabled {
                dmc.bytesRemaining = 0
            } else if dmc.bytesRemaining == 0 {
                dmc.start()
            }
            dmc.irqFlag = false
            
        case 0x4017:
            frameMode5Step   = (value & 0x80) != 0
            frameIRQInhibit  = (value & 0x40) != 0
            if frameIRQInhibit { frameIRQFlag = false }
            
            frameCycle = 0
            halfRateToggle = false
            
            if frameMode5Step {
                clockQuarterFrame()
                clockHalfFrame()
            }
        default:
            break
        }
    }
    
    func tick() {
        cpuCycle &+= 1
        
        triangle.clockTimer()
        
        halfRateToggle.toggle()
        if halfRateToggle {
            pulse1.clockTimer()
            pulse2.clockTimer()
            noise.clockTimer()
            dmc.clockTimer()
            
            frameCycle &+= 1
            
            if !frameMode5Step {
                switch frameCycle {
                case 3729:
                    clockQuarterFrame()
                case 7457:
                    clockQuarterFrame()
                    clockHalfFrame()
                case 11186:
                    clockQuarterFrame()
                case 14915:
                    clockQuarterFrame()
                    clockHalfFrame()
                    if !frameIRQInhibit { pendingFrameIRQ = true }
                    frameCycle = 0
                default:
                    break
                }
            } else {
                switch frameCycle {
                case 3729:
                    clockQuarterFrame()
                case 7457:
                    clockQuarterFrame()
                    clockHalfFrame()
                case 11186:
                    clockQuarterFrame()
                case 14915:
                    clockQuarterFrame()
                    clockHalfFrame()
                case 18641:
                    frameCycle = 0
                default:
                    break
                }
            }
        }
        
        if pendingFrameIRQ {
            frameIRQFlag = true
            pendingFrameIRQ = false
        }
        irqPending = ((!frameIRQInhibit && frameIRQFlag) || dmc.irqFlag)
    }
    
    private func clockQuarterFrame() {
        pulse1.clockEnvelope()
        pulse2.clockEnvelope()
        triangle.clockLinear()
        noise.clockEnvelope()
    }
    
    private func clockHalfFrame() {
        pulse1.clockLength(); pulse1.clockSweep()
        pulse2.clockLength(); pulse2.clockSweep()
        triangle.clockLength()
        noise.clockLength()
    }
    
    func outputSample() -> Float {
        let p1  = Float(pulse1.output)
        let p2  = Float(pulse2.output)
        let tri = Float(triangle.output)
        let noi = Float(noise.output)
        let dm  = Float(dmc.output)
        
        let pulseSum = min(Int(p1 + p2), 30)
        let tndSum   = min(Int(3 * tri + 2 * noi + dm), 202)
        
        let mixed = pulseTable[pulseSum] + tndTable[tndSum]
        let x = mixed - 0.0005
        lpY = lpY + lpAlpha * (x - lpY)
        return lpY
    }
}
