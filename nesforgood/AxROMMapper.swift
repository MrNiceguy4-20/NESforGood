//
//  AxROMMapper.swift
//  nesforgood
//
//  Created by kevin on 2025-10-30.
//


final class AxROMMapper: Mapper {
    let prgROM: [UInt8]
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    private var bank: UInt8 = 0
    private var mirroringBit: UInt8 = 0
    private(set) var mirroring: Mirroring

    init(prgROM: [UInt8], chr: CHRMemory, prgRAM: ExtRAM?, mirroring: Mirroring) {
        self.prgROM = prgROM
        self.chr = chr
        self.prgRAM = prgRAM
        self.mirroring = mirroring
        self.bank = 0
        self.mirroringBit = 0
    }

    func cpuWrite(address: UInt16, value: UInt8) {
        if (0x6000...0x7FFF).contains(address) {
            prgRAM?.data[Int(address - 0x6000)] = value
        } else if address >= 0x8000 {
            bank = value & 0x07
            mirroringBit = (value >> 4) & 0x01
            mirroring = (mirroringBit == 0) ? .singleScreenLow : .singleScreenHigh
        }
    }

    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x6000...0x7FFF:
            return prgRAM?.data[Int(address - 0x6000)] ?? 0
        case 0x8000...0xFFFF:
            let bankSize = 32 * 1024
            let base = Int(bank % UInt8(max(1, prgROM.count / bankSize))) * bankSize
            return prgROM[base + Int(address & 0x7FFF)]
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