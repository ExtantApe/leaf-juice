import AppKit
import LeafJuiceCore
import SwiftUI
import UniformTypeIdentifiers

/// Look through resource packs, rank them into recipes, build, update and share.
struct ResourcePacksPage: View {
    let server: ServerController
    @State private var packs: [LibraryPack] = []
    @State private var recipe = PackRecipe()
    @State private var recipeNames: [String] = []
    @State private var lock: PackLock?
    @State private var history: [PackBuild] = []
    @State private var updates: [String: PackUpdate] = [:]
    @State private var browsing: LibraryPack?
    @State private var working: String?
    @State private var error: String?
    @State private var link = ""
    @State private var url = ""
    @State private var required = false
    @State private var lastChanges: PackChanges?
    @State private var review: PendingUpdate?
    @State private var sharing = false
    @State private var confirmRemove: LibraryPack?
    @State private var newRecipe = false
    @State private var newName = ""
    @State private var fit: PackCoverage?
    @State private var locator: PackFileLocator?
    @State private var confirmServe: PackBuild?
    @State private var checkFailed: PackURLCheck?
    @State private var hostingRefresh = 0
    /// Each included pack's songs.json, by pack id.
    @State private var songLists: [String: PackSongList] = [:]

    struct PendingUpdate: Identifiable {
        var id: String { pack.id }
        var pack: LibraryPack
        var version: PackVersion
        var changes: PackChanges
    }

    private var live: ResourcePacks.ServerPack {
        ResourcePacks.current((try? String(contentsOf: server.paths.properties, encoding: .utf8)) ?? "")
    }
    private var mc: String? { server.profile.software.mcVersion.isEmpty ? nil : server.profile.software.mcVersion }
    private var enabled: [PackRecipe.Entry] { recipe.entries.filter(\.enabled) }

    var body: some View {
        Page(title: "Resource Packs", subtitle: "Look through packs, rank them into one, and use it on this server.") {
            if let error { Callout(tone: .danger, title: error) }
            serverCard
            libraryCard
            if !packs.isEmpty { recipeCard }
            if !history.isEmpty { buildsCard }
            if !packs.isEmpty {
                PackHostingCard(server: server, recipeNames: recipeNames, live: live) { hostingRefresh += 1 }
            }
            if let browsing { PackBrowser(pack: browsing) { self.browsing = nil } }
        }
        .task { await start() }
        .sheet(item: $review) { pending in
            UpdateReviewSheet(pending: pending) {
                pin(pending)
                review = nil
            } onCancel: { review = nil }
        }
        .sheet(isPresented: $sharing) { ShareSheet(recipe: recipe, history: history) }
        .confirmationDialog("Remove this pack from the library?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } })) {
            Button("Remove", role: .destructive) { if let pack = confirmRemove { remove(pack) } }
        } message: {
            Text("All its versions go. Packs you've already built aren't affected, but recipes won't be able to rebuild with it.")
        }
        .confirmationDialog("Serve this build to players?", isPresented: Binding(get: { confirmServe != nil }, set: { if !$0 { confirmServe = nil } })) {
            Button("Serve It") { if let build = confirmServe { serve(build) } }
        } message: {
            Text(serveWarning)
        }
        .alert("New recipe", isPresented: $newRecipe) {
            TextField("Name", text: $newName)
            Button("Create") { createRecipe() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A recipe is one way of ranking your packs, such as one for each server.")
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

    private var libraryCard: some View {
        Card(title: "Library", systemImage: "photo.stack") {
            Hint("Every version of every pack is kept, unchanged. Top of the list wins, as in Minecraft's own list.")
            ForEach(Array(recipe.entries.enumerated()), id: \.element.pack) { index, entry in
                if let pack = packs.first(where: { $0.id == entry.pack }) { row(pack, entry, index) }
            }
            HStack {
                TextField("Link", text: $link, prompt: Text("A Modrinth or GitHub page, or a link to a zip"))
                    .accessibilityLabel("Link to a resource pack")
                Button("Add Link") { addLink() }.buttonStyle(.juice).disabled(link.isEmpty || working != nil)
                Button("Add Files…") { addFiles() }.buttonStyle(.juicePrimary).disabled(working != nil)
            }
            HStack {
                Button("Check for Updates") { checkUpdates() }.buttonStyle(.juice).disabled(working != nil || !packs.contains { $0.source.canCheckForUpdates })
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

    private func row(_ pack: LibraryPack, _ entry: PackRecipe.Entry, _ index: Int) -> some View {
        let version = pack.version(entry.version)
        return HStack(alignment: .center, spacing: 10) {
            Toggle("Include \(pack.title)", isOn: Binding(get: { entry.enabled }, set: { value in change(entry) { $0.enabled = value } }))
                .labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.title).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                Hint(details(pack, version)).lineLimit(1)
                if let note = version?.note { Hint(note).foregroundStyle(Tone.warning.color) }
            }
            Spacer()
            if let update = updates[pack.id] {
                Button("Review \(update.version)…") { reviewUpdate(pack, update) }.buttonStyle(.juicePrimary).disabled(working != nil)
            }
            if pack.versions.count > 1 {
                Menu(version?.version ?? "Version") {
                    ForEach(pack.versions.reversed()) { candidate in
                        Button(candidate.version) { change(entry) { $0.version = candidate.sha1 } }
                    }
                }
                .fixedSize().accessibilityLabel("Version of \(pack.title)")
            }
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.juice).disabled(index == 0).accessibilityLabel("Higher priority")
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.juice).disabled(index == recipe.entries.count - 1).accessibilityLabel("Lower priority")
            Button("Look Through") { browsing = pack }.buttonStyle(.juice).accessibilityLabel("Look through \(pack.title)")
            Button("Remove…") { confirmRemove = pack }.buttonStyle(.juice).accessibilityLabel("Remove \(pack.title)")
        }
    }

    private func details(_ pack: LibraryPack, _ version: PackVersion?) -> String {
        var parts = [pack.license?.title ?? "No license on record"]
        if let v = version?.format { parts.append("format \(v)") }
        if let size = version?.size { parts.append(Format.bytes(size)) }
        parts.append(pack.source.title)
        return parts.joined(separator: ", ")
    }

    // MARK: Recipe

    private var recipeCard: some View {
        Card(title: "Recipe", systemImage: "square.stack.3d.down.right") {
            HStack {
                Picker("Recipe", selection: Binding(get: { recipe.name }, set: { open($0) })) {
                    ForEach(recipeNames, id: \.self) { Text($0).tag($0) }
                }
                .frame(maxWidth: 260)
                Button("New…") {
                    newName = ""
                    newRecipe = true
                }
                .buttonStyle(.juice)
                Spacer()
                Button("Build") { build() }.buttonStyle(.juicePrimary).disabled(working != nil || enabled.isEmpty)
            }
            fitSection
            categorySection
            leaveOutSection
            if enabled.contains(where: { songLists[$0.pack] != nil }) { songsSection }
            if let lock {
                PackContributionsView(lock: lock, recipe: recipe, packs: packs, locator: locator) { path, pack in
                    recipe.winners[path] = pack
                    saved()
                }
            }
            mineSection
            if let lastChanges, !lastChanges.isEmpty { changesSection(lastChanges) }
            HStack {
                Button("Share…") { sharing = true }.buttonStyle(.juice).disabled(enabled.isEmpty)
                Button("Import Recipe…") { importRecipe() }.buttonStyle(.juice).disabled(working != nil)
            }
        }
    }

    @ViewBuilder private var fitSection: some View {
        if let fit {
            DisclosureGroup("Covers \(fit.percent)% of Minecraft \(fit.mc)'s textures") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(fit.rows) { row in
                        HStack(spacing: 10) {
                            Text(row.category).foregroundStyle(Juice.ink).frame(width: 130, alignment: .leading)
                            ProgressView(value: Double(row.covered), total: Double(max(row.total, 1))).frame(maxWidth: 200).accessibilityLabel("\(row.category): \(row.percent) percent")
                            Text("\(row.covered) of \(row.total)").font(.callout).foregroundStyle(Juice.muted)
                        }
                    }
                    Hint("Anything not covered uses the game's own art. A pack listed lower down fills in gaps from the ones above it.")
                    if fit.unused > 0 { Hint("\(fit.unused) textures here are for things this version doesn't have, so the game ignores them.") }
                    if let format = fit.serverFormat { Hint("This Minecraft version uses pack format \(format).") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Juice.ink)
        }
    }

    private var categorySection: some View {
        DisclosureGroup("Who wins each kind of file") {
            VStack(alignment: .leading, spacing: 6) {
                Hint("Follows the ranking above unless you choose a pack here. For example, one pack's blocks with another's models. Picking a winner for one file overrides this.")
                ForEach(ResourcePacks.categories, id: \.self) { category in
                    Picker(category, selection: Binding(get: { recipe.categoryWinners[category] ?? "" }, set: { value in
                        recipe.categoryWinners[category] = value.isEmpty ? nil : value
                        saved()
                    })) {
                        Text("By ranking").tag("")
                        ForEach(enabled, id: \.pack) { entry in
                            Text(packs.first { $0.id == entry.pack }?.title ?? entry.pack).tag(entry.pack)
                        }
                    }
                    .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Juice.ink)
    }

    private var leaveOutSection: some View {
        DisclosureGroup("Leave out parts of a pack") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(enabled, id: \.pack) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(packs.first { $0.id == entry.pack }?.title ?? entry.pack).font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 4) {
                            ForEach(ResourcePacks.categories, id: \.self) { category in
                                Toggle(category, isOn: Binding(get: { !entry.excluded.contains(category) }, set: { keep in
                                    change(entry) { if keep { $0.excluded.remove(category) } else { $0.excluded.insert(category) } }
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
    }

    private var songsSection: some View {
        DisclosureGroup("Songs") {
            VStack(alignment: .leading, spacing: 12) {
                Hint("Untick a song to leave it out of this recipe's pack, so Minecraft's own track plays in its place. Each change makes a new build with its own SHA-1, so build again and update the server.")
                ForEach(enabled.filter { songLists[$0.pack] != nil }, id: \.pack) { entry in
                    songs(for: entry, list: songLists[entry.pack]!)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Juice.ink)
    }

    private func songs(for entry: PackRecipe.Entry, list: PackSongList) -> some View {
        let off = entry.songsOff ?? []
        let missing = off.subtracting(list.songs.map(\.id)).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            Text(packs.first { $0.id == entry.pack }?.title ?? entry.pack).font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
            ForEach(list.problems, id: \.self) { Callout(tone: .warning, title: "Songs can't be switched off one by one", detail: $0) }
            ForEach(list.songs) { song in
                Toggle(isOn: Binding(get: { !off.contains(song.id) }, set: { keep in
                    change(entry) { e in
                        var set = e.songsOff ?? []
                        if keep { set.remove(song.id) } else { set.insert(song.id) }
                        e.songsOff = set.isEmpty ? nil : set
                    }
                })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.title).foregroundStyle(Juice.ink)
                        Hint(songDetail(song, size: list.sizes[song.id]))
                    }
                }
                .toggleStyle(.checkbox)
                .accessibilityHint(off.contains(song.id) ? "Left out. Minecraft's own tracks play instead." : "Included.")
            }
            ForEach(list.notes, id: \.self) { Hint($0) }
            if !missing.isEmpty {
                HStack {
                    Hint("Switched off, but no longer in this pack: \(missing.joined(separator: ", ")).")
                    Button("Forget") { change(entry) { e in e.songsOff = (e.songsOff ?? []).subtracting(missing); if e.songsOff?.isEmpty == true { e.songsOff = nil } } }
                        .buttonStyle(.juice)
                }
            }
        }
    }

    private func songDetail(_ song: PackSong, size: Int64?) -> String {
        var parts = ["Stands in for " + song.standsInFor.joined(separator: ", ")]
        if let size { parts.append(Format.bytes(size)) }
        if let credit = song.credit, !credit.isEmpty { parts.append(credit) }
        return parts.joined(separator: " · ")
    }

    private var mineSection: some View {
        HStack {
            Text("My changes").foregroundStyle(Juice.ink)
            Hint("Your own files, in the same layout as a pack. They always win and updates never touch them.")
            Spacer()
            Button("Open Folder") {
                try? FileOps.ensureDir(ResourcePacks.mine)
                NSWorkspace.shared.open(ResourcePacks.mine)
            }
            .buttonStyle(.juice)
        }
    }

    private func changesSection(_ changes: PackChanges) -> some View {
        Callout(tone: changes.lostPicks.isEmpty ? .info : .warning, title: "Since the last build", detail: changes.summary)
    }

    // MARK: Builds

    private var buildsCard: some View {
        Card(title: "Builds", systemImage: "shippingbox") {
            ForEach(Array(history.prefix(8).enumerated()), id: \.element.sha1) { index, item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Juice.ink)
                        Hint("\(item.sha1.prefix(12))…, \(Format.bytes(item.size)), \(item.fileCount) files, \(item.merged.count) merged")
                        ForEach(item.warnings, id: \.self) { Hint($0) }
                    }
                    Spacer()
                    if live.sha1 == item.sha1 { Badge(text: "On this server", tone: .good) }
                    if servedSHA1 == item.sha1 {
                        Badge(text: "At its address", tone: .good)
                    } else if !hostedElsewhere, !server.hasPerWorldPacks {
                        Button("Serve This Build") { askToServe(item) }.buttonStyle(.juice)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ResourcePacks.buildFile(item, recipe: recipe.name)]) }.buttonStyle(.juice)
                    Button("Copy SHA-1") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.sha1, forType: .string)
                    }
                    .buttonStyle(.juice)
                }
            }
            if let newest = history.first, !server.hasPerWorldPacks {
                Divider()
                Hint("Players' games download a pack from the web. Serve it from Hosting below, or upload it somewhere such as mc-packs.net. LeafJuice downloads it from the address first to check it's the same file.")
                HStack {
                    Link("Open mc-packs.net", destination: URL(string: "https://mc-packs.net")!).buttonStyle(.juice)
                    TextField("Address", text: $url, prompt: Text(server.packAddress(recipe: recipe.name) ?? "https://download.mc-packs.net/pack/\(newest.sha1).zip"))
                        .accessibilityLabel("Web address of the pack")
                    Toggle("Required", isOn: $required).toggleStyle(.checkbox).fixedSize()
                        .help("Players who decline are disconnected.")
                    Button(server.state.canStart ? "Use on This Server" : "Use at Next Restart") { apply(newest) }.buttonStyle(.juicePrimary).disabled(working != nil || chosenURL.isEmpty)
                }
                if let checkFailed {
                    Callout(tone: .danger, title: "That address didn't give this build", detail: checkFailed.summary)
                    HStack {
                        Button("Use It Anyway") { write(newest) }.buttonStyle(.juice)
                        Button("Cancel") { self.checkFailed = nil }.buttonStyle(.juice)
                    }
                }
            }
        }
    }

    private var chosenURL: String { url.isEmpty ? (server.packAddress(recipe: recipe.name) ?? "") : url }
    private var servedSHA1: String? { _ = hostingRefresh; return server.servedPackSHA1(recipe: recipe.name) }
    private var hostedElsewhere: Bool { _ = hostingRefresh; return server.packHostSettings.recipes[ResourcePacks.slug(recipe.name)]?.elsewhere != nil }

    private var serveWarning: String {
        var lines = ["This gives every player a copy of these packs, so check their terms first. A guide, not legal advice."]
        for item in ResourcePacks.licenseReview(recipe) {
            switch item.sharing {
            case .allowed: break
            case let .conditions(text), let .ask(text): lines.append("\(item.pack.title): \(text)")
            }
        }
        if let plugin = server.perWorldPackPlugin { lines.append("\(plugin) doesn't use this address. Give it the build's own address and SHA-1 from Hosting.") }
        return lines.joined(separator: "\n\n")
    }

    // MARK: Actions

    private func start() async {
        recipeNames = ResourcePacks.recipeNames()
        if recipeNames.isEmpty {
            ResourcePacks.saveRecipe(PackRecipe())
            recipeNames = ResourcePacks.recipeNames()
        }
        recipe = ResourcePacks.loadRecipe(recipeNames.first ?? "combined")
        required = live.required
        await server.refreshPlugins()
        server.startPackHostIfWanted()
        await reload()
        #if DEBUG
        if ProcessInfo.processInfo.environment["LEAFJUICE_SNAPSHOT"] != nil { browsing = packs.first }
        #endif
    }

    private func reload() async {
        packs = ResourcePacks.list()
        recipe = ResourcePacks.reconcile(recipe, with: packs)
        ResourcePacks.saveRecipe(recipe)
        recipeNames = ResourcePacks.recipeNames()
        history = ResourcePacks.history(recipe.name)
        await refreshLock()
    }

    private func refreshLock() async {
        var lists: [String: PackSongList] = [:]
        for entry in recipe.entries where entry.enabled {
            if let list = await ResourcePacks.songList(for: entry) { lists[entry.pack] = list }
        }
        songLists = lists
        lock = try? await ResourcePacks.resolve(recipe)
        locator = try? await ResourcePacks.locator(recipe)
        // Measuring needs one download of Mojang's file list per version, and works without it otherwise.
        if let mc, !enabled.isEmpty { fit = try? await ResourcePacks.coverage(recipe, mc: mc) } else { fit = nil }
        if let now = lock, let newest = history.first, let then = ResourcePacks.loadLock(sha1: newest.sha1, recipe: recipe.name) {
            lastChanges = ResourcePacks.changes(from: then, to: now, recipe: recipe)
        } else {
            lastChanges = nil
        }
    }

    private func saved() {
        ResourcePacks.saveRecipe(recipe)
        Task { await refreshLock() }
    }

    private func open(_ name: String) {
        recipe = ResourcePacks.reconcile(ResourcePacks.loadRecipe(name), with: packs)
        history = ResourcePacks.history(name)
        Task { await refreshLock() }
    }

    private func createRecipe() {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var fresh = PackRecipe()
        fresh.name = name
        fresh = ResourcePacks.reconcile(fresh, with: packs)
        ResourcePacks.saveRecipe(fresh)
        recipe = fresh
        recipeNames = ResourcePacks.recipeNames()
        history = []
        lastChanges = nil
        Task { await refreshLock() }
    }

    private func change(_ entry: PackRecipe.Entry, _ edit: (inout PackRecipe.Entry) -> Void) {
        guard let index = recipe.entries.firstIndex(where: { $0.pack == entry.pack }) else { return }
        edit(&recipe.entries[index])
        saved()
    }

    private func move(_ index: Int, by offset: Int) {
        guard recipe.entries.indices.contains(index + offset) else { return }
        recipe.entries.swapAt(index, index + offset)
        saved()
    }

    private func perform(_ text: String, _ work: @escaping () async throws -> Void) {
        working = text
        error = nil
        Task {
            do { try await work() } catch { self.error = error.localizedDescription }
            working = nil
        }
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip]
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        perform("Reading…") {
            for url in urls { try await ResourcePacks.add(url) }
            await reload()
        }
    }

    private func addLink() {
        guard let source = PackSource.parse(link) else {
            error = "That doesn't look like a web address."
            return
        }
        perform("Downloading…") {
            try await ResourcePacks.download(source, mc: mc)
            link = ""
            await reload()
        }
    }

    private func checkUpdates() {
        perform("Checking…") {
            var found: [String: PackUpdate] = [:]
            for pack in packs where pack.source.canCheckForUpdates {
                if let update = try? await ResourcePacks.checkUpdate(pack, mc: mc) { found[pack.id] = update }
            }
            updates = found
            if found.isEmpty { server.notice = "All your packs are on their newest versions." }
        }
    }

    /// Fetches it, and works out what it'd change. The recipe stays on its current version until you accept.
    private func reviewUpdate(_ pack: LibraryPack, _ update: PackUpdate) {
        perform("Downloading \(update.version)…") {
            let updated = try await ResourcePacks.download(pack.source, update: update, mc: mc)
            guard let newest = updated.latest else { return }
            await reload()
            var trial = recipe
            if let index = trial.entries.firstIndex(where: { $0.pack == updated.id }) { trial.entries[index].version = newest.sha1 }
            let before = try await ResourcePacks.resolve(recipe)
            let after = try await ResourcePacks.resolve(trial)
            review = PendingUpdate(pack: updated, version: newest, changes: ResourcePacks.changes(from: before, to: after, recipe: trial))
        }
    }

    private func pin(_ pending: PendingUpdate) {
        guard let index = recipe.entries.firstIndex(where: { $0.pack == pending.pack.id }) else { return }
        recipe.entries[index].version = pending.version.sha1
        updates[pending.pack.id] = nil
        saved()
    }

    private func remove(_ pack: LibraryPack) {
        perform("Removing…") {
            try await ResourcePacks.remove(pack)
            if browsing == pack { browsing = nil }
            await reload()
        }
    }

    private func build() {
        perform("Building…") {
            _ = try await ResourcePacks.combine(recipe)
            history = ResourcePacks.history(recipe.name)
            await refreshLock()
        }
    }

    private func importRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let file = panel.url else { return }
        perform("Fetching its packs…") {
            let result = try await ResourcePacks.importRecipe(Data(contentsOf: file), mc: mc)
            ResourcePacks.saveRecipe(result.recipe)
            recipe = result.recipe
            await reload()
            if !result.missing.isEmpty {
                self.error = "Couldn't get the exact file for: \(result.missing.map(\.title).joined(separator: ", ")). Add those by hand, and the recipe will use them."
            }
        }
    }

    private func askToServe(_ item: PackBuild) { confirmServe = item }

    private func serve(_ item: PackBuild) {
        do {
            try server.serveBuild(sha1: item.sha1, recipe: recipe.name)
            hostingRefresh += 1
        } catch { self.error = error.localizedDescription }
    }

    /// An address served from here always has the file, and a staged change only switches at the restart.
    /// Anywhere else is checked first, and the person can still go ahead, say if they haven't uploaded it yet.
    private func apply(_ build: PackBuild) {
        checkFailed = nil
        let address = chosenURL
        if server.isServedFromHere(address: address, recipe: recipe.name) {
            write(build)
            return
        }
        perform("Checking the address…") {
            let result = await PackHosting.check(url: address, expected: build.sha1, ticket: server.packCheckTicket(for: address))
            if result.ok { write(build) } else { checkFailed = result }
        }
    }

    private func write(_ build: PackBuild) {
        checkFailed = nil
        let address = chosenURL
        Task {
            do {
                let outcome = try await server.usePack(url: address, sha1: build.sha1, required: required, recipe: recipe.name)
                server.notice = outcome == .staged ? "The resource pack applies at the next restart." : "The resource pack is set, and players get it the next time they join."
                hostingRefresh += 1
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct UpdateReviewSheet: View {
    let pending: ResourcePacksPage.PendingUpdate
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Update \(pending.pack.title) to \(pending.version.version)?").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            Text("In this recipe: \(pending.changes.summary).").foregroundStyle(Juice.ink)
            if !pending.changes.lostPicks.isEmpty {
                Callout(tone: .warning, title: pending.changes.lostPicks.count == 1 ? "1 file you picked a winner for is gone" : "\(pending.changes.lostPicks.count) files you picked winners for are gone", detail: pending.changes.lostPicks.prefix(6).joined(separator: "\n"))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    section("Players would see these change", pending.changes.changed)
                    section("New", pending.changes.added)
                    section("Removed", pending.changes.removed)
                    section("Changed, but a higher pack still wins", pending.changes.hidden)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            Hint("The old version stays in the library, and nothing is built until you press Build.")
            HStack {
                Button("Keep the Current Version") { onCancel() }.buttonStyle(.juice).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use This Version") { onAccept() }.buttonStyle(.juicePrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    @ViewBuilder private func section(_ title: String, _ items: [PackChanges.Change]) -> some View {
        if !items.isEmpty {
            Text("\(title) (\(items.count))").font(.callout.weight(.semibold)).foregroundStyle(Juice.ink)
            ForEach(items.prefix(40)) { item in
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.path).font(.callout).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.head)
                    Hint(item.detail)
                }
            }
            if items.count > 40 { Hint("And \(items.count - 40) more.") }
        }
    }
}

/// Recipes first, because they carry no one else's work. A combined pack gets its licenses looked at first.
struct ShareSheet: View {
    let recipe: PackRecipe
    let history: [PackBuild]
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    private var review: [(pack: LibraryPack, sharing: PackLicense.Sharing)] { ResourcePacks.licenseReview(recipe) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share \(recipe.name)").font(.title2.weight(.semibold)).foregroundStyle(Juice.ink)
            if let error { Callout(tone: .danger, title: error) }
            Card(title: "The recipe", systemImage: "doc.text") {
                Text("A small file saying where to get each pack and how to rank them. Others download the packs from their authors.").foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
                Hint("Your own My changes files and packs added by hand aren't included, so anyone using it needs those from you.")
                Button("Export Recipe…") { exportRecipe() }.buttonStyle(.juicePrimary)
            }
            Card(title: "The combined pack", systemImage: "shippingbox") {
                Text("This shares other people's work, so check their terms first. Being free doesn't by itself give you permission.").foregroundStyle(Juice.ink).fixedSize(horizontal: false, vertical: true)
                ForEach(review, id: \.pack.id) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Badge(text: label(item.sharing), tone: tone(item.sharing)).frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(item.pack.title), \(item.pack.license?.title ?? "no license on record")").foregroundStyle(Juice.ink)
                            if let note = note(item.sharing) { Hint(note) }
                        }
                    }
                }
                Hint("A guide, not legal advice. The file includes credits and asks that it isn't sold, but nothing can enforce that once it's shared.")
                Button("Export Combined Pack…") { exportPack() }.buttonStyle(.juice).disabled(history.isEmpty)
                if history.isEmpty { Hint("Build it first.") }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.juice).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func label(_ sharing: PackLicense.Sharing) -> String {
        switch sharing {
        case .allowed: "Looks fine"
        case .conditions: "On conditions"
        case .ask: "Check first"
        }
    }

    private func tone(_ sharing: PackLicense.Sharing) -> Tone {
        switch sharing {
        case .allowed: .good
        case .conditions: .info
        case .ask: .warning
        }
    }

    private func note(_ sharing: PackLicense.Sharing) -> String? {
        switch sharing {
        case .allowed: nil
        case let .conditions(text), let .ask(text): text
        }
    }

    private func exportRecipe() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(ResourcePacks.slug(recipe.name))-recipe.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try ResourcePacks.exportRecipe(recipe).write(to: url) } catch { self.error = error.localizedDescription }
    }

    private func exportPack() {
        guard let newest = history.first else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(ResourcePacks.slug(recipe.name)).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.copyItem(at: ResourcePacks.buildFile(newest, recipe: recipe.name), to: url)
        } catch { self.error = error.localizedDescription }
    }
}

/// A pack's images, so you can see what it changes before using it.
struct PackBrowser: View {
    let pack: LibraryPack
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
        Card(title: pack.title, systemImage: "eye") {
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
        .task(id: pack.id) {
            do {
                guard let version = pack.latest else { return }
                images = try await ResourcePacks.images(in: pack, version)
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
