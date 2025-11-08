import Foundation
import CoreGraphics
import AppKit
import SwiftUI
import Metal

// MARK: - PPU (Picture Processing Unit)
final class PPU {
    // ===== CPU-visible registers =====
    var ctrl: UInt8 = 0           // $2000
    var mask: UInt8 = 0           // $2001
    var status: UInt8 = 0         // $2002
    var oamAddr: UInt8 = 0        // $2003
    var scroll: UInt16 = 0        // synthesized from $2005 writes
    var addr: UInt16 = 0          // synthesized from $2006 writes
    var data: UInt8 = 0           // $2007 data port (buffered)
    // MARK: - Bus connection
    weak var bus: Bus?
    // ===== Internal VRAM/palette/OAM =====
    private(set) var vram: [UInt8]
    private var palette = [UInt8](repeating: 0, count: 0x20)
    private var cachedPalette = [UInt8](repeating: 0, count: 0x20)
    var oam = [UInt8](repeating: 0xFF, count: 256)
    private var secondaryOAM = [UInt8](repeating: 0xFF, count: 32)
    
    
    // ===== BG auto-detect for pattern table base =====
    private var bgAutoBaseLocked: Bool = false
    private var bgAutoBase: UInt16 = 0x0000
    private var bgAutoProbeCount: Int = 0
    private var bgAutoNonZeroSeen: Bool = false
    private var bgProbeLastLo: UInt8 = 0
    private var bgProbeBaseUsed: UInt16 = 0x0000
// ===== Loopy registers =====
    private var v: UInt16 = 0
    private var t: UInt16 = 0
    private var x: UInt8 = 0
    private var w: Bool = false
    private var dataBuffer: UInt8 = 0
    
    // ===== Timing =====
    private(set) var cycle: Int = 0
    private(set) var scanline: Int = -1
    private(set) var frame: UInt64 = 0
    var frameReady: Bool = false
    var nmiPending: Bool = false
    private(set) var ppuDot: UInt64 = 0
    // DEBUG counters
    private var dbgBgNonZeroPx: Int = 0
    private var dbgBgSamplerNonZero: Int = 0
    private var dbgFrames: UInt64 = 0
    
    // ===== Cartridge/mirroring =====
    private let cartridge: Cartridge
    private let baseMirroring: Mirroring
    
    // ===== Background shifters and prefetch =====
    private var bgNextTileId: UInt8 = 0
    private var bgNextTileAttrib: UInt8 = 0
    private var bgNextTileLsb: UInt8 = 0
    private var bgNextTileMsb: UInt8 = 0
    private var bgShifterPatternLo: UInt16 = 0
    private var bgShifterPatternHi: UInt16 = 0
    private var bgShifterAttribLo: UInt16 = 0
    private var bgShifterAttribHi: UInt16 = 0
    
    // ===== Sprite pipeline =====
    private var spriteCount: Int = 0
    private var spriteShifterPatternLo = [UInt8](repeating: 0, count: 8)
    private var spriteShifterPatternHi = [UInt8](repeating: 0, count: 8)
    private var spriteAttributes = [UInt8](repeating: 0, count: 8)
    private var spriteXPositions = [UInt8](repeating: 0, count: 8)
    private var spriteZeroHitPossible: Bool = false
    
    // ===== Packed framebuffer =====
    private let fbW = 256
    private let fbH = 240
    private let fbCount: Int
    private let fbBytesPerRow: Int
    private var fbPtr: UnsafeMutablePointer<UInt32>
    
    // ===== Reused CG objects =====
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo: CGBitmapInfo = [
        .byteOrder32Little,
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
    ]
    private var dataProvider: CGDataProvider!
    private var cachedCGImage: CGImage!
    
    // ===== System palette (64 entries) =====
    private static let sysPal: [UInt32] = [
        0x7C7C7C,0x0000FC,0x0000BC,0x4428BC,0x940084,0xA80020,0xA81000,0x881400,
        0x503000,0x007800,0x006800,0x005800,0x000058,0x000000,0x000000,0x000000,
        0xBCBCBC,0x0078F8,0x0058F8,0x6844FC,0xD800CC,0xE40058,0xF83800,0xE45C10,
        0xAC7C00,0x00B800,0x00A800,0x00A844,0x008888,0x000000,0x000000,0x000000,
        0xF8F8F8,0x3CBCFC,0x6888FC,0x9878F8,0xF878F8,0xF85898,0xF87858,0xFCA044,
        0xF8B800,0xB8F818,0x58D854,0x58F898,0x00E8D8,0x787878,0x000000,0x000000,
        0xFCFCFC,0xA4E4FC,0xB8B8F8,0xD8B8F8,0xF8B8F8,0xF8A4C0,0xF0D0B0,0xFCE0A8,
        0xF8D878,0xD8F878,0xB8F8B8,0xB8F8D8,0x00FCFC,0xF8D8F8,0x000000,0x000000
    ]
    
    // ===== Loopy masks/mirroring helpers =====
    private let coarseXMask: UInt16 = 0x001F
    private let coarseYMask: UInt16 = 0x03E0
    private let nametableXMask: UInt16 = 0x0400
    private let nametableYMask: UInt16 = 0x0800
    private let fineYMask: UInt16 = 0x7000
    private let nametableMask: UInt16 = 0x0C00
    private let xScrollMask: UInt16 = 0x041F
    private let yScrollMask: UInt16 = 0x7BE0
    private let vramAddrMask: UInt16 = 0x3FFF
    private let tableMapHorizontal = [0,0,1,1]
    private let tableMapVertical = [0,1,0,1]
    @inline(__always) private func currentMirroring() -> Mirroring {
        if let m = cartridge.mapper as? MMC3Mapper { return m.mirroring }
        if let m = cartridge.mapper as? MMC1Mapper { return m.mirroring }
        if let m = cartridge.mapper as? AxROMMapper { return m.mirroring }
        if let m = cartridge.mapper as? MMC5Mapper { return m.mirroring }
        return baseMirroring
    }
    
    private var rendering: Bool { (mask & 0x18) != 0 }
    
    init(cartridge: Cartridge) {
        self.cartridge = cartridge
        self.baseMirroring = cartridge.mirroring
        self.vram = [UInt8](repeating: 0, count: baseMirroring == .fourScreen ? 0x1000 : 0x800)
        
        self.fbCount = fbW * fbH
        self.fbBytesPerRow = fbW * MemoryLayout<UInt32>.size
        self.fbPtr = .allocate(capacity: fbCount)
        self.fbPtr.initialize(repeating: 0xFF000000, count: fbCount)
        
        self.dataProvider = CGDataProvider(
            dataInfo: nil,
            data: UnsafeRawPointer(fbPtr),
            size: fbCount * MemoryLayout<UInt32>.size,
            releaseData: { _,_,_ in }
        )
        
        self.cachedCGImage = CGImage(
            width: fbW,
            height: fbH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: fbBytesPerRow,
            space: PPU.colorSpace,
            bitmapInfo: PPU.bitmapInfo,
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
    
    deinit {
        fbPtr.deinitialize(count: fbCount)
        fbPtr.deallocate()
    }
    
    func cpuRead(address: UInt16) -> UInt8 {
        switch address {
        case 0x2002:
            let v = status
            status &= 0x7F
            w = false
            // FIX: NES does not clear nmiPending on $2002 read. Only NMI execution or PPU reset clears it.
            // nmiPending = false // REMOVED
            return v
        case 0x2004:
            return oam[Int(oamAddr)]
        case 0x2007:
            let addr = self.v & 0x3FFF
            var ret: UInt8 = 0
            if (addr & 0x3F00) == 0x3F00 {
                ret = ppuRead(addr: addr)
                dataBuffer = ppuRead(addr: (addr &- 0x1000) & 0x3FFF)
            } else {
                ret = dataBuffer
                dataBuffer = ppuRead(addr: addr)
            }
            self.v &+= (ctrl & 0x04) == 0 ? 1 : 32
            return ret
        default:
            return 0
        }
    }
    
    func cpuWrite(address: UInt16, value: UInt8) {
        switch address {
        case 0x2000:
            ctrl = value
            t = (t & ~nametableMask) | (UInt16(value & 0x03) << 10)
            
        case 0x2001:
            mask = value
            
        case 0x2003:
            oamAddr = value
        case 0x2004:
            oam[Int(oamAddr)] = value
            oamAddr &+= 1
        case 0x2005:
            if !w {
                t = (t & ~coarseXMask) | UInt16(value >> 3)
                x = value & 0x07
            } else {
                let fy = UInt16(value & 0x07) << 12
                let cy = UInt16((value >> 3) & 0x1F) << 5
                t = (t & ~yScrollMask) | fy | cy
            }
            w.toggle()
        case 0x2006:
            if !w {
                t = (t & 0x00FF) | (UInt16(value & 0x3F) << 8)
            } else {
                t = (t & 0xFF00) | UInt16(value)
                v = t
            }
            w.toggle()
        case 0x2007:
            ppuWrite(addr: v, value: value)
            v &+= (ctrl & 0x04) == 0 ? 1 : 32
        default:
            break
        }
    }
    
    @inline(__always) private func ppuRead(addr: UInt16) -> UInt8 {
        let a = addr & vramAddrMask
        if a < 0x2000 {
            cartridge.mapper.ppuA12Observe(addr: a, ppuDot: ppuDot)
            return cartridge.mapper.ppuRead(address: a)
        }
        if a < 0x3F00 { return vram[Int(nameTableMirror(addr: a))] }
        var pa = a & 0x001F
        if pa == 0x10 { pa = 0x00 }
        else if pa == 0x14 { pa = 0x04 }
        else if pa == 0x18 { pa = 0x08 }
        else if pa == 0x1C { pa = 0x0C }
        return cachedPalette[Int(pa)] & 0x3F
    }
    
    @inline(__always) private func ppuWrite(addr: UInt16, value: UInt8) {
        let a = addr & vramAddrMask
        if a < 0x2000 {
            cartridge.mapper.ppuWrite(address: a, value: value)
            return
        }
        if a < 0x3F00 {
            vram[Int(nameTableMirror(addr: a))] = value
            return
        }
        var pa = a & 0x001F
        if pa == 0x10 { pa = 0x00 }
        else if pa == 0x14 { pa = 0x04 }
        else if pa == 0x18 { pa = 0x08 }
        else if pa == 0x1C { pa = 0x0C }
        palette[Int(pa)] = value
        cachedPalette[Int(pa)] = value
    }
    
    @inline(__always) private func nameTableMirror(addr: UInt16) -> UInt16 {
        let base = (addr - 0x2000) % 0x1000
        let table = base / 0x400
        let offset = base % 0x400
        if let mmc5 = cartridge.mapper as? MMC5Mapper {
            let map = mmc5.nametableMap
            let nt = (map >> (2 * Int(table))) & 0x03
            switch nt {
            case 0: return offset % 0x400
            case 1: return 0x400 + (offset % 0x400)
            case 2: return UInt16(mmc5.fillTile)
            case 3: return UInt16(mmc5.fillTile)
            default: return offset % 0x400
            }
        }
        switch currentMirroring() {
        case .horizontal:
            return UInt16(tableMapHorizontal[Int(table)]) * 0x400 + offset
        case .vertical:
            return UInt16(tableMapVertical[Int(table)]) * 0x400 + offset
        case .fourScreen:
            return addr & 0x0FFF
        case .singleScreenLow:
            return offset % 0x400
        case .singleScreenHigh:
            return 0x400 + (offset % 0x400)
        }
    }
    
    func oamDMA(bus: Bus, value: UInt8) {
        let start = UInt16(value) << 8
        // Clear OAM before DMA to avoid stale data
        oam = [UInt8](repeating: 0xFF, count: 256)
        
        for i in 0..<256 {
            let a = start + UInt16(i)
            let d = bus.cpuRead(address: a)
            // Log every 4th byte (sprite Y-position)
            if i % 4 == 0 {
                
            }
            oam[i] = d
        }
        // Reset oamAddr after DMA
        oamAddr = 0
    }
    
    private func cachePalette() {
        for i in 0..<0x20 {
            var pa = UInt16(i)
            if pa == 0x10 { pa = 0x00 }
            else if pa == 0x14 { pa = 0x04 }
            else if pa == 0x18 { pa = 0x08 }
            else if pa == 0x1C { pa = 0x0C }
            cachedPalette[Int(pa)] = palette[Int(pa)] & 0x3F
        }
    }
    
    func tick() {
        if scanline == -1 && cycle == 0 {
            cachePalette()
        }
        
        if rendering && scanline >= 0 && scanline < 240 {
            let c = cycle
            if (c >= 1 && c <= 256) || (c >= 321 && c <= 336) {
                bgShifterPatternLo &<<= 1
                bgShifterPatternHi &<<= 1
                bgShifterAttribLo &<<= 1
                bgShifterAttribHi &<<= 1
                
                switch (c - 1) & 7 {
                case 0: loadBGShifters(); fetchNameTable()
                case 2: fetchAttrib()
                case 4: fetchLoTile()
                case 6:
                    fetchHiTile()
                    incX()
                default: break
                }
            }
            if cycle == 256 { incY() }
            if cycle == 257 { transferX() }
            if cycle == 65 { evalSprites() }
            if cycle == 257 { fetchSpriteData() }
            if cycle >= 1 && cycle <= 256 {
                renderPixelFast()
                advanceSpriteShifters()
            }
        }
        
        // FIX (Prev): Horizontal Transfer must happen on the pre-render scanline at cycle 257.
        if scanline == -1 && rendering && cycle == 257 {
            transferX()
        }
        
        if scanline == -1 && rendering && cycle >= 280 && cycle <= 304 {
            transferY()
        }
        
        cycle &+= 1
        ppuDot &+= 1
        if cycle >= 341 {
            cycle = 0
            scanline &+= 1
            if scanline >= 261 {
                scanline = -1
                frame &+= 1
                frameReady = true
            }
        }
        
        if scanline == -1 && cycle == 0 && rendering && (frame & 1) == 1 {
            cycle = 1
        }
        
        if scanline == 241 && cycle == 1 {
            #if DEBUG
            print(String(format:"[PPU][Frame %llu] BGpx=%d, BGsamp=%d", dbgFrames, dbgBgNonZeroPx, dbgBgSamplerNonZero))
            dbgBgNonZeroPx = 0
            dbgBgSamplerNonZero = 0
            dbgFrames &+= 1
            #endif
            status |= 0x80
            if (ctrl & 0x80) != 0 { nmiPending = true }
        } else if scanline == -1 && cycle == 1 {
            status = 0
            spriteZeroHitPossible = false
            nmiPending = false
            // FIX (Robustness): MMC5 Scanline Counter Reset
            if let mapper = cartridge.mapper as? MMC5Mapper {
                mapper.resetScanlineCounter()
            }
        }
        
        // FIX: Moved MMC1 bank switch to a cleaner timing point (cycle 340 of pre-render line -1)
        if scanline == -1 && cycle == 340, let mmc1 = cartridge.mapper as? MMC1Mapper {
            mmc1.applyPendingBankSwitchIfSafe(ppuDot: ppuDot)
        }
        
        if let mapper = cartridge.mapper as? MMC3Mapper {
            mapper.tickPPUCycles(1)
        }
    }
    
    @inline(__always) private func loadBGShifters() {
        let loMask: UInt16 = (bgNextTileAttrib & 0x01) != 0 ? 0xFF : 0x00
        let hiMask: UInt16 = (bgNextTileAttrib & 0x02) != 0 ? 0xFF : 0x00
        bgShifterAttribLo = (bgShifterAttribLo & 0xFF00) | loMask
        bgShifterAttribHi = (bgShifterAttribHi & 0xFF00) | hiMask
        bgShifterPatternLo = (bgShifterPatternLo & 0xFF00) | UInt16(bgNextTileLsb)
        bgShifterPatternHi = (bgShifterPatternHi & 0xFF00) | UInt16(bgNextTileMsb)
    }
    
    @inline(__always) private func fetchNameTable() {
        if let mmc5 = cartridge.mapper as? MMC5Mapper, mmc5.extRamMode == 0 {
            bgNextTileId = mmc5.fillTile
        } else {
            bgNextTileId = ppuRead(addr: 0x2000 | (v & 0x0FFF))
        }
    }
    
    @inline(__always) private func fetchAttrib() {
        if let mmc5 = cartridge.mapper as? MMC5Mapper, mmc5.extAttrEnabled {
            let nt = (v & 0x0C00) >> 10
            let coarseX = (v & 0x001F)
            let coarseY = (v & 0x03E0) >> 5
            let exRamAddr = Int(nt * 0x400 + coarseY * 32 + coarseX)
            bgNextTileAttrib = mmc5.prgRAM?.data[exRamAddr] ?? 0
        } else {
            let a = 0x23C0 | (v & 0x0C00) | ((v >> 4) & 0x0038) | ((v >> 2) & 0x0007)
            let attr = ppuRead(addr: a)
            let q = (((v & 0x0002) != 0) ? 1 : 0) | (((v & 0x0040) != 0) ? 2 : 0)
            bgNextTileAttrib = (attr >> UInt8(q << 1)) & 0x03
        }
    }
    
    @inline(__always) private func fetchLoTile() {
        let base: UInt16
        if let mmc5 = cartridge.mapper as? MMC5Mapper, mmc5.extAttrEnabled {
            let nt = (v & 0x0C00) >> 10
            let coarseX = (v & 0x001F)
            let coarseY = (v & 0x03E0) >> 5
            let exRamAddr = Int(nt * 0x400 + coarseY * 32 + coarseX)
            let chrBank = mmc5.prgRAM?.data[exRamAddr] ?? 0
            base = UInt16(chrBank & 0x3F) << 12
        } else {
            // Force base strictly from $2000 bit 4 (no auto-detect)
            base = ((ctrl & 0x10) != 0) ? UInt16(0x1000) : UInt16(0x0000)
        }
        bgProbeBaseUsed = base
        bgProbeLastLo = ppuRead(addr: base &+ UInt16(bgNextTileId) &* 16 &+ ((v >> 12) & 0x0007))
        bgNextTileLsb = bgProbeLastLo
    }
    
    @inline(__always) private func fetchHiTile() {
        let base: UInt16
        if let mmc5 = cartridge.mapper as? MMC5Mapper, mmc5.extAttrEnabled {
            let nt = (v & 0x0C00) >> 10
            let coarseX = (v & 0x001F)
            let coarseY = (v & 0x03E0) >> 5
            let exRamAddr = Int(nt * 0x400 + coarseY * 32 + coarseX)
            let chrBank = mmc5.prgRAM?.data[exRamAddr] ?? 0
            base = UInt16(chrBank & 0x3F) << 12
        } else {
            // Force base strictly from $2000 bit 4 (no auto-detect)
            base = ((ctrl & 0x10) != 0) ? UInt16(0x1000) : UInt16(0x0000)
        }
        bgNextTileMsb = ppuRead(addr: base &+ UInt16(bgNextTileId) &* 16 &+ ((v >> 12) & 0x0007) &+ 8)

        // Auto-detect: if selected base is 0x1000 and repeated reads are zero, fall back to 0x0000 once
        if let mmc5 = cartridge.mapper as? MMC5Mapper, mmc5.extAttrEnabled {
            // do nothing under MMC5 ext attributes
        } else if !bgAutoBaseLocked {
            if bgProbeBaseUsed == 0x1000 {
                let both = bgProbeLastLo | bgNextTileMsb
                if both != 0 {
                    bgAutoNonZeroSeen = true
                    bgAutoBase = 0x1000
                    bgAutoBaseLocked = true
                } else {
                    bgAutoProbeCount += 1
                    if bgAutoProbeCount >= 64 && !bgAutoNonZeroSeen {
                        bgAutoBase = 0x0000
                        bgAutoBaseLocked = true
                    }
                }
            } else {
                bgAutoBase = 0x0000
                bgAutoBaseLocked = true
            }
        }
    }
    
    @inline(__always) private func incX() {
        if (v & coarseXMask) == 0x001F { v &= ~coarseXMask; v ^= nametableXMask } else { v &+= 1 }
    }
    
    @inline(__always) private func incY() {
        if (v & fineYMask) != 0x7000 {
            v &+= 0x1000 // Increment fine Y (bits 12-14)
        } else {
            v &= ~fineYMask // Clear fine Y
            var cy = (v & coarseYMask) >> 5 // Get coarse Y (bits 5-9)
            
            // --- FIXED VERTICAL WRAP LOGIC ---
            if cy == 29 {
                // coarse Y wraps from 29 to 0, toggles nametable Y bit (bit 11)
                cy = 0
                v ^= nametableYMask
            } else if cy == 31 {
                // coarse Y wraps from 31 to 0 (no nametable toggle here)
                cy = 0
            } else {
                // normal increment
                cy &+= 1
            }
            // --- END FIXED VERTICAL WRAP LOGIC ---
            
            v = (v & ~coarseYMask) | (cy << 5) // Write back coarse Y
        }
    }
    
    @inline(__always) private func transferX() { v = (v & ~xScrollMask) | (t & xScrollMask) }
    @inline(__always) private func transferY() { v = (v & ~yScrollMask) | (t & yScrollMask) }
    
    @inline(__always) private func evalSprites() {
        secondaryOAM = [UInt8](repeating: 0xFF, count: 32)
        spriteCount = 0
        spriteZeroHitPossible = false
        let height = (ctrl & 0x20) == 0 ? 8 : 16
        var n = 0
        var overflow = false
        while n < 64 && spriteCount < 8 {
            let y = Int(oam[n*4 + 0])
            let dy = Int(scanline + 1) - y
            // Skip invalid sprites (e.g., y-position 0xF8 or off-screen)
            if y == 0xF8 || dy < -height || dy >= height {
                if spriteCount == 8 {
                    overflow = true
                }
                n &+= 1
                continue
            }
            let src = n * 4
            let dst = spriteCount * 4
            secondaryOAM[dst + 0] = oam[src + 0]
            secondaryOAM[dst + 1] = oam[src + 1]
            secondaryOAM[dst + 2] = oam[src + 2]
            secondaryOAM[dst + 3] = oam[src + 3]
            if n == 0 { spriteZeroHitPossible = true }
            spriteCount &+= 1
            if scanline >= 80 && scanline <= 120 {
                 
            }
            n &+= 1
        }
        if spriteCount == 0 && scanline >= 80 && scanline <= 120 {
            
        }
        if overflow {
            status |= 0x20
        }
    }
    
    @inline(__always) private func fetchSpriteData() {
        let height = (ctrl & 0x20) == 0 ? 8 : 16
        var table: UInt16 = 0
        // Lock CHR bank for MMC1 during sprite fetch
        var lockedBank0Offset: Int? = nil
        var lockedBank1Offset: Int? = nil
        if let mmc1 = cartridge.mapper as? MMC1Mapper {
            lockedBank0Offset = mmc1.chrBank0Offset
            lockedBank1Offset = mmc1.chrBank1Offset
        }
        
        for i in 0..<spriteCount {
            let y = Int(secondaryOAM[i*4])
            let tile = secondaryOAM[i*4 + 1]
            let attr = secondaryOAM[i*4 + 2]
            let xPos = secondaryOAM[i*4 + 3]
            spriteXPositions[i] = xPos
            spriteAttributes[i] = attr
            
            var dy = Int(scanline + 1) - y
            dy = max(0, min(dy, height - 1))
            if (attr & 0x80) != 0 { dy = height - 1 - dy }
            
            var addr: UInt16
            if let mmc5 = cartridge.mapper as? MMC5Mapper, mmc5.extAttrEnabled {
                let nt = (v & 0x0C00) >> 10
                let coarseX = (v & 0x001F)
                let coarseY = (v & 0x03E0) >> 5
                let exRamAddr = Int(nt * 0x400 + coarseY * 32 + coarseX)
                let chrBank = mmc5.prgRAM?.data[exRamAddr] ?? 0
                addr = UInt16(chrBank & 0x3F) << 12 &+ UInt16(tile) &* 16 &+ UInt16(dy)
                table = UInt16(chrBank & 0x3F) << 12
            } else if height == 8 {
                table = UInt16((ctrl & 0x08) != 0 ? 1 : 0) << 12
                addr = table &+ UInt16(tile) &* 16 &+ UInt16(dy)
            } else {
                table = UInt16(tile & 1) << 12
                let tileBase = tile & 0xFE
                let off = dy >= 8 ? 16 : 0
                addr = table &+ UInt16(tileBase) &* 16 &+ UInt16(dy & 7) &+ UInt16(off)
            }
            
            let lo: UInt8
            let hi: UInt8
            if let mmc1 = cartridge.mapper as? MMC1Mapper, let bank0 = lockedBank0Offset, let bank1 = lockedBank1Offset {
                let a = Int(addr & 0x1FFF)
                let chrMode4K = (mmc1.control & 0x10) != 0
                let idx: Int
                if chrMode4K {
                    idx = a < 0x1000 ? bank0 + a : bank1 + (a - 0x1000)
                } else {
                    idx = bank0 + a
                }
                lo = mmc1.chr.data[idx % max(mmc1.chr.data.count, 1)]
                hi = mmc1.chr.data[(idx + 8) % max(mmc1.chr.data.count, 1)]
                if scanline >= 80 && scanline <= 120 {
                    
                }
            } else {
                lo = ppuRead(addr: addr)
                hi = ppuRead(addr: addr &+ 8)
                if scanline >= 80 && scanline <= 120 {
                    
                }
            }
            
            spriteShifterPatternLo[i] = (attr & 0x40) != 0 ? rev8(lo) : lo
            spriteShifterPatternHi[i] = (attr & 0x40) != 0 ? rev8(hi) : hi
        }
        
        // Dummy fetch for MMC3 IRQs
        if spriteCount == 0 {
            let addr = UInt16(0x1000)
            _ = ppuRead(addr: addr)
            _ = ppuRead(addr: addr &+ 8)
        }
        for i in spriteCount..<8 {
            spriteShifterPatternLo[i] = 0
            spriteShifterPatternHi[i] = 0
        }
    }
    
    @inline(__always) private func rev8(_ b: UInt8) -> UInt8 {
        var v = b
        v = ((v >> 1) & 0x55) | ((v & 0x55) << 1)
        v = ((v >> 2) & 0x33) | ((v & 0x33) << 2)
        v = ((v >> 4) & 0x0F) | ((v & 0x0F) << 4)
        return v
    }
    
    @inline(__always) private func advanceSpriteShifters() {
        for i in 0..<spriteCount {
            if spriteXPositions[i] > 0 {
                spriteXPositions[i] &-= 1
            } else {
                spriteShifterPatternLo[i] <<= 1
                spriteShifterPatternHi[i] <<= 1
            }
        }
    }
    
    @inline(__always) private func renderPixelFast() {
        let bgOn = (mask & 0x08) != 0
        let spOn = (mask & 0x10) != 0
        let leftBg = (mask & 0x02) != 0
        let leftSp = (mask & 0x04) != 0
        let c = cycle - 1
        
        var bgPixel: UInt8 = 0, bgPal: UInt8 = 0
        var useSplit = false
        var splitPixel: UInt8 = 0, splitPal: UInt8 = 0

        if let mmc5 = cartridge.mapper as? MMC5Mapper, mmc5.splitEnabled && bgOn {
            let tileX = c / 8
            if (mmc5.splitSide && tileX >= Int(mmc5.splitThreshold)) || (!mmc5.splitSide && tileX < Int(mmc5.splitThreshold)) {
                let splitV = UInt16(mmc5.splitScroll) << 5
                let base = UInt16(mmc5.splitChrBank & 0x3F) << 12
                let tileAddr = 0x2000 | (splitV & 0x0FFF)
                let tileId = ppuRead(addr: tileAddr)
                let attrAddr = 0x23C0 | (splitV & nametableMask) | ((splitV >> 7) & 0x0038) | ((splitV >> 2) & 0x0007)
                let attr = ppuRead(addr: attrAddr)
                let q = (((splitV & 0x0002) != 0) ? 1 : 0) | (((splitV & 0x0040) != 0) ? 2 : 0)
                let splitAttr = (attr >> UInt8(q << 1)) & 0x03
                let lo = ppuRead(addr: base &+ UInt16(tileId) &* 16 &+ ((splitV >> 12) & 0x0007))
                let hi = ppuRead(addr: base &+ UInt16(tileId) &* 16 &+ ((splitV >> 12) & 0x0007) &+ 8)
                let xMask: UInt16 = 0x8000 >> (x + UInt8(c % 8))
                let p0 = (lo & UInt8(xMask >> 8)) != 0 ? 1 : 0
                let p1 = (hi & UInt8(xMask >> 8)) != 0 ? 1 : 0
                splitPixel = UInt8((p1 << 1) | p0)
                splitPal = splitAttr
                useSplit = splitPixel != 0
    }
        }

        if !useSplit {
            let xMask: UInt16 = 0x8000 >> x
            let p0 = (bgShifterPatternLo & xMask) != 0 ? 1 : 0
            let p1 = (bgShifterPatternHi & xMask) != 0 ? 1 : 0
            bgPixel = UInt8((p1 << 1) | p0)
            
            let a0 = (bgShifterAttribLo & xMask) != 0 ? 1 : 0
            let a1 = (bgShifterAttribHi & xMask) != 0 ? 1 : 0
            bgPal = UInt8((a1 << 1) | a0)
            
            if !bgOn || (c < 8 && !leftBg) { bgPixel = 0; bgPal = 0 }
        } else {
            bgPixel = splitPixel
            bgPal = splitPal
        }
        
        var s0: UInt8 = 0
        if spriteZeroHitPossible && spriteCount > 0 && spriteXPositions[0] == 0 {
            let s0p1: UInt8 = (spriteShifterPatternHi[0] & 0x80) != 0 ? 1 : 0
            let s0p0: UInt8 = (spriteShifterPatternLo[0] & 0x80) != 0 ? 1 : 0
            s0 = (s0p1 << 1) | s0p0
        }
        
        var fgPixel: UInt8 = 0, fgPal: UInt8 = 0
        var fgPri = false
        var fgIndex: Int? = nil
        if spOn && spriteCount > 0 { // Ensure sprites are only rendered if enabled
            for i in 0..<spriteCount {
                if spriteXPositions[i] == 0 {
                    let p1: UInt8 = (spriteShifterPatternHi[i] & 0x80) != 0 ? 1 : 0
                    let p0: UInt8 = (spriteShifterPatternLo[i] & 0x80) != 0 ? 1 : 0
                    let px = (p1 << 1) | p0
                    if px != 0 {
                        fgPixel = px
                        fgPal = (spriteAttributes[i] & 0x03) + 0x04
                        fgPri = (spriteAttributes[i] & 0x20) == 0
                        fgIndex = i
                        break
                    }
                }
            }
            if c < 8 && !leftSp { fgPixel = 0; fgPal = 0; fgIndex = nil }
        }
        
        // FIX 1: Sprite 0 Hit suppression in cycles 1-8 if mask bit 2 is clear.
        if s0 != 0 && bgPixel != 0 && bgOn && spOn && c < 255 {
            // c is 0-indexed column, so c=0 is cycle 1.
            // Check if rendering is enabled in the left 8 pixels OR if c >= 8
            if (c >= 8) || (mask & 0x04) != 0 {
                status |= 0x40
            }
        }
        
        let useFg = (bgPixel == 0 && fgPixel != 0) || (bgPixel != 0 && fgPixel != 0 && fgPri)
        let px: UInt8 = (bgPixel == 0 && fgPixel == 0) ? 0 : (useFg ? fgPixel : bgPixel)
        let pal: UInt8 = (bgPixel == 0 && fgPixel == 0) ? 0 : (useFg ? fgPal : bgPal)
        
        var colorIndex: UInt8
        if let mmc5 = cartridge.mapper as? MMC5Mapper, mmc5.extAttrEnabled && !useFg && bgPixel != 0 {
            let nt = (v & 0x0C00) >> 10
            let coarseX = (v & 0x001F)
            let coarseY = (v & 0x03E0) >> 5
            let exRamAddr = Int(nt * 0x400 + coarseY * 32 + coarseX)
            let palIdx = (mmc5.prgRAM?.data[exRamAddr] ?? 0 >> 6) & 0x03
            colorIndex = cachedPalette[Int((palIdx << 2) | UInt8(px))]
        } else {
            let idx = 0x3F00 &+ (UInt16(pal) << 2) &+ UInt16(px)
            colorIndex = ppuRead(addr: idx)
        }
        
        
        
        setPixel(x: c, y: scanline, paletteIndex: colorIndex)
    }
    
    @inline(__always) private func setPixel(x: Int, y: Int, paletteIndex: UInt8) {
        if x < 0 || x >= fbW || y < 0 || y >= fbH { return }
        let rgb = PPU.sysPal[Int(paletteIndex) & 0x3F]
        let r = (rgb >> 16) & 0xFF
        let g = (rgb >> 8) & 0xFF
        let b = rgb & 0xFF
        let pixel: UInt32 = (0xFF << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        fbPtr[y * fbW + x] = pixel
    }
    
    func getFrameImage() -> Image {
        let cgimg = CGImage(
            width: fbW,
            height: fbH,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: fbBytesPerRow,
            space: PPU.colorSpace,
            bitmapInfo: PPU.bitmapInfo,
            provider: dataProvider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        cachedCGImage = cgimg
        return Image(decorative: cgimg, scale: 1.0)
    }
    
    private var uploadBuffer: MTLBuffer?
    
    func makeTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .bgra8Unorm
        desc.width = max(1, fbW)
        desc.height = max(1, fbH)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .private
        
        let bufferSize = fbW * fbH * MemoryLayout<UInt32>.size
        uploadBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
        
        guard let texture = device.makeTexture(descriptor: desc) else {
            assertionFailure("PPU.makeTexture(): failed to create Metal texture")
            return nil
        }
        
        return texture
    }
    
    func copyFrame(to texture: MTLTexture) {
        let device = texture.device
        guard let buffer = uploadBuffer else { return }
        
        let ptr = buffer.contents().bindMemory(to: UInt32.self, capacity: fbW * fbH)
        ptr.assign(from: fbPtr, count: fbW * fbH)
        
        if let queue = device.makeCommandQueue(),
           let cmd = queue.makeCommandBuffer(),
           let blit = cmd.makeBlitCommandEncoder() {
            let region = MTLRegionMake2D(0, 0, fbW, fbH)
            blit.copy(from: buffer,
                      sourceOffset: 0,
                      sourceBytesPerRow: fbW * MemoryLayout<UInt32>.size,
                      sourceBytesPerImage: fbW * fbH * MemoryLayout<UInt32>.size,
                      sourceSize: region.size,
                      to: texture,
                      destinationSlice: 0,
                      destinationLevel: 0,
                      destinationOrigin: region.origin)
            blit.endEncoding()
            cmd.commit()
        }
    }
    
    func clearFrame() {
        fbPtr.initialize(repeating: 0xFF000000, count: fbW * fbH)
    }
    
    func reset() {
        cycle = 0
        scanline = -1
        frame = 0
        frameReady = false
        nmiPending = false
        status = 0
        ctrl = 0
        mask = 0
        oamAddr = 0
        w = false
        v = 0
        t = 0
        x = 0
        clearFrame()
        cachePalette()
        // Clear OAM to prevent stale data
        oam = [UInt8](repeating: 0xFF, count: 256)
        secondaryOAM = [UInt8](repeating: 0xFF, count: 32)
    }
    
    func pollMapperIRQ() -> Bool {
        if let b = bus, b.mapperIRQAsserted {
            if let mmc5 = cartridge.mapper as? MMC5Mapper {
                return mmc5.mapperIRQAsserted()
            }
            return true
        }
        return false
    }
}
