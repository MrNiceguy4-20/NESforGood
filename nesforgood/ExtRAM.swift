final class ExtRAM {
    var data: [UInt8]
    init(size: Int) {
        self.data = [UInt8](repeating: 0, count: max(size, 8 * 1024))
    }
}
