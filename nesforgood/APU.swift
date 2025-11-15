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

    private var pending4017write: Int = -1
    private var pending4017value: UInt8 = 0

    private var pulseTable = [Float](repeating: 0, count: 31)
    private var tndTable = [Float](repeating: 0, count: 203)

    private var lpY: Float = 0.0
    private var lpAlpha: Float = 0.0

    private var hpY: Float = 0.0
    private var hpX: Float = 0.0
    private var hpAlpha: Float = 0.0

    init() {
        pulseTable[0] = 0.0
        for i in 1..<31 {
            pulseTable[i] = 95.52 / (8128.0 / Float(i) + 100.0)
        }
        tndTable[0] = 0.0
        for i in 1..<203 {
            tndTable[i] = 163.67 / (24329.0 / Float(i) + 100.0)
        }

        pulse1.apu = self
        pulse2.apu = self
        triangle.apu = self
        noise.apu = self
        dmc.apu = self

        let fcLP: Float = 12000.0
        let fs: Float = 44100.0
        let aLP = 1.0 - exp(-2.0 * Float.pi * fcLP / fs)
        self.lpAlpha = aLP

        let fcHP: Float = 90.0
        let dt = 1.0 / fs
        let RC = 1.0 / (2.0 * Float.pi * fcHP)
        self.hpAlpha = RC / (RC + dt)
    }

    func reset() {
        pulse1.reset()
        pulse2.reset()
        triangle.reset()
        noise.reset()
        dmc.reset()

        frameIRQFlag = false
        pendingFrameIRQ = false
        irqPending = false
        frameCycle = 0
        halfRateToggle = false
        frameMode5Step = false
        frameIRQInhibit = false
        pending4017write = -1
        pending4017value = 0

        lpY = 0.0
        hpY = 0.0
        hpX = 0.0
    }

    @inline(__always) func readStatus() -> UInt8 {
        var val: UInt8 = 0
        if pulse1.lengthCounter > 0 { val |= 0x01 }
        if pulse2.lengthCounter > 0 { val |= 0x02 }
        if triangle.lengthCounter > 0 { val |= 0x04 }
        if noise.lengthCounter > 0 { val |= 0x08 }
        if dmc.bytesRemaining > 0 { val |= 0x10 }

        if frameIRQFlag { val |= 0x40 }
        if dmc.irqFlag   { val |= 0x80 }

        irqPending = ((!frameIRQInhibit && frameIRQFlag) || dmc.irqFlag)

        frameIRQFlag = false

        return val
    }

    @inline(__always) func cpuWrite(address: UInt16, value: UInt8) {
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
            irqPending = ((!frameIRQInhibit && frameIRQFlag) || dmc.irqFlag)

        case 0x4017:
            pending4017value = value
            pending4017write = (cpuCycle % 2 == 0) ? 2 : 3

        default:
            break
        }
    }

    private func apply4017Write(_ value: UInt8) {
        frameMode5Step   = (value & 0x80) != 0
        frameIRQInhibit  = (value & 0x40) != 0
        if frameIRQInhibit { frameIRQFlag = false }

        frameCycle = 0
        halfRateToggle = false

        if frameMode5Step {
            clockQuarterFrame()
            clockHalfFrame()
        }
        irqPending = ((!frameIRQInhibit && frameIRQFlag) || dmc.irqFlag)
    }

    func tick() {
        cpuCycle &+= 1

        if pending4017write > 0 {
            pending4017write -= 1
            if pending4017write == 0 {
                apply4017Write(pending4017value)
            }
        }

        triangle.clockTimer()

        halfRateToggle.toggle()
        if halfRateToggle {
            pulse1.clockTimer()
            pulse2.clockTimer()
            noise.clockTimer()
            dmc.clockTimer()

            if !frameMode5Step {
                switch frameCycle {
                case 3728:
                    clockQuarterFrame()
                case 7456:
                    clockQuarterFrame()
                    clockHalfFrame()
                case 11185:
                    clockQuarterFrame()
                case 14914:
                    clockQuarterFrame()
                    clockHalfFrame()
                    if !frameIRQInhibit { pendingFrameIRQ = true }
                default:
                    break
                }
            } else {
                switch frameCycle {
                case 3728:
                    clockQuarterFrame()
                case 7456:
                    clockQuarterFrame()
                    clockHalfFrame()
                case 11185:
                    clockQuarterFrame()
                case 18640:
                    clockQuarterFrame()
                    clockHalfFrame()
                default:
                    break
                }
            }

            frameCycle &+= 1

            if !frameMode5Step {
                if frameCycle == 14915 { frameCycle = 0 }
            } else {
                if frameCycle == 18641 { frameCycle = 0 }
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

        let pulseSumRaw = Int(p1 + p2)
        let pulseSum = min(max(pulseSumRaw, 0), 30)

        let tndSumRaw = Int(3 * tri + 2 * noi + dm)
        let tndSum = min(max(tndSumRaw, 0), 202)

        let mixed = pulseTable[pulseSum] + tndTable[tndSum]

        let lpOut = lpY + lpAlpha * (mixed - lpY)
        lpY = lpOut

        let hpOut = hpAlpha * (hpY + lpOut - hpX)
        hpX = lpOut
        hpY = hpOut

        return hpOut
    }

    func consumeDMCStallCycles() -> Int {
        let cycles = dmcStallCycles
        dmcStallCycles = 0
        return cycles
    }
}
