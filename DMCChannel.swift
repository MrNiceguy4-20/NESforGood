final class DMCChannel {
    weak var apu: APU?
    
    var enabled: Bool = false
    var irqEnable: Bool = false
    var loop: Bool = false
    var rateIndex: UInt8 = 0
    var directLoad: UInt8 = 0
    var sampleAddress: UInt16 = 0
    var sampleLength: UInt16 = 0
    
    var currentAddress: UInt16 = 0
    var bytesRemaining: UInt16 = 0
    var shiftRegister: UInt8 = 0
    var bitCount: UInt8 = 8
    var output: UInt8 = 0
    var timer: UInt16 = 0
    var irqFlag: Bool = false
    var silence: Bool = true
    
    static let rateTable: [UInt16] = [
        428, 380, 340, 320, 286, 254, 226, 214,
        190, 160, 142, 128, 106,  84,  72,  54
    ]
    
    func reset() {
        irqFlag = false
    }
    
    func write(reg: UInt8, value: UInt8) {
        switch reg {
        case 0:
            irqEnable = (value & 0x80) != 0
            loop      = (value & 0x40) != 0
            rateIndex = value & 0x0F
            if !irqEnable { irqFlag = false }
        case 1:
            directLoad = value & 0x7F
            output = directLoad
        case 2:
            sampleAddress = 0xC000 + UInt16(value) * 64
        case 3:
            sampleLength = UInt16(value) * 16 + 1
        default: break
        }
    }
    
    func start() {
        currentAddress = sampleAddress
        bytesRemaining = sampleLength
        shiftRegister  = 0
        bitCount       = 8
        timer          = DMCChannel.rateTable[Int(rateIndex)]
        silence        = true
        irqFlag        = false
    }
    
    private func fetchNextByte() {
        guard let bus = apu?.bus else { return }
        let byte = bus.cpuRead(address: currentAddress)
        apu?.dmcStallCycles &+= 4  // or 3 on PAL, but 4 is safe
        
        shiftRegister = byte
        silence = false                     // This is essential
        bitCount = 8                        // Already set above, but safe
        
        currentAddress &+= 1
        if currentAddress == 0 { currentAddress = 0x8000 }
        
        bytesRemaining &-= 1
        if bytesRemaining == 0 {
            if loop {
                start()
            } else if irqEnable {
                irqFlag = true
            }
        }
    }
    
    @inline(__always)
    func clockTimer() {
        if timer > 0 {
            timer &-= 1
            return
        }
        
        // Timer expired → clock the DPCM output unit
        timer = DMCChannel.rateTable[Int(rateIndex)]
        
        // Process current bit (if we have one)
        if !silence {
            if (shiftRegister & 1) != 0 {
                if output <= 125 { output &+= 2 }
            } else {
                if output >= 2 { output &-= 2 }
            }
        }
        
        // Always shift — even if silence, so bitCount stays in sync
        shiftRegister >>= 1
        bitCount &-= 1
        
        // When we've shifted out all 8 bits...
        if bitCount == 0 {
            bitCount = 8
            
            if bytesRemaining > 0 {
                fetchNextByte()        // Loads new byte → silence = false inside fetchNextByte()
            } else {
                // No more data → go silent immediately
                // Do NOT feed a phantom 0 bit
                silence = true
            }
        }
    }
}
