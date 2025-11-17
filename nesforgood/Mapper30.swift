final class Mapper30: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private(set) var mirroring: Mirroring

    private let prgBankSize = 16 * 1024
    private let chrBankSize = 8 * 1024
    private let prgBankMask: Int
    private let chrBankMask: Int

    private var reg: UInt8 = 0
    private var prgBank: UInt8 = 0
    private var chrBank: UInt8 = 0

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring

        let prgBanks = max(1, prgROM.count / prgBankSize)
        self.prgBankMask = prgBanks - 1

        let chrBanks = max(1, chr.data.count / chrBankSize)
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
            let bank = Int(prgBank) & prgBankMask
            let base = bank * prgBankSize
            let off  = Int(address &- 0x8000)
            return prgROM[(base &+ off) % prgROM.count]

        case 0xC000...0xFFFF:
            guard !prgROM.isEmpty else { return 0 }
            let base = prgROM.count - prgBankSize
            let off  = Int(address &- 0xC000)
            return prgROM[base &+ off]

        default:
            return 0
        }
    }

    @inline(__always)
    func cpuWrite(address: UInt16, value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            prgRAM?.data[Int(address &- 0x6000)] = value
            return
        }
        guard address >= 0x8000 else { return }

        reg = value
        let prg = value & 0x1F
        let chr = (value >> 5) & 0x03

        prgBank = UInt8(Int(prg) & prgBankMask)
        chrBank = UInt8(Int(chr) & chrBankMask)
        // bit7 (nametable) ignored here; you can hook it into mirroring if you want
    }

    @inline(__always)
    func ppuRead(address: UInt16) -> UInt8 {
        let size = chr.data.count
        guard size > 0 else { return 0 }
        let bank = Int(chrBank) & chrBankMask
        let base = bank * chrBankSize
        let off  = Int(address & 0x1FFF)
        return chr.data[(base &+ off) % size]
    }

    @inline(__always)
    func ppuWrite(address: UInt16, value: UInt8) {
        if chr.isRAM {
            let size = chr.data.count
            guard size > 0 else { return }
            let bank = Int(chrBank) & chrBankMask
            let base = bank * chrBankSize
            let off  = Int(address & 0x1FFF)
            chr.data[(base &+ off) % size] = value
        }
    }

    @inline(__always) func ppuA12Observe(addr: UInt16, ppuDot: UInt64) {}
    @inline(__always) func mapperIRQAsserted() -> Bool { false }
    @inline(__always) func mapperIRQClear() {}
    @inline(__always) func clockScanlineCounter() {}
}
