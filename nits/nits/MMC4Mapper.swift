final class MMC4Mapper: Mapper {
    private let prgROM: [UInt8]
    private let chr: CHRMemory
    private let prgRAM: ExtRAM?
    private let chrBankSize = 4 * 1024
    private let prgBankCount: Int
    private let chrBankCount: Int
    private(set) var mirroring: Mirroring

    private var prgBank: UInt8 = 0
    private var chrL0: UInt8 = 0
    private var chrL1: UInt8 = 0
    private var chrR0: UInt8 = 0
    private var chrR1: UInt8 = 0
    private var latchL: UInt8 = 0xFE
    private var latchR: UInt8 = 0xFE

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring
        self.prgBankCount = max(prgROM.count / 0x4000, 1)
        self.chrBankCount = max(chr.data.count / chrBankSize, 1)
        self.prgBank = 0
    }

    @inline(__always)
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

    @inline(__always)
    func cpuWrite(address: UInt16, value: UInt8) {
        switch address {
        case 0x6000...0x7FFF:
            if let ram = prgRAM {
                let idx = Int(address - 0x6000)
                if idx < ram.size { ram.data[idx] = value }
            }
        case 0xA000...0xAFFF:
            prgBank = maskPRGBank(value)
        case 0xB000...0xBFFF:
            chrL0 = maskCHRBank(value)
        case 0xC000...0xCFFF:
            chrL1 = maskCHRBank(value)
        case 0xD000...0xDFFF:
            chrR0 = maskCHRBank(value)
        case 0xE000...0xEFFF:
            chrR1 = maskCHRBank(value)
        case 0xF000...0xFFFF:
            mirroring = (value & 0x01) == 0 ? .vertical : .horizontal
        default:
            break
        }
    }

    @inline(__always)
    func ppuRead(address: UInt16) -> UInt8 {
        let bankIndex = chrBankIndex(for: address)
        let offset = Int(address & 0x0FFF)
        let idx = min(bankIndex * chrBankSize + offset, chr.data.count - 1)
        return chr.data[idx]
    }

    @inline(__always)
    func ppuWrite(address: UInt16, value: UInt8) {
        guard chr.isRAM else { return }

        let bankIndex = chrBankIndex(for: address)
        let offset = Int(address & 0x0FFF)
        let idx = min(bankIndex * chrBankSize + offset, chr.data.count - 1)
        chr.data[idx] = value
    }

    @inline(__always)
    private func chrBankIndex(for rawAddress: UInt16) -> Int {
        let a = rawAddress & 0x1FFF
        switch a {
        case 0x0FD8: latchL = 0xFD
        case 0x0FE8: latchL = 0xFE
        case 0x1FD8: latchR = 0xFD
        case 0x1FE8: latchR = 0xFE
        default:
            break
        }

        if a < 0x1000 {
            let bank = (latchL == 0xFD) ? chrL0 : chrL1
            return Int(bank) % chrBankCount
        } else {
            let bank = (latchR == 0xFD) ? chrR0 : chrR1
            return Int(bank) % chrBankCount
        }
    }

    @inline(__always)
    private func maskPRGBank(_ value: UInt8) -> UInt8 {
        guard prgBankCount > 1 else { return 0 }
        return UInt8(Int(value) % prgBankCount)
    }

    @inline(__always)
    private func maskCHRBank(_ value: UInt8) -> UInt8 {
        guard chrBankCount > 1 else { return 0 }
        return UInt8(Int(value) % chrBankCount)
    }

    @inline(__always) func ppuA12Observe(addr: UInt16, ppuDot: UInt64) {}
    @inline(__always) func mapperIRQAsserted() -> Bool { false }
    @inline(__always) func mapperIRQClear() {}
    @inline(__always) func clockScanlineCounter() {}
}
