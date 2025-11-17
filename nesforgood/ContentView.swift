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
    @State private var scaleMode: ScaleMode = .integer
    @State private var shaderMode: ShaderMode = .none
    @State private var vsyncEnabled: Bool = true
    @State private var frameLimit: Int = 60
    @State private var gamma: Double = 1.0
    @State private var crtEnabled: Bool = true
    @State private var colorTemp: Double = 0.0
    @State private var curvature: Double = 0.08

    // New: Turbo + audio latency state
    @State private var turboEnabled: Bool = false
    @State private var audioLatency: EmulatorCore.AudioLatency = .medium

    var body: some View {
        VStack(spacing: 0) {
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
                .opacity(emulator.cartridge == nil ? 0.0 : 1.0)

                if emulator.cartridge == nil {
                    Text("Load a ROM to start playing")
                        .foregroundColor(.gray)
                        .padding()
                }
            }

            Divider()

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
                }
                .padding(.horizontal, 6)

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
                }
                .padding(.horizontal, 6)

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

                // New: Turbo toggle
                Toggle("Turbo", isOn: $turboEnabled)
                    .toggleStyle(.switch)
                    .tint(.orange)
                    .help("Run emulation as fast as possible (no frame pacing)")

                // New: Audio latency picker
                HStack(spacing: 8) {
                    Text("Audio Latency").font(.headline)
                    Picker("Audio Latency", selection: $audioLatency) {
                        Text("Low").tag(EmulatorCore.AudioLatency.low)
                        Text("Medium").tag(EmulatorCore.AudioLatency.medium)
                        Text("High").tag(EmulatorCore.AudioLatency.high)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.regular)
                    .tint(.accentColor)
                }
                .padding(.horizontal, 6)

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
        .onAppear {
            // Initialize core with current UI state
            emulator.setVSync(vsyncEnabled)
            emulator.setFrameLimit(frameLimit)
            emulator.setTurboEnabled(turboEnabled)
            emulator.setAudioLatency(audioLatency)
        }
        .onDisappear {
            emulator.stop()
        }
        .onChange(of: vsyncEnabled) { _, newValue in
            emulator.setVSync(newValue)
        }
        .onChange(of: frameLimit) { _, newValue in
            emulator.setFrameLimit(newValue)
        }
        .onChange(of: turboEnabled) { _, newValue in
            emulator.setTurboEnabled(newValue)
        }
        .onChange(of: audioLatency) { _, newValue in
            emulator.setAudioLatency(newValue)
        }
        .onReceive(
            Timer
                .publish(every: 1.0 / 10.0, on: .main, in: .common)
                .autoconnect()
        ) { _ in
            let current = emulator.frameSerial
            let deltaFrames = Double(current &- lastSerial)
            fps = deltaFrames * 10.0
            lastSerial = current
        }
        .onReceive(NotificationCenter.default.publisher(for: .emulatorLoadROM)) { _ in
            loadROM()
        }
        .onReceive(NotificationCenter.default.publisher(for: .emulatorReset)) { _ in
            if emulator.cartridge != nil {
                emulator.reset()
            }
        }
    }

    private var canStart: Bool {
        emulator.cartridge != nil && !emulator.isRunning
    }

    private func loadROM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nes") ?? .data]
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
