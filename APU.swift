import Foundation

final class APU {
    public var dmcStallCycles: Int = 0
    weak var bus: Bus?

    // MARK: - Channels
    var pulse1 = PulseChannel(channel: 1)
    var pulse2 = PulseChannel(channel: 2)
    var triangle = TriangleChannel()
    var noise = NoiseChannel()
    var dmc = DMCChannel()

    // MARK: - Timing
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

    // MARK: - Mixing tables
    private var pulseTable = [Float](repeating: 0, count: 31)
    private var tndTable = [Float](repeating: 0, count: 203)

    // MARK: - Filters
    private var lpY: Float = 0.0
    private var lpAlpha: Float = 0.0
    private var hpY: Float = 0.0
    private var hpX: Float = 0.0
    private var hpAlpha: Float = 0.0

    // MARK: - Dynamic sample rate support
    private var outputSampleRate: Float = 44_100.0

    // MARK: - Initializers

    convenience init(sampleRate: Float) {
        self.init()
        self.outputSampleRate = max(8_000.0, sampleRate)
        configureFilters()
    }

    init() {
        outputSampleRate = 44_100.0

        // NES pulse output lookup table
        pulseTable[0] = 0.0
        for i in 1..<31 {
            pulseTable[i] = 95.52 / (8128.0 / Float(i) + 100.0)
        }

        // NES triangle/noise/DMC (TND) mixer lookup table
        tndTable[0] = 0.0
        for i in 1..<203 {
            tndTable[i] = 163.67 / (24329.0 / Float(i) + 100.0)
        }

        pulse1.apu = self
        pulse2.apu = self
        triangle.apu = self
        noise.apu = self
        dmc.apu = self

        configureFilters()
    }

    // MARK: - Filters

    private func configureFilters() {
        let fs = max(8_000.0, outputSampleRate)

        // Low-pass (~12 kHz)
        let fcLP: Float = 12_000.0
        lpAlpha = 1.0 - exp(-2.0 * .pi * fcLP / fs)

        // High-pass (~90 Hz)
        let fcHP: Float = 90.0
        let dt = 1.0 / fs
        let rc = 1.0 / (2.0 * .pi * fcHP)
        hpAlpha = rc / (rc + dt)
    }

    func setOutputSampleRate(_ rate: Float) {
        let clamped = max(8_000.0, rate)
        guard abs(clamped - outputSampleRate) > 0.1 else { return }
        outputSampleRate = clamped
        configureFilters()
    }

    // MARK: - Reset

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

    // MARK: - CPU Register Reads

    @inline(__always)
    func readStatus() -> UInt8 {
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

    // MARK: - CPU Register Writes

    @inline(__always)
    func cpuWrite(address: UInt16, value: UInt8) {
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
            pulse1.enabled   = (value & 0x01) != 0
            pulse2.enabled   = (value & 0x02) != 0
            triangle.enabled = (value & 0x04) != 0
            noise.enabled    = (value & 0x08) != 0
            dmc.enabled      = (value & 0x10) != 0

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
            pending4017write = (cpuCycle & 1) == 0 ? 2 : 3

        default:
            break
        }
    }

    // MARK: - Frame Counter Writes

    @inline(__always)
    private func apply4017Write(_ value: UInt8) {
        frameMode5Step  = (value & 0x80) != 0
        frameIRQInhibit = (value & 0x40) != 0
        if frameIRQInhibit { frameIRQFlag = false }

        frameCycle = 0
        halfRateToggle = false

        if frameMode5Step {
            clockQuarterFrame()
            clockHalfFrame()
        }

        irqPending = ((!frameIRQInhibit && frameIRQFlag) || dmc.irqFlag)
    }

    // MARK: - Tick

    @inline(__always)
    func tick() {
        cpuCycle &+= 1

        // Handle delayed write to $4017
        if pending4017write > 0 {
            pending4017write &-= 1
            if pending4017write == 0 {
                apply4017Write(pending4017value)
            }
        }

        // Triangle clocks every CPU cycle
        triangle.clockTimer()

        // Others clock at half CPU rate
        halfRateToggle.toggle()
        if halfRateToggle {
            pulse1.clockTimer()
            pulse2.clockTimer()
            noise.clockTimer()
            dmc.clockTimer()

            if !frameMode5Step {
                switch frameCycle {
                case 3728: clockQuarterFrame()
                case 7456: clockQuarterFrame(); clockHalfFrame()
                case 11_185: clockQuarterFrame()
                case 14_914:
                    clockQuarterFrame()
                    clockHalfFrame()
                    if !frameIRQInhibit { pendingFrameIRQ = true }
                default: break
                }
            } else {
                switch frameCycle {
                case 3728: clockQuarterFrame()
                case 7456: clockQuarterFrame(); clockHalfFrame()
                case 11_185: clockQuarterFrame()
                case 18_640: clockQuarterFrame(); clockHalfFrame()
                default: break
                }
            }

            frameCycle &+= 1

            if !frameMode5Step {
                if frameCycle == 14_915 { frameCycle = 0 }
            } else {
                if frameCycle == 18_641 { frameCycle = 0 }
            }
        }

        if pendingFrameIRQ {
            frameIRQFlag = true
            pendingFrameIRQ = false
        }

        irqPending = ((!frameIRQInhibit && frameIRQFlag) || dmc.irqFlag)
    }

    // MARK: - Envelope & Sweep

    @inline(__always)
    private func clockQuarterFrame() {
        pulse1.clockEnvelope()
        pulse2.clockEnvelope()
        triangle.clockLinear()
        noise.clockEnvelope()
    }

    @inline(__always)
    private func clockHalfFrame() {
        pulse1.clockLength()
        pulse1.clockSweep()
        pulse2.clockLength()
        pulse2.clockSweep()
        triangle.clockLength()
        noise.clockLength()
    }

    // MARK: - Output Mixer

    @inline(__always)
    func outputSample() -> Float {
        let p1  = Float(pulse1.output)
        let p2  = Float(pulse2.output)
        let tri = Float(triangle.output)
        let noi = Float(noise.output)
        let dm  = Float(dmc.output)

        var pulseSum = Int(p1 + p2)
        if pulseSum < 0 { pulseSum = 0 }
        else if pulseSum > 30 { pulseSum = 30 }

        var tndSum = Int(3 * tri + 2 * noi + dm)
        if tndSum < 0 { tndSum = 0 }
        else if tndSum > 202 { tndSum = 202 }

        let mixed = pulseTable[pulseSum] + tndTable[tndSum]

        // Low-pass
        let lpOut = lpY + lpAlpha * (mixed - lpY)
        lpY = lpOut

        // High-pass
        let hpOut = hpAlpha * (hpY + lpOut - hpX)
        hpX = lpOut
        hpY = hpOut

        var out = hpOut * 0.9
        if out > 1.0 { out = 1.0 }
        if out < -1.0 { out = -1.0 }
        return out
    }

    // MARK: - DMC Stall Cycles

    @inline(__always)
    func consumeDMCStallCycles() -> Int {
        let cycles = dmcStallCycles
        dmcStallCycles = 0
        return cycles
    }
}
