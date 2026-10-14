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
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Nach Updates suchen …") {
                    Task { await Updater.checkForUpdates() }
                }
            }
        }
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
            .contextMenu {
                if url != nil { Button("Entfernen") { url = nil } }
            }
            .overlay(alignment: .topTrailing) {
                if url != nil {
                    Button { url = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .help("Bild entfernen")
                    .padding(6)
                }
            }
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
    @State private var history: [CounterpartHistory.Entry] = []
    @State private var thumbnails: [CounterpartHistory.Entry: NSImage] = [:]

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

            if !history.isEmpty { historyStrip }

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
        .task { await loadHistory() }
    }

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Letzte Ergebnisse").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(history, id: \.self) { entry in
                        let isCurrent = entry.matches(target: target, strength: strength)
                        Button {
                            target = entry.target
                            strength = entry.strength
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    Color.secondary.opacity(0.08)
                                    if let image = thumbnails[entry] {
                                        Image(nsImage: image).resizable().scaledToFill()
                                    }
                                }
                                .frame(width: 96, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.accentColor, lineWidth: isCurrent ? 2 : 0)
                                )
                                Text("\(entry.target.label) · \(Int(entry.strength * 100)) %")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(isCurrent ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(entry.date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadHistory() async {
        history = CounterpartHistory.entries(for: draft.sourceURL)

        let generator = generator, thumbnail = draft.thumbnail
        for entry in history {
            let image = try? await Task.detached(priority: .utility) {
                try await generator.generate(from: thumbnail, to: entry.target, strength: entry.strength)
            }.value
            if let image { thumbnails[entry] = NSImage(cgImage: image, size: .zero) }
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

                CounterpartHistory.record(source: draft.sourceURL, target: target, strength: strength)
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

// MARK: - Updates

/// Sucht auf GitHub nach einem neueren Release und installiert es auf Wunsch:
/// DMG laden, App daraus kopieren, nach dem Beenden austauschen und neu starten.
@MainActor
enum Updater {
    private static let repo = "sheeshwarg/dusk-and-dawn"
    private static var isBusy = false

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let body: String?
        let assets: [Asset]

        var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    }

    enum UpdateError: LocalizedError {
        case noDMG, mountFailed, appNotFound, wrongApp

        var errorDescription: String? {
            switch self {
            case .noDMG: return "Das Release enthält keine DMG-Datei."
            case .mountFailed: return "Die DMG konnte nicht geöffnet werden."
            case .appNotFound: return "In der DMG wurde keine App gefunden."
            case .wrongApp: return "Die App in der DMG passt nicht zu Dusk & Dawn."
            }
        }
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static func checkForUpdates() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let release: Release
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            release = try JSONDecoder().decode(Release.self, from: data)
        } catch {
            showAlert("Update-Prüfung fehlgeschlagen", error.localizedDescription)
            return
        }

        guard release.version.compare(currentVersion, options: .numeric) == .orderedDescending else {
            showAlert("Dusk & Dawn ist aktuell", "Version \(currentVersion) ist die neueste Version.")
            return
        }

        let alert = NSAlert()
        alert.messageText = "Dusk & Dawn \(release.version) ist verfügbar"
        var notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if notes.count > 600 { notes = String(notes.prefix(600)) + " …" }
        alert.informativeText = "Installiert ist Version \(currentVersion).\n\n\(notes)"
        alert.addButton(withTitle: "Installieren")
        alert.addButton(withTitle: "Später")
        alert.addButton(withTitle: "Release ansehen")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await install(release)
        case .alertThirdButtonReturn:
            NSWorkspace.shared.open(release.html_url)
        default:
            break
        }
    }

    private static func install(_ release: Release) async {
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            showAlert("Installation fehlgeschlagen", UpdateError.noDMG.localizedDescription)
            return
        }

        let target = Bundle.main.bundleURL
        do {
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("DuskAndDawn-Update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

            let (download, _) = try await URLSession.shared.download(from: asset.browser_download_url)
            let dmg = work.appendingPathComponent(asset.name)
            try FileManager.default.moveItem(at: download, to: dmg)

            // Ohne Schreibrecht auf den eigenen Ordner: DMG öffnen und manuell installieren lassen
            guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
                NSWorkspace.shared.open(dmg)
                showAlert("Bitte manuell installieren",
                          "Dusk & Dawn darf sich an seinem Speicherort nicht selbst ersetzen. Zieh die App aus dem geöffneten Fenster in den Ordner „Programme“.")
                return
            }

            let staged = try await Task.detached { try stageApp(from: dmg, in: work) }.value
            try relaunch(replacing: target, with: staged, backup: work.appendingPathComponent("Backup.app"))
        } catch {
            showAlert("Installation fehlgeschlagen", error.localizedDescription)
        }
    }

    /// DMG einhängen, App herauskopieren, DMG wieder auswerfen.
    nonisolated private static func stageApp(from dmg: URL, in work: URL) throws -> URL {
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path, dmg.path])
        else { throw UpdateError.mountFailed }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }

        let contents = try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.appNotFound }
        guard Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError.wrongApp }

        let staged = work.appendingPathComponent(app.lastPathComponent)
        guard run("/usr/bin/ditto", [app.path, staged.path]) else { throw UpdateError.appNotFound }
        return staged
    }

    /// Hilfsprozess wartet, bis die App beendet ist, tauscht sie aus (mit Rückfall
    /// auf die alte Version bei Fehlern) und startet sie neu.
    private static func relaunch(replacing target: URL, with staged: URL, backup: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$2" "$4" && /usr/bin/ditto "$3" "$2"; then
            rm -rf "$4"
        else
            rm -rf "$2"; mv "$4" "$2"
        fi
        open "$2"
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh",
                            String(ProcessInfo.processInfo.processIdentifier),
                            target.path, staged.path, backup.path]
        try helper.run()
        NSApp.terminate(nil)
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Gegenstück-Erzeugung

enum Mood: String, Codable, Hashable, Sendable {
    case light, dark

    var opposite: Mood { self == .light ? .dark : .light }
    var adjective: String { self == .light ? "helles" : "dunkles" }
    var label: String { self == .light ? "Hell" : "Dunkel" }
}

/// Merkt sich pro Ausgangsbild die zuletzt übernommenen Einstellungen. Der Filter
/// ist deterministisch, daher reichen Richtung und Stärke, um ein Ergebnis exakt
/// wiederherzustellen – Bilder müssen nicht gespeichert werden.
enum CounterpartHistory {
    struct Entry: Codable, Hashable {
        let target: Mood
        let strength: Double
        let date: Date

        func matches(target: Mood, strength: Double) -> Bool {
            self.target == target && abs(self.strength - strength) < 0.005
        }
    }

    private static let key = "counterpartHistory"
    private static let maxEntries = 10
    private static let maxSources = 50

    static func entries(for source: URL) -> [Entry] {
        load()[id(source)] ?? []
    }

    static func record(source: URL, target: Mood, strength: Double) {
        var all = load()
        var list = all[id(source)] ?? []
        list.removeAll { $0.matches(target: target, strength: strength) }
        list.insert(Entry(target: target, strength: strength, date: Date()), at: 0)
        all[id(source)] = Array(list.prefix(maxEntries))

        // Älteste Ausgangsbilder verwerfen, damit die Einstellungen nicht unbegrenzt wachsen
        if all.count > maxSources {
            let byAge = all.sorted { ($0.value.first?.date ?? .distantPast) > ($1.value.first?.date ?? .distantPast) }
            all = Dictionary(uniqueKeysWithValues: byAge.prefix(maxSources).map { ($0.key, $0.value) })
        }

        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func id(_ source: URL) -> String { source.standardizedFileURL.path }

    private static func load() -> [String: [Entry]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: [Entry]].self, from: data)
        else { return [:] }
        return all
    }
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
    let thumbnail: CGImage
    let detected: Mood

    init(sourceURL: URL) throws {
        self.sourceURL = sourceURL
        source = try WallpaperWriter.loadImage(sourceURL)
        preview = try ImageFile.downscaled(source, maxDimension: 1200)
        thumbnail = try ImageFile.downscaled(preview, maxDimension: 200)
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
