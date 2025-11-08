final class ColorDreamsMapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    let mirroring: Mirroring

    private var prgBank: UInt8 = 0
    private var chrBank: UInt8 = 0

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring
        self.prgBank = 0
        self.chrBank = 0
    }

    func cpuWrite(address: UInt16, value: UInt8) {
        if address >= 0x8000 {
            prgBank = value & 0x03
            chrBank = (value >> 4) & 0x0F
        } else if (0x6000...0x7FFF).contains(address) {
            prgRAM?.data[Int(address - 0x6000)] = value
        }
    }

    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            return prgRAM?.data[Int(address - 0x6000)] ?? 0
        case 0x8000...0xFFFF:
            let base = Int(prgBank) * 0x8000
            let idx = base + Int(address & 0x7FFF)
            return prgROM[idx % prgROM.count]
        default:
            return 0
        }
    }

    func ppuRead(address: UInt16) -> UInt8 {
        let base = Int(chrBank) * 0x2000
        return chr.data[(base + Int(address & 0x1FFF)) % chr.data.count]
    }

    func ppuWrite(address: UInt16, value: UInt8) {
        if chr.isRAM {
            let base = Int(chrBank) * 0x2000
            chr.data[(base + Int(address & 0x1FFF)) % chr.data.count] = value
        }
    }
}
