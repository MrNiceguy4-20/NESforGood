import Foundation

enum CartridgeError: Error {
    case invalidROM
    case unsupportedMapper(Int)
}

enum Mirroring {
    case horizontal
    case vertical
    case fourScreen
    case singleScreenLow
    case singleScreenHigh
}

final class Cartridge {
    let prgROM: [UInt8]
    let mirroring: Mirroring
    let hasBattery: Bool
    let chr: CHRMemory
    let prgRAM: ExtRAM?
    let mapper: Mapper
    private var saveURL: URL?

    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count > 16,
              String(bytes: bytes[0..<4], encoding: .ascii) == "NES\u{1A}" else {
            throw CartridgeError.invalidROM
        }

        var prg16Banks = Int(bytes[4])
        var chr8Banks = Int(bytes[5])
        let prgSize = prg16Banks * 16 * 1024
        let chrSize = chr8Banks * 8 * 1024
        let flags6 = bytes[6]
        let flags7 = bytes[7]
        let isINES2 = (flags7 & 0x0C) == 0x08
        var mapperID = Int((flags6 >> 4)) | Int(flags7 & 0xF0)
        if isINES2 && bytes.count >= 10 {
            mapperID |= Int(bytes[8] & 0x0F) << 8
            prg16Banks |= Int(bytes[9] & 0x0F) << 8
            chr8Banks |= Int(bytes[9] >> 4) << 8
        }

        let hasTrainer = (flags6 & 0x04) != 0
        hasBattery = (flags6 & 0x02) != 0
        let prgStart = 16 + (hasTrainer ? 512 : 0)
        let prgEnd = min(prgStart + prgSize, bytes.count)
        let chrStart = prgEnd
        let chrEnd = min(chrStart + chrSize, bytes.count)

        self.prgROM = Array(bytes[prgStart..<prgEnd])
        let mirrorBit = flags6 & 0x01
        let fourScreenBit = flags6 & 0x08
        if fourScreenBit != 0 {
            self.mirroring = .fourScreen
        } else if mirrorBit == 0 {
            self.mirroring = .horizontal
        } else {
            self.mirroring = .vertical
        }

        if chrSize == 0 {
            self.chr = CHRMemory(size: 8 * 1024, isRAM: true)
        } else {
            self.chr = CHRMemory(size: chrSize, isRAM: false, initial: Array(bytes[chrStart..<chrEnd]))
        }

        self.prgRAM = ExtRAM(size: 8 * 1024)
        if hasBattery, let ram = self.prgRAM {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let filename = "nes_save_\(Cartridge.quickHash(self.prgROM)).sav"
            let url = docs.appendingPathComponent(filename)
            self.saveURL = url
            if let data = try? Data(contentsOf: url), data.count == ram.data.count {
                ram.data = [UInt8](data)
            }
        }

        switch mapperID {
        case 0: self.mapper = NROMMapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM)
        case 1: self.mapper = MMC1Mapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        case 2: self.mapper = UxROMMapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM)
        case 3: self.mapper = CNROMMapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM)
        case 4: self.mapper = MMC3Mapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        case 5: self.mapper = MMC5Mapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        case 7: self.mapper = AxROMMapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        case 9: self.mapper = MMC2Mapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        case 10: self.mapper = MMC4Mapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        case 11: self.mapper = ColorDreamsMapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        case 66: self.mapper = GNROMMapper(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        case 71: self.mapper = Mapper71(prgROM: prgROM, chr: chr, prgRAM: prgRAM, mirroring: mirroring)
        default: throw CartridgeError.unsupportedMapper(mapperID)
        }
    }

    func saveBatteryRAM() {
        guard hasBattery, let ram = prgRAM, let url = saveURL else { return }
        try? Data(ram.data).write(to: url, options: [.atomic])
    }

    private static func quickHash(_ bytes: [UInt8]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in bytes {
            h ^= UInt64(b)
            h = (h &* 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
        }
        return String(format: "%016llx", h)
    }
}

protocol Mapper: AnyObject {
    func cpuRead(address: UInt16) -> UInt8
    func cpuWrite(address: UInt16, value: UInt8)
    func ppuRead(address: UInt16) -> UInt8
    func ppuWrite(address: UInt16, value: UInt8)
    func ppuA12Observe(addr: UInt16, ppuDot: UInt64)
    func mapperIRQAsserted() -> Bool
    func mapperIRQClear()
}

extension Mapper {
    func ppuA12Observe(addr: UInt16, ppuDot: UInt64) {}
    func mapperIRQAsserted() -> Bool { return false }
    func mapperIRQClear() {}
}
