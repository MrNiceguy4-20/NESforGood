import Foundation

final class Bus {
    // MARK: - MMC1 (Mapper 1) state
    // Kept to avoid changing the Bus class structure, though unused now.
    private var mmc1Shift: UInt8 = 0x10
    private var mmc1Control: UInt8 = 0x0C
    private var mmc1CHR0: UInt8 = 0
    private var mmc1CHR1: UInt8 = 0
    private var mmc1PRG: UInt8 = 0
    private var mmc1PRGRAMDisable: Bool = false
    private var mmc1Mirroring: UInt8 = 2
    private var prgRAM: [UInt8] = Array(repeating: 0, count: 0x2000)
    
    // MARK: - ROM data buffers
    public var prg: [UInt8] = []
    public var chr: [UInt8] = []
    
    // MARK: - Mapper integration
    var mapperID: Int = 0
    // Kept to avoid changing the Bus class structure, though unused now.
    private var mmc3PRGBanks: [Int] = [0, 0, -2, -1]
    private var mmc3CHR: [Int] = Array(repeating: 0, count: 8)
    private var mmc3BankSelect: UInt8 = 0
    private var mmc3PRGMode: Bool = false
    private var mmc3CHRMode: Bool = false
    private var mmc3IRQCounter: UInt8 = 0
    private var mmc3IRQReload: UInt8 = 0
    private var mmc3IRQEnabled: Bool = false
    private var mmc3IRQPending: Bool = false
    
    public var mapperIRQAsserted: Bool {
        return cartridge.mapper.mapperIRQAsserted()
    }
    
    func clearMapperIRQ() {
        cartridge.mapper.mapperIRQClear()
    }
    
    func setMapperID(_ id: Int) {
        mapperID = id
        mmc3PRGBanks = [0, 1, -2, -1]
        mmc3CHR = Array(repeating: 0, count: 8)
        mmc3BankSelect = 0; mmc3PRGMode = false; mmc3CHRMode = false
        mmc3IRQCounter = 0; mmc3IRQReload = 0; mmc3IRQEnabled = false; mmc3IRQPending = false
        if chr.isEmpty { chr = Array(repeating: 0, count: 0x2000) }
    }
    
    private var ram = [UInt8](repeating: 0, count: 0x0800)
    
    var cartridge: Cartridge
    let ppu: PPU
    let apu: APU
    let controller: Controller
    weak var core: EmulatorCore?
    
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
    }
    
    @inline(__always) private func ppuReg(_ addr: UInt16) -> UInt16 {
        return 0x2000 | (addr & 0x0007)
    }
    
    @inline(__always) private func ramIndex(_ addr: UInt16) -> Int {
        return Int(addr & 0x07FF)
    }
    
    func cpuRead(address: UInt16) -> UInt8 {
        if address >= 0x0200 && address <= 0x02FF {
            let value = ram[ramIndex(address)]
            
            return value
        }
        
        // FIX: Route all high memory reads directly to the mapper/cartridge.
        if address >= 0x6000 {
            return cartridge.mapper.cpuRead(address: address)
        }
        // Old redundant MMC1/MMC3 logic removed.
        
        switch address {
        case 0x0000...0x1FFF:
            return ram[ramIndex(address)]
        
        case 0x2000...0x3FFF:
            return ppu.cpuRead(address: ppuReg(address))
        
        case 0x4000...0x4013, 0x4015, 0x4017:
            return apu.read(address: address)
        
        case 0x4014:
            return 0
        
        case 0x4016:
            return controller.read()
        
        case 0x4018...0x5FFF:
            return 0
        
        default:
            log("cpuRead from unmapped \(String(format: "$%04X", address))")
            return 0
        }
    }
    
    func cpuWrite(address: UInt16, value: UInt8) {
        
        // FIX: Route all high memory writes directly to the mapper/cartridge.
        if address >= 0x6000 {
            cartridge.mapper.cpuWrite(address: address, value: value)
            return
        }
        // Old redundant MMC1/MMC3 logic removed.
        
        switch address {
        case 0x0000...0x1FFF:
            ram[ramIndex(address)] = value
        
        case 0x2000...0x3FFF:
            ppu.cpuWrite(address: ppuReg(address), value: value)
        
        case 0x4000...0x4013, 0x4015, 0x4017:
            apu.write(address: address, value: value)
        
        case 0x4014:
            
            ppu.oamDMA(bus: self, value: value)
            if let core = core {
                core.dmaActive = true
                core.dmaSourceAddr = UInt16(value) << 8
                core.dmaByteIndex = 0
                core.dmaOamIndex = ppu.oamAddr
                let align = (core.cpu?.cycles ?? 0) % 2 == 1 ? 1 : 0
                core.dmaCyclesLeft = 513 + align
            }
        
        case 0x4016:
            controller.write(value: value)
        
        case 0x4018...0x5FFF:
            break
        
        default:
            log("cpuWrite to unmapped \(String(format: "$%04X", address)) = \(String(format: "$%02X", value))")
        }
    }
    
    func prgRead(bank: Int, offset: Int) -> UInt8 {
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
    
    func applyMirroringFromMMC1(_ mode: UInt8) {
        if let mmc1 = cartridge.mapper as? MMC1Mapper {
            mmc1.applyControl(mmc1Control)
        }
    }
}
