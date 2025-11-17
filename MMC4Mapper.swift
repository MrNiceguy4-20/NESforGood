import Foundation

final class MMC4Mapper: Mapper {
    private let prgROM: [UInt8]
    private let chr: CHRMemory
    private let prgRAM: ExtRAM?
    private let chrBankSize = 4 * 1024

    private var prgBank: UInt8 = 0
    private var chrL0: UInt8 = 0
    private var chrL1: UInt8 = 0
    private var chrR0: UInt8 = 0
    private var chrR1: UInt8 = 0
    private var latchL: UInt8 = 0
    private var latchR: UInt8 = 0

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
    }

    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            if let ram = prgRAM {
                let idx = Int(address - 0x6000)
                if idx < ram.size { return ram.data[idx] }
            }
            return 0
        case 0x8000...0xBFFF:
            let base = Int(prgBank) * 0x4000
            let off = Int(address - 0x8000)
            let idx = min(base + off, prgROM.count - 1)
            return prgROM[idx]
        case 0xC000...0xFFFF:
            let fixedBase = max(prgROM.count - 0x4000, 0)
            let off = Int(address - 0xC000)
            let idx = min(fixedBase + off, prgROM.count - 1)
            return prgROM[idx]
        default:
            return 0
        }
    }

    func cpuWrite(address: UInt16, value: UInt8) {
        switch address {
        case 0xA000...0xAFFF:
            prgBank = value & 0x0F
        case 0xB000...0xBFFF:
            chrL0 = value & 0x1F
        case 0xC000...0xCFFF:
            chrL1 = value & 0x1F
        case 0xD000...0xDFFF:
            chrR0 = value & 0x1F
        case 0xE000...0xEFFF:
            chrR1 = value & 0x1F
        default:
            break
        }
    }

    func ppuRead(address: UInt16) -> UInt8 {
        let a = Int(address & 0x1FFF)
        let bank: Int
        if a < 0x1000 {
            bank = Int((latchL == 0xFD) ? chrL0 : chrL1)
        } else {
            bank = Int((latchR == 0xFD) ? chrR0 : chrR1)
        }
        let base = bank * chrBankSize
        let idx = min(base + (a % chrBankSize), chr.data.count - 1)
        return chr.data[idx]
    }

    func ppuWrite(address: UInt16, value: UInt8) {
        guard chr.isRAM else { return }
        let a = address & 0x1FFF
        if a == 0x0FD { latchL = 0xFD }
        else if a == 0x0FE { latchL = 0xFE }
        else if a == 0x1FD { latchR = 0xFD }
        else if a == 0x1FE { latchR = 0xFE }

        let idx = Int(a) % chr.data.count
        chr.data[idx] = value
    }

    func ppuA12Observe(addr: UInt16, ppuDot: UInt64) {}
    func mapperIRQAsserted() -> Bool { false }
    func mapperIRQClear() {}
    func clockScanlineCounter() {}
}
