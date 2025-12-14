import SwiftUI
import MetalKit
import Dispatch

enum ScaleMode: String, CaseIterable, Identifiable {
    case integer = "Integer"
    case free = "Free"
    var id: String { rawValue }
}

enum ShaderMode: String, CaseIterable, Identifiable {
    case none = "None"
    case scanlines = "Scanlines"
    var id: String { rawValue }
}

struct MetalView: NSViewRepresentable {
    let emulator: EmulatorCore
    var scaleMode: ScaleMode
    var shaderMode: ShaderMode
    var vsyncEnabled: Bool
    var frameLimit: Int
    var gamma: Float
    var colorTemp: Float
    var curvature: Float

    @inline(__always) func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal not supported") }
        view.device = device
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.preferredFramesPerSecond = vsyncEnabled ? frameLimit : max(30, frameLimit)
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        context.coordinator.configure(view: view, emulator: emulator, scaleMode: scaleMode, shaderMode: shaderMode)
        context.coordinator.gamma = gamma
        context.coordinator.colorTemp = colorTemp
        context.coordinator.curvature = curvature
        context.coordinator.vsyncEnabled = vsyncEnabled
        context.coordinator.frameLimit = frameLimit
        return view
    }

    @inline(__always) func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.scaleMode = scaleMode
        context.coordinator.shaderMode = shaderMode
        context.coordinator.gamma = gamma
        context.coordinator.colorTemp = colorTemp
        context.coordinator.curvature = curvature
        context.coordinator.vsyncEnabled = vsyncEnabled
        context.coordinator.frameLimit = frameLimit
        nsView.preferredFramesPerSecond = vsyncEnabled ? frameLimit : max(30, frameLimit)
    }

    @inline(__always) func makeCoordinator() -> Coordinator { Coordinator() }
}

struct Uniforms {
    var texSize: SIMD2<Float>
    var mode: UInt32
    var gamma: Float
    var curvature: Float
    var colorTemp: Float
    var _pad: Float
}

final class Coordinator: NSObject, MTKViewDelegate {
    @inline(__always) func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private var emulator: EmulatorCore!
    private(set) var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var pipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!
    private var vb: MTLBuffer?
    private var ub: MTLBuffer?
    private var srcTexture: MTLTexture?
    private var cachedDrawableSize: CGSize = .zero
    private var cachedScaleSnapshot: ScaleMode = .integer

    var scaleMode: ScaleMode = .integer
    var shaderMode: ShaderMode = .none
    var gamma: Float = 1.0
    var colorTemp: Float = 0.0
    var curvature: Float = 0.0
    var vsyncEnabled: Bool = true
    var frameLimit: Int = 60

    private let texSize = SIMD2<Float>(256, 240)
    private var lastTime: CFTimeInterval = CACurrentMediaTime()
    private var lastCartridgeID: ObjectIdentifier? = nil

    @inline(__always) func configure(view: MTKView, emulator: EmulatorCore, scaleMode: ScaleMode, shaderMode: ShaderMode) {
        self.emulator = emulator
        self.scaleMode = scaleMode
        self.shaderMode = shaderMode
        guard let device = view.device else { return }
        self.device = device
        self.queue = device.makeCommandQueue()

        let lib = try! device.makeDefaultLibrary(bundle: .main)
        let desc = MTLRenderPipelineDescriptor()
        desc.colorAttachments[0].pixelFormat = view.colorPixelFormat
        desc.vertexFunction = lib.makeFunction(name: "v_main")
        desc.fragmentFunction = lib.makeFunction(name: "f_main")
        self.pipeline = try! device.makeRenderPipelineState(descriptor: desc)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .nearest
        sd.magFilter = .nearest
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        self.sampler = device.makeSamplerState(descriptor: sd)

        var U = Uniforms(texSize: texSize, mode: 0, gamma: 1.0, curvature: 0.0, colorTemp: 0.0, _pad: 0.0)
        self.ub = device.makeBuffer(bytes: &U, length: MemoryLayout<Uniforms>.stride, options: .storageModeShared)

        view.delegate = self
    }

    @inline(__always) func draw(in view: MTKView) {
        let currentCartridgeID = emulator.cartridge.map { ObjectIdentifier($0) }

        if lastCartridgeID != currentCartridgeID {
            srcTexture = nil
            lastCartridgeID = currentCartridgeID
        }

        guard emulator.isRunning,
              let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let device = view.device else {
            return
        }
        if !vsyncEnabled {
            let now = CACurrentMediaTime()
            let target = 1.0 / Double(max(1, frameLimit))
            if now - lastTime < target { return }
            lastTime = now
        }

        if let ppu = emulator.ppu {
            if srcTexture == nil {
                srcTexture = ppu.makeTexture(device: device)
            } else if let tex = srcTexture {
                ppu.copyFrame(to: tex)
            }
        }
        guard let source = srcTexture else { return }

        updateVertexBufferIfNeeded(for: view)
        guard let vb = vb else { return }

        if let ub = ub {
            let U = ub.contents().bindMemory(to: Uniforms.self, capacity: 1)
            U.pointee.mode = (shaderMode == .scanlines) ? 1 : 0
            U.pointee.texSize = texSize
            U.pointee.gamma = gamma
            U.pointee.curvature = curvature
            U.pointee.colorTemp = colorTemp
        }

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: passDesc) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vb, offset: 0, index: 0)
        if let ub = ub { enc.setFragmentBuffer(ub, offset: 0, index: 1) }
        enc.setFragmentTexture(source, index: 0)
        enc.setFragmentSamplerState(sampler, index:0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    @inline(__always) private func updateVertexBufferIfNeeded(for view: MTKView) {
        guard let device = self.device ?? view.device else { return }
        let drawableSize = view.drawableSize
        guard drawableSize.width > 0 && drawableSize.height > 0 else { return }

        // Only update if the size or the scaling mode has changed
        if drawableSize == cachedDrawableSize && cachedScaleSnapshot == scaleMode {
            return
        }

        cachedDrawableSize = drawableSize
        cachedScaleSnapshot = scaleMode

        let baseW: CGFloat = 256
        let baseH: CGFloat = 240
        let dw = drawableSize.width
        let dh = drawableSize.height

        var W: CGFloat
        var H: CGFloat

        if scaleMode == .integer {
            let sx = floor(dw / baseW)
            let sy = floor(dh / baseH)
            let scale = max(1, Int(min(sx, sy)))
            W = CGFloat(scale) * baseW
            H = CGFloat(scale) * baseH
        } else {
            let aspect = baseW / baseH
            if dw / dh > aspect {
                H = dh
                W = H * aspect
            } else {
                W = dw
                H = W / aspect
            }
        }

        let x0 = (dw - W) * 0.5
        let y0 = (dh - H) * 0.5
        let x1 = x0 + W
        let y1 = y0 + H

        let ndc = { (x: CGFloat, y: CGFloat) -> SIMD2<Float> in
            SIMD2<Float>(
                Float((x / dw) * 2.0 - 1.0),
                Float((y / dh) * 2.0 - 1.0)
            )
        }

        let verts: [Float] = [
            ndc(x0, y0).x, ndc(x0, y0).y, 0.0, 1.0,
            ndc(x1, y0).x, ndc(x1, y0).y, 1.0, 1.0,
            ndc(x0, y1).x, ndc(x0, y1).y, 0.0, 0.0,
            ndc(x1, y0).x, ndc(x1, y0).y, 1.0, 1.0,
            ndc(x1, y1).x, ndc(x1, y1).y, 1.0, 0.0,
            ndc(x0, y1).x, ndc(x0, y1).y, 0.0, 0.0
        ]

        let dataLength = MemoryLayout<Float>.size * verts.count
        if vb == nil || vb!.length < dataLength {
            vb = device.makeBuffer(bytes: verts, length: dataLength, options: .storageModeShared)
        } else if let vb = vb {
            let ptr = vb.contents().bindMemory(to: Float.self, capacity: verts.count)
            // Corrected: use update(from:count:) instead of deprecated assign(from:count:)
            verts.withUnsafeBufferPointer { buf in
                ptr.update(from: buf.baseAddress!, count: buf.count)
            }
        }
    }
}
