import Foundation

final class APU {
    public var dmcStallCycles: Int = 0
    weak var bus: Bus?

    // Channels
    var pulse1 = PulseChannel(channel: 1)
    var pulse2 = PulseChannel(channel: 2)
    var triangle = TriangleChannel()
    var noise = NoiseChannel()
    var dmc = DMCChannel()

    // CPU / APU timing
    private var cpuCycle: UInt64 = 0

    // Half-rate divider (pulse/noise/dmc timers)
    private var halfRateToggle: Bool = false

    // Frame sequencer
    private var frameCycle: UInt32 = 0
    private var frameMode5Step: Bool = false
    private var frameIRQInhibit: Bool = false

    // IRQ model – exact Blargg hardware behavior (triple set + 2-cycle CPU delay)
    private var frameIRQPendingCycles: Int = 0
    private var frameIRQFlag: Bool = false   // ✅ ADD THIS
    var irqPending: Bool = false

    // $4017 write jitter (even = 2 cycles delay, odd = 3 cycles delay)
    private var pending4017write: Int = -1
    private var pending4017value: UInt8 = 0
    private var pending4017WasOdd: Bool = false
    
    // Length clocking helpers
    private var lengthClockedThisCycle: Bool = false

    // Halt flag pipeline – exact 1-cycle delay when setting halt
    private var haltDelayCountdown: Int = 0

    // Reload-immunity tracking
    private var reloadThisTickP1: Bool = false
    private var reloadThisTickP2: Bool = false
    private var reloadThisTickTri: Bool = false
    private var reloadThisTickNoise: Bool = false

    private var preClockLengthP1: UInt8 = 0
    private var preClockLengthP2: UInt8 = 0
    private var preClockLengthTri: UInt8 = 0
    private var preClockLengthNoise: UInt8 = 0

    // Correct hardware length table (fixes 02.len_table)
    let lengthTable: [UInt8] = [
        0x0A, 0xFE, 0x14, 0x02, 0x28, 0x04, 0x50, 0x06,
        0xA0, 0x08, 0x3C, 0x0A, 0x0E, 0x0C, 0x1A, 0x0E,
        0x0C, 0x10, 0x18, 0x12, 0x30, 0x14, 0x60, 0x16,
        0xC0, 0x18, 0x48, 0x1A, 0x10, 0x1C, 0x20, 0x1E
    ]

    // Audio tables & filters
    private var pulseTable = [Float](repeating: 0, count: 31)
    private var tndTable   = [Float](repeating: 0, count: 203)
    private var lpY: Float = 0.0
    private var lpAlpha: Float = 0.0
    private var hpY: Float = 0.0
    private var hpX: Float = 0.0
    private var hpAlpha: Float = 0.0
    private var outputSampleRate: Float = 48_000.0

    convenience init(sampleRate: Float) {
        self.init()
        self.outputSampleRate = max(8_000.0, sampleRate)
        configureFilters()
    }

    init() {
        outputSampleRate = 48_000.0

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

        configureFilters()
    }

    @inline(__always) private func configureFilters() {
        let fs = outputSampleRate
        let fcLP: Float = 12_000.0
        lpAlpha = 1.0 - exp(-2.0 * Float.pi * fcLP / fs)

        let fcHP: Float = 90.0
        let dt = 1.0 / fs
        let rc = 1.0 / (2.0 * Float.pi * fcHP)
        hpAlpha = rc / (rc + dt)
    }

    @inline(__always)
    func setOutputSampleRate(_ rate: Float) {
        let clamped = max(8_000.0, rate)
        guard abs(clamped - outputSampleRate) > 0.1 else { return }
        outputSampleRate = clamped
        configureFilters()
    }

    // MARK: - Reset (exact power-up behavior)
    @inline(__always)
    func reset() {
        pulse1.reset()
        pulse2.reset()
        triangle.reset()
        noise.reset()
        dmc.reset()

        cpuCycle = 0
        frameCycle = 0
        frameMode5Step = false
        frameIRQInhibit = false
        frameIRQPendingCycles = 0
        frameIRQFlag = false
        irqPending = false

        pending4017write = -1
        halfRateToggle = false
        haltDelayCountdown = 0

        lpY = 0
        hpY = 0
        hpX = 0

        pending4017write = -1   // ✅ NO delayed $4017 write on reset

    }


    // MARK: - $4015 read
    @inline(__always)
    func readStatus() -> UInt8 {
        var val: UInt8 = 0
        if pulse1.lengthCounter > 0   { val |= 0x01 }
        if pulse2.lengthCounter > 0   { val |= 0x02 }
        if triangle.lengthCounter > 0 { val |= 0x04 }
        if noise.lengthCounter > 0    { val |= 0x08 }
        if dmc.bytesRemaining > 0     { val |= 0x10 }
        if frameIRQFlag { val |= 0x40 }
        if dmc.irqFlag  { val |= 0x80 }

        frameIRQFlag = false          // clear visible flag on read
            // DMC fallback only
         // leave DMC alone
        return val

    }

    // MARK: - CPU Writes
    @inline(__always)
    func cpuWrite(address: UInt16, value: UInt8) {
        switch address {
        case 0x4000:
            let wasHalted = pulse1.lengthHalt
            pulse1.write(reg: 0, value: value)
            if pulse1.lengthHalt && !wasHalted { haltDelayCountdown = 1 }

        case 0x4001: pulse1.write(reg: 1, value: value)
        case 0x4002: pulse1.write(reg: 2, value: value)
        case 0x4003:
            pulse1.write(reg: 3, value: value)
            if pulse1.enabled {
                let index = (value >> 3) & 0x1F
                pulse1.lengthCounter = lengthTable[Int(index)]
            }
            if !lengthClockedThisCycle {
                reloadThisTickP1 = true
            }


        case 0x4004:
            let wasHalted = pulse2.lengthHalt
            pulse2.write(reg: 0, value: value)
            if pulse2.lengthHalt && !wasHalted { haltDelayCountdown = 1 }
        case 0x4005: pulse2.write(reg: 1, value: value)
        case 0x4006: pulse2.write(reg: 2, value: value)
        case 0x4007:
            pulse2.write(reg: 3, value: value)
            if pulse2.enabled {
                let index = (value >> 3) & 0x1F
                pulse2.lengthCounter = lengthTable[Int(index)]
            }
            if !lengthClockedThisCycle {
                reloadThisTickP2 = true
            }


        case 0x4008: triangle.write(reg: 0, value: value)
        case 0x400A: triangle.write(reg: 2, value: value)
        case 0x400B:
            triangle.write(reg: 3, value: value)
            if triangle.enabled {
                let index = (value >> 3) & 0x1F
                triangle.lengthCounter = lengthTable[Int(index)]
            }
            if !lengthClockedThisCycle {
                reloadThisTickTri = true
            }


        case 0x400C:
            let wasHalted = noise.lengthHalt
            noise.write(reg: 0, value: value)
            if noise.lengthHalt && !wasHalted { haltDelayCountdown = 1 }
        case 0x400E: noise.write(reg: 2, value: value)
        case 0x400F:
            noise.write(reg: 3, value: value)
            if noise.enabled {
                let index = (value >> 3) & 0x1F
                noise.lengthCounter = lengthTable[Int(index)]
            }
            if !lengthClockedThisCycle {
                reloadThisTickNoise = true
            }


        case 0x4010...0x4013: dmc.write(reg: UInt8(address & 3), value: value)

        case 0x4015:
            pulse1.enabled = (value & 0x01) != 0
            pulse2.enabled = (value & 0x02) != 0
            triangle.enabled = (value & 0x04) != 0
            noise.enabled = (value & 0x08) != 0
            dmc.enabled = (value & 0x10) != 0

            if !pulse1.enabled   { pulse1.lengthCounter = 0 }
            if !pulse2.enabled   { pulse2.lengthCounter = 0 }
            if !triangle.enabled { triangle.lengthCounter = 0 }
            if !noise.enabled    { noise.lengthCounter = 0 }

            if !dmc.enabled {
                dmc.bytesRemaining = 0
            } else if dmc.bytesRemaining == 0 {
                dmc.start()
            }
            dmc.irqFlag = false

        case 0x4017:
            pending4017value = value
            let evenCycle = (cpuCycle & 1) == 0
            pending4017WasOdd = !evenCycle          // ✅ STORE PARITY HERE
            pending4017write = evenCycle ? 2 : 3    // jitter delay

        default: break
        }
    }

    // MARK: - Apply pending $4017 write
    @inline(__always)
    private func apply4017(_ value: UInt8) {

        frameMode5Step = (value & 0x80) != 0
        frameIRQInhibit = (value & 0x40) != 0

        // ✅ Inhibit clears both delay and flag
        if frameIRQInhibit {
            frameIRQPendingCycles = 0
            frameIRQFlag = false
            irqPending = false
        }

        // ✅ Correct jitter-based frame start
        frameCycle = pending4017WasOdd ? 1 : 0

        // ✅ Immediate clock only in 5-step mode
        if frameMode5Step {
            clockQuarterFrame()
            clockHalfFrame()
        }
    }



    // MARK: - Main Tick
    @inline(__always)
    func tick() {
        cpuCycle &+= 1
        lengthClockedThisCycle = false

        // $4017 jitter handling
        if pending4017write > 0 {
            pending4017write -= 1
            if pending4017write == 0 {
                apply4017(pending4017value)
            }
        }

        triangle.clockTimer()

        // Frame sequencer – exact Blargg cycles
        if !frameMode5Step {
            // 4-step mode
            switch frameCycle {
            case 7457:  clockQuarterFrame()
            case 14913: clockQuarterFrame()
                        clockHalfFrame()
            case 22371: clockQuarterFrame()
            case 29829: clockQuarterFrame()
                        clockHalfFrame()
                        if !frameIRQInhibit {
                            frameIRQPendingCycles = 5   // 3 flag sets + 2 CPU delay → IRQ on 29833
                        }
            default: break
            }
        } else {
            // 5-step mode
            switch frameCycle {
            case 7457:  clockQuarterFrame()
            case 14913: clockQuarterFrame()
                        clockHalfFrame()
            case 22371: clockQuarterFrame()
            case 37281: clockQuarterFrame()
                        clockHalfFrame()
            default: break
            }
        }

        // Pulse / Noise / DMC timers (half rate)
        if halfRateToggle {
            pulse1.clockTimer()
            pulse2.clockTimer()
            noise.clockTimer()
            dmc.clockTimer()
        }
        halfRateToggle.toggle()

        // IRQ counter
        if frameIRQPendingCycles > 0 {
            frameIRQPendingCycles -= 1
            if frameIRQPendingCycles == 0 {
                frameIRQFlag = true     // ✅ latch for $4015
                irqPending = true      // ✅ CPU IRQ line
            }
        } else {
            irqPending = dmc.irqFlag
        }

        frameCycle &+= 1
    }

    // MARK: - Frame Clocks
    @inline(__always)
    private func clockQuarterFrame() {
        pulse1.clockEnvelope()
        pulse2.clockEnvelope()
        triangle.clockLinear()
        noise.clockEnvelope()
    }

    @inline(__always)
    private func clockHalfFrame() {

        if haltDelayCountdown > 0 {
            haltDelayCountdown -= 1
            if haltDelayCountdown > 0 { return }
        }

        lengthClockedThisCycle = true

        // ✅ Snapshot BEFORE clock
        preClockLengthP1 = pulse1.lengthCounter
        preClockLengthP2 = pulse2.lengthCounter
        preClockLengthTri = triangle.lengthCounter
        preClockLengthNoise = noise.lengthCounter

        // ✅ Clock sweeps + lengths
        pulse1.clockSweep(); pulse2.clockSweep()
        pulse1.clockLength(); pulse2.clockLength()
        triangle.clockLength()
        noise.clockLength()

        // ✅ UNDO reload if it happened AFTER the length clock
        if reloadThisTickP1 && preClockLengthP1 > 0 {
            pulse1.lengthCounter = preClockLengthP1
        }
        if reloadThisTickP2 && preClockLengthP2 > 0 {
            pulse2.lengthCounter = preClockLengthP2
        }
        if reloadThisTickTri && preClockLengthTri > 0 {
            triangle.lengthCounter = preClockLengthTri
        }
        if reloadThisTickNoise && preClockLengthNoise > 0 {
            noise.lengthCounter = preClockLengthNoise
        }

        // ✅ Clear flags
        reloadThisTickP1 = false
        reloadThisTickP2 = false
        reloadThisTickTri = false
        reloadThisTickNoise = false
    }



    // MARK: - Audio Output
    @inline(__always)
    func outputSample() -> Float {
        let p1  = Int(pulse1.output)
        let p2  = Int(pulse2.output)
        let tri = Int(triangle.output)
        let noi = Int(noise.output)
        let dm  = Int(dmc.output)

        var pulseSum = p1 + p2
        if pulseSum < 0 { pulseSum = 0 }
        else if pulseSum > 30 { pulseSum = 30 }

        var tndSum = 3 * tri + 2 * noi + dm
        if tndSum < 0 { tndSum = 0 }
        else if tndSum > 202 { tndSum = 202 }

        let mixed = pulseTable[pulseSum] + tndTable[tndSum]

        let lpOut = lpY + lpAlpha * (mixed - lpY)
        lpY = lpOut

        let hpOut = hpAlpha * (hpY + lpOut - hpX)
        hpX = lpOut
        hpY = hpOut

        var out = hpOut * 0.5
        if out > 1.0 { out = 1.0 }
        if out < -1.0 { out = -1.0 }
        return out
    }

    @inline(__always)
    func consumeDMCStallCycles() -> Int {
        let cycles = dmcStallCycles
        dmcStallCycles = 0
        return cycles
    }
}
