final class ExtRAM {
    // ---
    // --- OPTIMIZATION: Replaced [UInt8] with UnsafeMutablePointer ---
    // ---
    var data: UnsafeMutablePointer<UInt8>
    let size: Int

    init(size: Int) {
        let allocSize = max(size, 8 * 1024)
        self.size = allocSize
        self.data = .allocate(capacity: allocSize)
        self.data.initialize(repeating: 0, count: allocSize)
    }
    
    deinit {
        data.deinitialize(count: size)
        data.deallocate()
    }
}
