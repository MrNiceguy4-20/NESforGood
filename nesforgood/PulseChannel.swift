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
    
    func write(reg: UInt8, value: UInt8) {
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
            if enabled { lengthCounter = PulseChannel.lengthTable[Int(value >> 3)] }
            sequencer = 0
            envelopeStart = true
        default: break
        }
    }
    
    func clockTimer() {
        if timer == 0 {
            timer = period
            sequencer = (sequencer &+ 1) & 7
        } else {
            timer &-= 1
        }
    }
    
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
    
    func clockSweep() {
        let targetInt = calculateTarget()
        let muted = isMuted()
        
        if sweepDivider == 0 && sweepEnable && sweepShift > 0 && !muted {
            period = UInt16(max(0, min(0x7FF, targetInt)))
        }
        
        if sweepDivider == 0 || sweepReload {
            sweepDivider = sweepPeriod
            sweepReload = false
        } else {
            sweepDivider &-= 1
        }
    }
    
    private func calculateTarget() -> Int {
        let shifted = Int(period) >> Int(sweepShift)
        var change = shifted
        if sweepNegate {
            change = -shifted
            if channel == 1 { change &-= 1 }
        }
        var targetInt = Int(period) &+ change
        if targetInt < 0 { targetInt = 0 }
        return targetInt
    }
    
    func isMuted() -> Bool {
        let targetInt = calculateTarget()
        return period < 8 || targetInt > 0x7FF
    }
    
    func clockLength() {
        if !lengthHalt && lengthCounter > 0 { lengthCounter &-= 1 }
    }
    
    var output: UInt8 {
        if !enabled || lengthCounter == 0 || isMuted() { return 0 }
        if PulseChannel.dutyTables[Int(duty)][Int(sequencer)] == 0 { return 0 }
        return constantVolume ? volume : decayLevel
    }
}
