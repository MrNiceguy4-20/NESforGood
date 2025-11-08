# 🚀 NESforGood: Cycle-Accurate Nintendo Entertainment System Emulator (macOS)

NESforGood is a performant, cross-platform-compatible NES emulator written entirely in **Swift**. It utilizes the **Metal framework** for high-speed GPU rendering, custom shaders for visual effects, and focuses on **cycle-accurate PPU timing** to ensure compatibility with challenging titles like *Super Mario Bros. 3* and *Castlevania*.

-----

## ✨ Features

  * **High Compatibility:** Implements complex mappers necessary for advanced commercial titles.
      * **Mapper Support:** NROM (0), MMC1 (1), UxROM (2), CNROM (3), MMC3 (4), MMC5 (5), AxROM (7), MMC2 (9), MMC4 (10), ColorDreams (11), GNROM (66), and Mapper 71.
  * **Cycle-Accurate Timing:** Precise simulation of $\text{CPU}$ ($\text{6502}$) and $\text{PPU}$ clocks, crucial for games utilizing scanline interrupts (like $\text{MMC}3$).
  * **Advanced Graphics Pipeline:**
      * **Metal Rendering:** Uses $\text{MTKView}$ and custom Metal shaders for fast, low-latency display.
      * **Visual Enhancements:** Includes **integer scaling** and optional **CRT emulation** (scanlines, gamma adjustment, and curvature).
  * **Peripherals Support:**
      * Full emulation of **$\text{APU}$** (Pulse, Triangle, Noise, $\text{DMC}$ channels) with audio buffering and resampling.
      * Support for Keyboard and **Game Controller** (via $\text{GameController}$ framework).
  * **Battery/Save State:** Automatic loading and saving of battery-backed $\text{PRG}$ $\text{RAM}$ for titles that support it.

-----

## 💻 Tech Stack

  * **Language:** Swift
  * **Platform:** macOS
  * **Frameworks:** SwiftUI, Metal, MetalKit, AVFoundation, GameController

-----

## 🏗️ Architecture Highlights

The emulator is designed with clear separation of concerns, mapping closely to the original NES hardware components:

  * **`EmulatorCore.swift`:** The main timing loop responsible for cycling the $\text{CPU}$, $\text{PPU}$, and $\text{APU}$ in the correct $1:3:1$ ratio, handling $\text{DMA}$ stalls, and managing frame presentation.
  * **`Bus.swift`:** Handles memory mapping, routing $\text{CPU}$ requests to $\text{RAM}$, $\text{PPU}$ registers, $\text{APU}$ registers, and the active $\text{Cartridge}$ $\text{Mapper}$.
  * **`PPU.swift`:** Contains the complex graphics logic, managing Loopy registers, scroll synchronization, sprite evaluation, and rendering pixels to a frame buffer for GPU consumption.
  * **Mappers (e.g., `MMC3Mapper.swift`):** Manages banking and hardware-specific features like $\text{IRQ}$ timing based on $\text{PPU}$ $\text{A}12$ line observation.
  * **`MetalView.swift` / `DefaultShader.metal`:** Provides the high-performance drawing layer using $\text{Metal}$ for custom vertex/fragment shading.

-----

## ▶️ Getting Started

### Prerequisites

  * macOS (Latest stable version recommended)
  * Xcode (Latest version)

### Building and Running

1.  **Clone the repository:**
    ```bash
    git clone https://github.com/yourusername/NESforGood.git
    cd NESforGood
    ```
2.  **Open in Xcode:**
    ```bash
    open NESEmulator.xcodeproj
    ```
3.  **Run:** Select the `NESEmulator` target and build/run the application ($\text{⌘} \text{R}$).
4.  **Load a ROM:** Use the **File \> Load ROM...** menu or the "Load ROM" button ($\text{📁}$) in the toolbar to select a standard `.nes` file.

-----

## 🎮 Controls

| NES Button | Default Key Mapping | Game Controller |
| :--- | :--- | :--- |
| **A** | A Key | Button A / X |
| **B** | B Key | Button B / Circle |
| **Select** | Spacebar | Left Shoulder |
| **Start** | Return / Enter | Right Shoulder |
| **Up** | Up Arrow | D-Pad Up |
| **Down** | Down Arrow | D-Pad Down |
| **Left** | Left Arrow | D-Pad Left |
| **Right** | D-Pad Right | Right Arrow |

-----

## 🤝 Contributing

Contributions are welcome\! If you find bugs related to specific mappers, timing, or $\text{PPU}$ rendering errors, please open an issue or submit a pull request. We aim for $100\%$ cycle-accurate playback for high-fidelity emulation.

-----

## 📝 License

This project is licensed under the [MIT License](https://www.google.com/search?q=LICENSE).
