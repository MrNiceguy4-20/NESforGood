final class NROMMapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgBanks: Int
    let prgRAM: ExtRAM?

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgBanks = prgROM.count / 16384
        self.prgRAM = prgRAM
    }

    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            return prgRAM?.data[Int(address - 0x6000)] ?? 0
        case 0x8000...0xFFFF:
            var addr = Int(address & 0x7FFF)
            if prgBanks == 1 { addr %= prgROM.count }
            return prgROM[addr]
        default:
            return 0
        }
    }

    func cpuWrite(address: UInt16, value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            prgRAM?.data[Int(address - 0x6000)] = value
        }
    }

    func ppuRead(address: UInt16) -> UInt8 {
        return chr.data[Int(address) % max(chr.data.count, 1)]
    }

    func ppuWrite(address: UInt16, value: UInt8) {
        if chr.isRAM {
            chr.data[Int(address) % chr.data.count] = value
        }
    }
}
