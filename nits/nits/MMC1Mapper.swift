import Foundation

final class MMC1Mapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    var prgRAM: ExtRAM?
    private(set) var mirroring: Mirroring

    private var shiftRegister: UInt8 = 0x10
    var control: UInt8 = 0x0C
    var chrBank0: UInt8 = 0
    private var chrBank1: UInt8 = 0
    private var prgBank: UInt8 = 0

    private let prgBankSize = 16 * 1024
    private let chrBankSize4K = 4 * 1024
    private var prgRAMEnabled: Bool = true
    var chrBank0Offset: Int = 0
    var chrBank1Offset: Int = 0
    var prgBank0Offset: Int = 0
    private var prgBank1Offset: Int = 0

    private var prevA12: UInt8 = 0
    private var pendingChrBank0Offset: Int? = nil
    private var pendingChrBank1Offset: Int? = nil

    @inline(__always)
    private func maskCHR4K(_ v: UInt8) -> UInt8 {
        let banks = max(1, chr.data.count / chrBankSize4K)
        if banks <= 1 { return 0 }
        return UInt8(Int(v) % banks)
    }

    @inline(__always)
    private func maskPRG16K(_ v: UInt8) -> UInt8 {
        let banks = max(1, prgROM.count / prgBankSize)
        if banks <= 1 { return 0 }
        return UInt8(Int(v) % banks)
    }

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring
        reset()
        updateOffsets()
    }

    @inline(__always) func reset() {
        shiftRegister = 0x10
        applyControl(0x0C) // Mode 3: PRG fixed, vertical mirroring
        chrBank0 = 0
        chrBank1 = 0
        prgBank = 0
        prgRAMEnabled = true
        prevA12 = 0
        pendingChrBank0Offset = nil
        pendingChrBank1Offset = nil
    }

    @inline(__always) func applyControl(_ v: UInt8) {
        control = v & 0x1F
        switch (control & 0x03) {
        case 0: mirroring = .singleScreenLow
        case 1: mirroring = .singleScreenHigh
        case 2: mirroring = .vertical
        case 3: mirroring = .horizontal
        default: break
        }
        updateOffsets()
    }

    @inline(__always)
    func cpuWrite(address: UInt16, value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            if prgRAMEnabled, let ram = prgRAM {
                let idx = Int(address - 0x6000)
                if idx < ram.size { ram.data[idx] = value }
            }
            return
        }
        guard address >= 0x8000 else { return }
        if (value & 0x80) != 0 {
            shiftRegister = 0x10
            applyControl(control | 0x0C)
            return
        }
        let carry = value & 1
        let complete = (shiftRegister & 1) != 0
        shiftRegister = (shiftRegister >> 1) | (carry << 4)
        if complete {
            let reg = (address >> 13) & 0x03
            let data = shiftRegister & 0x1F
            switch reg {
            case 0: applyControl(data)
            case 1: chrBank0 = maskCHR4K(data)
            case 2: chrBank1 = maskCHR4K(data)
            case 3:
                prgBank = maskPRG16K(data & 0x0F)
                prgRAMEnabled = (data & 0x10) == 0
            default: break
            }
            shiftRegister = 0x10
            let (pOff0, pOff1) = computeCHRBankOffsets()
            pendingChrBank0Offset = pOff0
            pendingChrBank1Offset = pOff1
            updatePROffsets()
        }
    }

    @inline(__always)
    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            if prgRAMEnabled, let ram = prgRAM {
                let idx = Int(address - 0x6000)
                if idx < ram.size { return ram.data[idx] }
            }
            return 0
        case 0x8000...0xBFFF:
            let off = Int(address - 0x8000)
            let idx = prgBank0Offset + off
            return prgROM[idx % max(prgROM.count, 1)]
        case 0xC000...0xFFFF:
            let off = Int(address - 0xC000)
            let idx = prgBank1Offset + off
            return prgROM[idx % max(prgROM.count, 1)]
        default:
            return 0
        }
    }

    @inline(__always)
    func ppuRead(address: UInt16) -> UInt8 {
        if chr.data.isEmpty { return 0 }
        let a = Int(address & 0x1FFF)
        let chrMode4K = (control & 0x10) != 0
        let idx: Int
        if chrMode4K {
            if a < 0x1000 {
                idx = chrBank0Offset + a
            } else {
                idx = chrBank1Offset + (a - 0x1000)
            }
        } else {
            idx = chrBank0Offset + a
        }
        if idx >= 0 && idx < chr.data.count {
            return chr.data[idx]
        }
        return 0
    }

    @inline(__always)
    func ppuWrite(address: UInt16, value: UInt8) {
        guard chr.isRAM else { return }
        let a = Int(address & 0x1FFF)
        let chrMode4K = (control & 0x10) != 0
        let idx: Int
        if chrMode4K {
            if a < 0x1000 {
                idx = chrBank0Offset + a
            } else {
                idx = chrBank1Offset + (a - 0x1000)
            }
        } else {
            idx = chrBank0Offset + a
        }
        if idx >= 0 && idx < chr.data.count {
            chr.data[idx] = value
        }
    }

    @inline(__always)
    private func computeCHRBankOffsets() -> (Int, Int) {
        let chrMode = (control & 0x10) != 0
        if chrMode {
            let off0 = Int(chrBank0) * 0x1000
            let off1 = Int(chrBank1) * 0x1000
            return (off0, off1)
        } else {
            let off0 = Int(chrBank0 & 0x1E) * 0x1000
            let off1 = off0 + 0x1000
            return (off0, off1)
        }
    }

    @inline(__always)
    private func updatePROffsets() {
        let prgMode = (control >> 2) & 0x03
        switch prgMode {
        case 0, 1:
            prgBank0Offset = Int(prgBank & 0x1E) * 0x4000
            prgBank1Offset = prgBank0Offset + 0x4000
        case 2:
            prgBank0Offset = 0
            prgBank1Offset = Int(prgBank) * 0x4000
        default:
            prgBank0Offset = Int(prgBank) * 0x4000
            prgBank1Offset = max(0, prgROM.count - 0x4000)
        }
    }

    @inline(__always) private func updateOffsets() {
        let (off0, off1) = computeCHRBankOffsets()
        chrBank0Offset = off0
        chrBank1Offset = off1
        updatePROffsets()
    }

    @inline(__always)
    func ppuA12Observe(addr: UInt16, ppuDot: UInt64) {
        let a12: UInt8 = (addr & 0x1000) != 0 ? 1 : 0
        if prevA12 == 0 && a12 == 1 {
            if let po0 = pendingChrBank0Offset, let po1 = pendingChrBank1Offset {
                chrBank0Offset = po0
                chrBank1Offset = po1
                pendingChrBank0Offset = nil
                pendingChrBank1Offset = nil
            }
        }
        prevA12 = a12
    }

    @inline(__always) func mapperIRQAsserted() -> Bool { false }
    @inline(__always) func mapperIRQClear() {}
    @inline(__always) func clockScanlineCounter() {}
}
