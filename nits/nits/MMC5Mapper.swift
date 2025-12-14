final class MMC5Mapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    public private(set) var mirroring: Mirroring
    public private(set) var prgMode: UInt8 = 3
    public private(set) var chrMode: UInt8 = 3
    private var prgRamProtect1: UInt8 = 0
    private var prgRamProtect2: UInt8 = 0
    public private(set) var extRamMode: UInt8 = 0
    public private(set) var nametableMap: UInt8 = 0
    public private(set) var fillTile: UInt8 = 0
    public private(set) var fillColor: UInt8 = 0
    private var prgBanks = [UInt8](repeating: 0, count: 5)
    private var chrBanks = [UInt8](repeating: 0, count: 12)
    private var chrUpper: UInt8 = 0
    public private(set) var splitEnabled: Bool = false
    public private(set) var splitSide: Bool = false
    public private(set) var splitThreshold: UInt8 = 0
    public private(set) var splitScroll: UInt8 = 0
    public private(set) var splitChrBank: UInt8 = 0
    
    // --- ACCESS CONTROL FIXES FOR PPU WRITE ---
    public var scanlineTarget: UInt8 = 0 // Needs to be readable/writable by PPU
    public var irqEnabled: Bool = false     // Needs to be readable/writable by PPU
    public var irqPending: Bool = false     // Needs to be readable/writable by PPU
    public var inFrame: Bool = false        // Needs to be readable/writable by PPU
    public var scanlineCounter: UInt8 = 0   // Needs to be readable/writable by PPU
    // --- END FIXES ---

    private var lastPpuAddr: UInt16 = 0
    private var matchCount: UInt8 = 0
    private var lastEdgeDot: UInt64 = 0
    public private(set) var extAttrEnabled: Bool = false
    private var eightBySixteen: Bool = false
    private let prgBankSize8K = 8192
    private let chr1K = 1024

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        if let existingRAM = prgRAM {
            self.prgRAM = existingRAM
        } else {
            self.prgRAM = ExtRAM(size: 64 * 1024)
        }
        self.mirroring = mirroring
        reset()
    }
    
    @inline(__always) func reset() {
        prgMode = 3
        chrMode = 3
        prgRamProtect1 = 0
        prgRamProtect2 = 0
        extRamMode = 0
        nametableMap = 0
        fillTile = 0
        fillColor = 0
        prgBanks = [UInt8](repeating: 0, count: 5)
        chrBanks = [UInt8](repeating: 0, count: 12)
        chrUpper = 0
        splitEnabled = false
        splitSide = false
        splitThreshold = 0
        splitScroll = 0
        splitChrBank = 0
        scanlineTarget = 0
        irqEnabled = false
        irqPending = false
        inFrame = false
        scanlineCounter = 0
        lastPpuAddr = 0
        matchCount = 0
        lastEdgeDot = 0
        extAttrEnabled = false
        eightBySixteen = false
    }

    @inline(__always)
    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x5C00...0x5FFF:
            switch extRamMode {
            case 2: return prgRAM?.data[Int(address - 0x5C00)] ?? 0
            case 3: return prgRAM?.data[Int(address - 0x5C00)] ?? 0
            default: return 0
            }
        case 0x6000...0x7FFF:
            if prgRamEnabled {
                let bank = Int(prgBanks[0] & 0x07)
                let off = Int(address - 0x6000)
                return prgRAM?.data[(bank * 8192 + off) % (prgRAM?.size ?? 1)] ?? 0
            }
            return 0
        case 0x8000...0xFFFF:
            return prgRomRead(address: address)
        case 0x5204:
            let s = inFrame ? 0x40 : 0
            let p = irqPending ? 0x80 : 0
            irqPending = false
            return UInt8(s | p)
        default:
            return 0
        }
    }

    @inline(__always)
    func cpuWrite(address: UInt16, value: UInt8) {
        switch address {
        case 0x5100:
            prgMode = value & 0x03
        case 0x5101:
            chrMode = value & 0x03
        case 0x5102:
            prgRamProtect1 = value & 0x03
        case 0x5103:
            prgRamProtect2 = value & 0x03
        case 0x5104:
            extRamMode = value & 0x03
            extAttrEnabled = (extRamMode == 1)
        case 0x5105:
            nametableMap = value
        case 0x5106:
            fillTile = value
        case 0x5107:
            fillColor = value & 0x03
        case 0x5113...0x5117:
            prgBanks[Int(address - 0x5113)] = value
        case 0x5120...0x512B:
            chrBanks[Int(address - 0x5120)] = value
        case 0x5130:
            chrUpper = value & 0x03
        case 0x5200:
            splitEnabled = (value & 0x80) != 0
            splitSide = (value & 0x40) != 0
            splitThreshold = value & 0x3F
        case 0x5201:
            splitScroll = value
        case 0x5202:
            splitChrBank = value
        case 0x5203:
            scanlineTarget = value
        case 0x5204:
            irqEnabled = (value & 0x80) != 0
        case 0x5C00...0x5FFF:
            if extRamMode == 0 || extRamMode == 1 {
                prgRAM?.data[Int(address - 0x5C00)] = value
            } else if extRamMode == 2 {
                prgRAM?.data[Int(address - 0x5C00)] = value
            }
        case 0x6000...0x7FFF:
            if prgRamEnabled {
                let bank = Int(prgBanks[0] & 0x07)
                let off = Int(address - 0x6000)
                prgRAM?.data[(bank * 8192 + off) % (prgRAM?.size ?? 1)] = value
            }
        default:
            break
        }
    }

    private var prgRamEnabled: Bool {
        prgRamProtect1 == 0x02 && prgRamProtect2 == 0x01
    }

    @inline(__always)
    private func prgRomRead(address: UInt16) -> UInt8 {
        let a = Int(address) - 0x8000
        let lastBank = (prgROM.count / prgBankSize8K) - 1
        switch prgMode {
        case 0:
            let bank = Int(prgBanks[4] & 0x7F) & ~3
            return prgROM[(bank * prgBankSize8K + a) % prgROM.count]
        case 1:
            if a < 0x4000 {
                let bank = Int(prgBanks[2] & 0x7F) & ~1
                return prgBanks[2] & 0x80 != 0 ? prgRamRead(bank: bank, off: a) : prgROM[(bank * prgBankSize8K + a) % prgROM.count]
            } else {
                let bank = Int(prgBanks[4] & 0x7F) & ~1
                return prgROM[(bank * prgBankSize8K + (a - 0x4000)) % prgROM.count]
            }
        case 2:
            if a < 0x4000 {
                let bank = Int(prgBanks[2] & 0x7F) & ~1
                return prgBanks[2] & 0x80 != 0 ? prgRamRead(bank: bank, off: a) : prgROM[(bank * prgBankSize8K + a) % prgROM.count]
            } else if a < 0x6000 {
                let bank = Int(prgBanks[3] & 0x7F)
                return prgBanks[3] & 0x80 != 0 ? prgRamRead(bank: bank, off: a - 0x4000) : prgROM[(bank * prgBankSize8K + (a - 0x4000)) % prgROM.count]
            } else {
                let bank = Int(prgBanks[4] & 0x7F)
                return prgROM[(bank * prgBankSize8K + (a - 0x6000)) % prgROM.count]
            }
        case 3:
            let slot = a / prgBankSize8K
            let regIndex = slot + 1
            let bank = Int(prgBanks[regIndex] & 0x7F)
            let off = a % prgBankSize8K
            if prgBanks[regIndex] & 0x80 != 0 && slot < 3 {
                return prgRamRead(bank: bank, off: off)
            } else {
                let finalBank = slot == 3 ? lastBank : bank
                return prgROM[(finalBank * prgBankSize8K + off) % prgROM.count]
            }
        default:
            return 0
        }
    }

    @inline(__always)
    private func prgRamRead(bank: Int, off: Int) -> UInt8 {
        prgRAM?.data[(bank * prgBankSize8K + off) % (prgRAM?.size ?? 1)] ?? 0
    }

    @inline(__always)
    func ppuRead(address: UInt16) -> UInt8 {
        let a = Int(address & 0x1FFF)
        let bank = getChrBank(for: address)
        let idx = (bank * chr1K + a) % chr.data.count
        
        if extAttrEnabled {
            // Placeholder
        }
        
        return chr.data[idx]
    }

    @inline(__always)
    func ppuWrite(address: UInt16, value: UInt8) {
        if chr.isRAM {
            let a = Int(address & 0x1FFF)
            let bank = getChrBank(for: address)
            chr.data[(bank * chr1K + a) % chr.data.count] = value
        }
    }

    @inline(__always)
    private func getChrBank(for address: UInt16) -> Int {
        let slot = Int(address) / chrSlotSize
        guard slot >= 0 && slot < chrRegsForSlot.count else { return 0 }
        let reg = chrRegsForSlot[slot]
        var bank = Int(chrBanks[reg])
        
        switch chrMode {
        case 2, 3:
            bank |= Int(chrUpper) << 8
        default: break
        }
        
        if extAttrEnabled {
            bank = Int(chrUpper) << 6 | (bank & 0x3F)
        }
        return bank
    }

    private var chrSlotSize: Int {
        switch chrMode {
        case 0: return 8192
        case 1: return 4096
        case 2: return 2048
        case 3: return 1024
        default: return 1024
        }
    }

    private var chrRegsForSlot: [Int] {
        switch chrMode {
        case 0: return [11, 11, 11, 11, 11, 11, 11, 11]
        case 1: return [3, 3, 3, 3, 11, 11, 11, 11]
        case 2: return [1, 1, 3, 3, 9, 9, 11, 11]
        case 3: return [0, 1, 2, 3, 8, 9, 10, 11]
        default: return [0, 1, 2, 3, 8, 9, 10, 11]
        }
    }
    
    @inline(__always)
    func clockScanlineCounter() {
        // This method satisfies the Mapper protocol but the actual
        // MMC5 counting is handled in PPU.swift at cycle 256 for accuracy.
    }

    @inline(__always) func mapperIRQAsserted() -> Bool { return irqPending && irqEnabled }
    @inline(__always) func mapperIRQClear() { irqPending = false }
}
