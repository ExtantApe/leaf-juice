import LeafJuiceCore
import SwiftUI

/// What each pack adds to the recipe, down to the file, and where to choose another copy.
struct PackContributionsView: View {
    let lock: PackLock
    let recipe: PackRecipe
    let packs: [LibraryPack]
    let locator: PackFileLocator?
    let choose: (_ path: String, _ pack: String?) -> Void

    @State private var pack = ""
    @State private var show = PackFileFilter.all
    @State private var category = ""
    @State private var search = ""
    @State private var imagesOnly = true
    @State private var limit = Self.pageSize
    private static let pageSize = 100

    private func title(_ id: String) -> String {
        if id == ResourcePacks.mineID { return "My changes" }
        return packs.first { $0.id == id }?.title ?? id
    }

    private var counts: [PackContribution] {
        ResourcePacks.contributions(lock, order: recipe.entries.filter(\.enabled).map { ($0.pack, title($0.pack)) })
    }

    private var shown: [LockedFile] {
        ResourcePacks.files(lock, pack: pack.isEmpty ? nil : pack, show: show, category: category.isEmpty ? nil : category, search: search, imagesOnly: imagesOnly)
    }

    var body: some View {
        DisclosureGroup("What each pack contributes") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(counts) { summary($0) }
                Divider()
                filters
                let files = shown
                Hint("\(files.count) file\(files.count == 1 ? "" : "s"). Languages, sounds, fonts, atlases and item model overrides merge, so there's nothing to choose for them.")
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(files.prefix(limit)) { row($0) }
                }
                if files.count > limit {
                    Button("Show \(min(Self.pageSize, files.count - limit)) More") { limit += Self.pageSize }.buttonStyle(.juice)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Juice.ink)
    }

    private func summary(_ item: PackContribution) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(item.title).font(.callout.weight(.semibold)).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Show Its Files") {
                    pack = item.pack
                    show = .all
                    limit = Self.pageSize
                }
                .buttonStyle(.juice)
                .accessibilityLabel("Show files from \(item.title)")
            }
            Hint(detail(item))
            if !item.winsByCategory.isEmpty {
                Hint(item.winsByCategory.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            }
        }
    }

    private func detail(_ item: PackContribution) -> String {
        var parts = ["Supplies \(item.wins) file\(item.wins == 1 ? "" : "s"), \(item.images) of them images"]
        if item.only > 0 { parts.append("\(item.only) only it has") }
        if item.loses > 0 { parts.append("\(item.loses) replaced by another pack") }
        if item.same > 0 { parts.append("\(item.same) identical to the one used") }
        if item.merged > 0 { parts.append("\(item.merged) merged") }
        return parts.joined(separator: ", ")
    }

    private var filters: some View {
        HStack {
            Picker("Pack", selection: $pack) {
                Text("Every pack").tag("")
                ForEach(counts) { Text($0.title).tag($0.pack) }
            }
            .frame(maxWidth: 230)
            Picker("Show", selection: $show) {
                ForEach(PackFileFilter.allCases) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 240)
            Picker("Kind", selection: $category) {
                Text("Everything").tag("")
                ForEach(ResourcePacks.categories, id: \.self) { Text($0).tag($0) }
            }
            .frame(maxWidth: 190)
            TextField("Search", text: $search, prompt: Text("diamond")).frame(maxWidth: 160).accessibilityLabel("Search files")
            Toggle("Images only", isOn: $imagesOnly).toggleStyle(.checkbox).fixedSize()
        }
        .onChange(of: [pack, show.rawValue, category, search, String(imagesOnly)]) { limit = Self.pageSize }
    }

    private func row(_ file: LockedFile) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(file.copies, id: \.pack) { copy in
                thumbnail(file, copy)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(file.path).font(.callout).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.head).textSelection(.enabled).help(file.path)
                Hint("\(file.reasonText): \(title(file.winner))")
            }
            Spacer()
            if file.canChoose {
                Picker("Winner for \(file.path)", selection: Binding(get: { recipe.winners[file.path] ?? "" }, set: { choose(file.path, $0.isEmpty ? nil : $0) })) {
                    Text("Follow the recipe").tag("")
                    ForEach(file.copies, id: \.pack) { Text(title($0.pack)).tag($0.pack) }
                }
                .labelsHidden().frame(maxWidth: 220)
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func thumbnail(_ file: LockedFile, _ copy: LockedFile.Copy) -> some View {
        let used = copy.pack == file.winner || file.reason == .merged
        Group {
            if file.isImage, let url = locator?.url(path: file.path, pack: copy.pack) {
                AsyncTexture(url: url)
            } else {
                Image(systemName: "doc").foregroundStyle(Juice.muted).accessibilityHidden(true)
            }
        }
        .frame(width: 44, height: 44)
        .background(Juice.raised, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(used ? Tone.good.color : Color.clear, lineWidth: 2))
        .help("\(title(copy.pack))\(used ? ", used in the build" : "")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title(copy.pack))\(used ? ", used in the build" : "")")
    }
}
