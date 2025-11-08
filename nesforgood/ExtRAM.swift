final class ExtRAM {
    var data: [UInt8]
    init(size: Int) {
        // Common sizes: 8KB..32KB. Default to 8KB if unknown.
        self.data = [UInt8](repeating: 0, count: max(size, 8 * 1024))
    }
}
