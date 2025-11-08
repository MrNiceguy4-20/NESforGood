final class CHRMemory {
    var data: [UInt8]
    let isRAM: Bool
    init(size: Int, isRAM: Bool, initial: [UInt8] = []) {
        if isRAM {
            self.data = [UInt8](repeating: 0, count: max(size, 8192)) // at least 8KB CHR-RAM
        } else {
            self.data = initial.isEmpty ? [UInt8](repeating: 0, count: size) : initial
        }
        self.isRAM = isRAM
    }
}
