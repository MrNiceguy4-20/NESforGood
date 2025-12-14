import Foundation

final class Bus {
    private var mmc1Shift: UInt8 = 0x10
    private var mmc1Control: UInt8 = 0x0C
    private var mmc1CHR0: UInt8 = 0
    private var mmc1CHR1: UInt8 = 0
    private var mmc1PRG: UInt8 = 0
    private var mmc1PRGRAMDisable: Bool = false
    private var mmc1Mirroring: UInt8 = 2
    private var prgRAM: [UInt8] = Array(repeating: 0, count: 0x2000)
    public var prg: [UInt8] = []
    public var chr: [UInt8] = []
    var mapperID: Int = 0
    private var mmc3PRGBanks: [Int] = [0, 0, -2, -1]
    private var mmc3CHR: [Int] = Array(repeating: 0, count: 8)
    private var mmc3BankSelect: UInt8 = 0
    private var mmc3PRGMode: Bool = false
    private var mmc3CHRMode: Bool = false
    private var mmc3IRQCounter: UInt8 = 0
    private var mmc3IRQReload: UInt8 = 0
    private var mmc3IRQEnabled: Bool = false
    private var mmc3IRQPending: Bool = false

    private var ram: UnsafeMutablePointer<UInt8>

    var cartridge: Cartridge
    let ppu: PPU
    let apu: APU
    let controller: Controller
    weak var core: EmulatorCore?

    private let mapper: Mapper
    private let nromMapper: NROMMapper?
    private let mmc1Mapper: MMC1Mapper?
    private let uxromMapper: UxROMMapper?
    private let cnromMapper: CNROMMapper?
    private let mmc3Mapper: MMC3Mapper?
    private let mmc5Mapper: MMC5Mapper?
    private let axromMapper: AxROMMapper?
    private let mmc2Mapper: MMC2Mapper?
    private let mmc4Mapper: MMC4Mapper?
    private let colorDreamsMapper: ColorDreamsMapper?
    private let gnromMapper: GNROMMapper?
    private let mapper71: Mapper71?

    private var prgReadTable: [((UInt16) -> UInt8)] = []
    private var prgWriteTable: [((UInt16, UInt8) -> Void)] = []

    // PPU register dispatch tables ($2000–$3FFF mirrored)
    private lazy var ppuRegisterReads: [() -> UInt8] = [
        { 0 },
        { 0 },
        { self.ppu.readStatus() },
        { self.ppu.readOAMData() },
        { 0 },
        { 0 },
        { 0 },
        { self.ppu.readData() }
    ]

    private lazy var ppuRegisterWrites: [(UInt8) -> Void] = [
        { self.ppu.writeCtrl($0) },
        { self.ppu.writeMask($0) },
        { _ in },
        { self.ppu.writeOAMAddr($0) },
        { self.ppu.writeOAMData($0) },
        { self.ppu.writeScroll($0) },
        { self.ppu.writeAddr($0) },
        { self.ppu.writeData($0) }
    ]

    private let debugLogging = false

    @inline(__always) private func log(_ s: @autoclosure () -> String) {
        if debugLogging { print("[BUS] \(s())") }
    }

    init(cartridge: Cartridge, ppu: PPU, apu: APU, controller: Controller, core: EmulatorCore) {
        self.cartridge = cartridge
        self.ppu = ppu
        self.apu = apu
        self.controller = controller
        self.core = core

        self.ram = .allocate(capacity: 0x0800)
        self.ram.initialize(repeating: 0, count: 0x0800)

        let mapper = cartridge.mapper
        self.mapper = mapper
        self.nromMapper = mapper as? NROMMapper
        self.mmc1Mapper = mapper as? MMC1Mapper
        self.uxromMapper = mapper as? UxROMMapper
        self.cnromMapper = mapper as? CNROMMapper
        self.mmc3Mapper = mapper as? MMC3Mapper
        self.mmc5Mapper = mapper as? MMC5Mapper
        self.axromMapper = mapper as? AxROMMapper
        self.mmc2Mapper = mapper as? MMC2Mapper
        self.mmc4Mapper = mapper as? MMC4Mapper
        self.colorDreamsMapper = mapper as? ColorDreamsMapper
        self.gnromMapper = mapper as? GNROMMapper
        self.mapper71 = mapper as? Mapper71

        let readClosure: ((UInt16) -> UInt8) = { addr in
            cartridge.mapper.cpuRead(address: addr)
        }
        let writeClosure: ((UInt16, UInt8) -> Void) = { addr, val in
            cartridge.mapper.cpuWrite(address: addr, value: val)
        }

        self.prgReadTable = Array(repeating: readClosure, count: 0x10000)
        self.prgWriteTable = Array(repeating: writeClosure, count: 0x10000)
    }

    deinit {
        ram.deinitialize(count: 0x0800)
        ram.deallocate()
    }

    @inline(__always) func clearMapperIRQ() {
        cartridge.mapper.mapperIRQClear()
    }

    @inline(__always) func setMapperID(_ id: Int) {
        mapperID = id
        mmc3PRGBanks = [0, 1, -2, -1]
        mmc3CHR = Array(repeating: 0, count: 8)
        mmc3BankSelect = 0
        mmc3PRGMode = false
        mmc3CHRMode = false
        mmc3IRQCounter = 0
        mmc3IRQReload = 0
        mmc3IRQEnabled = false
        mmc3IRQPending = false
        if chr.isEmpty { chr = Array(repeating: 0, count: 0x2000) }
    }

    @inline(__always) private func ramIndex(_ addr: UInt16) -> Int {
        Int(addr & 0x07FF)
    }

    // MARK: - CPU Read / Write

    @inline(__always)
    func cpuRead(address: UInt16) -> UInt8 {
        if address < 0x2000 {
            return ram[ramIndex(address)]
        }

        if address < 0x4000 {
            return ppuRegisterReads[Int(address & 0x0007)]()
        }

        if address == 0x4015 {
            return apu.readStatus()
        }

        if address == 0x4016 {
            return controller.read()
        }

        if address >= 0x6000 {
            return prgReadTable[Int(address)](address)
        }

        return 0
    }

    @inline(__always)
    func cpuWrite(address: UInt16, value: UInt8) {
        if address < 0x2000 {
            ram[ramIndex(address)] = value
            return
        }

        if address < 0x4000 {
            ppuRegisterWrites[Int(address & 0x0007)](value)
            return
        }

        if address <= 0x4013 || address == 0x4015 || address == 0x4017 {
            apu.cpuWrite(address: address, value: value)
            return
        }

        if address == 0x4014 {
            if let core = core {
                core.dmaActive = true
                core.dmaSourceAddr = UInt16(value) << 8
                core.dmaByteIndex = 0
                core.dmaOamIndex = ppu.oamAddr
                let align = (core.cpu?.cycles ?? 0) % 2 == 1 ? 1 : 0
                core.dmaCyclesLeft = 513 + align
            }
            return
        }

        if address == 0x4016 {
            controller.write(value: value)
            return
        }

        if address >= 0x6000 {
            prgWriteTable[Int(address)](address, value)
        }
    }

    // MARK: - PRG Helpers

    @inline(__always) func prgRead(bank: Int, offset: Int) -> UInt8 {
        let size = prg.count
        if size == 0 { return 0 }

        let bankSize = 0x2000
        var b = bank
        if b < 0 {
            let nbanks = size / bankSize
            b = nbanks + bank
            if b < 0 { b = 0 }
        }

        var idx = b * bankSize + offset
        idx = max(0, min(size - 1, idx))
        return prg[idx]
    }

    @inline(__always) func applyMirroringFromMMC1(_ mode: UInt8) {
        if let mmc1 = cartridge.mapper as? MMC1Mapper {
            mmc1.applyControl(mmc1Control)
        }
    }
}
