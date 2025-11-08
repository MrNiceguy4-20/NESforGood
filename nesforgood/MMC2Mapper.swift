//
//  MMC2Mapper.swift
//  nesforgood
//
//  Created by kevin on 2025-10-30.
//


final class MMC2Mapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private(set) var mirroring: Mirroring

    private var prgBank: UInt8 = 0
    private var chrFD0: UInt8 = 0
    private var chrFE0: UInt8 = 0
    private var chrFD1: UInt8 = 0
    private var chrFE1: UInt8 = 0
    private var latch0: UInt8 = 0xFD
    private var latch1: UInt8 = 0xFD

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring
        self.prgBank = 0
        self.chrFD0 = 0
        self.chrFE0 = 0
        self.chrFD1 = 0
        self.chrFE1 = 0
        self.latch0 = 0xFD
        self.latch1 = 0xFD
    }

    func cpuWrite(address: UInt16, value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            prgRAM?.data[Int(address - 0x6000)] = value
            return
        }

        switch address & 0xF000 {
        case 0xA000:
            prgBank = value & 0x0F
        case 0xB000:
            chrFD0 = value & 0x1F
        case 0xC000:
            chrFE0 = value & 0x1F
        case 0xD000:
            chrFD1 = value & 0x1F
        case 0xE000:
            chrFE1 = value & 0x1F
        case 0xF000:
            mirroring = (value & 0x01) == 0 ? .vertical : .horizontal
        default:
            break
        }
    }

    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            return prgRAM?.data[Int(address - 0x6000)] ?? 0
        case 0x8000...0x9FFF:
            let idx = Int(prgBank) * 0x2000 + Int(address & 0x1FFF)
            return prgROM[idx % prgROM.count]
        case 0xA000...0xFFFF:
            let base = prgROM.count - 0x6000
            let idx = base + Int(address - 0xA000)
            return prgROM[idx % prgROM.count]
        default:
            return 0
        }
    }

    func ppuRead(address: UInt16) -> UInt8 {
        let addr = Int(address & 0x1FFF)
        let isLeft = addr < 0x1000
        let latch = isLeft ? latch0 : latch1
        let bank: UInt8 = if isLeft {
            latch == 0xFD ? chrFD0 : chrFE0
        } else {
            latch == 0xFD ? chrFD1 : chrFE1
        }
        let idx = Int(bank) * 0x1000 + (addr % 0x1000)
        let value = chr.data[idx % chr.data.count]

        let triggerAddr = address & 0x3FFF
        if (0x0FD8...0x0FDF).contains(triggerAddr) {
            latch0 = 0xFD
        } else if (0x0FE8...0x0FEF).contains(triggerAddr) {
            latch0 = 0xFE
        } else if (0x1FD8...0x1FDF).contains(triggerAddr) {
            latch1 = 0xFD
        } else if (0x1FE8...0x1FEF).contains(triggerAddr) {
            latch1 = 0xFE
        }

        return value
    }

    func ppuWrite(address: UInt16, value: UInt8) {
        if chr.isRAM {
            chr.data[Int(address & 0x1FFF) % chr.data.count] = value
        }
    }
}