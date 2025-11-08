
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var emulator = EmulatorCore()
    @State private var lastFrameTime: Date = Date()
    @State private var fps: Double = 0
    @State private var romName: String = "No ROM loaded"
    @State private var lastSerial: UInt64 = 0

    // Phase 4 controls
    @State private var scaleMode: ScaleMode = .integer
    @State private var shaderMode: ShaderMode = .none

    // Phase 5 controls
    @State private var vsyncEnabled: Bool = true
    @State private var frameLimit: Int = 60 // 30 / 60 / 120
    @State private var gamma: Double = 1.0 // 0.8 ... 1.4
    @State private var crtEnabled: Bool = true
    @State private var colorTemp: Double = 0.0 // 0=cool, 1=warm
    @State private var curvature: Double = 0.08 // 0...0.2 gentle CRT

    var body: some View {
        VStack(spacing: 0) {
            // Display
            ZStack {
                MetalView(
                    emulator: emulator,
                    scaleMode: scaleMode,
                    shaderMode: shaderMode,
                    vsyncEnabled: vsyncEnabled,
                    frameLimit: frameLimit,
                    gamma: Float(gamma),
                    colorTemp: Float(colorTemp),
                    curvature: Float(crtEnabled ? curvature : 0.0)
                )
                .background(Color.black)
                if emulator.cartridge == nil {
                    Text("Load a ROM to start playing")
                        .foregroundColor(.gray)
                        .padding()
                }
            }

            Divider()

            // Status bar
            HStack(spacing: 16) {
                Spacer()
                Text("ROM: \(romName)")
                    .foregroundColor(.secondary)
                Text(String(format: "FPS: %.1f", fps))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: loadROM) {
                    Label("Load ROM", systemImage: "folder")
                }

                Button(action: {
                    emulator.start()
                    lastFrameTime = Date()
                }) {
                    Label("Start", systemImage: "play.circle")
                }
                .disabled(!canStart)

                Button(action: { emulator.stop() }) {
                    Label("Stop", systemImage: "stop.circle")
                }
                .disabled(!emulator.isRunning)

                Button(action: { emulator.reset() }) {
                    Label("Reset", systemImage: "arrow.clockwise")
                }

                // Phase 4 (inline): Scale + Shader
                HStack(spacing: 8) {
                    Text("Scale:").font(.headline)
                    Picker("Scale", selection: $scaleMode) {
                        ForEach(ScaleMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.regular)
                    .tint(.accentColor)
                    .cornerRadius(12)
                }.padding(.horizontal, 6)

                HStack(spacing: 8) {
                    Text("Shader:").font(.headline)
                    Picker("Shader", selection: $shaderMode) {
                        ForEach(ShaderMode.allCases) { shader in
                            Text(shader.rawValue).tag(shader)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.regular)
                    .tint(.accentColor)
                    .cornerRadius(12)
                }.padding(.horizontal, 6)

                // Phase 5 (inline): VSync + Frame limit + Gamma + Temp
                Toggle("VSync", isOn: $vsyncEnabled)
                Toggle("CRT Mode", isOn: $crtEnabled)
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .padding(.leading, 8)
    
                    .toggleStyle(.switch)
                    .controlSize(.regular)
                    .tint(.accentColor)
                    .padding(.leading, 8)

                Picker("FPS", selection: $frameLimit) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("120").tag(120)
                }
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .tint(.accentColor)
                .cornerRadius(12)
                .help("Frame limit")

                HStack(spacing: 8) {
                    Text("Gamma").font(.headline)
                    Slider(value: $gamma, in: 0.8...1.4, step: 0.02)
                        .frame(width: 140)
                        .help("Display gamma")
                }.padding(.horizontal, 6)

                HStack(spacing: 8) {
                    Text("Warmth").font(.headline)
                    Slider(value: $colorTemp, in: 0.0...1.0, step: 0.02)
                        .frame(width: 120)
                        .help("Color temperature (cool → warm)")
                }.padding(.horizontal, 6)

                Spacer()

                if emulator.isRunning {
                    Label("Running", systemImage: "gamecontroller")
                        .foregroundStyle(.green)
                } else {
                    Label("Stopped", systemImage: "pause.circle")
                        .foregroundStyle(.red)
                }
            }
        }
        .onDisappear { emulator.stop() }
        
        .onChange(of: vsyncEnabled) { old, newValue in
            emulator.setVSync(newValue)
        }
        .onChange(of: frameLimit) { old, newValue in
            emulator.setFrameLimit(newValue)
        }
.onReceive(Timer.publish(every: 1.0/10.0, on: .main, in: .common).autoconnect()) { _ in
            let current = emulator.frameSerial
            let deltaFrames = Double(current &- lastSerial)
            fps = deltaFrames * 10.0
            lastSerial = current
        }
    }

    private var canStart: Bool {
        emulator.cartridge != nil && !emulator.isRunning
    }

    private func loadROM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.data]
        panel.allowedFileTypes = ["nes"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select a NES ROM"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                try emulator.loadROM(data: data)
                romName = url.lastPathComponent
                emulator.reset()
                fps = 0
            } catch {
                let alert = NSAlert()
                alert.messageText = "Error"
                alert.informativeText = "Failed to load ROM: \(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }
}

#Preview { ContentView() }

