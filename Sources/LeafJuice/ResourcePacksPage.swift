import AppKit
import LeafJuiceCore
import SwiftUI
import UniformTypeIdentifiers

/// Look through resource packs, combine them, and put the result on a server.
struct ResourcePacksPage: View {
    let server: ServerController
    @State private var packs: [ResourcePack] = []
    @State private var recipe = ResourcePacks.loadRecipe()
    @State private var conflicts: [PackConflict] = []
    @State private var browsing: ResourcePack?
    @State private var result: CombineResult?
    @State private var working: String?
    @State private var error: String?
    @State private var url = ""
    @State private var required = false
    @State private var confirmRemove: ResourcePack?

    private var live: ResourcePacks.ServerPack {
        ResourcePacks.current((try? String(contentsOf: server.paths.properties, encoding: .utf8)) ?? "")
    }

    var body: some View {
        Page(title: "Resource Packs", subtitle: "Look through packs, combine them into one, and use it on this server.") {
            if let error { Callout(tone: .danger, title: error) }
            serverCard
            libraryCard
            if orderedEntries.filter(\.enabled).count > 0 { combineCard }
            if let browsing { PackBrowser(pack: browsing) { self.browsing = nil } }
        }
        .task { await reload() }
        .confirmationDialog("Remove this pack from the library?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) { if let pack = confirmRemove { remove(pack) } }
        } message: {
            Text(confirmRemove?.fileName ?? "")
        }
    }

    // MARK: This server

    private var serverCard: some View {
        Card(title: "On this server", systemImage: "server.rack") {
            if live.isSet {
                Fact(label: "Pack", value: live.url)
                Fact(label: "SHA-1", value: live.sha1.isEmpty ? "None set" : live.sha1)
                Fact(label: "Players", value: live.required ? "Must accept it to join" : "Can decline it")
            } else {
                Text("This server doesn't send a resource pack.").foregroundStyle(Juice.ink)
            }
        }
    }

    // MARK: Library

    private var orderedEntries: [PackRecipe.Entry] { recipe.entries.filter { e in packs.contains { $0.fileName == e.fileName } } }

    private var libraryCard: some View {
        Card(title: "Library", systemImage: "photo.stack") {
            Hint("Top of the list wins, as in Minecraft's own list. The original files are never changed.")
            ForEach(Array(orderedEntries.enumerated()), id: \.element.fileName) { index, entry in
                if let pack = packs.first(where: { $0.fileName == entry.fileName }) { row(pack, entry, index) }
            }
            HStack {
                Button("Add Packs…") { addPacks() }.buttonStyle(.juicePrimary).disabled(working != nil)
                Button("Show in Finder") {
                    try? FileOps.ensureDir(ResourcePacks.library)
                    NSWorkspace.shared.open(ResourcePacks.library)
                }
                .buttonStyle(.juice)
                if let working {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(working).foregroundStyle(Juice.ink)
                }
            }
        }
    }

    private func row(_ pack: ResourcePack, _ entry: PackRecipe.Entry, _ index: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("Include \(pack.fileName)", isOn: Binding(get: { entry.enabled }, set: { value in update(entry) { $0.enabled = value } }))
                .labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.fileName).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                Hint([pack.format.map { "Format \($0)" }, Format.bytes(pack.size), pack.description.split(whereSeparator: \.isNewline).first.map(String.init)].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")).lineLimit(1)
            }
            Spacer()
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.juice).disabled(index == 0).accessibilityLabel("Higher priority")
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.juice).disabled(index == orderedEntries.count - 1).accessibilityLabel("Lower priority")
            Button("Look Through") { browsing = pack }.buttonStyle(.juice)
            Button("Remove…") { confirmRemove = pack }.buttonStyle(.juice)
        }
    }

    // MARK: Combine

    private let categories = ["Blocks", "Items", "Entities", "Interface", "Paintings", "Sky and weather", "Particles", "Other textures", "Models", "Sounds", "Languages", "Fonts", "Shaders", "Other"]

    private var combineCard: some View {
        Card(title: "Combine", systemImage: "square.stack.3d.down.right") {
            HStack {
                TextField("Name", text: Binding(get: { recipe.name }, set: { recipe.name = $0; save() }), prompt: Text("combined")).frame(maxWidth: 240)
                Button("Combine") { combine() }.buttonStyle(.juicePrimary).disabled(working != nil)
            }
            DisclosureGroup("Leave out parts of a pack") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(orderedEntries.filter(\.enabled), id: \.fileName) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.fileName).font(.callout.weight(.semibold)).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
                                ForEach(categories, id: \.self) { category in
                                    Toggle(category, isOn: Binding(get: { !entry.excluded.contains(category) }, set: { keep in
                                        update(entry) { if keep { $0.excluded.remove(category) } else { $0.excluded.insert(category) } }
                                    }))
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Juice.ink)
            if !conflicts.isEmpty {
                DisclosureGroup("\(conflicts.count) file\(conflicts.count == 1 ? "" : "s") in more than one pack") {
                    VStack(alignment: .leading, spacing: 6) {
                        Hint("The top pack's copy is used unless you pick another. Languages, sounds, fonts, atlases and item model overrides are merged, so they aren't listed.")
                        ForEach(conflicts.prefix(200)) { conflict in
                            HStack {
                                Text(conflict.path).font(.callout).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Picker("Winner for \(conflict.path)", selection: Binding(get: { conflict.winner }, set: { recipe.winners[conflict.path] = $0; save() })) {
                                    ForEach(conflict.providers, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden().frame(maxWidth: 220)
                            }
                        }
                        if conflicts.count > 200 { Hint("And \(conflicts.count - 200) more.") }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(Juice.ink)
            }
            if let result { resultSection(result) }
        }
    }

    @ViewBuilder private func resultSection(_ result: CombineResult) -> some View {
        Callout(tone: result.warnings.isEmpty ? .good : .warning, title: "Made \(result.file.lastPathComponent)", detail: ([Format.bytes(result.size) + ", \(result.fileCount) files, \(result.merged.count) merged."] + result.warnings).joined(separator: "\n")) {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([result.file]) }.buttonStyle(.juice)
        }
        Fact(label: "SHA-1", value: result.sha1)
        Hint("Players' games download a pack from the web, so upload it somewhere first. mc-packs.net is free and made for this, and gives you an address with this SHA-1 in it.")
        HStack {
            Link("Open mc-packs.net", destination: URL(string: "https://mc-packs.net")!).buttonStyle(.juice)
            Button("Copy SHA-1") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(result.sha1, forType: .string)
            }
            .buttonStyle(.juice)
        }
        HStack {
            TextField("Address", text: $url, prompt: Text("https://download.mc-packs.net/pack/\(result.sha1).zip"))
                .accessibilityLabel("Web address of the uploaded pack")
            Toggle("Players must accept it", isOn: $required).toggleStyle(.checkbox).fixedSize()
            Button(server.state.canStart ? "Use on This Server" : "Use at Next Restart") { apply(result) }.buttonStyle(.juicePrimary).disabled(url.isEmpty)
        }
    }

    // MARK: Actions

    private func reload() async {
        // The first read of a big pack takes a moment, and an empty list would look like nothing's there.
        if packs.isEmpty { working = "Reading your packs…" }
        packs = await ResourcePacks.list()
        working = nil
        #if DEBUG
        if ProcessInfo.processInfo.environment["LEAFJUICE_SNAPSHOT"] != nil { browsing = packs.first }
        #endif
        // Newly added packs join at the bottom; removed ones drop out.
        for pack in packs where !recipe.entries.contains(where: { $0.fileName == pack.fileName }) {
            recipe.entries.append(PackRecipe.Entry(fileName: pack.fileName))
        }
        recipe.entries.removeAll { e in !packs.contains { $0.fileName == e.fileName } }
        required = live.required
        save()
        await refreshConflicts()
    }

    private func refreshConflicts() async {
        conflicts = (try? await ResourcePacks.conflicts(recipe)) ?? []
    }

    private func save() {
        ResourcePacks.saveRecipe(recipe)
        Task { await refreshConflicts() }
    }

    private func update(_ entry: PackRecipe.Entry, _ change: (inout PackRecipe.Entry) -> Void) {
        guard let index = recipe.entries.firstIndex(where: { $0.fileName == entry.fileName }) else { return }
        change(&recipe.entries[index])
        result = nil
        save()
    }

    private func move(_ index: Int, by offset: Int) {
        let shown = orderedEntries
        guard shown.indices.contains(index + offset),
              let a = recipe.entries.firstIndex(where: { $0.fileName == shown[index].fileName }),
              let b = recipe.entries.firstIndex(where: { $0.fileName == shown[index + offset].fileName }) else { return }
        recipe.entries.swapAt(a, b)
        result = nil
        save()
    }

    private func addPacks() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        working = "Reading…"
        error = nil
        Task {
            for url in urls {
                do { _ = try await ResourcePacks.add(url) } catch { self.error = error.localizedDescription }
            }
            working = nil
            await reload()
        }
    }

    private func remove(_ pack: ResourcePack) {
        do {
            try ResourcePacks.remove(pack)
            if browsing == pack { browsing = nil }
            Task { await reload() }
        } catch { self.error = error.localizedDescription }
    }

    private func combine() {
        working = "Combining…"
        error = nil
        Task {
            do { result = try await ResourcePacks.combine(recipe) } catch { self.error = error.localizedDescription }
            working = nil
        }
    }

    private func apply(_ result: CombineResult) {
        do {
            guard let file = server.configs.first(where: { $0.path == "server.properties" }) else { throw LeafError("This server has no server.properties yet. Start it once first.") }
            let text = try ResourcePacks.applying(url: url, sha1: result.sha1, required: required, to: server.configText(file))
            let outcome = try server.saveConfig(file, text: text)
            server.notice = outcome == .staged ? "The resource pack applies at the next restart." : "The resource pack is set, and players get it the next time they join."
        } catch { self.error = error.localizedDescription }
    }
}

/// A pack's images, so you can see what it changes before using it.
struct PackBrowser: View {
    let pack: ResourcePack
    let onClose: () -> Void
    @State private var images: [(path: String, url: URL)] = []
    @State private var search = ""
    @State private var category = "All"
    @State private var error: String?

    private var categories: [String] { ["All"] + Array(Set(images.map { ResourcePacks.category(of: $0.path) })).sorted() }
    private var shown: [(path: String, url: URL)] {
        images.filter { (category == "All" || ResourcePacks.category(of: $0.path) == category) && (search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        Card(title: pack.fileName, systemImage: "eye") {
            HStack {
                TextField("Search", text: $search, prompt: Text("diamond")).frame(maxWidth: 220).accessibilityLabel("Search images")
                Picker("Category", selection: $category) { ForEach(categories, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: 240)
                Hint("\(shown.count) of \(images.count) images")
                Spacer()
                Button("Close") { onClose() }.buttonStyle(.juice)
            }
            if let error { Callout(tone: .danger, title: error) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(shown.prefix(400), id: \.path) { item in
                    VStack(spacing: 3) {
                        AsyncTexture(url: item.url)
                            .frame(width: 72, height: 72)
                            .background(Juice.raised, in: RoundedRectangle(cornerRadius: 6))
                        Text((item.path as NSString).lastPathComponent).font(.caption2).foregroundStyle(Juice.muted).lineLimit(1).truncationMode(.middle)
                    }
                    .help(item.path)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.path)
                }
            }
            if shown.count > 400 { Hint("Showing the first 400. Search to narrow it down.") }
        }
        .task(id: pack.fileName) {
            do {
                images = try await ResourcePacks.images(in: pack)
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Pixel art stays sharp. An animated strip shows its first frame.
struct AsyncTexture: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let loaded = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let full = NSImage(contentsOf: url), let cg = full.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
                let side = cg.width
                if cg.height > side, cg.height % side == 0, let frame = cg.cropping(to: CGRect(x: 0, y: 0, width: side, height: side)) {
                    return NSImage(cgImage: frame, size: NSSize(width: side, height: side))
                }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
            image = loaded
        }
    }
}
