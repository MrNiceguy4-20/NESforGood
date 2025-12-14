class PulseChannel {
    weak var apu: APU?
    let channel: Int

    var enabled: Bool = false
    var duty: UInt8 = 0
    var lengthHalt: Bool = false
    var constantVolume: Bool = false
    var volume: UInt8 = 0

    var envelopeStart: Bool = false
    var envelopeDivider: UInt8 = 0
    var decayLevel: UInt8 = 0

    var sweepEnable: Bool = false
    var sweepPeriod: UInt8 = 0
    var sweepNegate: Bool = false
    var sweepShift: UInt8 = 0
    var sweepReload: Bool = false
    var sweepDivider: UInt8 = 0

    var period: UInt16 = 0
    var timer: UInt16 = 0
    var lengthCounter: UInt8 = 0
    var sequencer: UInt8 = 0

    static let dutyTables: [[UInt8]] = [
        [0,1,0,0,0,0,0,0],
        [0,1,1,0,0,0,0,0],
        [0,1,1,1,1,0,0,0],
        [1,0,0,1,1,1,1,1]
    ]

    static let lengthTable: [UInt8] = [
        10,254,20,2,40,4,80,6,160,8,60,10,14,12,26,14,
        12,16,24,18,48,20,96,22,192,24,72,26,16,28,32,30
    ]

    init(channel: Int) { self.channel = channel }

    @inline(__always) func reset() {
        enabled = false
        lengthCounter = 0
        sequencer = 0
        timer = 0
        period = 0
        envelopeStart = false
        decayLevel = 0
        sweepEnable = false
        sweepReload = false
        sweepDivider = 0
    }

    @inline(__always) func write(reg: UInt8, value: UInt8) {
        switch reg {
        case 0:
            duty = value >> 6
            lengthHalt = (value & 0x20) != 0
            constantVolume = (value & 0x10) != 0
            volume = value & 0x0F
        case 1:
            sweepEnable = (value & 0x80) != 0
            sweepPeriod = (value >> 4) & 0x07
            sweepNegate = (value & 0x08) != 0
            sweepShift  = value & 0x07
            sweepReload = true
        case 2:
            period = (period & 0xFF00) | UInt16(value)
        case 3:
            period = (period & 0x00FF) | (UInt16(value & 0x07) << 8)
            if enabled { lengthCounter = PulseChannel.lengthTable[Int(((value >> 3) & 0x1F) & 0x1F)] }
            sequencer = 0
            envelopeStart = true
        default: break
        }
    }

    @inline(__always)
    func clockTimer() {
        if timer == 0 {
            timer = period
            sequencer = (sequencer &+ 1) & 7
        } else {
            timer &-= 1
        }
    }

    @inline(__always)
    func clockEnvelope() {
        if envelopeStart {
            decayLevel = 15
            envelopeDivider = volume
            envelopeStart = false
        } else if envelopeDivider == 0 {
            envelopeDivider = volume
            if decayLevel > 0 { decayLevel &-= 1 }
            else if lengthHalt { decayLevel = 15 }
        } else {
            envelopeDivider &-= 1
        }
    }

    @inline(__always)
    func clockSweep() {
        if sweepDivider == 0 || sweepReload {
            sweepDivider = sweepPeriod
            sweepReload = false
        } else {
            sweepDivider &-= 1
        }

        if sweepDivider == 0 && sweepEnable && sweepShift > 0 && period >= 8 {
            let target = calculateTarget()
            if target <= 0x7FF {
                period = UInt16(target)
            }
        }
    }

    @inline(__always)
    private func calculateTarget() -> Int {
        let delta = Int(period >> sweepShift)
        if sweepNegate {
            var negated = -delta
            if channel == 1 {
                negated &-= 1
            }
            return Int(period) + negated
        } else {
            return Int(period) + delta
        }
    }

    @inline(__always)
    private func isMuted() -> Bool {
        return period < 8 || calculateTarget() > 0x7FF
    }

    @inline(__always)
    func clockLength() {
        if !lengthHalt && lengthCounter > 0 { lengthCounter &-= 1 }
    }

    var output: UInt8 {
        if !enabled || lengthCounter == 0 || isMuted() { return 0 }
        if PulseChannel.dutyTables[Int(duty)][Int(sequencer)] == 0 { return 0 }
        return constantVolume ? volume : decayLevel
    }
}
