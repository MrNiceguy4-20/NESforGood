final class MMC3Mapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private(set) var mirroring: Mirroring
    private var bankSelect: UInt8 = 0
    private var bankData = [UInt8](repeating: 0, count: 8)
    private var prgMode: Bool { (bankSelect & 0x40) != 0 }
    private var chrMode: Bool { (bankSelect & 0x80) != 0 }
    private var irqLatch: UInt8 = 0
    private var irqCounter: UInt8 = 0
    private var irqReload: Bool = false
    private var irqEnabled: Bool = false
    private var irqAsserted: Bool = false
    private var lastA12High: Bool = false
    private var lastEdgeDot: UInt64 = 0
    private var a12HighCount: UInt8 = 0
    private let a12Debounce: UInt64 = 12
    private let a12HighThreshold: UInt8 = 2
    private var irqPendingDelay: UInt64 = 0
    private let irqDelayCycles: UInt64 = 8
    private let prgBankSize = 8192
    private let chr1K = 1024
    
    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring
        self.bankSelect = 0
        self.bankData = [UInt8](repeating: 0, count: 8)
        self.irqLatch = 0
        self.irqCounter = 0
        self.irqReload = false
        self.irqEnabled = false
        self.irqAsserted = false
        self.lastA12High = false
        self.lastEdgeDot = 0
        self.a12HighCount = 0
        self.irqPendingDelay = 0
    }
    
    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            return prgRAM?.data[Int(address - 0x6000)] ?? 0
        case 0x8000...0x9FFF:
            let bank = prgMode ? prgROM.count / prgBankSize - 2 : Int(bankData[6])
            let off = Int(address & 0x1FFF)
            return prgROM[(bank * prgBankSize + off) % prgROM.count]
        case 0xA000...0xBFFF:
            let bank = Int(bankData[7])
            let off = Int(address & 0x1FFF)
            return prgROM[(bank * prgBankSize + off) % prgROM.count]
        case 0xC000...0xDFFF:
            let bank = prgMode ? Int(bankData[6]) : prgROM.count / prgBankSize - 2
            let off = Int(address & 0x1FFF)
            return prgROM[(bank * prgBankSize + off) % prgROM.count]
        case 0xE000...0xFFFF:
            let bank = prgROM.count / prgBankSize - 1
            let off = Int(address & 0x1FFF)
            return prgROM[bank * prgBankSize + off]
        default:
            return 0
        }
    }
    
    func cpuWrite(address: UInt16, value: UInt8) {
        switch address {
        case 0x6000...0x7FFF:
            prgRAM?.data[Int(address - 0x6000)] = value
        case 0x8000...0x9FFE where address % 2 == 0:
            bankSelect = value
        case 0x8001...0x9FFF where address % 2 == 1:
            bankData[Int(bankSelect & 0x07)] = value
        case 0xA000...0xBFFE where address % 2 == 0:
            mirroring = (value & 0x01) == 0 ? .vertical : .horizontal
        case 0xA001...0xBFFF where address % 2 == 1:
            _ = value 
        case 0xC000...0xDFFE where address % 2 == 0:
            irqLatch = value
        case 0xC001...0xDFFF where address % 2 == 1:
            irqReload = true
        case 0xE000...0xFFFE where address % 2 == 0:
            irqEnabled = false
            irqAsserted = false
        case 0xE001...0xFFFF where address % 2 == 1:
            irqEnabled = true
        default:
            break
        }
    }
    
    func ppuRead(address: UInt16) -> UInt8 {
        guard !chr.data.isEmpty else { return 0 }
        let a = Int(address & 0x1FFF)
        let r0 = Int(bankData[0] & 0xFE) * chr1K
        let r1 = Int(bankData[1] & 0xFE) * chr1K
        let r2 = Int(bankData[2]) * chr1K
        let r3 = Int(bankData[3]) * chr1K
        let r4 = Int(bankData[4]) * chr1K
        let r5 = Int(bankData[5]) * chr1K
        let idx: Int
        if !chrMode {
            if a < 0x0400 { idx = r0 + a }
            else if a < 0x0800 { idx = r0 + chr1K + (a - 0x0400) }
            else if a < 0x0C00 { idx = r1 + (a - 0x0800) }
            else if a < 0x1000 { idx = r1 + chr1K + (a - 0x0C00) }
            else if a < 0x1400 { idx = r2 + (a - 0x1000) }
            else if a < 0x1800 { idx = r3 + (a - 0x1400) }
            else if a < 0x1C00 { idx = r4 + (a - 0x1800) }
            else { idx = r5 + (a - 0x1C00) }
        } else {
            if a < 0x0400 { idx = r2 + a }
            else if a < 0x0800 { idx = r3 + (a - 0x0400) }
            else if a < 0x0C00 { idx = r4 + (a - 0x0800) }
            else if a < 0x1000 { idx = r5 + (a - 0x0C00) }
            else if a < 0x1400 { idx = r0 + (a - 0x1000) }
            else if a < 0x1800 { idx = r0 + chr1K + (a - 0x1400) }
            else if a < 0x1C00 { idx = r1 + (a - 0x1800) }
            else { idx = r1 + chr1K + (a - 0x1C00) }
        }
        return chr.data[idx % chr.data.count]
    }
    
    func ppuWrite(address: UInt16, value: UInt8) {
        if chr.isRAM {
            let idx = Int(address) % chr.data.count
            chr.data[idx] = value
        }
    }
    
    func ppuA12Observe(addr: UInt16, ppuDot: UInt64) {
        let a12High = (addr & 0x1000) != 0
        if a12High && !lastA12High {
            if ppuDot >= lastEdgeDot + a12Debounce {
                a12HighCount += 1
                if a12HighCount >= a12HighThreshold {
                    onA12RisingEdge()
                    lastEdgeDot = ppuDot
                    a12HighCount = 0
                }
            }
        } else if !a12High {
        }
        lastA12High = a12High
    }
    
    private func onA12RisingEdge() {
        if !irqEnabled { return }
        if irqReload {
            irqCounter = irqLatch
            irqReload = false
        } else if irqCounter == 0 {
            if irqLatch == 0 {
                irqPendingDelay = irqDelayCycles
            } else {
                irqCounter = irqLatch
            }
        } else {
            irqCounter -= 1
        }
        if irqCounter == 0 && irqEnabled {
            irqPendingDelay = irqDelayCycles
        }
    }
    
    func tickPPUCycles(_ cycles: UInt64) {
        if irqPendingDelay > 0 {
            if irqPendingDelay > cycles {
                irqPendingDelay -= cycles
            } else {
                if !irqReload {
                    irqPendingDelay = 0
                    irqAsserted = true
                }
            }
        }
    }
    
    func mapperIRQAsserted() -> Bool {
        return irqAsserted
    }
    
    func mapperIRQClear() {
        irqAsserted = false
    }
}
