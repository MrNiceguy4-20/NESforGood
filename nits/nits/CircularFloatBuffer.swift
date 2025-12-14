import Atomics // Import the Atomics library

final class CircularFloatBuffer {
    private let capacityMask: Int
    private var buffer: [Float]
    // Use ManagedAtomic<Int> for thread-safe, lock-free operations
    private let writeIndex = ManagedAtomic<Int>(0)
    private let readIndex = ManagedAtomic<Int>(0)
    
    init(capacity: Int) {
        var pow2 = 1
        while pow2 < max(2, capacity) { pow2 <<= 1 }
        self.buffer = [Float](repeating: 0, count: pow2)
        self.capacityMask = pow2 - 1
    }
    
    // The "producer" (main thread) only needs to read the readIndex
    // to know if there's space.
    
    @inline(__always) func reset() {
        writeIndex.store(0, ordering: .relaxed)
        readIndex.store(0, ordering: .relaxed)
    }
    
    @inline(__always) func availableToWrite() -> Int {
        let currentWrite = writeIndex.load(ordering: .relaxed)
        let currentRead = readIndex.load(ordering: .acquiring)
        return (buffer.count - 1) &- (currentWrite &- currentRead)
    }
    
    // The "consumer" (audio thread) only needs to read the writeIndex
    // to know if there's data.
    @inline(__always) func availableToRead() -> Int {
        let currentWrite = writeIndex.load(ordering: .acquiring)
        let currentRead = readIndex.load(ordering: .relaxed)
        return currentWrite &- currentRead
    }
    
    // --- PRODUCER (Main Thread) ---
    @inline(__always) func push(_ sample: Float) {
        let currentWrite = writeIndex.load(ordering: .relaxed)
        let currentRead = readIndex.load(ordering: .acquiring)
        
        // Check if the buffer is full
        if (currentWrite &- currentRead) < buffer.count {
            buffer[currentWrite & capacityMask] = sample
            // "Release" this new sample so the consumer thread can "acquire" it
            writeIndex.store(currentWrite &+ 1, ordering: .releasing)
        }
    }
    
    // --- CONSUMER (Audio Thread) ---
    @inline(__always) @discardableResult
    func pop(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let currentRead = readIndex.load(ordering: .relaxed)
        let currentWrite = writeIndex.load(ordering: .acquiring)

        let available = currentWrite &- currentRead
        if available == 0 { return 0 }

        let n = min(count, available)
        let start = currentRead & capacityMask
        let bufferCount = buffer.count
        let firstChunk = min(n, bufferCount &- start)

        buffer.withUnsafeBufferPointer { ptr in
            let base = ptr.baseAddress!
            // Corrected: use update(from:count:) instead of deprecated assign(from:count:)
            dst.update(from: base + start, count: firstChunk)
            if n > firstChunk {
                dst.advanced(by: firstChunk)
                    .update(from: base, count: n - firstChunk)
            }
        }

        // "Release" the newly-free space so the producer thread can "acquire" it
        readIndex.store(currentRead &+ n, ordering: .releasing)
        return n
    }
}
