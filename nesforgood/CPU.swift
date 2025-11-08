import Foundation

final class CPU {
    var A: UInt8 = 0
    var X: UInt8 = 0
    var Y: UInt8 = 0
    var SP: UInt8 = 0xFD
    var PC: UInt16 = 0
    var P: UInt8 = 0x24

    private let bus: Bus

    var cycles: UInt64 = 0

    private var stallIRQThisInstruction = false

    init(bus: Bus) {
        self.bus = bus
        reset()
    }

    func reset() {
        PC = readWord(address: 0xFFFC)
        SP = 0xFD
        P  = 0x24
        cycles = 0
        stallIRQThisInstruction = false
    }

    @inline(__always) private func read(address: UInt16) -> UInt8 {
        bus.cpuRead(address: address)
    }

    @inline(__always) private func write(address: UInt16, value: UInt8) {
        bus.cpuWrite(address: address, value: value)
    }

    private func readWord(address: UInt16) -> UInt16 {
        let lo = UInt16(read(address: address))
        let hi = UInt16(read(address: address &+ 1)) << 8
        return hi | lo
    }

    enum Flag: UInt8 {
        case C = 0b00000001, Z = 0b00000010, I = 0b00000100, D = 0b00001000
        case B = 0b00010000, U = 0b00100000, V = 0b01000000, N = 0b10000000
    }

    private func setFlag(_ f: Flag, _ on: Bool) {
        if on { P |= f.rawValue } else { P &= ~f.rawValue }
    }
    private func getFlag(_ f: Flag) -> Bool { (P & f.rawValue) != 0 }
    private func setZN(_ v: UInt8) { setFlag(.Z, v == 0); setFlag(.N, (v & 0x80) != 0) }

    private func push(_ v: UInt8) { write(address: 0x0100 | UInt16(SP), value: v); SP &-= 1 }
    private func pop() -> UInt8 { SP &+= 1; return read(address: 0x0100 | UInt16(SP)) }
    private func pushWord(_ w: UInt16) { push(UInt8((w >> 8) & 0xFF)); push(UInt8(w & 0xFF)) }
    private func popWord() -> UInt16 { let lo = UInt16(pop()); let hi = UInt16(pop()) << 8; return hi | lo }

    private func immediate() -> UInt8 { let v = read(address: PC); PC &+= 1; return v }
    private func zeroPage() -> UInt16 { let a = UInt16(read(address: PC)); PC &+= 1; return a }
    private func zeroPageX() -> UInt16 { let b = read(address: PC); PC &+= 1; return UInt16((b &+ X) & 0xFF) }
    private func zeroPageY() -> UInt16 { let b = read(address: PC); PC &+= 1; return UInt16((b &+ Y) & 0xFF) }
    private func absolute() -> UInt16 { let a = readWord(address: PC); PC &+= 2; return a }
    private func absoluteX() -> (UInt16, Bool) {
        let base = readWord(address: PC); PC &+= 2
        let addr = base &+ UInt16(X)
        return (addr, (addr & 0xFF00) != (base & 0xFF00))
    }
    private func absoluteY() -> (UInt16, Bool) {
        let base = readWord(address: PC); PC &+= 2
        let addr = base &+ UInt16(Y)
        return (addr, (addr & 0xFF00) != (base & 0xFF00))
    }
    private func indirect() -> UInt16 {
        let ptr = readWord(address: PC); PC &+= 2
        let loAddr = ptr
        let hiAddr = (ptr & 0xFF00) | UInt16(UInt8((ptr & 0x00FF) &+ 1))
        let lo = UInt16(read(address: loAddr))
        let hi = UInt16(read(address: hiAddr)) << 8
        return hi | lo
    }
    private func indirectX() -> UInt16 {
        let zp = (read(address: PC) &+ X) & 0xFF; PC &+= 1
        let lo = UInt16(read(address: UInt16(zp)))
        let hi = UInt16(read(address: UInt16((zp &+ 1) & 0xFF))) << 8
        return hi | lo
    }
    private func indirectY() -> (UInt16, Bool) {
        let zp = read(address: PC); PC &+= 1
        let lo = UInt16(read(address: UInt16(zp)))
        let hi = UInt16(read(address: UInt16((zp &+ 1) & 0xFF))) << 8
        let base = hi | lo
        let addr = base &+ UInt16(Y)
        return (addr, (addr & 0xFF00) != (base & 0xFF00))
    }
    private func relative() -> (UInt16, Bool) {
        let off = Int8(bitPattern: read(address: PC)); PC &+= 1
        let base = PC
        let target = UInt16(Int(base) &+ Int(off))
        return (target, (base & 0xFF00) != (target & 0xFF00))
    }

    private func adc(_ v: UInt8) {
        let c: UInt16 = getFlag(.C) ? 1 : 0
        let s = UInt16(A) &+ UInt16(v) &+ c
        let r = UInt8(truncatingIfNeeded: s)
        setFlag(.C, s > 0xFF)
        setFlag(.V, (~(A ^ v) & (A ^ r) & 0x80) != 0)
        A = r; setZN(A)
    }
    private func sbc(_ v: UInt8) { adc(~v) }

    private func and(_ v: UInt8) { A &= v; setZN(A) }
    private func ora(_ v: UInt8) { A |= v; setZN(A) }
    private func eor(_ v: UInt8) { A ^= v; setZN(A) }
    private func cmp(_ r: UInt8, _ v: UInt8) { let t = r &- v; setFlag(.C, r >= v); setZN(t) }

    private func aslA() { setFlag(.C, (A & 0x80) != 0); A &<<= 1; setZN(A) }
    private func lsrA() { setFlag(.C, (A & 0x01) != 0); A &>>= 1; setFlag(.N, false); setFlag(.Z, A == 0) }
    private func rolA() { let c = getFlag(.C) ? 1 : 0; let newC = (A & 0x80) != 0; A = (A &<< 1) | UInt8(c); setFlag(.C, newC); setZN(A) }
    private func rorA() { let c = getFlag(.C) ? 0x80 : 0; let newC = (A & 0x01) != 0; A = (A &>> 1) | UInt8(c); setFlag(.C, newC); setZN(A) }

    private func aslM(_ a: UInt16) { var v = read(address: a); setFlag(.C, (v & 0x80) != 0); v &<<= 1; write(address: a, value: v); setZN(v) }
    private func lsrM(_ a: UInt16) { var v = read(address: a); setFlag(.C, (v & 0x01) != 0); v &>>= 1; write(address: a, value: v); setFlag(.N, false); setFlag(.Z, v == 0) }
    private func rolM(_ a: UInt16) { var v = read(address: a); let cin: UInt8 = getFlag(.C) ? 1 : 0; let newC = (v & 0x80) != 0; v = (v &<< 1) | cin; write(address: a, value: v); setFlag(.C, newC); setZN(v) }
    private func rorM(_ a: UInt16) { var v = read(address: a); let cin: UInt8 = getFlag(.C) ? 0x80 : 0; let newC = (v & 0x01) != 0; v = (v &>> 1) | cin; write(address: a, value: v); setFlag(.C, newC); setZN(v) }

    func nmi() {
        pushWord(PC)
        var f = P; f &= ~Flag.B.rawValue; f |= Flag.U.rawValue
        push(f)
        setFlag(.I, true)
        stallIRQThisInstruction = true
        PC = readWord(address: 0xFFFA)
    }

    func irq() {
        if getFlag(.I) { return }
        pushWord(PC)
        var f = P; f &= ~Flag.B.rawValue; f |= Flag.U.rawValue
        push(f)
        setFlag(.I, true)
        stallIRQThisInstruction = true
        PC = readWord(address: 0xFFFE)
    }

    private func brk() {
        PC &+= 1
        pushWord(PC)
        let f = (P | Flag.B.rawValue | Flag.U.rawValue)
        push(f)
        setFlag(.I, true)
        stallIRQThisInstruction = true
        PC = readWord(address: 0xFFFE)
    }

    private func rti() {
        var f = pop()
        f |= Flag.U.rawValue; f &= ~Flag.B.rawValue
        P = f
        PC = popWord()
    }

    private func opSLO(_ addr: UInt16) { var v = read(address: addr); setFlag(.C, (v & 0x80) != 0); v &<<= 1; write(address: addr, value: v); ora(v) }
    private func opRLA(_ addr: UInt16) { var v = read(address: addr); let cin: UInt8 = getFlag(.C) ? 1 : 0; let newC = (v & 0x80) != 0; v = (v &<< 1) | cin; write(address: addr, value: v); setFlag(.C, newC); and(v) }
    private func opSRE(_ addr: UInt16) { var v = read(address: addr); setFlag(.C, (v & 0x01) != 0); v &>>= 1; write(address: addr, value: v); eor(v) }
    private func opRRA(_ addr: UInt16) { var v = read(address: addr); let cin: UInt8 = getFlag(.C) ? 0x80 : 0; let newC = (v & 0x01) != 0; v = (v &>> 1) | cin; write(address: addr, value: v); setFlag(.C, newC); adc(v) }
    private func opDCP(_ addr: UInt16) { var v = read(address: addr); v &-= 1; write(address: addr, value: v); cmp(A, v) }
    private func opISC(_ addr: UInt16) { var v = read(address: addr); v &+= 1; write(address: addr, value: v); sbc(v) }
    private func opLAX(_ v: UInt8) { A = v; X = v; setZN(v) }
    private func opSAX(_ addr: UInt16) { write(address: addr, value: A & X) }
    private func opANC(_ imm: UInt8) { and(imm); setFlag(.C, (A & 0x80) != 0) }
    private func opALR(_ imm: UInt8) { and(imm); lsrA() }
    private func opARR(_ imm: UInt8) {
        and(imm)
        let carryIn: UInt8 = getFlag(.C) ? 0x80 : 0
        let old = A
        let newC = (A & 0x01) != 0
        A = (A &>> 1) | carryIn
        setZN(A)
        let b5 = (A >> 5) & 1
        let b6 = (A >> 6) & 1
        setFlag(.V, (b5 ^ b6) != 0)
        setFlag(.C, (old & 0x40) != 0)
    }
    private func opAXS(_ imm: UInt8) { let t = (A & X); let r = t &- imm; setFlag(.C, t >= imm); X = r; setZN(X) }
    private func opLAS(_ addr: UInt16) { let v = read(address: addr) & SP; SP = v; A = v; X = v; setZN(v) }
    private func opTAS(storeAddr: UInt16, effectiveBase: UInt16) { let hiPlus1 = UInt8(((effectiveBase >> 8) & 0xFF) &+ 1); SP = A & X; let v = SP & hiPlus1; write(address: storeAddr, value: v) }
    private func opAHX(storeAddr: UInt16, effectiveBase: UInt16) { let v = (A & X) & UInt8(((effectiveBase >> 8) & 0xFF) &+ 1); write(address: storeAddr, value: v) }
    private func opSHY(storeAddr: UInt16, effectiveBase: UInt16) { let v = Y & UInt8(((effectiveBase >> 8) & 0xFF) &+ 1); write(address: storeAddr, value: v) }
    private func opSHX(storeAddr: UInt16, effectiveBase: UInt16) { let v = X & UInt8(((effectiveBase >> 8) & 0xFF) &+ 1); write(address: storeAddr, value: v) }

    @discardableResult
    func step() -> Int {
        if let core = bus.core, core.dmaActive {
            if core.dmaCyclesLeft > 0 {
                core.dmaCyclesLeft &-= 1
                cycles &+= 1
                if core.dmaCyclesLeft == 0 {
                    core.dmaActive = false
                }
                return 1
            }
        }
let opcode = read(address: PC)
        PC &+= 1
        var c = 0

        switch opcode {
            case 0xEB:
                let value = immediate()
                sbc(value)
return 2
            case 0xFC:
                execIllegalNOP(2)
return 2
            case 0xDC:
                execIllegalNOP(2)
return 2
            case 0x7C:
                execIllegalNOP(2)
return 2
            case 0x5C:
                execIllegalNOP(2)
return 2
            case 0x3C:
                execIllegalNOP(2)
return 2
            case 0xF4:
                execIllegalNOP(1)
return 2
            case 0xD4:
                execIllegalNOP(1)
return 2
            case 0x74:
                execIllegalNOP(1)
return 2
            case 0x54:
                execIllegalNOP(1)
return 2
            case 0x34:
                execIllegalNOP(1)
return 2
            case 0x64:
                execIllegalNOP(1)
return 2
            case 0x44:
                execIllegalNOP(1)
return 2
            case 0xE2:
                execIllegalNOP(1)
return 2
            case 0xC2:
                execIllegalNOP(1)
return 2
            case 0x89:
                execIllegalNOP(1)
return 2
            case 0x82:
                execIllegalNOP(1)
return 2
            case 0xFA:
return 2
            case 0xDA:
return 2
            case 0x7A:
return 2
            case 0x5A:
return 2
            case 0x3A:
return 2
        case 0xA9:
            c = 2; A = immediate(); setZN(A)
        case 0xA5:
            c = 3; A = read(address: zeroPage()); setZN(A)
        case 0xB5:
            c = 4; A = read(address: zeroPageX()); setZN(A)
        case 0xAD:
            c = 4; A = read(address: absolute()); setZN(A)
        case 0xBD:
            let (aBD, xpBD) = absoluteX()
            c = 4 + (xpBD ? 1 : 0)
            A = read(address: aBD); setZN(A)
        case 0xB9:
            let (aB9, ypB9) = absoluteY()
            c = 4 + (ypB9 ? 1 : 0)
            A = read(address: aB9); setZN(A)
        case 0xA1:
            c = 6; A = read(address: indirectX()); setZN(A)
        case 0xB1:
            let (aB1, ypB1) = indirectY()
            c = 5 + (ypB1 ? 1 : 0)
            A = read(address: aB1); setZN(A)

        case 0xA2:
            c = 2; X = immediate(); setZN(X)
        case 0xA6:
            c = 3; X = read(address: zeroPage()); setZN(X)
        case 0xB6:
            c = 4; X = read(address: zeroPageY()); setZN(X)
        case 0xAE:
            c = 4; X = read(address: absolute()); setZN(X)
        case 0xBE:
            let (aBE, ypBE) = absoluteY()
            c = 4 + (ypBE ? 1 : 0)
            X = read(address: aBE); setZN(X)

        case 0xA0:
            c = 2; Y = immediate(); setZN(Y)
        case 0xA4:
            c = 3; Y = read(address: zeroPage()); setZN(Y)
        case 0xB4:
            c = 4; Y = read(address: zeroPageX()); setZN(Y)
        case 0xAC:
            c = 4; Y = read(address: absolute()); setZN(Y)
        case 0xBC:
            let (aBC, xpBC) = absoluteX()
            c = 4 + (xpBC ? 1 : 0)
            Y = read(address: aBC); setZN(Y)

        case 0x85:
            c = 3; write(address: zeroPage(), value: A)
        case 0x95:
            c = 4; write(address: zeroPageX(), value: A)
        case 0x8D:
            c = 4; write(address: absolute(), value: A)
        case 0x9D:
            let (a9D, _) = absoluteX()
            c = 5; write(address: a9D, value: A)
        case 0x99:
            let (a99, _) = absoluteY()
            c = 5; write(address: a99, value: A)
        case 0x81:
            c = 6; write(address: indirectX(), value: A)
        case 0x91:
            let (a91, _) = indirectY()
            c = 6; write(address: a91, value: A)

        case 0x86:
            c = 3; write(address: zeroPage(), value: X)
        case 0x96:
            c = 4; write(address: zeroPageY(), value: X)
        case 0x8E:
            c = 4; write(address: absolute(), value: X)

        case 0x84:
            c = 3; write(address: zeroPage(), value: Y)
        case 0x94:
            c = 4; write(address: zeroPageX(), value: Y)
        case 0x8C:
            c = 4; write(address: absolute(), value: Y)

        case 0xAA: c = 2; X = A; setZN(X)
        case 0x8A: c = 2; A = X; setZN(A)
        case 0xA8: c = 2; Y = A; setZN(Y)
        case 0x98: c = 2; A = Y; setZN(A)
        case 0xBA: c = 2; X = SP; setZN(X)
        case 0x9A: c = 2; SP = X

        case 0x48: c = 3; push(A)
        case 0x68: c = 4; A = pop(); setZN(A)
        case 0x08: c = 3; push(P | Flag.B.rawValue | Flag.U.rawValue)
        case 0x28:
            c = 4
            var fPLP = pop()
            fPLP |= Flag.U.rawValue
            fPLP &= ~Flag.B.rawValue
            P = fPLP

        case 0x29: c = 2; and(immediate())
        case 0x25: c = 3; and(read(address: zeroPage()))
        case 0x35: c = 4; and(read(address: zeroPageX()))
        case 0x2D: c = 4; and(read(address: absolute()))
        case 0x3D:
            let (a3D, xp3D) = absoluteX()
            c = 4 + (xp3D ? 1 : 0)
            and(read(address: a3D))
        case 0x39:
            let (a39, yp39) = absoluteY()
            c = 4 + (yp39 ? 1 : 0)
            and(read(address: a39))
        case 0x21: c = 6; and(read(address: indirectX()))
        case 0x31:
            let (a31, yp31) = indirectY()
            c = 5 + (yp31 ? 1 : 0)
            and(read(address: a31))

        case 0x09: c = 2; ora(immediate())
        case 0x05: c = 3; ora(read(address: zeroPage()))
        case 0x15: c = 4; ora(read(address: zeroPageX()))
        case 0x0D: c = 4; ora(read(address: absolute()))
        case 0x1D:
            let (a1D, xp1D) = absoluteX()
            c = 4 + (xp1D ? 1 : 0)
            ora(read(address: a1D))
        case 0x19:
            let (a19, yp19) = absoluteY()
            c = 4 + (yp19 ? 1 : 0)
            ora(read(address: a19))
        case 0x01: c = 6; ora(read(address: indirectX()))
        case 0x11:
            let (a11, yp11) = indirectY()
            c = 5 + (yp11 ? 1 : 0)
            ora(read(address: a11))

        case 0x49: c = 2; eor(immediate())
        case 0x45: c = 3; eor(read(address: zeroPage()))
        case 0x55: c = 4; eor(read(address: zeroPageX()))
        case 0x4D: c = 4; eor(read(address: absolute()))
        case 0x5D:
            let (a5D, xp5D) = absoluteX()
            c = 4 + (xp5D ? 1 : 0)
            eor(read(address: a5D))
        case 0x59:
            let (a59, yp59) = absoluteY()
            c = 4 + (yp59 ? 1 : 0)
            eor(read(address: a59))
        case 0x41: c = 6; eor(read(address: indirectX()))
        case 0x51:
            let (a51, yp51) = indirectY()
            c = 5 + (yp51 ? 1 : 0)
            eor(read(address: a51))

        case 0x24:
            c = 3
            let v24 = read(address: zeroPage())
            setFlag(.Z, (A & v24) == 0); setFlag(.V, (v24 & 0x40) != 0); setFlag(.N, (v24 & 0x80) != 0)
        case 0x2C:
            c = 4
            let v2C = read(address: absolute())
            setFlag(.Z, (A & v2C) == 0); setFlag(.V, (v2C & 0x40) != 0); setFlag(.N, (v2C & 0x80) != 0)

        case 0x69: c = 2; adc(immediate())
        case 0x65: c = 3; adc(read(address: zeroPage()))
        case 0x75: c = 4; adc(read(address: zeroPageX()))
        case 0x6D: c = 4; adc(read(address: absolute()))
        case 0x7D:
            let (a7D, xp7D) = absoluteX()
            c = 4 + (xp7D ? 1 : 0)
            adc(read(address: a7D))
        case 0x79:
            let (a79, yp79) = absoluteY()
            c = 4 + (yp79 ? 1 : 0)
            adc(read(address: a79))
        case 0x61: c = 6; adc(read(address: indirectX()))
        case 0x71:
            let (a71, yp71) = indirectY()
            c = 5 + (yp71 ? 1 : 0)
            adc(read(address: a71))

        case 0xE9: c = 2; sbc(immediate())
        case 0xE5: c = 3; sbc(read(address: zeroPage()))
        case 0xF5: c = 4; sbc(read(address: zeroPageX()))
        case 0xED: c = 4; sbc(read(address: absolute()))
        case 0xFD:
            let (aFD, xpFD) = absoluteX()
            c = 4 + (xpFD ? 1 : 0)
            sbc(read(address: aFD))
        case 0xF9:
            let (aF9, ypF9) = absoluteY()
            c = 4 + (ypF9 ? 1 : 0)
            sbc(read(address: aF9))
        case 0xE1: c = 6; sbc(read(address: indirectX()))
        case 0xF1:
            let (aF1, ypF1) = indirectY()
            c = 5 + (ypF1 ? 1 : 0)
            sbc(read(address: aF1))

        case 0xC9: c = 2; cmp(A, immediate())
        case 0xC5: c = 3; cmp(A, read(address: zeroPage()))
        case 0xD5: c = 4; cmp(A, read(address: zeroPageX()))
        case 0xCD: c = 4; cmp(A, read(address: absolute()))
        case 0xDD:
            let (aDD, xpDD) = absoluteX()
            c = 4 + (xpDD ? 1 : 0)
            cmp(A, read(address: aDD))
        case 0xD9:
            let (aD9, ypD9) = absoluteY()
            c = 4 + (ypD9 ? 1 : 0)
            cmp(A, read(address: aD9))
        case 0xC1: c = 6; cmp(A, read(address: indirectX()))
        case 0xD1:
            let (aD1, ypD1) = indirectY()
            c = 5 + (ypD1 ? 1 : 0)
            cmp(A, read(address: aD1))

        case 0xE0: c = 2; cmp(X, immediate())
        case 0xE4: c = 3; cmp(X, read(address: zeroPage()))
        case 0xEC: c = 4; cmp(X, read(address: absolute()))

        case 0xC0: c = 2; cmp(Y, immediate())
        case 0xC4: c = 3; cmp(Y, read(address: zeroPage()))
        case 0xCC: c = 4; cmp(Y, read(address: absolute()))

        case 0xE6:
            c = 5; do { let a = zeroPage(); var v = read(address: a); v &+= 1; write(address: a, value: v); setZN(v) }
        case 0xF6:
            c = 6; do { let a = zeroPageX(); var v = read(address: a); v &+= 1; write(address: a, value: v); setZN(v) }
        case 0xEE:
            c = 6; do { let a = absolute(); var v = read(address: a); v &+= 1; write(address: a, value: v); setZN(v) }
        case 0xFE:
            c = 7
            let (aFE, _) = absoluteX()
            var vFE = read(address: aFE); vFE &+= 1; write(address: aFE, value: vFE); setZN(vFE)

        case 0xC6:
            c = 5; do { let a = zeroPage(); var v = read(address: a); v &-= 1; write(address: a, value: v); setZN(v) }
        case 0xD6:
            c = 6; do { let a = zeroPageX(); var v = read(address: a); v &-= 1; write(address: a, value: v); setZN(v) }
        case 0xCE:
            c = 6; do { let a = absolute(); var v = read(address: a); v &-= 1; write(address: a, value: v); setZN(v) }
        case 0xDE:
            c = 7
            let (aDE, _) = absoluteX()
            var vDE = read(address: aDE); vDE &-= 1; write(address: aDE, value: vDE); setZN(vDE)

        case 0xE8: c = 2; X &+= 1; setZN(X)
        case 0xC8: c = 2; Y &+= 1; setZN(Y)
        case 0xCA: c = 2; X &-= 1; setZN(X)
        case 0x88: c = 2; Y &-= 1; setZN(Y)

        case 0x0A: c = 2; aslA()
        case 0x4A: c = 2; lsrA()
        case 0x2A: c = 2; rolA()
        case 0x6A: c = 2; rorA()

        case 0x06:
            c = 5; aslM(zeroPage())
        case 0x16:
            c = 6; aslM(zeroPageX())
        case 0x0E:
            c = 6; aslM(absolute())
        case 0x1E:
            c = 7
            let (a1E, _) = absoluteX()
            aslM(a1E)

        case 0x46:
            c = 5; lsrM(zeroPage())
        case 0x56:
            c = 6; lsrM(zeroPageX())
        case 0x4E:
            c = 6; lsrM(absolute())
        case 0x5E:
            c = 7
            let (a5E, _) = absoluteX()
            lsrM(a5E)

        case 0x26:
            c = 5; rolM(zeroPage())
        case 0x36:
            c = 6; rolM(zeroPageX())
        case 0x2E:
            c = 6; rolM(absolute())
        case 0x3E:
            c = 7
            let (a3E, _) = absoluteX()
            rolM(a3E)

        case 0x66:
            c = 5; rorM(zeroPage())
        case 0x76:
            c = 6; rorM(zeroPageX())
        case 0x6E:
            c = 6; rorM(absolute())
        case 0x7E:
            c = 7
            let (a7E, _) = absoluteX()
            rorM(a7E)

        case 0x4C:
            c = 3; PC = absolute()
        case 0x6C:
            c = 5; PC = indirect()
        case 0x20:
            c = 6
            let t = absolute()
            let ret = PC &- 1
            pushWord(ret)
            PC = t
        case 0x60:
            c = 6; PC = popWord() &+ 1
        case 0x00:
            c = 7; brk()
        case 0x40:
            c = 6; rti()

        case 0x90:
            c = 2
            if !getFlag(.C) {
                let (t, cross) = relative()
                c &+= 1; if cross { c &+= 1 }
                PC = t
            } else { _ = relative() }
        case 0xB0:
            c = 2
            if getFlag(.C) {
                let (t, cross) = relative()
                c &+= 1; if cross { c &+= 1 }
                PC = t
            } else { _ = relative() }
        case 0xF0:
            c = 2
            if getFlag(.Z) {
                let (t, cross) = relative()
                c &+= 1; if cross { c &+= 1 }
                PC = t
            } else { _ = relative() }
        case 0x30:
            c = 2
            if getFlag(.N) {
                let (t, cross) = relative()
                c &+= 1; if cross { c &+= 1 }
                PC = t
            } else { _ = relative() }
        case 0xD0:
            c = 2
            if !getFlag(.Z) {
                let (t, cross) = relative()
                c &+= 1; if cross { c &+= 1 }
                PC = t
            } else { _ = relative() }
        case 0x10:
            c = 2
            if !getFlag(.N) {
                let (t, cross) = relative()
                c &+= 1; if cross { c &+= 1 }
                PC = t
            } else { _ = relative() }
        case 0x50:
            c = 2
            if !getFlag(.V) {
                let (t, cross) = relative()
                c &+= 1; if cross { c &+= 1 }
                PC = t
            } else { _ = relative() }
        case 0x70:
            c = 2
            if getFlag(.V) {
                let (t, cross) = relative()
                c &+= 1; if cross { c &+= 1 }
                PC = t
            } else { _ = relative() }

        case 0x18: c = 2; setFlag(.C, false)
        case 0x38: c = 2; setFlag(.C, true)
        case 0x58: c = 2; setFlag(.I, false)
        case 0x78: c = 2; setFlag(.I, true)
        case 0xB8: c = 2; setFlag(.V, false)
        case 0xD8: c = 2; setFlag(.D, false)
        case 0xF8: c = 2; setFlag(.D, true)

        case 0xEA: c = 2

        case 0xA7: c = 3; opLAX(read(address: zeroPage()))
        case 0xB7: c = 4; opLAX(read(address: zeroPageY()))
        case 0xAF: c = 4; opLAX(read(address: absolute()))
        case 0xBF:
            let (aBF, ypBF) = absoluteY()
            c = 4 + (ypBF ? 1 : 0)
            opLAX(read(address: aBF))
        case 0xA3: c = 6; opLAX(read(address: indirectX()))
        case 0xB3:
            let (aB3, ypB3) = indirectY()
            c = 5 + (ypB3 ? 1 : 0)
            opLAX(read(address: aB3))

        case 0x87: c = 3; opSAX(zeroPage())
        case 0x97: c = 4; opSAX(zeroPageY())
        case 0x8F: c = 4; opSAX(absolute())
        case 0x83: c = 6; opSAX(indirectX())

        case 0xC7: c = 5; opDCP(zeroPage())
        case 0xD7: c = 6; opDCP(zeroPageX())
        case 0xCF: c = 6; opDCP(absolute())
        case 0xDF:
            c = 7
            let (aDF, _) = absoluteX()
            opDCP(aDF)
        case 0xDB, 0xD3:
            c = 8
            let (aD3, _) = indirectY()
            opDCP(aD3)

        case 0xE7: c = 5; opISC(zeroPage())
        case 0xF7: c = 6; opISC(zeroPageX())
        case 0xEF: c = 6; opISC(absolute())
        case 0xFF:
            c = 7
            let (aFF, _) = absoluteX()
            opISC(aFF)
        case 0xFB, 0xF3:
            c = 8
            let (aF3, _) = indirectY()
            opISC(aF3)

        case 0x07: c = 5; opSLO(zeroPage())
        case 0x17: c = 6; opSLO(zeroPageX())
        case 0x0F: c = 6; opSLO(absolute())
        case 0x1F:
            c = 7
            let (a1F, _) = absoluteX()
            opSLO(a1F)
        case 0x1B, 0x13:
            c = 8
            let (a13, _) = indirectY()
            opSLO(a13)

        case 0x27: c = 5; opRLA(zeroPage())
        case 0x37: c = 6; opRLA(zeroPageX())
        case 0x2F: c = 6; opRLA(absolute())
        case 0x3F:
            c = 7
            let (a3F, _) = absoluteX()
            opRLA(a3F)
        case 0x3B, 0x33:
            c = 8
            let (a33, _) = indirectY()
            opRLA(a33)

        case 0x47: c = 5; opSRE(zeroPage())
        case 0x57: c = 6; opSRE(zeroPageX())
        case 0x4F: c = 6; opSRE(absolute())
        case 0x5F:
            c = 7
            let (a5F, _) = absoluteX()
            opSRE(a5F)
        case 0x5B, 0x53:
            c = 8
            let (a53, _) = indirectY()
            opSRE(a53)

        case 0x67: c = 5; opRRA(zeroPage())
        case 0x77: c = 6; opRRA(zeroPageX())
        case 0x6F: c = 6; opRRA(absolute())
        case 0x7F:
            c = 7
            let (a7F, _) = absoluteX()
            opRRA(a7F)
        case 0x7B, 0x73:
            c = 8
            let (a73, _) = indirectY()
            opRRA(a73)

        case 0x0B, 0x2B: c = 2; opANC(immediate())
        case 0x4B: c = 2; opALR(immediate())
        case 0x6B: c = 2; opARR(immediate())
        case 0xCB: c = 2; opAXS(immediate())

        case 0xBB:
            let (aBB, ypBB) = absoluteY()
            c = 4 + (ypBB ? 1 : 0)
            opLAS(aBB)
        case 0x9B:
            let base9B = readWord(address: PC); PC &+= 2
            let addr9B = base9B &+ UInt16(Y)
            c = 5
            opTAS(storeAddr: addr9B, effectiveBase: base9B)
        case 0x9F:
            let base9F = readWord(address: PC); PC &+= 2
            let addr9F = base9F &+ UInt16(Y)
            c = 5
            opAHX(storeAddr: addr9F, effectiveBase: base9F)
        case 0x93:
            let zp93 = read(address: PC); PC &+= 1
            let lo93 = UInt16(read(address: UInt16(zp93)))
            let hi93 = UInt16(read(address: UInt16((zp93 &+ 1) & 0xFF))) << 8
            let base93 = hi93 | lo93
            let addr93 = base93 &+ UInt16(Y)
            c = 6
            opAHX(storeAddr: addr93, effectiveBase: base93)
        case 0x9C:
            let base9C = readWord(address: PC); PC &+= 2
            let addr9C = base9C &+ UInt16(X)
            c = 5
            opSHY(storeAddr: addr9C, effectiveBase: base9C)
        case 0x9E:
            let base9E = readWord(address: PC); PC &+= 2
            let addr9E = base9E &+ UInt16(Y)
            c = 5
            opSHX(storeAddr: addr9E, effectiveBase: base9E)

        case 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA:
            c = 2
        case 0x80, 0x82, 0x89, 0xC2, 0xE2:
            c = 2; _ = immediate()
        case 0x04, 0x44, 0x64:
            c = 3; _ = zeroPage()
        case 0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4:
            c = 4; _ = zeroPageX()
        case 0x0C:
            c = 4; _ = absolute()
        case 0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC:
            let (_, cross) = absoluteX(); c = 4 + (cross ? 1 : 0)

        default:
            c = 2
        }

        if stallIRQThisInstruction { stallIRQThisInstruction = false }
        cycles &+= UInt64(c)
        return c
    }

    @inline(__always) private func execIllegalNOP(_ bytes: Int) {
        for _ in 0..<bytes { _ = immediate() }
    }
    
}
