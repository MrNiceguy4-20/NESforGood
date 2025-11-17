final class MMC2Mapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private(set) var mirroring: Mirroring

    private let prgBankSize = 16 * 1024
    private let chrBankSize4K = 4 * 1024

    private let prgBankMask: Int
    private let chrBankMask: Int
    private let chrSize: Int

    private var prgBank: UInt8 = 0

    // CHR registers
    private var chr0Lo: UInt8 = 0
    private var chr0Hi: UInt8 = 0
    private var chr1Lo: UInt8 = 0
    private var chr1Hi: UInt8 = 0

    // Latches (0 or 1)
    private var latch0: UInt8 = 0
    private var latch1: UInt8 = 0

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring

        let prgBanks = max(1, prgROM.count / prgBankSize)
        self.prgBankMask = prgBanks - 1

        self.chrSize = chr.data.count
        let chrBanks = max(1, chrSize / chrBankSize4K)
        self.chrBankMask = chrBanks - 1
    }

    @inline(__always)
    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            if let ram = prgRAM { return ram.data[Int(address &- 0x6000)] }
            return 0

        case 0x8000...0xBFFF:
            guard !prgROM.isEmpty else { return 0 }
            let base = Int(prgBank & UInt8(prgBankMask)) * prgBankSize
            let off  = Int(address &- 0x8000)
            return prgROM[base &+ off]

        case 0xC000...0xFFFF:
            guard !prgROM.isEmpty else { return 0 }
            let base = prgROM.count - 2 * prgBankSize
            let off  = Int(address &- 0xC000)
            return prgROM[base &+ off]

        default:
            return 0
        }
    }

    @inline(__always)
    func cpuWrite(address: UInt16, value: UInt8) {
        switch address {
        case 0xA000...0xAFFF:
            prgBank = value & 0x0F

        case 0xB000...0xBFFF:
            chr0Lo = value & 0x1F

        case 0xC000...0xCFFF:
            chr0Hi = value & 0x1F

        case 0xD000...0xDFFF:
            chr1Lo = value & 0x1F

        case 0xE000...0xEFFF:
            chr1Hi = value & 0x1F

        case 0xF000...0xFFFF:
            mirroring = (value & 1) == 0 ? .vertical : .horizontal

        case 0x6000...0x7FFF:
            prgRAM?.data[Int(address &- 0x6000)] = value

        default:
            break
        }
    }

    @inline(__always)
    func ppuRead(address: UInt16) -> UInt8 {
        let a = address & 0x1FFF
        if a < 0x1000 {
            // Pattern table 0 – latch0
            if a == 0x0FD8 { latch0 = 0 }
            else if a == 0x0FE8 { latch0 = 1 }

            let sel = (latch0 == 0) ? chr0Lo : chr0Hi
            let bank = Int(sel) & chrBankMask
            let base = bank * chrBankSize4K
            let off  = Int(a)
            if chrSize == 0 { return 0 }
            return chr.data[(base &+ off) % chrSize]
        } else {
            // Pattern table 1 – latch1
            if a == 0x1FD8 { latch1 = 0 }
            else if a == 0x1FE8 { latch1 = 1 }

            let sel = (latch1 == 0) ? chr1Lo : chr1Hi
            let bank = Int(sel) & chrBankMask
            let base = bank * chrBankSize4K
            let off  = Int(a &- 0x1000)
            if chrSize == 0 { return 0 }
            return chr.data[(base &+ off) % chrSize]
        }
    }

    @inline(__always)
    func ppuWrite(address: UInt16, value: UInt8) {
        if !chr.isRAM || chrSize == 0 { return }
        let a = address & 0x1FFF
        let idx: Int
        if a < 0x1000 {
            let sel = (latch0 == 0) ? chr0Lo : chr0Hi
            let bank = Int(sel) & chrBankMask
            let base = bank * chrBankSize4K
            idx = (base &+ Int(a)) % chrSize
        } else {
            let sel = (latch1 == 0) ? chr1Lo : chr1Hi
            let bank = Int(sel) & chrBankMask
            let base = bank * chrBankSize4K
            idx = (base &+ Int(a &- 0x1000)) % chrSize
        }
        chr.data[idx] = value
    }

    @inline(__always) func ppuA12Observe(addr: UInt16, ppuDot: UInt64) {}
    @inline(__always) func mapperIRQAsserted() -> Bool { false }
    @inline(__always) func mapperIRQClear() {}
    @inline(__always) func clockScanlineCounter() {}
}
