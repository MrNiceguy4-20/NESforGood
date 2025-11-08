import Foundation
import AVFoundation

// MARK: - APU (Audio Processing Unit)
class APU {
    // DMC memory fetch stalls the CPU by 4 cycles per byte (true NES behavior)
    public var dmcStallCycles: Int = 0
    weak var bus: Bus?
    
    var pulse1 = PulseChannel(channel: 1)
    var pulse2 = PulseChannel(channel: 2)
    var triangle = TriangleChannel()
    var noise = NoiseChannel()
    var dmc = DMCChannel()
    
    // CPU-cycle domain counters (NTSC CPU ~1.789773 MHz)
    private var cpuCycle: UInt64 = 0
    
    // Frame sequencer (runs on every other CPU cycle = ~894 kHz)
    // We use a divider bit to avoid modulo on every tick.
    private var halfRateToggle: Bool = false
    private var frameCycle: UInt32 = 0          // counts at half CPU rate
    private var frameMode5Step: Bool = false    // false: 4-step, true: 5-step
    private var frameIRQInhibit: Bool = false
    private var frameIRQFlag: Bool = false      // internal frame IRQ flag
    private var pendingFrameIRQ: Bool = false
    
    // Public IRQ line (polled by EmulatorCore)
    var irqPending: Bool = false
    
    // Mixing tables (nonlinear DAC approximation)
    private var pulseTable = [Float](repeating: 0, count: 31)
    private var tndTable = [Float](repeating: 0, count: 203)

    // One-pole low-pass filter state (approximate NES output roll-off)
    private var lpY: Float = 0.0
    private var lpAlpha: Float = 0.0
    
    init() {
        // Precompute the standard mixer curves
        for i in 0..<31 { pulseTable[i] = 95.52 / (8128.0 / Float(i) + 100.0) }
        for i in 0..<203 { tndTable[i] = 163.67 / (24329.0 / Float(i) + 100.0) }
        
        // Wire channels to APU
        pulse1.apu = self
        pulse2.apu = self
        triangle.apu = self
        noise.apu = self
        dmc.apu = self
        // Precompute low-pass alpha for fc≈14 kHz at fs=44.1 kHz
        let fc: Float = 14000.0
        let fs: Float = 44100.0
        let a = 1.0 - exp(-2.0 * Float.pi * fc / fs)
        self.lpAlpha = a
    }
    
    // MARK: - CPU register interface
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
            
            // Reading $4015 clears the frame IRQ flag (but not DMC IRQ)
            frameIRQFlag = false
            // Update the combined line
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
            // Enable bits
            pulse1.enabled  = (value & 0x01) != 0
            pulse2.enabled  = (value & 0x02) != 0
            triangle.enabled = (value & 0x04) != 0
            noise.enabled   = (value & 0x08) != 0
            dmc.enabled     = (value & 0x10) != 0
            
            // Length counter clearing
            if !pulse1.enabled  { pulse1.lengthCounter  = 0 }
            if !pulse2.enabled  { pulse2.lengthCounter  = 0 }
            if !triangle.enabled { triangle.lengthCounter = 0 }
            if !noise.enabled   { noise.lengthCounter   = 0 }
            
            // DMC enable / IRQ clear semantics
            if !dmc.enabled {
                dmc.bytesRemaining = 0
            } else if dmc.bytesRemaining == 0 {
                dmc.start()
            }
            // Writing $4015 clears only the DMC IRQ flag
            dmc.irqFlag = false
            
        case 0x4017:
            // Frame counter control
            frameMode5Step   = (value & 0x80) != 0
            frameIRQInhibit  = (value & 0x40) != 0
            if frameIRQInhibit { frameIRQFlag = false }
            
            // Reset the frame sequencer divider
            frameCycle = 0
            halfRateToggle = false
            
            // When switching to 5-step, clock immediately (quarter + half)
            if frameMode5Step {
                clockQuarterFrame()
                clockHalfFrame()
            }
        default:
            break
        }
    }
    
    // MARK: - Master tick (called once per CPU cycle)
    func tick() {
        cpuCycle &+= 1
        
        // Triangle clocks every CPU cycle
        triangle.clockTimer()
        
        // Other channels/DMC clock on even CPU cycles (match APU timers)
        halfRateToggle.toggle()
        if halfRateToggle {
            pulse1.clockTimer()
            pulse2.clockTimer()
            noise.clockTimer()
            dmc.clockTimer()
            
            // Frame sequencer advances at this rate too
            frameCycle &+= 1
            
            if !frameMode5Step {
                // 4-step sequence (NTSC)
                // 3729, 7457, 11186, 14915 are the classic edges at half-CPU rate
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
                // 5-step (no IRQ)
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
        
        // Present a single combined IRQ line for the core to poll
        if pendingFrameIRQ {
            frameIRQFlag = true
            pendingFrameIRQ = false
        }
        irqPending = ((!frameIRQInhibit && frameIRQFlag) || dmc.irqFlag)
    }
    
    // MARK: - Frame sequencer helpers
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
    
    // MARK: - Mixer
    func outputSample() -> Float {
        // Channel outputs to linear mixer
        let p1  = Float(pulse1.output)
        let p2  = Float(pulse2.output)
        let tri = Float(triangle.output)
        let noi = Float(noise.output)
        let dm  = Float(dmc.output)
        
        // Clamp to table bounds
        let pulseSum = min(Int(p1 + p2), 30)
        let tndSum   = min(Int(3 * tri + 2 * noi + dm), 202)
        
        // Nonlinear DAC mix (already scaled 0..~1). Slight bias cut.
        let mixed = pulseTable[pulseSum] + tndTable[tndSum]
        let x = mixed - 0.0005 // tiny DC offset trim for long runs
        // One-pole LPF
        lpY = lpY + lpAlpha * (x - lpY)
        return lpY
    }
}
