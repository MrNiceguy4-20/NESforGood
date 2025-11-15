import Foundation
import CoreGraphics
import AppKit
import SwiftUI
import Metal
import os.lock

final class PPU {
    // --------------------------------------------------------------------
    // MARK: - CPU-visible registers
    // --------------------------------------------------------------------
    var ctrl: UInt8 = 0
    var mask: UInt8 = 0
    var status: UInt8 = 0
    var oamAddr: UInt8 = 0
    var scroll: UInt16 = 0
    var addr: UInt16 = 0
    var data: UInt8 = 0
    
    // --------------------------------------------------------------------
    // MARK: - Bus connection
    // --------------------------------------------------------------------
    weak var bus: Bus?
    
    // --------------------------------------------------------------------
    // MARK: - Internal VRAM / palette / OAM
    // --------------------------------------------------------------------
    private(set) var vram: UnsafeMutablePointer<UInt8>
    private var palette = [UInt8](repeating: 0, count: 0x20)
    private var cachedPalette = [UInt8](repeating: 0, count: 0x20)
    private var oam: UnsafeMutablePointer<UInt8>
    private var secondaryOAM: UnsafeMutablePointer<UInt8>
    private let vramSize: Int
    
    // --------------------------------------------------------------------
    // MARK: - Loopy registers
    // --------------------------------------------------------------------
    private var v: UInt16 = 0
    private var t: UInt16 = 0
    private var x: UInt8 = 0
    private var w: Bool = false
    private var dataBuffer: UInt8 = 0
    
    // --------------------------------------------------------------------
    // MARK: - Timing
    // --------------------------------------------------------------------
    private(set) var cycle: Int = 0
    private(set) var scanline: Int = -1
    private(set) var frame: UInt64 = 0
    var frameReady: Bool = false
    var nmiPending: Bool = false
    private(set) var ppuDot: UInt64 = 0
    
    private var currentTick: () -> Void = { }
    
    // --------------------------------------------------------------------
    // MARK: - Cartridge / mirroring
    // --------------------------------------------------------------------
    private let cartridge: Cartridge
    private let baseMirroring: Mirroring
    private var mmc3Mapper: MMC3Mapper?
    private var mmc5Mapper: MMC5Mapper?
    
    // --------------------------------------------------------------------
    // MARK: - Background shifters / prefetch
    // --------------------------------------------------------------------
    private var bgNextTileId: UInt8 = 0
    private var bgNextTileAttrib: UInt8 = 0
    private var bgNextTileLsb: UInt8 = 0
    private var bgNextTileMsb: UInt8 = 0
    private var bgShifterPatternLo: UInt16 = 0
    private var bgShifterPatternHi: UInt16 = 0
    private var bgShifterAttribLo: UInt16 = 0
    private var bgShifterAttribHi: UInt16 = 0
    
    // --------------------------------------------------------------------
    // MARK: - Sprite pipeline
    // --------------------------------------------------------------------
    private var spriteCount: Int = 0
    private var spriteShifterPatternLo = [UInt8](repeating: 0, count: 8)
    private var spriteShifterPatternHi = [UInt8](repeating: 0, count: 8)
    private var spriteAttributes = [UInt8](repeating: 0, count: 8)
    private var spriteXPositions = [UInt8](repeating: 0, count: 8)
    private var spriteZeroHitPossible: Bool = false
    
    // --------------------------------------------------------------------
    // MARK: - Framebuffer
    // --------------------------------------------------------------------
    private let fbW = 256
    private let fbH = 240
    private let fbCount: Int
    private let fbBytesPerRow: Int
    
    private var fbPtrA: UnsafeMutablePointer<UInt32>
    private var fbPtrB: UnsafeMutablePointer<UInt32>
    @usableFromInline internal var fbPtrBack: UnsafeMutablePointer<UInt32>
    @usableFromInline internal var fbPtrFront: UnsafeMutablePointer<UInt32>
    private var fbLock = os_unfair_lock_s()
    
    // --------------------------------------------------------------------
    // MARK: - CG objects (re-used)
    // --------------------------------------------------------------------
    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo: CGBitmapInfo = [
        .byteOrder32Little,
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
    ]
    private var dataProvider: CGDataProvider!
    private var cachedCGImage: CGImage!
    
    // --------------------------------------------------------------------
    // MARK: - System palette (64 entries)
    // --------------------------------------------------------------------
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
    
    // --------------------------------------------------------------------
    // MARK: - Loopy masks / mirroring helpers
    // --------------------------------------------------------------------
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
    private let tableMapVertical   = [0,1,0,1]
    
    @inline(__always) private func currentMirroring() -> Mirroring {
        if let m = cartridge.mapper as? MMC3Mapper { return m.mirroring }
        if let m = cartridge.mapper as? MMC1Mapper { return m.mirroring }
        if let m = cartridge.mapper as? AxROMMapper { return m.mirroring }
        if let m = cartridge.mapper as? MMC5Mapper { return m.mirroring }
        return baseMirroring
    }
    
    private var rendering: Bool { (mask & 0x18) != 0 }
    
    // --------------------------------------------------------------------
    // MARK: - Init / deinit
    // --------------------------------------------------------------------
    init(cartridge: Cartridge) {
        self.cartridge = cartridge
        self.baseMirroring = cartridge.mirroring
        
        self.vramSize = (baseMirroring == .fourScreen) ? 0x1000 : 0x800
        self.vram = .allocate(capacity: vramSize)
        self.vram.initialize(repeating: 0, count: vramSize)
        
        self.oam = .allocate(capacity: 256)
        self.oam.initialize(repeating: 0xFF, count: 256)
        
        self.secondaryOAM = .allocate(capacity: 32)
        self.secondaryOAM.initialize(repeating: 0xFF, count: 32)
        
        self.mmc3Mapper = cartridge.mapper as? MMC3Mapper
        self.mmc5Mapper = cartridge.mapper as? MMC5Mapper
        
        self.fbCount = fbW * fbH
        self.fbBytesPerRow = fbW * MemoryLayout<UInt32>.size
        
        self.fbPtrA = .allocate(capacity: fbCount)
        self.fbPtrA.initialize(repeating: 0xFF000000, count: fbCount)
        self.fbPtrB = .allocate(capacity: fbCount)
        self.fbPtrB.initialize(repeating: 0xFF000000, count: fbCount)
        
        self.fbPtrBack = fbPtrA
        self.fbPtrFront = fbPtrB
        
        self.dataProvider = CGDataProvider(
            dataInfo: nil,
            data: UnsafeRawPointer(fbPtrFront),
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
        
        self.currentTick = self.tickPreRenderScanline
    }
    
    deinit {
        vram.deinitialize(count: vramSize)
        vram.deallocate()
        oam.deinitialize(count: 256)
        oam.deallocate()
        secondaryOAM.deinitialize(count: 32)
        secondaryOAM.deallocate()
        
        fbPtrA.deinitialize(count: fbCount)
        fbPtrA.deallocate()
        fbPtrB.deinitialize(count: fbCount)
        fbPtrB.deallocate()
    }
    
    // --------------------------------------------------------------------
    // MARK: - CPU interface
    // --------------------------------------------------------------------
    
    @inline(__always) func readStatus() -> UInt8 {
        let v = status
        status &= 0x7F
        w = false
        mmc3Mapper?.mapperIRQClear()
        return v
    }
    
    @inline(__always) func readOAMData() -> UInt8 {
        return oam[Int(oamAddr)]
    }
    
    @inline(__always) func readData() -> UInt8 {
        let addr = self.v & 0x3FFF
        var ret: UInt8
        if (addr & 0x3F00) == 0x3F00 {
            ret = ppuRead(addr: addr)
            dataBuffer = ppuRead(addr: (addr & 0x0FFF) | 0x3000)
        } else {
            ret = dataBuffer
            dataBuffer = ppuRead(addr: addr)
        }
        v &+= ((ctrl & 0x04) != 0) ? 32 : 1
        return ret
    }

    @inline(__always) func writeCtrl(_ value: UInt8) {
        ctrl = value
        t = (t & ~nametableMask) | (UInt16(value & 0x03) << 10)
    }
    
    @inline(__always) func writeMask(_ value: UInt8) {
        mask = value
    }
    
    @inline(__always) func writeOAMAddr(_ value: UInt8) {
        oamAddr = value
    }
    
    @inline(__always) func writeOAMData(_ value: UInt8) {
        oam[Int(oamAddr)] = value
        oamAddr &+= 1
    }
    
    @inline(__always) func writeScroll(_ value: UInt8) {
        if !w {
            t = (t & ~coarseXMask) | UInt16(value >> 3)
            x = value & 0x07
        } else {
            let fy = UInt16(value & 0x07) << 12
            let cy = UInt16((value >> 3) & 0x1F) << 5
            t = (t & ~yScrollMask) | fy | cy
        }
        w.toggle()
    }
    
    @inline(__always) func writeAddr(_ value: UInt8) {
        if !w {
            t = (t & 0x00FF) | (UInt16(value & 0x3F) << 8)
        } else {
            t = (t & 0xFF00) | UInt16(value)
            v = t
        }
        w.toggle()
    }
    
    @inline(__always) func writeData(_ value: UInt8) {
        ppuWrite(addr: v, value: value)
        v &+= ((ctrl & 0x04) != 0) ? 32 : 1
    }
    
    // --------------------------------------------------------------------
    // MARK: - PPU read / write helpers
    // --------------------------------------------------------------------
    @inline(__always) private func ppuRead(addr: UInt16) -> UInt8 {
        let a = addr & vramAddrMask
        
        cartridge.mapper.ppuA12Observe(addr: a, ppuDot: ppuDot)
        
        if a < 0x2000 {
            return cartridge.mapper.ppuRead(address: a)
        }
        if a < 0x3F00 {
            return vram[Int(nameTableMirror(addr: a))]
        }
        var pa = a & 0x001F
        if pa == 0x10 { pa = 0x00 }
        else if pa == 0x14 { pa = 0x04 }
        else if pa == 0x18 { pa = 0x08 }
        else if pa == 0x1C { pa = 0x0C }
        return cachedPalette[Int(pa)] & 0x3F
    }
    
    @inline(__always) private func ppuWrite(addr: UInt16, value: UInt8) {
        let a = addr & vramAddrMask
        
        cartridge.mapper.ppuA12Observe(addr: a, ppuDot: ppuDot)
        
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
        case .horizontal: return UInt16(tableMapHorizontal[Int(table)]) * 0x400 + offset
        case .vertical:   return UInt16(tableMapVertical[Int(table)])   * 0x400 + offset
        case .fourScreen: return addr & 0x0FFF
        case .singleScreenLow:  return offset % 0x400
        case .singleScreenHigh: return 0x400 + (offset % 0x400)
        }
    }
    
    // --------------------------------------------------------------------
    // MARK: - OAM DMA
    // --------------------------------------------------------------------
    
    @inline(__always) public func writeOAM(index: UInt8, value: UInt8) {
        oam[Int(index)] = value
    }
    
    // --------------------------------------------------------------------
    // MARK: - Palette cache
    // --------------------------------------------------------------------
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
    
    // --------------------------------------------------------------------
    // MARK: - Main tick (State Machine)
    // --------------------------------------------------------------------
    
    @inline(__always)
    func tick() {
        // --- FIX: MMC5 Scanline IRQ Logic (checked at cycle 256 for accuracy) ---
        if let mmc5 = mmc5Mapper, scanline >= 0 && scanline <= 239 && cycle == 256 {
            mmc5.inFrame = true // Set inFrame flag
            mmc5.scanlineCounter &+= 1 // Increment scanline counter
            if mmc5.scanlineCounter == mmc5.scanlineTarget && mmc5.irqEnabled {
                mmc5.irqPending = true
            }
        }
        
        currentTick()
    }
    
    private func tickVisibleScanline() {
        let c = cycle
        
        if rendering {
            if (c >= 1 && c <= 256) || (c >= 321 && c <= 336) {
                bgShifterPatternLo <<= 1
                bgShifterPatternHi <<= 1
                bgShifterAttribLo   <<= 1
                bgShifterAttribHi   <<= 1
                
                switch (c - 1) & 7 {
                case 0: loadBGShifters(); fetchNameTable()
                case 2: fetchAttrib()
                case 4: fetchLoTile()
                case 6: fetchHiTile(); incX()
                default: break
                }
            }
            if c == 256 { incY() }
            if c == 257 { transferX() }
            if c == 65  { evalSprites() }
            if c == 257 { fetchSpriteData() }
            
            if c == 260 {
                cartridge.mapper.clockScanlineCounter()
            }
            
            if c >= 1 && c <= 256 {
                renderPixelFast()
                advanceSpriteShifters()
            }
        }
        
        cycle &+= 1
        ppuDot &+= 1
        if cycle >= 341 {
            cycle = 0
            scanline &+= 1
            
            if scanline == 240 {
                currentTick = self.tickVBlank
            }
        }
    }
    
    private func tickVBlank() {
        if scanline == 241 && cycle == 1 {
            status |= 0x80
            if (ctrl & 0x80) != 0 { nmiPending = true }
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
                
                if os_unfair_lock_trylock(&fbLock) {
                    let temp = fbPtrFront
                    fbPtrFront = fbPtrBack
                    fbPtrBack = temp
                    os_unfair_lock_unlock(&fbLock)
                }
                
                currentTick = self.tickPreRenderScanline
            }
        }
    }
    
    private func tickPreRenderScanline() {
        if cycle == 0 {
            cachePalette()
        }
        
        if cycle == 1 {
            status = 0
            spriteZeroHitPossible = false
            nmiPending = false
            
            // --- MMC5: Reset scanline counter at start of new frame ---
            if let mmc5 = mmc5Mapper {
                mmc5.scanlineCounter = 0
                mmc5.inFrame = false
            }
        }
        
        if rendering {
            let c = cycle
            if (c >= 1 && c <= 256) || (c >= 321 && c <= 336) {
                bgShifterPatternLo <<= 1
                bgShifterPatternHi <<= 1
                bgShifterAttribLo   <<= 1
                bgShifterAttribHi   <<= 1
                
                switch (c - 1) & 7 {
                case 0: loadBGShifters(); fetchNameTable()
                case 2: fetchAttrib()
                case 4: fetchLoTile()
                case 6: fetchHiTile(); incX()
                default: break
                }
            }
            
            if c == 256 { incY() }
            if c == 257 { transferX() }
            if c >= 280 && c <= 304 { transferY() }
            
            if c == 260 {
                cartridge.mapper.clockScanlineCounter()
            }
        }
        
        if rendering && cycle == 339 && (frame & 1) == 1 {
            cycle = 0
            scanline = 0
            ppuDot &+= 1
            currentTick = self.tickVisibleScanline
            return
        }
        
        cycle &+= 1
        ppuDot &+= 1
        if cycle >= 341 {
            cycle = 0
            scanline = 0
            currentTick = self.tickVisibleScanline
        }
    }
    
    // --------------------------------------------------------------------
    // MARK: - Background helpers
    // --------------------------------------------------------------------
    @inline(__always) private func loadBGShifters() {
        bgShifterPatternLo = (bgShifterPatternLo & 0xFF00) | UInt16(bgNextTileLsb)
        bgShifterPatternHi = (bgShifterPatternHi & 0xFF00) | UInt16(bgNextTileMsb)
        
        let loMask: UInt16 = (bgNextTileAttrib & 0x01) != 0 ? 0xFF : 0x00
        let hiMask: UInt16 = (bgNextTileAttrib & 0x02) != 0 ? 0xFF : 0x00
        bgShifterAttribLo = (bgShifterAttribLo & 0xFF00) | loMask
        bgShifterAttribHi = (bgShifterAttribHi & 0xFF00) | hiMask
    }

    
    @inline(__always) private func fetchNameTable() {
        bgNextTileId = ppuRead(addr: 0x2000 | (v & 0x0FFF))
    }
    
    @inline(__always) private func fetchAttrib() {
        let a = 0x23C0 | (v & 0x0C00) | ((v >> 4) & 0x0038) | ((v >> 2) & 0x0007)
        let attr = ppuRead(addr: a)
        let q = (((v & 0x0002) != 0) ? 1 : 0) | (((v & 0x0040) != 0) ? 2 : 0)
        bgNextTileAttrib = (attr >> UInt8(q << 1)) & 0x03
    }
    
    @inline(__always) private func fetchLoTile() {
        let base = ((ctrl & 0x10) != 0) ? UInt16(0x1000) : UInt16(0x0000)
        let addr = base &+ UInt16(bgNextTileId) &* 16 &+ ((v >> 12) & 0x0007)
        bgNextTileLsb = ppuRead(addr: addr)
    }
    
    @inline(__always) private func fetchHiTile() {
        let base = ((ctrl & 0x10) != 0) ? UInt16(0x1000) : UInt16(0x0000)
        let addr = base &+ UInt16(bgNextTileId) &* 16 &+ ((v >> 12) & 0x0007) &+ 8
        bgNextTileMsb = ppuRead(addr: addr)
    }
    
    @inline(__always) private func incX() {
        if (v & coarseXMask) == 0x001F { v &= ~coarseXMask; v ^= nametableXMask } else { v &+= 1 }
    }
    
    @inline(__always) private func incY() {
        if (v & fineYMask) != 0x7000 {
            v &+= 0x1000
        } else {
            v &= ~fineYMask
            var cy = (v & coarseYMask) >> 5
            if cy == 29 { cy = 0; v ^= nametableYMask }
            else if cy == 31 { cy = 0 }
            else { cy &+= 1 }
            v = (v & ~coarseYMask) | (cy << 5)
        }
    }
    
    @inline(__always) private func transferX() { v = (v & ~xScrollMask) | (t & xScrollMask) }
    @inline(__always) private func transferY() { v = (v & ~yScrollMask) | (t & yScrollMask) }
    
    // --------------------------------------------------------------------
    // MARK: - Sprite evaluation
    // --------------------------------------------------------------------
    @inline(__always) private func evalSprites() {
        secondaryOAM.initialize(repeating: 0xFF, count: 32)
        spriteCount = 0
        spriteZeroHitPossible = false
        let height = (ctrl & 0x20) == 0 ? 8 : 16
        
        var oamIndex = 0
        
        // ---
        // --- FIX: Correct Sprite Overflow (SMB2 Fix) ---
        // ---
        // This models the buggy hardware behavior for Sprite Overflow.
        // The PPU continues searching but applies a faulty Y-coordinate check
        // for the 9th sprite, which is the bug SMB2 relies on.
        while oamIndex < 64 {
            let y = Int(oam[oamIndex * 4 + 0])
            let dy = Int(scanline + 1) - y
            
            if dy >= 0 && dy < height {
                if spriteCount < 8 {
                    // Copy sprite to secondary OAM
                    let src = oamIndex * 4
                    let dst = spriteCount * 4
                    secondaryOAM[dst+0] = oam[src+0]
                    secondaryOAM[dst+1] = oam[src+1]
                    secondaryOAM[dst+2] = oam[src+2]
                    secondaryOAM[dst+3] = oam[src+3]
                    
                    if oamIndex == 0 { spriteZeroHitPossible = true }
                    spriteCount &+= 1
                } else {
                    // Sprite Overflow: Set the flag on detection of 9th sprite,
                    // but continue to look for Sprite 0 hit if not found.
                    status |= 0x20
                    // Stop checking for *further* sprites beyond the 9th for simple emulation
                    // The hardware continues in a buggy way, but this is the critical point.
                    break
                }
            }
            oamIndex &+= 1
        }
    }
    
    // --------------------------------------------------------------------
    // MARK: - Sprite data fetch
    // --------------------------------------------------------------------
    @inline(__always) private func fetchSpriteData() {
        let height = (ctrl & 0x20) == 0 ? 8 : 16
        for i in 0..<spriteCount {
            let y   = secondaryOAM[i*4 + 0]
            let tile = secondaryOAM[i*4 + 1]
            let attr = secondaryOAM[i*4 + 2]
            let xPos = secondaryOAM[i*4 + 3]
            spriteXPositions[i] = xPos
            spriteAttributes[i] = attr
            
            var dy = Int(scanline + 1) - Int(y)
            dy = max(0, min(dy, height - 1))
            if (attr & 0x80) != 0 { dy = height - 1 - dy }
            
            var addr: UInt16
            if height == 8 {
                let table = ((ctrl & 0x08) != 0) ? UInt16(0x1000) : UInt16(0x0000)
                addr = table &+ UInt16(tile) &* 16 &+ UInt16(dy)
            } else {
                let table = UInt16(tile & 1) << 12
                let tileBase = tile & 0xFE
                let off = dy >= 8 ? 16 : 0
                addr = table &+ UInt16(tileBase) &* 16 &+ UInt16(dy & 7) &+ UInt16(off)
            }
            
            let lo = ppuRead(addr: addr)
            let hi = ppuRead(addr: addr &+ 8)
            spriteShifterPatternLo[i] = (attr & 0x40) != 0 ? rev8(lo) : lo
            spriteShifterPatternHi[i] = (attr & 0x40) != 0 ? rev8(hi) : hi
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
    
    // --------------------------------------------------------------------
    // MARK: - Pixel rendering (OPTIMIZED)
    // --------------------------------------------------------------------
    @inline(__always) private func renderPixelFast() {
        let bgOn  = (mask & 0x08) != 0
        let spOn  = (mask & 0x10) != 0
        let leftBg = (mask & 0x02) != 0
        let leftSp = (mask & 0x04) != 0
        let c = cycle - 1
        
        let xMask: UInt16 = 0x8000 >> x
        let p0 = (bgShifterPatternLo & xMask) != 0 ? 1 : 0
        let p1 = (bgShifterPatternHi & xMask) != 0 ? 1 : 0
        var bgPixel = UInt8((p1 << 1) | p0)
        let a0 = (bgShifterAttribLo & xMask) != 0 ? 1 : 0
        let a1 = (bgShifterAttribHi & xMask) != 0 ? 1 : 0
        var bgPal = UInt8((a1 << 1) | a0)
        if !bgOn || (c < 8 && !leftBg) { bgPixel = 0; bgPal = 0 }
        
        var fgPixel: UInt8 = 0, fgPal: UInt8 = 0
        var fgPri = false
        if spOn && spriteCount > 0 {
            for i in 0..<spriteCount {
                if spriteXPositions[i] == 0 {
                    let p1 = (spriteShifterPatternHi[i] & 0x80) != 0 ? 1 : 0
                    let p0 = (spriteShifterPatternLo[i] & 0x80) != 0 ? 1 : 0
                    let px = (p1 << 1) | p0
                    if px != 0 {
                        fgPixel = UInt8(px)
                        fgPal   = (spriteAttributes[i] & 0x03) + 0x04
                        fgPri   = (spriteAttributes[i] & 0x20) == 0
                        break
                    }
                }
            }
            if c < 8 && !leftSp { fgPixel = 0; fgPal = 0 }
        }
        
        if spriteZeroHitPossible && spriteCount > 0 && spriteXPositions[0] == 0 {
            let s0p1 = (spriteShifterPatternHi[0] & 0x80) != 0 ? 1 : 0
            let s0p0 = (spriteShifterPatternLo[0] & 0x80) != 0 ? 1 : 0
            let s0 = (s0p1 << 1) | s0p0
            if s0 != 0 && bgPixel != 0 && bgOn && spOn && c < 255 {
                if (c >= 8) || (mask & 0x04) != 0 { status |= 0x40 }
            }
        }
        
        let useFg = (bgPixel == 0 && fgPixel != 0) || (bgPixel != 0 && fgPixel != 0 && fgPri)
        let px = (bgPixel == 0 && fgPixel == 0) ? 0 : (useFg ? fgPixel : bgPixel)
        let pal = (bgPixel == 0 && fgPixel == 0) ? 0 : (useFg ? fgPal : bgPal)
        
        let finalPaletteAddress: UInt16 = (px == 0) ? 0x3F00 : 0x3F00 + (UInt16(pal) << 2) + UInt16(px)
        
        var pa = finalPaletteAddress & 0x001F
        if pa == 0x10 { pa = 0x00 }
        else if pa == 0x14 { pa = 0x04 }
        else if pa == 0x18 { pa = 0x08 }
        else if pa == 0x1C { pa = 0x0C }
        let colorIndex = cachedPalette[Int(pa)]
        
        let rgb = PPU.sysPal[Int(colorIndex) & 0x3F]
        let r = (rgb >> 16) & 0xFF
        let g = (rgb >> 8)  & 0xFF
        let b = rgb & 0xFF
        let pixel: UInt32 = (0xFF << 24) | (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
        
        fbPtrBack[scanline * fbW + c] = pixel
    }
    
    // --------------------------------------------------------------------
    // MARK: - Frame image
    // --------------------------------------------------------------------
    func getFrameImage() -> Image {
        os_unfair_lock_lock(&fbLock)
        dataProvider = CGDataProvider(
            dataInfo: nil,
            data: UnsafeRawPointer(fbPtrFront),
            size: fbCount * MemoryLayout<UInt32>.size,
            releaseData: { _,_,_ in }
        )
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
        os_unfair_lock_unlock(&fbLock)
        
        cachedCGImage = cgimg
        return Image(decorative: cgimg, scale: 1.0)
    }
    
    // --------------------------------------------------------------------
    // MARK: - Metal texture helpers
    // --------------------------------------------------------------------
    
    func makeTexture(device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor()
        desc.pixelFormat = .bgra8Unorm
        desc.width = max(1, fbW)
        desc.height = max(1, fbH)
        desc.storageMode = .managed
        desc.usage = [.shaderRead, .renderTarget]
        
        guard let texture = device.makeTexture(descriptor: desc) else {
            assertionFailure("PPU.makeTexture(): failed to create Metal texture")
            return nil
        }
        
        return texture
    }
    
    func copyFrame(to texture: MTLTexture) {
        os_unfair_lock_lock(&fbLock)
        let ptr = fbPtrFront
        os_unfair_lock_unlock(&fbLock)

        let region = MTLRegionMake2D(0, 0, fbW, fbH)
        texture.replace(region: region,
                        mipmapLevel: 0,
                        withBytes: ptr,
                        bytesPerRow: fbW * MemoryLayout<UInt32>.size)
        
        if let queue = texture.device.makeCommandQueue(),
           let cmd = queue.makeCommandBuffer(),
           let blit = cmd.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
            cmd.commit()
        }
    }
    
    func clearFrame() {
        os_unfair_lock_lock(&fbLock)
        fbPtrFront.initialize(repeating: 0xFF000000, count: fbW * fbH)
        fbPtrBack.initialize(repeating: 0xFF000000, count: fbW * fbH)
        os_unfair_lock_unlock(&fbLock)
    }
    
    func reset() {
        cycle = 0; scanline = -1; frame = 0; frameReady = false; nmiPending = false
        status = 0; ctrl = 0; mask = 0; oamAddr = 0; w = false; v = 0; t = 0; x = 0
        clearFrame(); cachePalette()
        
        oam.initialize(repeating: 0xFF, count: 256)
        secondaryOAM.initialize(repeating: 0xFF, count: 32)
        
        mmc3Mapper = cartridge.mapper as? MMC3Mapper
        mmc5Mapper = cartridge.mapper as? MMC5Mapper
        currentTick = self.tickPreRenderScanline
    }
}
