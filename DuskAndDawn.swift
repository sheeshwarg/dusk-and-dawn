// DuskAndDawn.swift – Dusk & Dawn
// Kleine macOS-App: zwei Bilder (hell/dunkel) reinziehen → dynamisches HEIC
// mit apple_desktop:apr-Metadaten exportieren. Alternativ ein Bild reinziehen
// und das Gegenstück erzeugen lassen. Benötigt macOS 13+.

import SwiftUI
import AppKit
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

// MARK: - App

@main
struct DuskAndDawnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Dusk & Dawn") {
            ContentView()
                .frame(minWidth: 640, minHeight: 400)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// MARK: - UI

@MainActor
struct ContentView: View {
    @State private var lightURL: URL?
    @State private var darkURL: URL?
    @State private var quality = 0.9
    @State private var status = "Zwei Bilder reinziehen – oder eins und das Gegenstück erzeugen."
    @State private var isBusy = false
    @State private var draft: CounterpartDraft?
    @State private var exportedURL: URL?

    /// Genau ein Feld belegt → Gegenstück kann erzeugt werden.
    private var canGenerate: Bool { (lightURL == nil) != (darkURL == nil) && !isBusy }

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 20) {
                DropZone(title: "Hell", systemImage: "sun.max", url: $lightURL)
                DropZone(title: "Dunkel", systemImage: "moon", url: $darkURL)
            }

            HStack {
                Text("Qualität")
                Slider(value: $quality, in: 0.5...1.0)
                Text("\(Int(quality * 100)) %")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }

            HStack {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if isBusy { ProgressView().controlSize(.small) }
                Button("Gegenstück erzeugen …") { startCounterpart() }
                    .disabled(!canGenerate)
                Button("Tauschen") { swap(&lightURL, &darkURL) }
                    .disabled(isBusy)
                Button("HEIC exportieren …") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(lightURL == nil || darkURL == nil || isBusy)
            }
        }
        .padding(24)
        .sheet(item: $draft) { draft in
            CounterpartSheet(draft: draft) { light, dark in
                lightURL = light
                darkURL = dark
                status = "Gegenstück übernommen – jetzt als HEIC exportieren."
            }
        }
        .alert(
            "Als Hintergrundbild festlegen?",
            isPresented: Binding(get: { exportedURL != nil }, set: { if !$0 { exportedURL = nil } }),
            presenting: exportedURL
        ) { url in
            Button("Festlegen") { finishExport(url, setAsWallpaper: true) }
            Button("Nicht jetzt", role: .cancel) { finishExport(url, setAsWallpaper: false) }
        } message: { _ in
            Text("Gilt für alle Bildschirme im aktuellen Space. Die Datei muss dafür an ihrem Speicherort bleiben.")
        }
    }

    private func startCounterpart() {
        guard let source = lightURL ?? darkURL else { return }

        isBusy = true
        status = "Analysiere Bild …"

        Task {
            let result: Result<CounterpartDraft, Error> = await Task.detached(priority: .userInitiated) {
                Result(catching: { try CounterpartDraft(sourceURL: source) })
            }.value

            isBusy = false
            switch result {
            case .success(let newDraft):
                status = "Erkannt: \(newDraft.detected.adjective) Bild."
                draft = newDraft
            case .failure(let error):
                status = "Fehler: \(error.localizedDescription)"
            }
        }
    }

    private func finishExport(_ url: URL, setAsWallpaper: Bool) {
        if setAsWallpaper {
            do {
                for screen in NSScreen.screens {
                    try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
                }
                status = "Gespeichert und als Hintergrundbild festgelegt."
            } catch {
                status = "Hintergrundbild konnte nicht gesetzt werden: \(error.localizedDescription)"
            }
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func export() {
        guard let light = lightURL, let dark = darkURL else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.heic]
        panel.nameFieldStringValue = light.deletingPathExtension().lastPathComponent + "-dynamic.heic"
        guard panel.runModal() == .OK, let out = panel.url else { return }

        isBusy = true
        status = "Exportiere …"
        let q = quality

        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result(catching: {
                    try WallpaperWriter.write(light: light, dark: dark, to: out, quality: q)
                })
            }.value

            isBusy = false
            switch result {
            case .success:
                status = "Gespeichert: \(out.lastPathComponent)"
                exportedURL = out
            case .failure(let error):
                status = "Fehler: \(error.localizedDescription)"
            }
        }
    }
}

struct DropZone: View {
    let title: String
    let systemImage: String
    @Binding var url: URL?

    @State private var isTargeted = false
    @State private var preview: NSImage?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))

                if let preview {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(10)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: systemImage).font(.system(size: 34))
                        Text("Bild hierher ziehen\noder klicken")
                            .multilineTextAlignment(.center)
                            .font(.callout)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .frame(width: 250, height: 220)
            .contentShape(Rectangle())
            .onTapGesture { pick() }
            .dropDestination(for: URL.self) { urls, _ in
                guard let first = urls.first else { return false }
                url = first
                return true
            } isTargeted: { isTargeted = $0 }
            .task(id: url) {
                preview = url.flatMap { NSImage(contentsOf: $0) }
            }

            Text(title).font(.headline)
            Text(url?.lastPathComponent ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { url = panel.url }
    }
}

struct CounterpartSheet: View {
    let draft: CounterpartDraft
    let onAccept: (_ light: URL, _ dark: URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var target: Mood
    @State private var strength = 0.7
    @State private var result: NSImage?
    @State private var isRendering = false
    @State private var error: String?

    private let generator: any CounterpartGenerator = FilterGenerator()

    init(draft: CounterpartDraft, onAccept: @escaping (_ light: URL, _ dark: URL) -> Void) {
        self.draft = draft
        self.onAccept = onAccept
        _target = State(initialValue: draft.detected.opposite)
    }

    private struct RenderKey: Equatable {
        let target: Mood
        let strength: Double
    }

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("Gegenstück erzeugen").font(.title3.bold())
                Text("Erkannt: \(draft.detected.adjective) Bild")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                pane("Original", image: NSImage(cgImage: draft.preview, size: .zero))
                pane("Vorschlag", image: result)
            }

            Picker("Erzeugen", selection: $target) {
                Text("Hell").tag(Mood.light)
                Text("Dunkel").tag(Mood.dark)
            }
            .pickerStyle(.segmented)

            HStack {
                Text("Stärke")
                Slider(value: $strength, in: 0.2...1.0)
                Text("\(Int(strength * 100)) %")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }

            HStack {
                if let error {
                    Text(error).font(.callout).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                if isRendering { ProgressView().controlSize(.small) }
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Übernehmen") { accept() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(result == nil || isRendering)
            }
        }
        .padding(24)
        .frame(width: 660)
        .task(id: RenderKey(target: target, strength: strength)) {
            await renderPreview()
        }
    }

    private func pane(_ title: String, image: NSImage?) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 298, height: 220)
            Text(title).font(.headline)
        }
    }

    private func renderPreview() async {
        // Kurz warten, damit schnelles Ziehen am Regler nicht jede Zwischenstufe rendert
        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !Task.isCancelled else { return }

        let generator = generator, preview = draft.preview, target = target, strength = strength
        do {
            let image = try await Task.detached(priority: .userInitiated) {
                try await generator.generate(from: preview, to: target, strength: strength)
            }.value
            guard !Task.isCancelled else { return }
            result = NSImage(cgImage: image, size: .zero)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func accept() {
        isRendering = true
        error = nil

        let generator = generator, draft = draft, target = target, strength = strength
        Task {
            do {
                // Volle Auflösung rendern und als temporäres PNG ablegen
                let url = try await Task.detached(priority: .userInitiated) {
                    let image = try await generator.generate(from: draft.source, to: target, strength: strength)
                    let url = try ImageFile.temporaryURL(basedOn: draft.sourceURL)
                    try ImageFile.writePNG(image, to: url)
                    return url
                }.value

                switch target {
                case .dark: onAccept(draft.sourceURL, url)
                case .light: onAccept(url, draft.sourceURL)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
                isRendering = false
            }
        }
    }
}

// MARK: - HEIC-Erzeugung

enum WallpaperError: LocalizedError {
    case cannotRead(URL)
    case resizeFailed
    case metadataFailed
    case cannotCreateDestination
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .cannotRead(let url): return "Bild konnte nicht gelesen werden: \(url.lastPathComponent)"
        case .resizeFailed: return "Bild konnte nicht skaliert werden."
        case .metadataFailed: return "Metadaten konnten nicht erzeugt werden."
        case .cannotCreateDestination: return "HEIC-Datei konnte nicht angelegt werden."
        case .encodingFailed: return "HEIC-Kodierung fehlgeschlagen."
        }
    }
}

enum WallpaperWriter {
    /// Schreibt ein HEIC mit zwei Bildern (Index 0 = hell, 1 = dunkel)
    /// und den XMP-Metadaten apple_desktop:apr = base64(bplist {"l": 0, "d": 1}).
    static func write(light: URL, dark: URL, to out: URL, quality: Double) throws {
        let lightImage = try loadImage(light)
        var darkImage = try loadImage(dark)

        // Dunkles Bild auf die Größe des hellen bringen (Aspect Fill, zentriert beschnitten)
        if darkImage.width != lightImage.width || darkImage.height != lightImage.height {
            darkImage = try resize(darkImage, width: lightImage.width, height: lightImage.height)
        }

        // Appearance-Plist: l = Index des hellen Bildes, d = Index des dunklen Bildes
        let plist: [String: Int] = ["l": 0, "d": 1]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let base64 = plistData.base64EncodedString()

        let metadata = CGImageMetadataCreateMutable()
        let ns = "http://ns.apple.com/namespace/1.0/" as CFString
        let prefix = "apple_desktop" as CFString

        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, ns, prefix, nil),
              let tag = CGImageMetadataTagCreate(ns, prefix, "apr" as CFString, .string, base64 as CFString),
              CGImageMetadataSetTagWithPath(metadata, nil, "apple_desktop:apr" as CFString, tag)
        else { throw WallpaperError.metadataFailed }

        guard let destination = CGImageDestinationCreateWithURL(
            out as CFURL, UTType.heic.identifier as CFString, 2, nil
        ) else { throw WallpaperError.cannotCreateDestination }

        let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        CGImageDestinationAddImageAndMetadata(destination, lightImage, metadata, options)
        CGImageDestinationAddImage(destination, darkImage, options)

        guard CGImageDestinationFinalize(destination) else { throw WallpaperError.encodingFailed }
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw WallpaperError.cannotRead(url) }
        return image
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw WallpaperError.resizeFailed }

        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawW = Double(image.width) * scale
        let drawH = Double(image.height) * scale
        let rect = CGRect(x: (Double(width) - drawW) / 2, y: (Double(height) - drawH) / 2,
                          width: drawW, height: drawH)

        context.interpolationQuality = .high
        context.draw(image, in: rect)

        guard let result = context.makeImage() else { throw WallpaperError.resizeFailed }
        return result
    }
}

// MARK: - Gegenstück-Erzeugung

enum Mood: Hashable, Sendable {
    case light, dark

    var opposite: Mood { self == .light ? .dark : .light }
    var adjective: String { self == .light ? "helles" : "dunkles" }
}

/// Erzeugt aus einem Bild die Variante für die jeweils andere Stimmung.
protocol CounterpartGenerator: Sendable {
    func generate(from image: CGImage, to mood: Mood, strength: Double) async throws -> CGImage
}

enum CounterpartError: LocalizedError {
    case renderFailed

    var errorDescription: String? { "Gegenstück konnte nicht erzeugt werden." }
}

/// Ausgangsbild samt erkannter Stimmung und verkleinerter Fassung für die Live-Vorschau.
struct CounterpartDraft: Identifiable, @unchecked Sendable {
    let id = UUID()
    let sourceURL: URL
    let source: CGImage
    let preview: CGImage
    let detected: Mood

    init(sourceURL: URL) throws {
        self.sourceURL = sourceURL
        source = try WallpaperWriter.loadImage(sourceURL)
        preview = try ImageFile.downscaled(source, maxDimension: 1200)
        detected = ImageFile.detectMood(preview)
    }
}

/// Tag/Nacht-Look per Core Image: Belichtung, Gamma, Sättigung, Farbtemperatur, Vignette.
struct FilterGenerator: CounterpartGenerator {
    func generate(from image: CGImage, to mood: Mood, strength s: Double) async throws -> CGImage {
        let input = CIImage(cgImage: image)
        let f = Float(s)

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = input
        let gamma = CIFilter.gammaAdjust()
        let controls = CIFilter.colorControls()
        let tint = CIFilter.colorMatrix()

        switch mood {
        case .dark:
            // Linear abdunkeln statt per Gamma, damit Schatten nicht absaufen
            exposure.ev = -3.0 * f
            gamma.power = 1
            controls.saturation = 1
            controls.contrast = 1
            // Kühler: Rot runter, Blau rauf
            tint.rVector = CIVector(x: CGFloat(1 - 0.2 * f), y: 0, z: 0, w: 0)
            tint.gVector = CIVector(x: 0, y: CGFloat(1 - 0.1 * f), z: 0, w: 0)
            tint.bVector = CIVector(x: 0, y: 0, z: CGFloat(1 + 0.1 * f), w: 0)
        case .light:
            // Gamma hellt Schatten auf, ohne dass Lichter ausbrennen
            exposure.ev = 1.0 * f
            gamma.power = 1 - 0.4 * f
            controls.saturation = 1 + 0.15 * f
            controls.contrast = 1
            // Sonnenlicht: Rot/Grün bekommen Helligkeit dazu, Blau runter
            tint.rVector = CIVector(x: CGFloat(1 + 0.1 * f), y: CGFloat(0.12 * f), z: 0, w: 0)
            tint.gVector = CIVector(x: 0, y: CGFloat(1 + 0.05 * f), z: 0, w: 0)
            tint.bVector = CIVector(x: 0, y: 0, z: CGFloat(1 - 0.25 * f), w: 0)
        }
        controls.brightness = 0
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        tint.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)

        gamma.inputImage = exposure.outputImage
        controls.inputImage = gamma.outputImage
        tint.inputImage = controls.outputImage
        var output = tint.outputImage

        if mood == .dark {
            // Nachtsehen: Farben weichen einem bläulichen Monochrom
            let night = CIFilter.colorMonochrome()
            night.inputImage = output
            night.color = CIColor(red: 0.35, green: 0.45, blue: 1.0)
            night.intensity = 0.6 * f
            output = night.outputImage

            let vignette = CIFilter.vignette()
            vignette.inputImage = output
            vignette.intensity = 0.5 * f
            vignette.radius = 2
            output = vignette.outputImage
        }

        guard let output else { throw CounterpartError.renderFailed }
        return try ImageFile.render(output.cropped(to: input.extent), colorSpace: image.colorSpace)
    }
}

enum ImageFile {
    private static let context = CIContext()

    static func render(_ image: CIImage, colorSpace: CGColorSpace?) throws -> CGImage {
        let space = colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
        else { throw CounterpartError.renderFailed }
        return result
    }

    static func downscaled(_ image: CGImage, maxDimension: Int) throws -> CGImage {
        let scale = Double(maxDimension) / Double(max(image.width, image.height))
        guard scale < 1 else { return image }

        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = CIImage(cgImage: image)
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        guard let output = filter.outputImage else { throw CounterpartError.renderFailed }
        return try render(output, colorSpace: image.colorSpace)
    }

    /// Hell oder dunkel anhand der mittleren Luminanz. Die Schwelle trennt
    /// Apples eigene Hell/Dunkel-Hintergrundbilder zu rund 93 % richtig.
    static func detectMood(_ image: CGImage) -> Mood {
        averageLuminance(image) >= 0.42 ? .light : .dark
    }

    /// Mittlere Luminanz (0…1) im sRGB-Raum.
    static func averageLuminance(_ image: CGImage) -> Double {
        let input = CIImage(cgImage: image)
        let average = CIFilter.areaAverage()
        average.inputImage = input
        average.extent = input.extent

        var pixel = [UInt8](repeating: 0, count: 4)
        if let output = average.outputImage {
            context.render(output, toBitmap: &pixel, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return (0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])) / 255
    }

    /// Temporärer Pfad mit dem Namen des Ausgangsbilds, damit der Exportname passt.
    static func temporaryURL(basedOn source: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuskAndDawn", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(source.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("png")
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw WallpaperError.cannotCreateDestination }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WallpaperError.encodingFailed }
    }
}
