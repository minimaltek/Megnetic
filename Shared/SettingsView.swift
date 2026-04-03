//
//  SettingsView.swift
//  Magnetic
//
//  Bottom sheet settings panel — Techno minimal design
//

import SwiftUI
#if os(iOS)
import PhotosUI
#endif
import CoreImage
import UniformTypeIdentifiers


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
    @Binding var basicMode: Int       // 0=METABALL, 1=LINE, 2=BOX, 3=RAIN
    @Binding var polygonSides: Double // RAIN orbit: 3=triangle .. 8=octagon
    @Binding var polygonInset: Double // RAIN star: 0=polygon, 1=fully collapsed
    @Binding var ballSize: Double
    @Binding var materialMode: Int
    @Binding var colorHue: Double
    @Binding var colorBri: Double
    @Binding var envMapIndex: Int
    @Binding var envIntensity: Double
    @Binding var customEnvImages: [PlatformImage?]
    @Binding var customEnvImageVersions: [Int]
    @Binding var bgMode: Int
    @Binding var bgCustomHue: Double
    @Binding var bgCustomSat: Double
    @Binding var bgCustomBri: Double
    @Binding var envLocked: Int
    @Binding var autoHue: Bool
    @Binding var autoBgHue: Bool
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
    @Binding var gainMode: Int          // 0=AUTO, 1=MANUAL
    @Binding var manualGain: Double
    @Binding var originalPhotoImages: [PlatformImage?]
    @Binding var boxNoiseType: Int
    @Binding var rainScaleMode: Int      // 0=OFF, 1=PENTA, 2=MAJOR, 3=MINOR, 4=BLUES
    @Binding var rainBlockInst: Int     // 0=BASE, 1=PIANO, 2=VOICE, 3=WOOD
    @Binding var rainWallInst: Int      // same options
    @Binding var rainRootNote: Int      // 0=C, 1=C#, 2=D, ... 11=B
    @Binding var rainOctave: Int        // -2 to +2 octave offset

    @Binding var rainBallCount: Int    // 1-3 balls in RAIN mode
    @Binding var rainDelayEnabled: Bool // delay on/off
    @Binding var rainDelaySync: Int    // delay sync division index
    @Binding var rainDelayFeedback: Double // 0~0.95
    @Binding var rainDelayAmount: Double   // 0~1
    @Binding var rainCategory: Int       // 0=Fall, 1=PinBall
    var onLoadPreset: (() -> Void)? = nil
    var onSavePreset: ((Int, @escaping (PlatformImage?) -> Void) -> Void)? = nil
    var onCustomSoundSaved: ((Int) -> Void)? = nil   // slot 0-2 → reload REC buffer
    var onRecorderOpen: (() -> Void)? = nil            // stop audio before recording
    
    // Display order for materials (maps UI index → materialMode value)
    private let materialDisplayOrder = [0, 1, 4, 3, 2]  // BLK, HG, GLS, CLR, WIRE
    private let materialNames = ["BLK", "HG", "GLS", "CLR", "WIRE"]
    private let materialIcons = ["circle.fill", "drop.fill", "cube.transparent.fill", "paintpalette.fill", "cube.transparent"]
    
    private let basicModeNames = ["METABALL", "LINE", "BOX", "RAIN"]
    private let basicModeIcons = ["drop.fill", "line.3.horizontal", "square.grid.3x3.topleft.filled", "cloud.rain"]
    private let orbitPatternNames = ["RND", "CRC", "SPH", "TOR", "SPI", "SAT", "DNA", "FIG8", "WAV", "RAIN"]
    private let orbitPatternIcons = ["dice", "circle", "globe", "circle.circle", "hurricane", "atom", "lungs", "infinity", "water.waves", "hexagon"]
    
    private let boxNoiseNames = ["PERLIN", "VORONOI", "SIMPLEX", "FBM"]
    private let boxNoiseIcons = ["waveform", "circle.hexagongrid", "water.waves", "mountain.2"]
    
    private let rainScaleNames = ["OFF", "PENTA", "MAJOR", "MINOR", "BLUES"]
    private let rainScaleIcons = ["speaker.slash", "music.note", "music.note.list", "music.quarternote.3", "guitars"]
    
    private let rainInstNames = ["BASE", "PIANO", "VOICE", "WOOD", "REC1", "REC2", "REC3"]
    private let rainInstIcons = ["waveform", "pianokeys", "circle.hexagongrid", "lines.measurement.horizontal", "record.circle", "record.circle", "record.circle"]
    
    // 12 chromatic note names for root note picker
    private let chromaticNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    // Octave offset labels
    private let octaveLabels = ["-2", "-1", "±0", "+1", "+2"]
    private let octaveValues = [-2, -1, 0, 1, 2]
    
    private let doubleTapNames = ["ORBIT", "COLOR", "BALL"]
    private let doubleTapIcons = ["arrow.trianglehead.2.clockwise", "paintbrush.fill", "circle.grid.2x2.fill"]
    
    private let hdriNames = ["OFF", "STUDIO", "LOFT", "SUNSET", "SKY", "GARDEN", "STD 2", "STD 3", "CLOUDY", "MORNING", "SUBURB", "MOON", "EARTH"]
    private let hdriFileNames = ["", "hdri_studio", "hdri_loft", "hdri_sunset", "hdri_sky", "hdri_garden", "hdri_studio2", "hdri_studio3", "hdri_cloudy", "hdri_morning", "hdri_suburb", "2k_moon", "flat_earth03"]
    private let hdriFileExts = ["", "jpg", "jpg", "jpg", "jpg", "jpg", "hdr", "hdr", "hdr", "hdr", "hdr", "jpg", "jpg"]
    
    @Environment(\.dismiss) private var dismiss
    @AppStorage("settingsSelectedTab") private var selectedTab = 0
    #if os(iOS)
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var showPhotoPicker: Bool = false
    #elseif os(macOS)
    @State private var showFileImporter: Bool = false
    #endif
    @State private var imageForCropping: PlatformImage? = nil
    @State private var activePhotoSlot: Int = 0
    @State private var slotOccupied: [Bool] = (0..<12).map { PresetManager.isSlotOccupied($0) }
    @State private var slotThumbnails: [PlatformImage?] = (0..<12).map { PresetManager.loadThumbnail(from: $0) }
    @State private var deleteSlotIndex: Int? = nil
    @State private var showRecorder: Bool = false
    @State private var recorderSlot: Int = 0
    
    private let tabNames = ["VISUAL", "MOTION", "AUDIO", "SLOT"]
    
    /// Cached HDRI thumbnails (loaded once from disk)
    /// JPG files load directly; HDR files are converted via CIImage → CGImage → PlatformImage
    private static let hdriThumbnailCache: [String: PlatformImage] = {
        var cache: [String: PlatformImage] = [:]
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
                if let image = PlatformImage.fromFile(url.path) {
                    cache[file.name] = image
                }
            } else {
                // HDR → CIImage → tone-mapped CGImage → PlatformImage thumbnail
                if let ciImage = CIImage(contentsOf: url) {
                    let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 52.0 / ciImage.extent.width,
                                                                           y: 32.0 / ciImage.extent.height))
                    if let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) {
                        cache[file.name] = PlatformImage.fromCGImage(cgImage)
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
        #if os(iOS)
        .fullScreenCover(isPresented: Binding(
            get: { imageForCropping != nil },
            set: { if !$0 { imageForCropping = nil } }
        )) {
            cropViewContent
        }
        .fullScreenCover(isPresented: $showRecorder) {
            SoundRecorderView(
                slot: recorderSlot,
                onSaved: {
                    showRecorder = false
                    rainBlockInst = 4 + recorderSlot
                    onCustomSoundSaved?(recorderSlot)
                },
                onCancel: {
                    showRecorder = false
                }
            )
        }
        #else
        .sheet(isPresented: Binding(
            get: { imageForCropping != nil },
            set: { if !$0 { imageForCropping = nil } }
        )) {
            cropViewContent
        }
        .sheet(isPresented: $showRecorder) {
            SoundRecorderView(
                slot: recorderSlot,
                onSaved: {
                    showRecorder = false
                    rainBlockInst = 4 + recorderSlot
                    onCustomSoundSaved?(recorderSlot)
                },
                onCancel: {
                    showRecorder = false
                }
            )
        }
        #endif
    }
    
    @ViewBuilder
    private var cropViewContent: some View {
        if let image = imageForCropping {
            ImageCropView(
                inputImage: image,
                onCropped: { croppedImage in
                    customEnvImages[activePhotoSlot] = croppedImage
                    customEnvImageVersions[activePhotoSlot] += 1
                    envMapIndex = 13 + activePhotoSlot
                    ContentView.saveCustomEnvImage(
                        cropped: croppedImage,
                        original: originalPhotoImages[activePhotoSlot],
                        slot: activePhotoSlot
                    )
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
                        
                        Button {
                            bgMode = index
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: bgIcons[index])
                                    .font(.system(size: 16))
                                    .frame(width: 44, height: 44)
                                    .background(
                                        bgMode == index ? selectedBg
                                            : index == 3 ? Color(hue: bgCustomHue, saturation: bgCustomSat, brightness: bgCustomBri).opacity(0.4)
                                            : Theme.surface,
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
                
                if bgMode == 3 {
                    VStack(spacing: 8) {
                        HStack {
                            Spacer()
                            
                            Text("HUE")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.label)
                                .tracking(1)
                            
                            Button {
                                autoBgHue.toggle()
                            } label: {
                                Text("AUTO")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(autoBgHue ? Theme.bg : Theme.dimmed)
                                    .tracking(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        autoBgHue ? Color(hue: bgCustomHue, saturation: bgCustomSat, brightness: bgCustomBri) : Theme.surface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if !autoBgHue {
                            Slider(value: $bgCustomHue, in: 0...1)
                                .tint(Color(hue: bgCustomHue, saturation: 0.8, brightness: 0.9))
                        }
                        
                        parameterRow(label: "BRI", value: String(format: "%.0f%%", bgCustomBri * 100)) {
                            Slider(value: $bgCustomBri, in: 0...1)
                                .tint(Color(hue: bgCustomHue, saturation: 0.8, brightness: bgCustomBri))
                        }
                    }
                }
                
                // Hide MATERIAL and ENVIRONMENT in RAIN mode (2D game, no 3D rendering)
                if basicMode != 3 {
                thinDivider()
                
                // Material selector
                sectionHeader("MATERIAL")
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<materialDisplayOrder.count, id: \.self) { index in
                            let mode = materialDisplayOrder[index]
                            let isCLR = mode == 3
                            let clrColor = Color(hue: colorHue, saturation: 1.0, brightness: colorBri)
                            Button {
                                materialMode = mode
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: materialIcons[index])
                                        .font(.system(size: 16))
                                        .frame(width: 44, height: 44)
                                        .background(
                                            materialMode == mode
                                                ? (isCLR ? clrColor : Theme.accent)
                                                : (isCLR ? clrColor.opacity(0.4) : Theme.surface),
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
                                        autoHue ? Color(hue: colorHue, saturation: 1.0, brightness: colorBri) : Theme.surface,
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if !autoHue {
                            Slider(value: $colorHue, in: 0...1)
                                .tint(Color(hue: colorHue, saturation: 0.8, brightness: 0.9))
                        }
                        
                        parameterRow(label: "BRI", value: String(format: "%.0f%%", colorBri * 100)) {
                            Slider(value: $colorBri, in: 0...1)
                                .tint(Color(hue: colorHue, saturation: 1.0, brightness: colorBri))
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
                                    #if os(iOS)
                                    showPhotoPicker = true
                                    #elseif os(macOS)
                                    showFileImporter = true
                                    #endif
                                }
                            } label: {
                                VStack(spacing: 6) {
                                    if let customImage = customEnvImages[slot] {
                                        Image(platformImage: customImage)
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
                        #if os(iOS)
                        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhotoItem, matching: .images)
                        .onChange(of: selectedPhotoItem) { newItem in
                            guard let newItem = newItem else { return }
                            Task {
                                if let data = try? await newItem.loadTransferable(type: Data.self),
                                   let image = PlatformImage.fromData(data) {
                                    originalPhotoImages[activePhotoSlot] = image
                                    imageForCropping = image
                                }
                            }
                        }
                        #elseif os(macOS)
                        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
                            if case .success(let url) = result,
                               url.startAccessingSecurityScopedResource() {
                                defer { url.stopAccessingSecurityScopedResource() }
                                if let data = try? Data(contentsOf: url),
                                   let image = PlatformImage.fromData(data) {
                                    originalPhotoImages[activePhotoSlot] = image
                                    imageForCropping = image
                                }
                            }
                        }
                        #endif
                        
                        // HDRI presets (index 1+)
                        ForEach(1..<hdriNames.count, id: \.self) { index in
                            Button {
                                envMapIndex = index
                            } label: {
                                VStack(spacing: 6) {
                                    if let thumb = Self.hdriThumbnailCache[hdriFileNames[index]] {
                                        Image(platformImage: thumb)
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
                        
                        Text("ENV WRAP")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.label)
                            .tracking(1)
                        
                        HStack(spacing: 2) {
                            ForEach(Array(["FREE", "H-FIX", "FRONT"].enumerated()), id: \.offset) { index, name in
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
                } // end if basicMode != 3 (MATERIAL + ENVIRONMENT)
                
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
                // BASE mode selector (top-level drawing mode)
                sectionHeader("BASE")
                
                HStack(spacing: 8) {
                    ForEach([0, 1, 3], id: \.self) { index in  // BOX (2) hidden for now
                        Button {
                            basicMode = index
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: basicModeIcons[index])
                                    .font(.system(size: 14))
                                    .frame(width: 44, height: 32)
                                    .background(
                                        basicMode == index ? Theme.accent : Theme.surface,
                                        in: Capsule()
                                    )
                                    .foregroundStyle(basicMode == index ? Theme.bg : Theme.dimmed)
                                
                                Text(basicModeNames[index])
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .foregroundStyle(basicMode == index ? Theme.text : Theme.dimmed)
                                    .tracking(0.5)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                
                // Hide double-tap toggles in RAIN mode
                if basicMode != 3 {
                thinDivider()
                
                sectionHeader("DOUBLE TAP RANDOM")
                
                HStack(spacing: 8) {
                    if basicMode == 0 || basicMode == 1 {
                        doubleTapToggle(name: "ORBIT", icon: "arrow.trianglehead.2.clockwise", isOn: $tapOrbit)
                    }
                    doubleTapToggle(name: "COLOR", icon: "paintbrush.fill", isOn: $tapColor)
                    doubleTapToggle(name: basicMode == 1 ? "LINE" : "BALL", icon: basicMode == 1 ? "line.3.horizontal" : "circle.grid.2x2.fill", isOn: $tapBall)
                    doubleTapToggle(name: "CAM", icon: "video.fill", isOn: $camMode)
                }
                } // end if basicMode != 3 (double tap toggles)
                
                // ORBIT selector (METABALL and LINE modes)
                if basicMode == 0 || basicMode == 1 {
                    thinDivider()
                    
                    sectionHeader("ORBIT")
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<orbitPatternNames.count, id: \.self) { index in
                                Button {
                                    orbitPattern = index
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: orbitPatternIcons[index])
                                            .font(.system(size: 14))
                                            .frame(width: 38, height: 32)
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
                                .frame(width: 44)
                            }
                        }
                    }
                    
                    // GRID toggle (METABALL and LINE modes, non-RND orbit)
                    if (basicMode == 0 || basicMode == 1) && orbitPattern != 0 {
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
                }
                
                // RAIN sides slider (only when RAIN orbit selected)
                if orbitPattern == 9 && basicMode == 1 {
                    thinDivider()
                    
                    parameterRow(label: "SIDES", value: "\(Int(polygonSides))") {
                        Slider(value: $polygonSides, in: 3...8, step: 1)
                            .tint(Theme.accent)
                    }
                    
                    parameterRow(label: "STAR", value: String(format: "%.0f%%", polygonInset * 100)) {
                        Slider(value: $polygonInset, in: 0...1)
                            .tint(Theme.accent)
                    }
                }
                
                // BOX noise type selector (only when BOX mode)
                if basicMode == 2 {
                    thinDivider()
                    
                    sectionHeader("NOISE TYPE")
                    
                    HStack(spacing: 8) {
                        ForEach(0..<boxNoiseNames.count, id: \.self) { index in
                            Button {
                                boxNoiseType = index
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: boxNoiseIcons[index])
                                        .font(.system(size: 14))
                                        .frame(width: 44, height: 32)
                                        .background(
                                            boxNoiseType == index ? Theme.accent : Theme.surface,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(boxNoiseType == index ? Theme.bg : Theme.dimmed)
                                    
                                    Text(boxNoiseNames[index])
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(boxNoiseType == index ? Theme.text : Theme.dimmed)
                                        .tracking(0.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
                
                if basicMode == 3 {
                    thinDivider()
                    
                    // RAIN sub-category selector: PinBall / Fall
                    sectionHeader("CATEGORY")
                    
                    HStack(spacing: 8) {
                        let categoryNames = ["FALL", "PINBALL"]
                        let categoryIcons = ["arrow.down.circle.fill", "circle.fill"]
                        
                        ForEach(0..<categoryNames.count, id: \.self) { index in
                            Button {
                                rainCategory = index
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: categoryIcons[index])
                                        .font(.system(size: 14))
                                        .frame(width: 44, height: 32)
                                        .background(
                                            rainCategory == index ? Theme.accent : Theme.surface,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(rainCategory == index ? Theme.bg : Theme.dimmed)
                                    
                                    Text(categoryNames[index])
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(rainCategory == index ? Theme.text : Theme.dimmed)
                                        .tracking(0.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    
                    thinDivider()
                    
                    sectionHeader("SCALE")
                    
                    HStack(spacing: 6) {
                        // Skip index 0 (OFF) — always use a scale
                        ForEach(1..<rainScaleNames.count, id: \.self) { index in
                            Button {
                                rainScaleMode = index
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: rainScaleIcons[index])
                                        .font(.system(size: 14))
                                        .frame(width: 44, height: 32)
                                        .background(
                                            rainScaleMode == index ? Theme.accent : Theme.surface,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(rainScaleMode == index ? Theme.bg : Theme.dimmed)
                                    
                                    Text(rainScaleNames[index])
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(rainScaleMode == index ? Theme.text : Theme.dimmed)
                                        .tracking(0.5)
                                }
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    
                    thinDivider()
                    
                    // BLOCK HIT instrument selector + REC1/2/3
                    sectionHeader("BLOCK HIT")
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            // Built-in instruments (0-3)
                            ForEach(0..<4, id: \.self) { index in
                                Button {
                                    rainBlockInst = index
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: rainInstIcons[index])
                                            .font(.system(size: 14))
                                            .frame(width: 44, height: 32)
                                            .background(
                                                rainBlockInst == index ? Theme.accent : Theme.surface,
                                                in: Capsule()
                                            )
                                            .foregroundStyle(rainBlockInst == index ? Theme.bg : Theme.dimmed)
                                        
                                        Text(rainInstNames[index])
                                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                                            .foregroundStyle(rainBlockInst == index ? Theme.text : Theme.dimmed)
                                            .tracking(0.5)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            
                            // REC slots (4-6 → slot 0-2)
                            ForEach(0..<3, id: \.self) { slot in
                                let instIndex = 4 + slot
                                let hasRec = CustomSoundManager.hasRecording(slot: slot)
                                let isSelected = rainBlockInst == instIndex
                                let recRed = Color(red: 0.9, green: 0.15, blue: 0.15)
                                VStack(spacing: 6) {
                                    Image(systemName: hasRec ? "waveform.circle.fill" : "record.circle")
                                        .font(.system(size: 14))
                                        .frame(width: 44, height: 32)
                                        .background(
                                            isSelected ? (hasRec ? recRed : Theme.accent) : (hasRec ? recRed.opacity(0.25) : Theme.surface),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(isSelected ? (hasRec ? .white : Theme.bg) : (hasRec ? recRed : Theme.dimmed))
                                    
                                    Text(rainInstNames[instIndex])
                                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                                        .foregroundStyle(isSelected ? Theme.text : (hasRec ? recRed : Theme.dimmed))
                                        .tracking(0.5)
                                }
                                .onTapGesture {
                                    if hasRec {
                                        rainBlockInst = instIndex
                                    } else {
                                        recorderSlot = slot
                                        onRecorderOpen?()
                                        showRecorder = true
                                    }
                                }
                                .onLongPressGesture {
                                    recorderSlot = slot
                                    onRecorderOpen?()
                                    showRecorder = true
                                }
                            }
                        }
                    }
                    
                    thinDivider()
                    
                    // WALL HIT instrument selector (built-in only)
                    sectionHeader("WALL HIT")
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(0..<4, id: \.self) { index in
                                Button {
                                    rainWallInst = index
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: rainInstIcons[index])
                                            .font(.system(size: 14))
                                            .frame(width: 44, height: 32)
                                            .background(
                                                rainWallInst == index ? Theme.accent : Theme.surface,
                                                in: Capsule()
                                            )
                                            .foregroundStyle(rainWallInst == index ? Theme.bg : Theme.dimmed)
                                        
                                        Text(rainInstNames[index])
                                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                                            .foregroundStyle(rainWallInst == index ? Theme.text : Theme.dimmed)
                                            .tracking(0.5)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    thinDivider()
                    
                    // ROOT note (12 chromatic) + OCTAVE offset — for Block Hit scale
                    sectionHeader("ROOT")
                    
                    HStack(spacing: 4) {
                        ForEach(0..<12, id: \.self) { index in
                            Button {
                                rainRootNote = index
                            } label: {
                                Text(chromaticNames[index])
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 30)
                                    .background(
                                        rainRootNote == index ? Theme.accent : Theme.surface,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .foregroundStyle(rainRootNote == index ? Theme.bg : Theme.dimmed)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    HStack(spacing: 4) {
                        Text("OCT")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.label)
                            .tracking(1)
                        
                        ForEach(0..<octaveValues.count, id: \.self) { index in
                            Button {
                                rainOctave = octaveValues[index]
                            } label: {
                                Text(octaveLabels[index])
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 28)
                                    .background(
                                        rainOctave == octaveValues[index] ? Theme.accent : Theme.surface,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                    .foregroundStyle(rainOctave == octaveValues[index] ? Theme.bg : Theme.dimmed)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    thinDivider()
                    
                    // DELAY effect on block sounds
                    HStack {
                        sectionHeader("DELAY")
                        Spacer()
                        Button {
                            rainDelayEnabled.toggle()
                        } label: {
                            Text(rainDelayEnabled ? "ON" : "OFF")
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    rainDelayEnabled ? Theme.accent : Theme.surface,
                                    in: Capsule()
                                )
                                .foregroundStyle(rainDelayEnabled ? Theme.bg : Theme.dimmed)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if rainDelayEnabled {
                        HStack(spacing: 4) {
                            ForEach(0..<MetaballRenderer.delaySyncNames.count, id: \.self) { index in
                                Button {
                                    rainDelaySync = index
                                } label: {
                                    Text(MetaballRenderer.delaySyncNames[index])
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(
                                            rainDelaySync == index ? Theme.accent : Theme.surface,
                                            in: Capsule()
                                        )
                                        .foregroundStyle(rainDelaySync == index ? Theme.bg : Theme.dimmed)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        
                        parameterRow(label: "FEEDBACK", value: String(format: "%.0f%%", rainDelayFeedback * 100)) {
                            Slider(value: $rainDelayFeedback, in: 0...0.95)
                                .tint(Theme.accent)
                        }
                        
                        parameterRow(label: "AMOUNT", value: String(format: "%.0f%%", rainDelayAmount * 100)) {
                            Slider(value: $rainDelayAmount, in: 0...1)
                                .tint(Theme.accent)
                        }
                    }
                    
                    thinDivider()
                    
                    // RAIN ball count (1-3)
                    parameterRow(label: "BALLS", value: "\(rainBallCount)") {
                        Slider(value: Binding(
                            get: { Double(rainBallCount) },
                            set: { rainBallCount = Int($0) }
                        ), in: 1...4, step: 1)
                            .tint(Theme.accent)
                    }
                }
                
                // Hide ball/voxel parameters in RAIN mode (not applicable to 2D game)
                if basicMode != 3 {
                thinDivider()
                
                // Section labels adapt to basicMode — LINE mode has no adjustable params
                if basicMode != 1 {
                    sectionHeader(basicMode == 2 ? "VOXEL" : "BALLS", bold: true)
                    VStack(spacing: 4) {
                        parameterRow(label: basicMode == 2 ? "DENSITY" : "COUNT", value: "\(Int(ballCount))", highlighted: tapBall && !lockCount, locked: $lockCount) {
                            Slider(value: $ballCount, in: 4...20, step: 1)
                                .tint(Theme.accent)
                        }
                        parameterRow(label: basicMode == 2 ? "CUBE SIZE" : "SIZE", value: String(format: "%.1fx", ballSize), highlighted: tapBall && !lockSize, locked: $lockSize) {
                            Slider(value: $ballSize, in: 0.3...0.75)
                                .tint(Theme.accent)
                        }
                        parameterRow(label: basicMode == 2 ? "SPREAD" : "SPACING", value: String(format: "%.1fx", spacing), highlighted: tapBall && !lockSpacing, locked: $lockSpacing) {
                            Slider(value: $spacing, in: 0.5...2.0)
                                .tint(Theme.accent)
                        }
                        parameterRow(label: basicMode == 2 ? "RADIUS" : "ORBIT SIZE", value: String(format: "%.1fx", orbitRange), highlighted: tapBall && !lockOrbit, locked: $lockOrbit) {
                            Slider(value: $orbitRange, in: 0.3...2.0)
                                .tint(Theme.accent)
                        }
                    }
                }
                } // end if basicMode != 3 (ball parameters)
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
                
                if basicMode == 3 {
                    Text("Not available in RAIN mode")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.dimmed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                
                // Mic toggle
                Group {
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
                        
                        // Gain mode: AUTO / MANUAL
                        HStack {
                            Spacer()
                            
                            Text("GAIN")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.label)
                                .tracking(1)
                            
                            HStack(spacing: 2) {
                                ForEach(Array(["AUTO", "MANUAL"].enumerated()), id: \.offset) { index, name in
                                    Button {
                                        gainMode = index
                                    } label: {
                                        Text(name)
                                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                                            .foregroundStyle(gainMode == index ? Theme.bg : Theme.dimmed)
                                            .tracking(0.5)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 6)
                                            .background(
                                                gainMode == index ? Theme.accent : Theme.surface,
                                                in: Capsule()
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        if gainMode == 1 {
                            parameterRow(label: "GAIN", value: String(format: "%.1f", manualGain)) {
                                Slider(value: $manualGain, in: 0.5...5.0, step: 0.1)
                                    .tint(Theme.accent)
                            }
                        }
                        
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
                }
                .disabled(basicMode == 3)
                .opacity(basicMode == 3 ? 0.3 : 1.0)
                
                thinDivider()
                
                sectionHeader("BEAT SYNC")
                
                // BPM AUTO/MANUAL toggle
                HStack {
                    Spacer()
                    
                    Text("BPM")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.label)
                        .tracking(1)
                    
                    let micAvailable = isMicEnabled && basicMode != 3
                    Button {
                        isBPMEnabled.toggle()
                    } label: {
                        Text("AUTO")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(isBPMEnabled && micAvailable ? Theme.bg : Theme.dimmed)
                            .tracking(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isBPMEnabled && micAvailable ? Theme.accent : Theme.surface,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!micAvailable)
                }
                
                if !isBPMEnabled || !isMicEnabled || basicMode == 3 {
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
                        Image(platformImage: thumb)
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
    
    // MARK: - Helpers
    
    
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


