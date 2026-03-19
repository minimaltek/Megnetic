//
//  SettingsView.swift
//  Magnetic
//
//  Bottom sheet settings panel — Techno minimal design
//

import SwiftUI
import PhotosUI
import CoreImage


// MARK: - Color Theme

private enum Theme {
    static let bg = Color(white: 0.06)
    static let surface = Color(white: 0.10)
    static let surfaceHi = Color(white: 0.14)
    static let label = Color(white: 0.50)
    static let text = Color(white: 0.88)
    static let accent = Color(white: 1.0)
    static let separator = Color(white: 0.18)
    static let dimmed = Color(white: 0.30)
}

struct SettingsView: View {
    
    @Binding var ballCount: Double
    @Binding var isMicEnabled: Bool
    @Binding var isBPMEnabled: Bool
    @Binding var orbitPattern: Int
    @Binding var ballSize: Double
    @Binding var materialMode: Int
    @Binding var colorHue: Double
    @Binding var envMapIndex: Int
    @Binding var envIntensity: Double
    @Binding var customEnvImages: [UIImage?]
    @Binding var customEnvImageVersions: [Int]
    @Binding var bgMode: Int
    @Binding var bgCustomHue: Double
    @Binding var bgCustomSat: Double
    @Binding var bgCustomBri: Double
    @Binding var envLocked: Int
    @Binding var autoHue: Bool
    @Binding var spacing: Double
    @Binding var orbitRange: Double
    @Binding var gridMode: Bool
    @Binding var tapOrbit: Bool
    @Binding var tapColor: Bool
    @Binding var tapBall: Bool
    @Binding var fps: Int
    @Binding var manualBPM: Double
    @Binding var recEnabled: Bool
    @Binding var camMode: Bool
    @Binding var consoleMode: Bool
    @Binding var brightnessSync: Bool
    @Binding var brightnessSyncMax: Double
    @Binding var lockCount: Bool
    @Binding var lockSize: Bool
    @Binding var lockSpacing: Bool
    @Binding var lockOrbit: Bool
    @Binding var originalPhotoImages: [UIImage?]
    var onLoadPreset: (() -> Void)? = nil
    var onSavePreset: ((Int, @escaping (UIImage?) -> Void) -> Void)? = nil
    
    // Display order for materials (maps UI index → materialMode value)
    private let materialDisplayOrder = [0, 1, 4, 3, 2]  // BLK, HG, GLS, CLR, WIRE
    private let materialNames = ["BLK", "HG", "GLS", "CLR", "WIRE"]
    private let materialIcons = ["circle.fill", "drop.fill", "cube.transparent.fill", "paintpalette.fill", "cube.transparent"]
    
    private let orbitPatternNames = ["RND", "CRC", "SPH", "TOR", "SPI", "SAT", "DNA", "FIG8", "WAV"]
    private let orbitPatternIcons = ["dice", "circle", "globe", "circle.circle", "hurricane", "atom", "lungs", "infinity", "water.waves"]
    
    private let doubleTapNames = ["ORBIT", "COLOR", "BALL"]
    private let doubleTapIcons = ["arrow.trianglehead.2.clockwise", "paintbrush.fill", "circle.grid.2x2.fill"]
    
    private let hdriNames = ["OFF", "STUDIO", "LOFT", "SUNSET", "SKY", "GARDEN", "STD 2", "STD 3", "CLOUDY", "MORNING", "SUBURB", "MOON", "EARTH"]
    private let hdriFileNames = ["", "hdri_studio", "hdri_loft", "hdri_sunset", "hdri_sky", "hdri_garden", "hdri_studio2", "hdri_studio3", "hdri_cloudy", "hdri_morning", "hdri_suburb", "2k_moon", "flat_earth03"]
    private let hdriFileExts = ["", "jpg", "jpg", "jpg", "jpg", "jpg", "hdr", "hdr", "hdr", "hdr", "hdr", "jpg", "jpg"]
    
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settingsSelectedTab") private var selectedTab = 0
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var imageForCropping: UIImage? = nil
    @State private var showPhotoPicker: Bool = false
    @State private var showBgColorPicker = false
    @State private var activePhotoSlot: Int = 0
    @State private var slotOccupied: [Bool] = (0..<12).map { PresetManager.isSlotOccupied($0) }
    @State private var slotThumbnails: [UIImage?] = (0..<12).map { PresetManager.loadThumbnail(from: $0) }
    @State private var deleteSlotIndex: Int? = nil
    
    private let tabNames = ["VISUAL", "MOTION", "AUDIO", "SLOT"]
    
    /// Cached HDRI thumbnails (loaded once from disk)
    /// JPG files load directly; HDR files are converted via CIImage → CGImage → UIImage
    private static let hdriThumbnailCache: [String: UIImage] = {
        var cache: [String: UIImage] = [:]
        let files: [(name: String, ext: String)] = [
            ("hdri_studio", "jpg"), ("hdri_loft", "jpg"), ("hdri_sunset", "jpg"),
            ("hdri_sky", "jpg"), ("hdri_garden", "jpg"),
            ("hdri_studio2", "hdr"), ("hdri_studio3", "hdr"),
            ("hdri_cloudy", "hdr"), ("hdri_morning", "hdr"), ("hdri_suburb", "hdr"),
            ("2k_moon", "jpg"), ("flat_earth03", "jpg")
        ]
        let ciContext = CIContext()
        for file in files {
            guard let url = Bundle.main.url(forResource: file.name, withExtension: file.ext) else { continue }
            if file.ext == "jpg" {
                if let image = UIImage(contentsOfFile: url.path) {
                    cache[file.name] = image
                }
            } else {
                // HDR → CIImage → tone-mapped CGImage → UIImage thumbnail
                if let ciImage = CIImage(contentsOf: url) {
                    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 52.0 / ciImage.extent.width,
                                                                           y: 32.0 / ciImage.extent.height))
                    if let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) {
                        cache[file.name] = UIImage(cgImage: cgImage)
                    }
                }
            }
        }
        return cache
    }()
    
    var body: some View {
        VStack(spacing: 0) {
            // Tab bar (top padding accounts for drag indicator)
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = index
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            Text(tabNames[index])
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(selectedTab == index ? Theme.accent : Theme.dimmed)
                                .tracking(2)
                            
                            Rectangle()
                                .fill(selectedTab == index ? Theme.accent : Color.clear)
                                .frame(height: 1)
                        }
                        .frame(height: 50)
                        .contentShape(Rectangle())
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            
            Rectangle()
                .fill(Theme.separator)
                .frame(height: 0.5)
                .padding(.top, 2)
            
            // Tab content (no swipe — prevents conflict with sliders)
            Group {
                switch selectedTab {
                case 0: visualTab
                case 1: motionTab
                case 2: audioTab
                case 3: slotTab
                default: visualTab
                }
            }
        }
        .background(Theme.bg)
        .fullScreenCover(isPresented: Binding(
            get: { imageForCropping != nil },
            set: { if !$0 { imageForCropping = nil } }
        )) {
            if let image = imageForCropping {
                ImageCropView(
                    inputImage: image,
                    onCropped: { croppedImage in
                        customEnvImages[activePhotoSlot] = croppedImage
                        customEnvImageVersions[activePhotoSlot] += 1
                        envMapIndex = 13 + activePhotoSlot
                        imageForCropping = nil
                    },
                    onCancel: {
                        imageForCropping = nil
                    },
                    onNewImage: { newImage in
                        originalPhotoImages[activePhotoSlot] = newImage
                    }
                )
            }
        }
    }
    
    // MARK: - Visual Tab
    
    private let bgNames = ["WHT", "BLK", "GRN", "CLR"]
    private let bgIcons = ["sun.max.fill", "moon.fill", "rectangle.inset.filled", "paintpalette.fill"]
    
    private var visualTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // Background selector
                sectionHeader("BACKGROUND")
                
                HStack(spacing: 8) {
                    ForEach(0..<bgNames.count, id: \.self) { index in
                        let selectedBg: Color = index == 2 ? Color.green
                            : index == 3 ? Color(hue: bgCustomHue, saturation: bgCustomSat, brightness: bgCustomBri)
                            : Theme.accent
                        let selectedFg: Color = index == 2 ? .white : index == 3 ? .white : Theme.bg
                        
                        if index == 3 {
                            Button {
                                bgMode = 3
                                showBgColorPicker = true
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: bgIcons[index])
                                        .font(.system(size: 16))
                                        .frame(width: 44, height: 44)
                                        .background(
                                            bgMode == index ? selectedBg : Color(hue: bgCustomHue, saturation: bgCustomSat, brightness: bgCustomBri).opacity(0.4),
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .foregroundStyle(bgMode == index ? selectedFg : Theme.dimmed)
                                    
                                    Text(bgNames[index])
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(bgMode == index ? Theme.text : Theme.dimmed)
                                        .tracking(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        } else {
                            Button {
                                bgMode = index
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: bgIcons[index])
                                        .font(.system(size: 16))
                                        .frame(width: 44, height: 44)
                                        .background(
                                            bgMode == index ? selectedBg : Theme.surface,
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .foregroundStyle(bgMode == index ? selectedFg : Theme.dimmed)
                                    
                                    Text(bgNames[index])
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(bgMode == index ? Theme.text : Theme.dimmed)
                                        .tracking(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                .sheet(isPresented: $showBgColorPicker) {
                    BgColorPickerSheet(
                        hue: $bgCustomHue,
                        sat: $bgCustomSat,
                        bri: $bgCustomBri
                    )
                    .presentationDetents([.medium])
                    .presentationBackground(Color(white: 0.06))
                }
                
                thinDivider()
                
                // Material selector
                sectionHeader("MATERIAL")
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<materialDisplayOrder.count, id: \.self) { index in
                            let mode = materialDisplayOrder[index]
                            Button {
                                materialMode = mode
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: materialIcons[index])
                                        .font(.system(size: 16))
                                        .frame(width: 44, height: 44)
                                        .background(
                                            materialMode == mode ? Theme.accent : Theme.surface,
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .foregroundStyle(materialMode == mode ? Theme.bg : Theme.dimmed)
                                    
                                    Text(materialNames[index])
                                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                                        .foregroundStyle(materialMode == mode ? Theme.text : Theme.dimmed)
                                        .tracking(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 56)
                        }
                    }
                }
                
                if materialMode == 3 {
                    VStack(spacing: 8) {
                        HStack {
                            Spacer()
                            
                            Text("HUE")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.label)
                                .tracking(1)
                            
                            Button {
                                autoHue.toggle()
                            } label: {
                                Text("AUTO")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(autoHue ? Theme.bg : Theme.dimmed)
                                    .tracking(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        autoHue ? Theme.accent : Theme.surface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if !autoHue {
                            Slider(value: $colorHue, in: 0...1)
                                .tint(Color(hue: colorHue, saturation: 0.8, brightness: 0.9))
                        }
                    }
                }
                
                thinDivider()
                
                // HDRI environment
                sectionHeader("ENVIRONMENT")
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        // OFF
                        Button {
                            envMapIndex = 0
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.surface)
                                    .frame(width: 52, height: 32)
                                    .overlay {
                                        Image(systemName: "circle.dashed")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Theme.dimmed)
                                    }
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(envMapIndex == 0 ? Theme.accent : Color.clear, lineWidth: 1.5)
                                    )
                                Text("OFF")
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(envMapIndex == 0 ? Theme.text : Theme.dimmed)
                                    .tracking(0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        
                        // PHOTO slots (×3)
                        ForEach(0..<3, id: \.self) { slot in
                            let slotIndex = 13 + slot
                            let slotNames = ["PHT 1", "PHT 2", "PHT 3"]
                            Button {
                                activePhotoSlot = slot
                                if let original = originalPhotoImages[slot] {
                                    imageForCropping = original
                                } else {
                                    showPhotoPicker = true
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    if let customImage = customEnvImages[slot] {
                                        Image(uiImage: customImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 52, height: 32)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(envMapIndex == slotIndex ? Theme.accent : Color.clear, lineWidth: 1.5)
                                            )
                                    } else {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.surface)
                                            .frame(width: 52, height: 32)
                                            .overlay {
                                                Image(systemName: "photo.on.rectangle")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(Theme.dimmed)
                                            }
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(envMapIndex == slotIndex ? Theme.accent : Color.clear, lineWidth: 1.5)
                                            )
                                    }
                                    
                                    Text(slotNames[slot])
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(envMapIndex == slotIndex ? Theme.text : Theme.dimmed)
                                        .tracking(0.5)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
                        .onChange(of: selectedPhotoItem) { newItem in
                            guard let newItem = newItem else { return }
                            Task {
                                if let data = try? await newItem.loadTransferable(type: Data.self),
                                   let image = UIImage(data: data) {
                                    originalPhotoImages[activePhotoSlot] = image
                                    imageForCropping = image
                                }
                            }
                        }
                        
                        // HDRI presets (index 1+)
                        ForEach(1..<hdriNames.count, id: \.self) { index in
                            Button {
                                envMapIndex = index
                            } label: {
                                VStack(spacing: 6) {
                                    if let thumb = Self.hdriThumbnailCache[hdriFileNames[index]] {
                                        Image(uiImage: thumb)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 52, height: 32)
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(envMapIndex == index ? Theme.accent : Color.clear, lineWidth: 1.5)
                                            )
                                    } else {
                                        // HDR files: no thumbnail, show icon
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Theme.surfaceHi)
                                            .frame(width: 52, height: 32)
                                            .overlay {
                                                Image(systemName: "sparkles")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(Theme.dimmed)
                                            }
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(envMapIndex == index ? Theme.accent : Color.clear, lineWidth: 1.5)
                                            )
                                    }
                                    
                                    Text(hdriNames[index])
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(envMapIndex == index ? Theme.text : Theme.dimmed)
                                        .tracking(0.5)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                
                if envMapIndex > 0 {
                    parameterRow(label: "BRIGHTNESS", value: String(format: "%.1f", envIntensity)) {
                        Slider(value: $envIntensity, in: 0.1...3.0)
                            .tint(Theme.accent)
                    }
                    
                    // Environment mapping mode
                    HStack {
                        Spacer()
                        
                        Text("ENV")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.label)
                            .tracking(1)
                        
                        HStack(spacing: 2) {
                            ForEach(Array(["FREE", "FIXED", "FRONT"].enumerated()), id: \.offset) { index, name in
                                Button {
                                    envLocked = index
                                } label: {
                                    Text(name)
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(envLocked == index ? Theme.bg : Theme.dimmed)
                                        .tracking(0.5)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 6)
                                        .background(
                                            envLocked == index ? Theme.accent : Theme.surface,
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                thinDivider()
                
                // FPS selector
                sectionHeader("FPS")
                
                HStack(spacing: 8) {
                    ForEach([24, 30, 60], id: \.self) { value in
                        Button {
                            fps = value
                        } label: {
                            Text("\(value)")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .frame(width: 44, height: 32)
                                .background(
                                    fps == value ? Theme.accent : Theme.surface,
                                    in: Capsule()
                                )
                                .foregroundStyle(fps == value ? Theme.bg : Theme.dimmed)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                
                thinDivider()
                
                // CONSOLE option
                HStack {
                    sectionHeader("CONSOLE")
                    
                    Spacer()
                    
                    Button {
                        consoleMode.toggle()
                    } label: {
                        Text(consoleMode ? "ON" : "OFF")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(consoleMode ? Theme.bg : Theme.dimmed)
                            .tracking(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                consoleMode ? Theme.accent : Theme.surface,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                
                thinDivider()
                
                // REC option
                HStack {
                    sectionHeader("REC")
                    
                    Spacer()
                    
                    Button {
                        recEnabled.toggle()
                    } label: {
                        Text(recEnabled ? "ON" : "OFF")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(recEnabled ? Theme.bg : Theme.dimmed)
                            .tracking(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                recEnabled ? Theme.accent : Theme.surface,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }

            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
    
    // MARK: - Motion Tab
    
    private var motionTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("DOUBLE TAP")
                
                HStack(spacing: 8) {
                    doubleTapToggle(name: "ORBIT", icon: "arrow.trianglehead.2.clockwise", isOn: $tapOrbit)
                    doubleTapToggle(name: "COLOR", icon: "paintbrush.fill", isOn: $tapColor)
                    doubleTapToggle(name: "BALL", icon: "circle.grid.2x2.fill", isOn: $tapBall)
                    doubleTapToggle(name: "CAM", icon: "video.fill", isOn: $camMode)
                }
                
                thinDivider()
                
                sectionHeader("ORBIT")
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<orbitPatternNames.count, id: \.self) { index in
                            Button {
                                orbitPattern = index
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: orbitPatternIcons[index])
                                        .font(.system(size: 14))
                                        .frame(width: 44, height: 32)
                                        .background(
                                            orbitPattern == index ? Theme.accent : Theme.surface,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(orbitPattern == index ? Theme.bg : Theme.dimmed)
                                    
                                    Text(orbitPatternNames[index])
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(orbitPattern == index ? Theme.text : Theme.dimmed)
                                        .tracking(0.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(width: 52)
                        }
                    }
                }
                
                if orbitPattern != 0 {
                    HStack {
                        Spacer()
                        
                        Text("GRID")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.label)
                            .tracking(1)
                        
                        Button {
                            gridMode.toggle()
                        } label: {
                            Text(gridMode ? "ON" : "OFF")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(gridMode ? Theme.bg : Theme.dimmed)
                                .tracking(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    gridMode ? Theme.accent : Theme.surface,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                thinDivider()
                
                sectionHeader("BALLS", bold: true)
                VStack(spacing: 4) {
                    parameterRow(label: "COUNT", value: "\(Int(ballCount))", highlighted: tapBall && !lockCount, locked: $lockCount) {
                        Slider(value: $ballCount, in: 4...20, step: 1)
                            .tint(Theme.accent)
                    }
                    parameterRow(label: "SIZE", value: String(format: "%.1fx", ballSize), highlighted: tapBall && !lockSize, locked: $lockSize) {
                        Slider(value: $ballSize, in: 0.3...0.75)
                            .tint(Theme.accent)
                    }
                    parameterRow(label: "SPACING", value: String(format: "%.1fx", spacing), highlighted: tapBall && !lockSpacing, locked: $lockSpacing) {
                        Slider(value: $spacing, in: 0.5...2.0)
                            .tint(Theme.accent)
                    }
                    parameterRow(label: "ORBIT SIZE", value: String(format: "%.1fx", orbitRange), highlighted: tapBall && !lockOrbit, locked: $lockOrbit) {
                        Slider(value: $orbitRange, in: 0.3...2.0)
                            .tint(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
    
    // MARK: - Audio Tab
    
    private var audioTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader("MICROPHONE")
                
                // Mic toggle
                HStack {
                    Spacer()
                    
                    Text("INPUT")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .tracking(1)
                    
                    Button {
                        isMicEnabled.toggle()
                    } label: {
                        Text(isMicEnabled ? "ON" : "OFF")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isMicEnabled ? Theme.bg : Theme.dimmed)
                            .tracking(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isMicEnabled ? Theme.accent : Theme.surface,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                
                if isMicEnabled {
                    thinDivider()
                    
                    // Brightness sync: boost env brightness based on mic input level
                    HStack {
                        sectionHeader("BRIGHTNESS SYNC")
                        
                        Spacer()
                        
                        Button {
                            brightnessSync.toggle()
                        } label: {
                            Text(brightnessSync ? "ON" : "OFF")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(brightnessSync ? Theme.bg : Theme.dimmed)
                                .tracking(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    brightnessSync ? Theme.accent : Theme.surface,
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if brightnessSync {
                        parameterRow(label: "MAX BOOST", value: String(format: "%.1f", brightnessSyncMax)) {
                            Slider(value: $brightnessSyncMax, in: 1.5...5.0, step: 0.1)
                                .tint(Theme.accent)
                        }
                    }
                }
                
                thinDivider()
                
                sectionHeader("BEAT SYNC")
                
                // BPM AUTO/MANUAL toggle
                HStack {
                    Spacer()
                    
                    Text("BPM")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .tracking(1)
                    
                    Button {
                        isBPMEnabled.toggle()
                    } label: {
                        Text("AUTO")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isBPMEnabled ? Theme.bg : Theme.dimmed)
                            .tracking(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isBPMEnabled ? Theme.accent : Theme.surface,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                
                if !isBPMEnabled {
                    parameterRow(label: "MANUAL", value: "\(Int(manualBPM))") {
                        Slider(value: $manualBPM, in: 20...200, step: 1)
                            .tint(Theme.accent)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }
    
    // MARK: - Slot Tab
    
    private let slotColumns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)
    
    private var slotTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: slotColumns, spacing: 10) {
                    ForEach(0..<12, id: \.self) { index in
                        slotCell(index: index)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear {
            slotOccupied = (0..<12).map { PresetManager.isSlotOccupied($0) }
            slotThumbnails = (0..<12).map { PresetManager.loadThumbnail(from: $0) }
        }
        .alert("Delete Preset?", isPresented: Binding(
            get: { deleteSlotIndex != nil },
            set: { if !$0 { deleteSlotIndex = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let idx = deleteSlotIndex {
                    PresetManager.delete(slotIndex: idx)
                    slotOccupied[idx] = false
                    slotThumbnails[idx] = nil
                    deleteSlotIndex = nil
                }
            }
            Button("Cancel", role: .cancel) {
                deleteSlotIndex = nil
            }
        } message: {
            if let idx = deleteSlotIndex {
                Text("Slot \(idx + 1) will be deleted.")
            }
        }
    }
    
    private func slotCell(index: Int) -> some View {
        let isOccupied = slotOccupied[index]
        
        return ZStack {
            if isOccupied, let thumb = slotThumbnails[index] {
                // Saved slot: show thumbnail
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .bottomTrailing) {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .shadow(color: .black, radius: 2)
                            .padding(4)
                    }
            } else if isOccupied {
                // Saved but no thumbnail
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surfaceHi)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.accent)
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.text)
                        }
                    }
            } else {
                // Empty slot
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.dimmed, style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "plus")
                                .font(.system(size: 18))
                                .foregroundStyle(Theme.dimmed)
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Theme.dimmed)
                        }
                    }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture {
            if isOccupied {
                // Load preset and dismiss settings
                if let dict = PresetManager.load(from: index) {
                    PresetManager.apply(dict)
                    onLoadPreset?()
                    dismiss()
                }
            } else {
                // Save preset + capture screenshot
                PresetManager.save(to: index)
                slotOccupied[index] = true
                onSavePreset?(index) { _ in
                    // Reload the saved 200x200 thumbnail from storage
                    slotThumbnails[index] = PresetManager.loadThumbnail(from: index)
                }
            }
        }
        .onLongPressGesture(minimumDuration: 0.5) {
            if isOccupied {
                deleteSlotIndex = index
            }
        }
    }
    
    // MARK: - Reusable Components
    
    private func sectionHeader(_ title: String, bold: Bool = false) -> some View {
        Text(title)
            .font(.system(size: bold ? 11 : 10, weight: bold ? .bold : .semibold, design: .monospaced))
            .foregroundStyle(bold ? Theme.text : Theme.label)
            .tracking(3)
    }
    
    private func parameterRow<S: View>(label: String, value: String, highlighted: Bool = false, locked: Binding<Bool>? = nil, @ViewBuilder slider: () -> S) -> some View {
        VStack(spacing: 8) {
            HStack {
                Spacer()
                
                if let locked = locked {
                    HStack(spacing: 3) {
                        Text(label)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .tracking(1)
                        if locked.wrappedValue {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 8))
                        }
                    }
                    .foregroundStyle(highlighted ? .white : (locked.wrappedValue ? Theme.dimmed : Theme.label))
                    .padding(.horizontal, highlighted ? 6 : 0)
                    .padding(.vertical, highlighted ? 2 : 0)
                    .background(
                        highlighted ? Color.red.opacity(0.7) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        locked.wrappedValue.toggle()
                    }
                } else {
                    Text(label)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .tracking(1)
                }
                
                Text(value)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .frame(width: 40, alignment: .trailing)
            }
            
            slider()
        }
    }
    
    private func doubleTapToggle(name: String, icon: String, isOn: Binding<Bool>) -> some View {
        let onColor = Color(red: 0.85, green: 0.15, blue: 0.15)
        return Button {
            isOn.wrappedValue.toggle()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 44, height: 32)
                    .background(
                        isOn.wrappedValue ? onColor : Theme.surface,
                        in: Capsule()
                    )
                    .foregroundStyle(isOn.wrappedValue ? .white : Theme.dimmed)
                
                Text(name)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(isOn.wrappedValue ? Theme.text : Theme.dimmed)
                    .tracking(0.5)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
    
    private func thinDivider() -> some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
    }
}

// MARK: - Custom Color Picker

struct BgColorPickerSheet: View {
    @Binding var hue: Double
    @Binding var sat: Double
    @Binding var bri: Double
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 8)
            
            // Color wheel
            ColorWheelView(hue: $hue, sat: $sat)
                .frame(width: 150, height: 150)
            
            // Brightness slider
            BrightnessSlider(bri: $bri, hue: hue, sat: sat)
                .frame(height: 24)
                .padding(.horizontal, 40)
            
            // Preview + OK
            HStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hue: hue, saturation: sat, brightness: bri))
                    .frame(width: 42, height: 42)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(white: 0.25), lineWidth: 1)
                    )
                
                Spacer()
                
                Button {
                    dismiss()
                } label: {
                    Text("OK")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 40)
            
            Spacer()
        }
        .background(Color(white: 0.06))
    }
}

// MARK: - Color Wheel (Hue × Saturation circle)

private struct ColorWheelView: View {
    @Binding var hue: Double
    @Binding var sat: Double
    
    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            
            ZStack {
                // Hue: angular gradient around the circle
                AngularGradient(
                    gradient: Gradient(colors: (0...12).map {
                        Color(hue: Double($0) / 12.0, saturation: 1, brightness: 1)
                    }),
                    center: .center
                )
                .clipShape(Circle())
                
                // Saturation: white center fading to clear at edges
                RadialGradient(
                    gradient: Gradient(colors: [.white, .white.opacity(0)]),
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
                .clipShape(Circle())
                
                // Selection indicator
                Circle()
                    .stroke(Color.white, lineWidth: 2.5)
                    .background(Circle().fill(Color(hue: hue, saturation: sat, brightness: 1.0)))
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
                    .position(indicatorPosition(radius: radius, center: CGPoint(x: radius, y: radius)))
            }
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateFromPoint(value.location, radius: radius, center: CGPoint(x: radius, y: radius))
                    }
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
    
    private func indicatorPosition(radius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = hue * 2 * .pi
        let dist = sat * Double(radius)
        return CGPoint(
            x: center.x + CGFloat(cos(angle)) * CGFloat(dist),
            y: center.y + CGFloat(sin(angle)) * CGFloat(dist)
        )
    }
    
    private func updateFromPoint(_ point: CGPoint, radius: CGFloat, center: CGPoint) {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        let dist = min(sqrt(dx * dx + dy * dy), Double(radius))
        let angle = atan2(dy, dx)
        hue = (angle / (2 * .pi) + 1).truncatingRemainder(dividingBy: 1.0)
        sat = dist / Double(radius)
    }
}

// MARK: - Brightness Slider

private struct BrightnessSlider: View {
    @Binding var bri: Double
    let hue: Double
    let sat: Double
    
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            
            ZStack(alignment: .leading) {
                // Gradient track: full color → black
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hue: hue, saturation: sat, brightness: 1.0),
                                Color.black
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: height / 2)
                            .stroke(Color(white: 0.20), lineWidth: 1)
                    )
                
                // Thumb
                Circle()
                    .fill(Color(hue: hue, saturation: sat, brightness: bri))
                    .frame(width: height - 4, height: height - 4)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                    .offset(x: (1 - bri) * Double(width - height) + 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, Double(value.location.x / width)))
                        bri = 1 - fraction
                    }
            )
        }
    }
}
