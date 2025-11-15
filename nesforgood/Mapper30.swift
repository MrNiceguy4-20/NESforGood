import Foundation

/// Mapper 30 – UNROM-512 style mapper.
/// Very similar to UxROM, but uses the full 5-bit bank number for PRG.
/// CHR is treated exactly like in the base UxROM implementation.
final class Mapper30: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private(set) var mirroring: Mirroring

    private var prgBank: UInt8 = 0

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring
        self.prgBank = 0
    }

    func cpuWrite(address: UInt16, value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            prgRAM?.data[Int(address - 0x6000)] = value
        } else if address >= 0x8000 {
            // Mapper 30 uses the lower 5 bits of the value for bank select.
            prgBank = value & 0x1F
        }
    }

    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            return prgRAM?.data[Int(address - 0x6000)] ?? 0
        case 0x8000...0xBFFF:
            // 16K switchable bank
            let bankCount = max(1, prgROM.count / 0x4000)
            let base = Int(prgBank % UInt8(bankCount)) * 0x4000
            return prgROM[base + Int(address & 0x3FFF)]
        case 0xC000...0xFFFF:
            // Fixed last 16K bank
            let base = prgROM.count - 0x4000
            return prgROM[base + Int(address & 0x3FFF)]
        default:
            return 0
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
