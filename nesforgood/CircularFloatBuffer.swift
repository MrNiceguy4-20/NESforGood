//
//  CircularFloatBuffer.swift
//  nesforgood
//
//  Created by kevin on 2025-10-30.
//


final class CircularFloatBuffer {
    private let capacityMask: Int
    private var buffer: [Float]
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    
    init(capacity: Int) {
        var pow2 = 1
        while pow2 < max(2, capacity) { pow2 <<= 1 }
        self.buffer = [Float](repeating: 0, count: pow2)
        self.capacityMask = pow2 - 1
    }
    
    @inline(__always) func availableToRead() -> Int { writeIndex &- readIndex }
    @inline(__always) func availableToWrite() -> Int { buffer.count &- availableToRead() }
    
    @inline(__always) func push(_ sample: Float) {
        if availableToWrite() > 0 {
            buffer[writeIndex & capacityMask] = sample
            writeIndex &+= 1
        }
    }
    
    @inline(__always) @discardableResult
    func pop(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let n = min(count, availableToRead())
        if n == 0 { return 0 }
        var idx = readIndex
        for i in 0..<n {
            dst.advanced(by: i).pointee = buffer[idx & capacityMask]
            idx &+= 1
        }
        readIndex = idx
        return n
    }
}