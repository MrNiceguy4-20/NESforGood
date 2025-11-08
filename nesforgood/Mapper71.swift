final class Mapper71: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private(set) var mirroring: Mirroring

    private var prgBank: UInt8 = 0
    private var mirrorBank: UInt8 = 0

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring
        self.prgBank = 0
        self.mirrorBank = 0
    }

    func cpuWrite(address: UInt16, value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            prgRAM?.data[Int(address - 0x6000)] = value
            return
        }

        switch address {
        case 0x8000...0x9FFF:
            mirrorBank = (value >> 4) & 0x01
            mirroring = mirrorBank == 0 ? .singleScreenLow : .singleScreenHigh
        case 0xC000...0xFFFF:
            prgBank = value & 0x0F
        default:
            break
        }
    }

    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            return prgRAM?.data[Int(address - 0x6000)] ?? 0
        case 0x8000...0xBFFF:
            let base = Int(prgBank) * 0x4000
            let idx = base + Int(address & 0x3FFF)
            return prgROM[idx % prgROM.count]
        case 0xC000...0xFFFF:
            let base = prgROM.count - 0x4000
            let idx = base + Int(address & 0x3FFF)
            return prgROM[idx % prgROM.count]
        default:
            return 0
        }
    }

    func ppuRead(address: UInt16) -> UInt8 {
        return chr.data[Int(address & 0x1FFF) % chr.data.count]
    }

    func ppuWrite(address: UInt16, value: UInt8) {
        if chr.isRAM {
            chr.data[Int(address & 0x1FFF) % chr.data.count] = value
        }
    }
}
