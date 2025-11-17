import Foundation

final class CPU {
    var A: UInt8 = 0
    var X: UInt8 = 0
    var Y: UInt8 = 0
    var SP: UInt8 = 0xFD
    var PC: UInt16 = 0
    var P: UInt8 = 0x24 // Processor Status Register

    private let bus: Bus

    var cycles: UInt64 = 0
    private var stallIRQThisInstruction = false

    // ---
    // --- OPTIMIZATION: The Opcode Table ---
    // ---
    private var opcodeTable: [() -> Int] = []

    init(bus: Bus) {
        self.bus = bus
        // Build the table *after* self is available
        self.opcodeTable = self.buildOpcodeTable()
        reset()
    }

    func reset() {
        PC = readWord(address: 0xFFFC)
        SP = 0xFD
        P  = 0x24
        cycles = 0
        stallIRQThisInstruction = false
    }

    // MARK: - Memory Access

    @inline(__always) private func read(address: UInt16) -> UInt8 {
        bus.cpuRead(address: address)
    }

    @inline(__always) private func write(address: UInt16, value: UInt8) {
        bus.cpuWrite(address: address, value: value)
    }

    @inline(__always) private func readWord(address: UInt16) -> UInt16 {
        let lo = UInt16(read(address: address))
        let hi = UInt16(read(address: address &+ 1)) << 8
        return hi | lo
    }

    // MARK: - Flags

    enum Flag: UInt8 {
        case C = 0b00000001 // Carry
        case Z = 0b00000010 // Zero
        case I = 0b00000100 // Interrupt Disable
        case D = 0b00001000 // Decimal Mode
        case B = 0b00010000 // Break
        case U = 0b00100000 // Unused (always 1)
        case V = 0b01000000 // Overflow
        case N = 0b10000000 // Negative
    }

    @inline(__always) private func setFlag(_ f: Flag, _ on: Bool) {
        if on { P |= f.rawValue } else { P &= ~f.rawValue }
    }

    @inline(__always) private func getFlag(_ f: Flag) -> Bool { (P & f.rawValue) != 0 }

    @inline(__always) private func setZN(_ v: UInt8) {
        setFlag(.Z, v == 0)
        setFlag(.N, (v & 0x80) != 0)
    }

    // MARK: - Stack Operations

    @inline(__always) private func push(_ v: UInt8) {
        write(address: 0x0100 | UInt16(SP), value: v)
        SP &-= 1
    }

    @inline(__always) private func pop() -> UInt8 {
        SP &+= 1
        return read(address: 0x0100 | UInt16(SP))
    }

    @inline(__always) private func pushWord(_ w: UInt16) {
        push(UInt8((w >> 8) & 0xFF))
        push(UInt8(w & 0xFF))
    }

    @inline(__always) private func popWord() -> UInt16 {
        let lo = UInt16(pop())
        let hi = UInt16(pop()) << 8
        return hi | lo
    }

    // MARK: - Addressing Modes
    // (These are now inlined into the table, but we keep
    //  them here for the ALU functions that are shared)

    @inline(__always) private func immediate() -> UInt8 {
        let v = read(address: PC)
        PC &+= 1
        return v
    }

    @inline(__always) private func zeroPage() -> UInt16 {
        let a = UInt16(read(address: PC))
        PC &+= 1
        return a
    }

    @inline(__always) private func zeroPageX() -> UInt16 {
        let b = read(address: PC)
        PC &+= 1
        return UInt16((b &+ X) & 0xFF)
    }

    @inline(__always) private func zeroPageY() -> UInt16 {
        let b = read(address: PC)
        PC &+= 1
        return UInt16((b &+ Y) & 0xFF)
    }

    @inline(__always) private func absolute() -> UInt16 {
        let a = readWord(address: PC)
        PC &+= 2
        return a
    }

    @inline(__always) private func absoluteX() -> (UInt16, Bool) {
        let base = readWord(address: PC)
        PC &+= 2
        let addr = base &+ UInt16(X)
        let pageCross = (addr & 0xFF00) != (base & 0xFF00)
        return (addr, pageCross)
    }

    @inline(__always) private func absoluteY() -> (UInt16, Bool) {
        let base = readWord(address: PC)
        PC &+= 2
        let addr = base &+ UInt16(Y)
        let pageCross = (addr & 0xFF00) != (base & 0xFF00)
        return (addr, pageCross)
    }

    @inline(__always) private func indirect() -> UInt16 {
        let ptr = readWord(address: PC)
        PC &+= 2

        let loAddr = ptr
        // NOTE: Emulating the 6502 indirect jump bug
        let hiAddr = (ptr & 0xFF00) | UInt16(UInt8((ptr & 0x00FF) &+ 1))

        let lo = UInt16(read(address: loAddr))
        let hi = UInt16(read(address: hiAddr)) << 8
        return hi | lo
    }

    @inline(__always) private func indirectX() -> UInt16 {
        let zp = (read(address: PC) &+ X) & 0xFF
        PC &+= 1
        let lo = UInt16(read(address: UInt16(zp)))
        let hi = UInt16(read(address: UInt16((zp &+ 1) & 0xFF))) << 8
        return hi | lo
    }

    @inline(__always) private func indirectY() -> (UInt16, Bool) {
        let zp = read(address: PC)
        PC &+= 1
        let lo = UInt16(read(address: UInt16(zp)))
        let hi = UInt16(read(address: UInt16((zp &+ 1) & 0xFF))) << 8
        let base = hi | lo
        let addr = base &+ UInt16(Y)
        let pageCross = (addr & 0xFF00) != (base & 0xFF00)
        return (addr, pageCross)
    }

    @inline(__always) private func relative() -> (UInt16, Bool) {
        let off = Int8(bitPattern: read(address: PC))
        PC &+= 1
        let base = PC
        let target = UInt16(bitPattern: Int16(bitPattern: base) &+ Int16(off))
        let pageCross = (base & 0xFF00) != (target & 0xFF00)
        return (target, pageCross)
    }

    // MARK: - Legal Instructions (ALU)
    // (These are kept as they are complex and shared)

    @inline(__always) private func adc(_ v: UInt8) {
        let c: UInt16 = getFlag(.C) ? 1 : 0
        let s = UInt16(A) &+ UInt16(v) &+ c
        let r = UInt8(truncatingIfNeeded: s)
        setFlag(.C, s > 0xFF)
        setFlag(.V, (~(A ^ v) & (A ^ r) & 0x80) != 0)
        A = r
        setZN(A)
    }

    @inline(__always) private func sbc(_ v: UInt8) {
        adc(~v)
    }

    @inline(__always) private func and(_ v: UInt8) { A &= v; setZN(A) }
    @inline(__always) private func ora(_ v: UInt8) { A |= v; setZN(A) }
    @inline(__always) private func eor(_ v: UInt8) { A ^= v; setZN(A) }

    @inline(__always) private func cmp(_ r: UInt8, _ v: UInt8) {
        let t = r &- v
        setFlag(.C, r >= v)
        setZN(t)
    }

    // MARK: - Legal Instructions (Read-Modify-Write)

    @inline(__always) private func aslA() { setFlag(.C, (A & 0x80) != 0); A &<<= 1; setZN(A) }
    @inline(__always) private func lsrA() { setFlag(.C, (A & 0x01) != 0); A &>>= 1; setFlag(.N, false); setFlag(.Z, A == 0) }
    @inline(__always) private func rolA() { let c: UInt8 = getFlag(.C) ? 1 : 0; let newC = (A & 0x80) != 0; A = (A &<< 1) | c; setFlag(.C, newC); setZN(A) }
    @inline(__always) private func rorA() { let c: UInt8 = getFlag(.C) ? 0x80 : 0; let newC = (A & 0x01) != 0; A = (A &>> 1) | c; setFlag(.C, newC); setZN(A) }

    @inline(__always) private func aslM(_ a: UInt16) { var v = read(address: a); setFlag(.C, (v & 0x80) != 0); v &<<= 1; write(address: a, value: v); setZN(v) }
    @inline(__always) private func lsrM(_ a: UInt16) { var v = read(address: a); setFlag(.C, (v & 0x01) != 0); v &>>= 1; write(address: a, value: v); setFlag(.N, false); setFlag(.Z, v == 0) }
    @inline(__always) private func rolM(_ a: UInt16) { var v = read(address: a); let cin: UInt8 = getFlag(.C) ? 1 : 0; let newC = (v & 0x80) != 0; v = (v &<< 1) | cin; write(address: a, value: v); setFlag(.C, newC); setZN(v) }
    @inline(__always) private func rorM(_ a: UInt16) { var v = read(address: a); let cin: UInt8 = getFlag(.C) ? 0x80 : 0; let newC = (v & 0x01) != 0; v = (v &>> 1) | cin; write(address: a, value: v); setFlag(.C, newC); setZN(v) }

    @inline(__always) private func incM(_ a: UInt16) { var v = read(address: a); v &+= 1; write(address: a, value: v); setZN(v) }
    @inline(__always) private func decM(_ a: UInt16) { var v = read(address: a); v &-= 1; write(address: a, value: v); setZN(v) }

    // MARK: - Interrupts & Control Flow

    func nmi() {
        pushWord(PC)
        var f = P
        f &= ~Flag.B.rawValue
        f |= Flag.U.rawValue
        push(f)
        setFlag(.I, true)
        stallIRQThisInstruction = true
        PC = readWord(address: 0xFFFA)
    }

    func irq() {
        if getFlag(.I) { return }
        pushWord(PC)
        var f = P
        f &= ~Flag.B.rawValue
        f |= Flag.U.rawValue
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
        f |= Flag.U.rawValue
        f &= ~Flag.B.rawValue
        P = f
        PC = popWord()
    }

    // ---
    // --- KIL/JAM (default illegal opcode) ---
    // ---
    @inline(__always) private func opKIL() -> Int {
        PC &-= 1 // Loop on self
        return 2 // KIL is typically 2 cycles
    }

    // MARK: - CPU Step

    @discardableResult
    func step() -> Int {

        if let core = bus.core, core.dmaActive {
            if core.dmaCyclesLeft > 0 {
                return 1 // DMA steals the cycle, but we don't increment CPU.cycles
            }
        }

        if stallIRQThisInstruction {
            stallIRQThisInstruction = false
        }

        let opcode = read(address: PC)
        PC &+= 1

        // ---
        // --- OPTIMIZATION: Execute from the table ---
        // ---
        let c = opcodeTable[Int(opcode)]()

        cycles &+= UInt64(c)
        return c
    }

    // ---
    // --- OPTIMIZATION: This function builds the 256-entry opcode table ---
    // ---
    private func buildOpcodeTable() -> [() -> Int] {
        var table: [() -> Int] = Array(repeating: { self.opKIL() }, count: 256)

        // --- Load/Store Operations ---

        // LDA
        table[0xA9] = { self.A = self.immediate(); self.setZN(self.A); return 2 }
        table[0xA5] = { self.A = self.read(address: self.zeroPage()); self.setZN(self.A); return 3 }
        table[0xB5] = { self.A = self.read(address: self.zeroPageX()); self.setZN(self.A); return 4 }
        table[0xAD] = { self.A = self.read(address: self.absolute()); self.setZN(self.A); return 4 }
        table[0xBD] = { let (addr, cross) = self.absoluteX(); self.A = self.read(address: addr); self.setZN(self.A); return 4 + (cross ? 1 : 0) }
        table[0xB9] = { let (addr, cross) = self.absoluteY(); self.A = self.read(address: addr); self.setZN(self.A); return 4 + (cross ? 1 : 0) }
        table[0xA1] = { self.A = self.read(address: self.indirectX()); self.setZN(self.A); return 6 }
        table[0xB1] = { let (addr, cross) = self.indirectY(); self.A = self.read(address: addr); self.setZN(self.A); return 5 + (cross ? 1 : 0) }

        // LDX
        table[0xA2] = { self.X = self.immediate(); self.setZN(self.X); return 2 }
        table[0xA6] = { self.X = self.read(address: self.zeroPage()); self.setZN(self.X); return 3 }
        table[0xB6] = { self.X = self.read(address: self.zeroPageY()); self.setZN(self.X); return 4 }
        table[0xAE] = { self.X = self.read(address: self.absolute()); self.setZN(self.X); return 4 }
        table[0xBE] = { let (addr, cross) = self.absoluteY(); self.X = self.read(address: addr); self.setZN(self.X); return 4 + (cross ? 1 : 0) }

        // LDY
        table[0xA0] = { self.Y = self.immediate(); self.setZN(self.Y); return 2 }
        table[0xA4] = { self.Y = self.read(address: self.zeroPage()); self.setZN(self.Y); return 3 }
        table[0xB4] = { self.Y = self.read(address: self.zeroPageX()); self.setZN(self.Y); return 4 }
        table[0xAC] = { self.Y = self.read(address: self.absolute()); self.setZN(self.Y); return 4 }
        table[0xBC] = { let (addr, cross) = self.absoluteX(); self.Y = self.read(address: addr); self.setZN(self.Y); return 4 + (cross ? 1 : 0) }

        // STA
        table[0x85] = { self.write(address: self.zeroPage(), value: self.A); return 3 }
        table[0x95] = { self.write(address: self.zeroPageX(), value: self.A); return 4 }
        table[0x8D] = { self.write(address: self.absolute(), value: self.A); return 4 }
        table[0x9D] = { let (addr, _) = self.absoluteX(); self.write(address: addr, value: self.A); return 5 }
        table[0x99] = { let (addr, _) = self.absoluteY(); self.write(address: addr, value: self.A); return 5 }
        table[0x81] = { self.write(address: self.indirectX(), value: self.A); return 6 }
        table[0x91] = { let (addr, _) = self.indirectY(); self.write(address: addr, value: self.A); return 6 }

        // STX
        table[0x86] = { self.write(address: self.zeroPage(), value: self.X); return 3 }
        table[0x96] = { self.write(address: self.zeroPageY(), value: self.X); return 4 }
        table[0x8E] = { self.write(address: self.absolute(), value: self.X); return 4 }

        // STY
        table[0x84] = { self.write(address: self.zeroPage(), value: self.Y); return 3 }
        table[0x94] = { self.write(address: self.zeroPageX(), value: self.Y); return 4 }
        table[0x8C] = { self.write(address: self.absolute(), value: self.Y); return 4 }

        // --- Register Transfers ---
        table[0xAA] = { self.X = self.A; self.setZN(self.X); return 2 }
        table[0x8A] = { self.A = self.X; self.setZN(self.A); return 2 }
        table[0xA8] = { self.Y = self.A; self.setZN(self.Y); return 2 }
        table[0x98] = { self.A = self.Y; self.setZN(self.A); return 2 }
        table[0xBA] = { self.X = self.SP; self.setZN(self.X); return 2 }
        table[0x9A] = { self.SP = self.X; return 2 }

        // --- Stack Operations ---
        table[0x48] = { self.push(self.A); return 3 }
        table[0x68] = { self.A = self.pop(); self.setZN(self.A); return 4 }
        table[0x08] = { self.push(self.P | Flag.B.rawValue | Flag.U.rawValue); return 3 }
        table[0x28] = { var f = self.pop(); f |= Flag.U.rawValue; f &= ~Flag.B.rawValue; self.P = f; return 4 }

        // --- Logical (AND) ---
        table[0x29] = { self.and(self.immediate()); return 2 }
        table[0x25] = { self.and(self.read(address: self.zeroPage())); return 3 }
        table[0x35] = { self.and(self.read(address: self.zeroPageX())); return 4 }
        table[0x2D] = { self.and(self.read(address: self.absolute())); return 4 }
        table[0x3D] = { let (addr, cross) = self.absoluteX(); self.and(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0x39] = { let (addr, cross) = self.absoluteY(); self.and(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0x21] = { self.and(self.read(address: self.indirectX())); return 6 }
        table[0x31] = { let (addr, cross) = self.indirectY(); self.and(self.read(address: addr)); return 5 + (cross ? 1 : 0) }

        // --- Logical (ORA) ---
        table[0x09] = { self.ora(self.immediate()); return 2 }
        table[0x05] = { self.ora(self.read(address: self.zeroPage())); return 3 }
        table[0x15] = { self.ora(self.read(address: self.zeroPageX())); return 4 }
        table[0x0D] = { self.ora(self.read(address: self.absolute())); return 4 }
        table[0x1D] = { let (addr, cross) = self.absoluteX(); self.ora(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0x19] = { let (addr, cross) = self.absoluteY(); self.ora(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0x01] = { self.ora(self.read(address: self.indirectX())); return 6 }
        table[0x11] = { let (addr, cross) = self.indirectY(); self.ora(self.read(address: addr)); return 5 + (cross ? 1 : 0) }

        // --- Logical (EOR) ---
        table[0x49] = { self.eor(self.immediate()); return 2 }
        table[0x45] = { self.eor(self.read(address: self.zeroPage())); return 3 }
        table[0x55] = { self.eor(self.read(address: self.zeroPageX())); return 4 }
        table[0x4D] = { self.eor(self.read(address: self.absolute())); return 4 }
        table[0x5D] = { let (addr, cross) = self.absoluteX(); self.eor(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0x59] = { let (addr, cross) = self.absoluteY(); self.eor(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0x41] = { self.eor(self.read(address: self.indirectX())); return 6 }
        table[0x51] = { let (addr, cross) = self.indirectY(); self.eor(self.read(address: addr)); return 5 + (cross ? 1 : 0) }

        // --- Bit Test (BIT) ---
        table[0x24] = { let v = self.read(address: self.zeroPage()); self.setFlag(.Z, (self.A & v) == 0); self.setFlag(.V, (v & 0x40) != 0); self.setFlag(.N, (v & 0x80) != 0); return 3 }
        table[0x2C] = { let v = self.read(address: self.absolute()); self.setFlag(.Z, (self.A & v) == 0); self.setFlag(.V, (v & 0x40) != 0); self.setFlag(.N, (v & 0x80) != 0); return 4 }

        // --- Arithmetic (ADC) ---
        table[0x69] = { self.adc(self.immediate()); return 2 }
        table[0x65] = { self.adc(self.read(address: self.zeroPage())); return 3 }
        table[0x75] = { self.adc(self.read(address: self.zeroPageX())); return 4 }
        table[0x6D] = { self.adc(self.read(address: self.absolute())); return 4 }
        table[0x7D] = { let (addr, cross) = self.absoluteX(); self.adc(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0x79] = { let (addr, cross) = self.absoluteY(); self.adc(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0x61] = { self.adc(self.read(address: self.indirectX())); return 6 }
        table[0x71] = { let (addr, cross) = self.indirectY(); self.adc(self.read(address: addr)); return 5 + (cross ? 1 : 0) }

        // --- Arithmetic (SBC) ---
        table[0xE9] = { self.sbc(self.immediate()); return 2 }
        table[0xEB] = { self.sbc(self.immediate()); return 2 } // Illegal
        table[0xE5] = { self.sbc(self.read(address: self.zeroPage())); return 3 }
        table[0xF5] = { self.sbc(self.read(address: self.zeroPageX())); return 4 }
        table[0xED] = { self.sbc(self.read(address: self.absolute())); return 4 }
        table[0xFD] = { let (addr, cross) = self.absoluteX(); self.sbc(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0xF9] = { let (addr, cross) = self.absoluteY(); self.sbc(self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0xE1] = { self.sbc(self.read(address: self.indirectX())); return 6 }
        table[0xF1] = { let (addr, cross) = self.indirectY(); self.sbc(self.read(address: addr)); return 5 + (cross ? 1 : 0) }

        // --- Compare (CMP) ---
        table[0xC9] = { self.cmp(self.A, self.immediate()); return 2 }
        table[0xC5] = { self.cmp(self.A, self.read(address: self.zeroPage())); return 3 }
        table[0xD5] = { self.cmp(self.A, self.read(address: self.zeroPageX())); return 4 }
        table[0xCD] = { self.cmp(self.A, self.read(address: self.absolute())); return 4 }
        table[0xDD] = { let (addr, cross) = self.absoluteX(); self.cmp(self.A, self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0xD9] = { let (addr, cross) = self.absoluteY(); self.cmp(self.A, self.read(address: addr)); return 4 + (cross ? 1 : 0) }
        table[0xC1] = { self.cmp(self.A, self.read(address: self.indirectX())); return 6 }
        table[0xD1] = { let (addr, cross) = self.indirectY(); self.cmp(self.A, self.read(address: addr)); return 5 + (cross ? 1 : 0) }

        // --- Compare (CPX) ---
        table[0xE0] = { self.cmp(self.X, self.immediate()); return 2 }
        table[0xE4] = { self.cmp(self.X, self.read(address: self.zeroPage())); return 3 }
        table[0xEC] = { self.cmp(self.X, self.read(address: self.absolute())); return 4 }

        // --- Compare (CPY) ---
        table[0xC0] = { self.cmp(self.Y, self.immediate()); return 2 }
        table[0xC4] = { self.cmp(self.Y, self.read(address: self.zeroPage())); return 3 }
        table[0xCC] = { self.cmp(self.Y, self.read(address: self.absolute())); return 4 }

        // --- Increment (INC) ---
        table[0xE6] = { self.incM(self.zeroPage()); return 5 }
        table[0xF6] = { self.incM(self.zeroPageX()); return 6 }
        table[0xEE] = { self.incM(self.absolute()); return 6 }
        table[0xFE] = { let (addr, _) = self.absoluteX(); self.incM(addr); return 7 }

        // --- Decrement (DEC) ---
        table[0xC6] = { self.decM(self.zeroPage()); return 5 }
        table[0xD6] = { self.decM(self.zeroPageX()); return 6 }
        table[0xCE] = { self.decM(self.absolute()); return 6 }
        table[0xDE] = { let (addr, _) = self.absoluteX(); self.decM(addr); return 7 }

        // --- Register Increments/Decrements ---
        table[0xE8] = { self.X &+= 1; self.setZN(self.X); return 2 }
        table[0xC8] = { self.Y &+= 1; self.setZN(self.Y); return 2 }
        table[0xCA] = { self.X &-= 1; self.setZN(self.X); return 2 }
        table[0x88] = { self.Y &-= 1; self.setZN(self.Y); return 2 }

        // --- Shifts (Accumulator) ---
        table[0x0A] = { self.aslA(); return 2 }
        table[0x4A] = { self.lsrA(); return 2 }
        table[0x2A] = { self.rolA(); return 2 }
        table[0x6A] = { self.rorA(); return 2 }

        // --- Shifts (Memory) ---
        table[0x06] = { self.aslM(self.zeroPage()); return 5 }
        table[0x16] = { self.aslM(self.zeroPageX()); return 6 }
        table[0x0E] = { self.aslM(self.absolute()); return 6 }
        table[0x1E] = { let (addr, _) = self.absoluteX(); self.aslM(addr); return 7 }

        table[0x46] = { self.lsrM(self.zeroPage()); return 5 }
        table[0x56] = { self.lsrM(self.zeroPageX()); return 6 }
        table[0x4E] = { self.lsrM(self.absolute()); return 6 }
        table[0x5E] = { let (addr, _) = self.absoluteX(); self.lsrM(addr); return 7 }

        table[0x26] = { self.rolM(self.zeroPage()); return 5 }
        table[0x36] = { self.rolM(self.zeroPageX()); return 6 }
        table[0x2E] = { self.rolM(self.absolute()); return 6 }
        table[0x3E] = { let (addr, _) = self.absoluteX(); self.rolM(addr); return 7 }

        table[0x66] = { self.rorM(self.zeroPage()); return 5 }
        table[0x76] = { self.rorM(self.zeroPageX()); return 6 }
        table[0x6E] = { self.rorM(self.absolute()); return 6 }
        table[0x7E] = { let (addr, _) = self.absoluteX(); self.rorM(addr); return 7 }

        // --- Jumps & Subroutines ---
        table[0x4C] = { self.PC = self.absolute(); return 3 }
        table[0x6C] = { self.PC = self.indirect(); return 5 }
        table[0x20] = { let target = self.absolute(); self.pushWord(self.PC &- 1); self.PC = target; return 6 }
        table[0x60] = { self.PC = self.popWord() &+ 1; return 6 }
        table[0x00] = { self.brk(); return 7 }
        table[0x40] = { self.rti(); return 6 }

        // --- Branches ---
        let branch: (Flag, Bool) -> () -> Int = { flag, condition in
            return {
                let (target, cross) = self.relative()
                if self.getFlag(flag) == condition {
                    self.PC = target
                    return 3 + (cross ? 1 : 0)
                }
                return 2
            }
        }

        table[0x90] = branch(.C, false) // BCC
        table[0xB0] = branch(.C, true)  // BCS
        table[0xF0] = branch(.Z, true)  // BEQ
        table[0x30] = branch(.N, true)  // BMI
        table[0xD0] = branch(.Z, false) // BNE
        table[0x10] = branch(.N, false) // BPL
        table[0x50] = branch(.V, false) // BVC
        table[0x70] = branch(.V, true)  // BVS

        // --- Flag Clears/Sets ---
        table[0x18] = { self.setFlag(.C, false); return 2 } // CLC
        table[0x38] = { self.setFlag(.C, true); return 2 }  // SEC
        table[0x58] = { self.setFlag(.I, false); return 2 } // CLI
        table[0x78] = { self.setFlag(.I, true); return 2 }  // SEI
        table[0xB8] = { self.setFlag(.V, false); return 2 } // CLV
        table[0xD8] = { self.setFlag(.D, false); return 2 } // CLD
        table[0xF8] = { self.setFlag(.D, true); return 2 }  // SED

        // --- NOP ---
        table[0xEA] = { return 2 }

        // ---
        // --- Illegal Opcodes ---
        // ---

        // --- Illegal NOPs ---
        let nop1: () -> Int = { return 2 }
        table[0x1A] = nop1; table[0x3A] = nop1; table[0x5A] = nop1; table[0x7A] = nop1; table[0xDA] = nop1; table[0xFA] = nop1

        let nop2: () -> Int = { self.PC &+= 1; return 2 } // imm
        table[0x80] = nop2; table[0x82] = nop2; table[0x89] = nop2; table[0xC2] = nop2; table[0xE2] = nop2

        let nop2zp: () -> Int = { _ = self.zeroPage(); return 3 } // zp
        table[0x04] = nop2zp; table[0x44] = nop2zp; table[0x64] = nop2zp

        let nop2zpx: () -> Int = { _ = self.zeroPageX(); return 4 } // zp,x
        table[0x14] = nop2zpx; table[0x34] = nop2zpx; table[0x54] = nop2zpx; table[0x74] = nop2zpx; table[0xD4] = nop2zpx; table[0xF4] = nop2zpx

        let nop3abs: () -> Int = { _ = self.absolute(); return 4 } // abs
        table[0x0C] = nop3abs

        let nop3absx: () -> Int = { let (addr, cross) = self.absoluteX(); _ = self.read(address: addr); return 4 + (cross ? 1 : 0) } // abs,x
        table[0x1C] = nop3absx; table[0x3C] = nop3absx; table[0x5C] = nop3absx; table[0x7C] = nop3absx; table[0xDC] = nop3absx; table[0xFC] = nop3absx

        // --- LAX (LDA + LDX) ---
        let opLAX: (UInt16) -> () = { addr in let v = self.read(address: addr); self.A = v; self.X = v; self.setZN(v) }
        table[0xA7] = { opLAX(self.zeroPage()); return 3 }
        table[0xB7] = { opLAX(self.zeroPageY()); return 4 }
        table[0xAF] = { opLAX(self.absolute()); return 4 }
        table[0xBF] = { let (addr, cross) = self.absoluteY(); opLAX(addr); return 4 + (cross ? 1 : 0) }
        table[0xA3] = { opLAX(self.indirectX()); return 6 }
        table[0xB3] = { let (addr, cross) = self.indirectY(); opLAX(addr); return 5 + (cross ? 1 : 0) }

        // --- SAX (STA & STX) ---
        let opSAX: (UInt16) -> () = { addr in self.write(address: addr, value: self.A & self.X) }
        table[0x87] = { opSAX(self.zeroPage()); return 3 }
        table[0x97] = { opSAX(self.zeroPageY()); return 4 }
        table[0x8F] = { opSAX(self.absolute()); return 4 }
        table[0x83] = { opSAX(self.indirectX()); return 6 }

        // --- DCP (DEC + CMP) ---
        let opDCP: (UInt16) -> () = { addr in var v = self.read(address: addr); v &-= 1; self.write(address: addr, value: v); self.cmp(self.A, v) }
        table[0xC7] = { opDCP(self.zeroPage()); return 5 }
        table[0xD7] = { opDCP(self.zeroPageX()); return 6 }
        table[0xCF] = { opDCP(self.absolute()); return 6 }
        table[0xDF] = { let (addr, _) = self.absoluteX(); opDCP(addr); return 7 }
        table[0xDB] = { let (addr, _) = self.absoluteY(); opDCP(addr); return 7 }
        table[0xC3] = { opDCP(self.indirectX()); return 8 }
        table[0xD3] = { let (addr, _) = self.indirectY(); opDCP(addr); return 8 }

        // --- ISC (INC + SBC) ---
        let opISC: (UInt16) -> () = { addr in var v = self.read(address: addr); v &+= 1; self.write(address: addr, value: v); self.sbc(v) }
        table[0xE7] = { opISC(self.zeroPage()); return 5 }
        table[0xF7] = { opISC(self.zeroPageX()); return 6 }
        table[0xEF] = { opISC(self.absolute()); return 6 }
        table[0xFF] = { let (addr, _) = self.absoluteX(); opISC(addr); return 7 }
        table[0xFB] = { let (addr, _) = self.absoluteY(); opISC(addr); return 7 }
        table[0xE3] = { opISC(self.indirectX()); return 8 }
        table[0xF3] = { let (addr, _) = self.indirectY(); opISC(addr); return 8 }

        // --- SLO (ASL + ORA) ---
        let opSLO: (UInt16) -> () = { addr in var v = self.read(address: addr); self.setFlag(.C, (v & 0x80) != 0); v &<<= 1; self.write(address: addr, value: v); self.ora(v) }
        table[0x07] = { opSLO(self.zeroPage()); return 5 }
        table[0x17] = { opSLO(self.zeroPageX()); return 6 }
        table[0x0F] = { opSLO(self.absolute()); return 6 }
        table[0x1F] = { let (addr, _) = self.absoluteX(); opSLO(addr); return 7 }
        table[0x1B] = { let (addr, _) = self.absoluteY(); opSLO(addr); return 7 }
        table[0x03] = { opSLO(self.indirectX()); return 8 }
        table[0x13] = { let (addr, _) = self.indirectY(); opSLO(addr); return 8 }

        // --- RLA (ROL + AND) ---
        let opRLA: (UInt16) -> () = { addr in var v = self.read(address: addr); let cin: UInt8 = self.getFlag(.C) ? 1 : 0; let newC = (v & 0x80) != 0; v = (v &<< 1) | cin; self.write(address: addr, value: v); self.setFlag(.C, newC); self.and(v) }
        table[0x27] = { opRLA(self.zeroPage()); return 5 }
        table[0x37] = { opRLA(self.zeroPageX()); return 6 }
        table[0x2F] = { opRLA(self.absolute()); return 6 }
        table[0x3F] = { let (addr, _) = self.absoluteX(); opRLA(addr); return 7 }
        table[0x3B] = { let (addr, _) = self.absoluteY(); opRLA(addr); return 7 }
        table[0x23] = { opRLA(self.indirectX()); return 8 }
        table[0x33] = { let (addr, _) = self.indirectY(); opRLA(addr); return 8 }

        // --- SRE (LSR + EOR) ---
        let opSRE: (UInt16) -> () = { addr in var v = self.read(address: addr); self.setFlag(.C, (v & 0x01) != 0); v &>>= 1; self.write(address: addr, value: v); self.eor(v) }
        table[0x47] = { opSRE(self.zeroPage()); return 5 }
        table[0x57] = { opSRE(self.zeroPageX()); return 6 }
        table[0x4F] = { opSRE(self.absolute()); return 6 }
        table[0x5F] = { let (addr, _) = self.absoluteX(); opSRE(addr); return 7 }
        table[0x5B] = { let (addr, _) = self.absoluteY(); opSRE(addr); return 7 }
        table[0x43] = { opSRE(self.indirectX()); return 8 }
        table[0x53] = { let (addr, _) = self.indirectY(); opSRE(addr); return 8 }

        // --- RRA (ROR + ADC) ---
        let opRRA: (UInt16) -> () = { addr in var v = self.read(address: addr); let cin: UInt8 = self.getFlag(.C) ? 0x80 : 0; let newC = (v & 0x01) != 0; v = (v &>> 1) | cin; self.write(address: addr, value: v); self.setFlag(.C, newC); self.adc(v) }
        table[0x67] = { opRRA(self.zeroPage()); return 5 }
        table[0x77] = { opRRA(self.zeroPageX()); return 6 }
        table[0x6F] = { opRRA(self.absolute()); return 6 }
        table[0x7F] = { let (addr, _) = self.absoluteX(); opRRA(addr); return 7 }
        table[0x7B] = { let (addr, _) = self.absoluteY(); opRRA(addr); return 7 }
        table[0x63] = { opRRA(self.indirectX()); return 8 }
        table[0x73] = { let (addr, _) = self.indirectY(); opRRA(addr); return 8 }

        // --- Illegal Immediate Opcodes ---
        table[0x0B] = { let v = self.immediate(); self.and(v); self.setFlag(.C, (self.A & 0x80) != 0); return 2 } // ANC
        table[0x2B] = { let v = self.immediate(); self.and(v); self.setFlag(.C, (self.A & 0x80) != 0); return 2 } // ANC
        table[0x4B] = { let v = self.immediate(); self.and(v); self.lsrA(); return 2 } // ALR
        table[0x6B] = { let v = self.immediate(); self.and(v); self.rorA(); return 2 } // ARR
        table[0xCB] = { let v = self.immediate(); let t = (self.A & self.X); let r = t &- v; self.setFlag(.C, t >= v); self.X = r; self.setZN(self.X); return 2 } // AXS

        // --- Other Misc Illegals ---
        table[0xBB] = { let (addr, cross) = self.absoluteY(); let v = self.read(address: addr) & self.SP; self.SP = v; self.A = v; self.X = v; self.setZN(v); return 4 + (cross ? 1 : 0) } // LAS
        table[0x9B] = { let (base, _) = self.absoluteY(); let addr = base; let hiPlus1 = UInt8(((base >> 8) & 0xFF) &+ 1); self.SP = self.A & self.X; let v = self.SP & hiPlus1; self.write(address: addr, value: v); return 5 } // TAS
        table[0x9F] = { let (addr, _) = self.absoluteY(); let base = addr &- UInt16(self.Y); let v = (self.A & self.X) & UInt8(((base >> 8) & 0xFF) &+ 1); self.write(address: addr, value: v); return 5 } // AHX
        table[0x93] = { let (addr, _) = self.indirectY(); let base = addr &- UInt16(self.Y); let v = (self.A & self.X) & UInt8(((base >> 8) & 0xFF) &+ 1); self.write(address: addr, value: v); return 6 } // AHX
        table[0x9C] = { let (addr, _) = self.absoluteX(); let base = addr &- UInt16(self.X); let v = self.Y & UInt8(((base >> 8) & 0xFF) &+ 1); self.write(address: addr, value: v); return 5 } // SHY
        table[0x9E] = { let (addr, _) = self.absoluteY(); let base = addr &- UInt16(self.Y); let v = self.X & UInt8(((base >> 8) & 0xFF) &+ 1); self.write(address: addr, value: v); return 5 } // SHX

        return table
    }
}
