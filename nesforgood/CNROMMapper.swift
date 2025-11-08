final class CNROMMapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private var chrBank: UInt8 = 0

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.chrBank = 0
    }

    func cpuWrite(address: UInt16, value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            prgRAM?.data[Int(address - 0x6000)] = value
        } else if address >= 0x8000 {
            chrBank = value & 0x03
        }
    }

    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            return prgRAM?.data[Int(address - 0x6000)] ?? 0
        case 0x8000...0xFFFF:
            var addr = Int(address & 0x7FFF)
            if prgROM.count == 16384 { addr %= 16384 }
            return prgROM[addr]
        default:
            return 0
        }
    }

    func ppuRead(address: UInt16) -> UInt8 {
        let base = Int(chrBank) * 8192
        if chr.data.isEmpty { return 0 }
        return chr.data[(base + Int(address)) % chr.data.count]
    }

    func ppuWrite(address: UInt16, value: UInt8) {
        if chr.isRAM {
            let base = Int(chrBank) * 8192
            if chr.data.isEmpty { return }
            chr.data[(base + Int(address)) % chr.data.count] = value
        }
    }
}
