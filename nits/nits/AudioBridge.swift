
import Foundation

/// Real-time safe bridge between APU audio output and the audio render thread.
/// Uses CircularFloatBuffer (push / pop API).
final class AudioBridge {

    private let buffer: CircularFloatBuffer
    private unowned let apu: APU

    private var running = false

    init(apu: APU, sampleRate: Float = 48_000, bufferSize: Int = 8192) {
        self.apu = apu
        self.buffer = CircularFloatBuffer(capacity: bufferSize)
    }

    /// Call from the emulator (producer thread)
    @inline(__always)
    func pumpFromAPU(cycles: Int) {
        guard running else { return }
        for _ in 0..<cycles {
            let s = apu.outputSample()
            buffer.push(s)   // ✅ correct API
        }
    }

    /// Call from CoreAudio / render thread (consumer)
    @inline(__always)
    func render(into out: UnsafeMutablePointer<Float>, frameCount: Int) {
        let got = buffer.pop(into: out, count: frameCount)  // ✅ correct API
        if got < frameCount {
            out.advanced(by: got).initialize(repeating: 0, count: frameCount - got)
        }
    }

    func start() { running = true }
    func stop()  { running = false }
}
