class NoiseChannel {
    weak var apu: APU?
    var enabled: Bool = false
    var lengthHalt: Bool = false
    var constantVolume: Bool = false
    var volume: UInt8 = 0
    var envelopeStart: Bool = false
    var envelopeDivider: UInt8 = 0
    var decayLevel: UInt8 = 0
    var mode: Bool = false
    var periodIndex: UInt8 = 0
    var lengthCounter: UInt8 = 0
    var timer: UInt16 = 0
    var shiftRegister: UInt16 = 1
    
    static let periodTable: [UInt16] = [
        4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068
    ]
    
    static let lengthTable = PulseChannel.lengthTable
    
    func reset() {
        enabled = false
        lengthCounter = 0
        timer = 0
        shiftRegister = 1
        envelopeStart = false
        decayLevel = 0
    }
    
    func write(reg: UInt8, value: UInt8) {
        switch reg {
        case 0:
            lengthHalt = (value & 0x20) != 0
            constantVolume = (value & 0x10) != 0
            volume = value & 0x0F
        case 2:
            mode = (value & 0x80) != 0
            periodIndex = value & 0x0F
        case 3:
            if enabled { lengthCounter = NoiseChannel.lengthTable[Int(value >> 3)] }
            envelopeStart = true
        default: break
        }
    }
    
    func clockTimer() {
        if timer == 0 {
            timer = NoiseChannel.periodTable[Int(periodIndex)]
            let feedback = (shiftRegister & 1) ^ ((shiftRegister >> (mode ? 6 : 1)) & 1)
            shiftRegister = (shiftRegister >> 1) | (feedback << 14)
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
    
    func clockLength() {
        if !lengthHalt && lengthCounter > 0 { lengthCounter &-= 1 }
    }
    
    var output: UInt8 {
        if !enabled || lengthCounter == 0 || (shiftRegister & 1) != 0 { return 0 }
        return constantVolume ? volume : decayLevel
    }
}
