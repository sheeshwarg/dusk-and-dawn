// DuskAndDawn.swift – Dusk & Dawn
// Kleine macOS-App: zwei Bilder (hell/dunkel) reinziehen → dynamisches HEIC
// mit apple_desktop:apr-Metadaten exportieren. Benötigt macOS 13+.

import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - App

@main
struct DuskAndDawnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Dusk & Dawn") {
            ContentView()
                .frame(minWidth: 580, minHeight: 400)
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
    @State private var status = "Zwei Bilder reinziehen – idealerweise gleiche Auflösung."
    @State private var isBusy = false

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
                Button("Tauschen") { swap(&lightURL, &darkURL) }
                    .disabled(isBusy)
                Button("HEIC exportieren …") { export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(lightURL == nil || darkURL == nil || isBusy)
            }
        }
        .padding(24)
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
                NSWorkspace.shared.activateFileViewerSelecting([out])
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

    private static func loadImage(_ url: URL) throws -> CGImage {
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
