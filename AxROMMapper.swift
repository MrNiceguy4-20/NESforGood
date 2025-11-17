final class AxROMMapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private(set) var mirroring: Mirroring

    private let prgBankSize = 32 * 1024
    private let prgBankMask: Int
    private let chrSize: Int
    private let hasChrRAM: Bool

    private var prgBank: UInt8 = 0

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring

        let prgBanks = max(1, prgROM.count / prgBankSize)
        self.prgBankMask = prgBanks - 1

        self.chrSize = chr.data.count
        self.hasChrRAM = chr.isRAM
    }

    @inline(__always)
    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            if let ram = prgRAM { return ram.data[Int(address &- 0x6000)] }
            return 0

        case 0x8000...0xFFFF:
            guard !prgROM.isEmpty else { return 0 }
            let bank = Int(prgBank) & prgBankMask
            let base = bank * prgBankSize
            let off  = Int(address &- 0x8000)
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

        prgBank = value & 0x07
        let mirrBit = (value & 0x10) >> 4
        mirroring = (mirrBit == 0) ? .singleScreenLow : .singleScreenHigh
    }

    @inline(__always)
    func ppuRead(address: UInt16) -> UInt8 {
        guard chrSize > 0 else { return 0 }
        let idx = Int(address & 0x1FFF) % chrSize
        return chr.data[idx]
    }

    @inline(__always)
    func ppuWrite(address: UInt16, value: UInt8) {
        guard hasChrRAM, chrSize > 0 else { return }
        let idx = Int(address & 0x1FFF) % chrSize
        chr.data[idx] = value
    }

    @inline(__always) func ppuA12Observe(addr: UInt16, ppuDot: UInt64) {}
    @inline(__always) func mapperIRQAsserted() -> Bool { false }
    @inline(__always) func mapperIRQClear() {}
    @inline(__always) func clockScanlineCounter() {}
}
