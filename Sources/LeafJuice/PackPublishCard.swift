import AppKit
import LeafJuiceCore
import SwiftUI

/// Publishing builds to the web server's folder (D189). Each publish gets a new random address; the old one goes once
/// nobody who might still need it is online. Packmule reads the hash from the file name.
struct PackPublishCard: View {
    let server: ServerController
    let recipeNames: [String]
    @State private var settings = PackPublishSettings()
    @State private var problem: String?
    @State private var copied: String?

    var body: some View {
        Card(title: "Publish to your web server", systemImage: "arrow.up.doc") {
            Hint("For a web server such as Caddy that serves a folder on this Mac. Each build goes in under a new random address, named by its SHA-1, so Packmule reads the hash from the link. Only the current build and one on its way out are ever there.")
            LabeledContent("Folder it serves") {
                HStack {
                    Text(settings.folder.isEmpty ? "Not chosen" : (settings.folder as NSString).abbreviatingWithTildeInPath).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseFolder).buttonStyle(.juice)
                }
            }
            LabeledContent("Its web address") {
                TextField("https://join.example.test/packs/", text: $settings.baseURL).textFieldStyle(.roundedBorder)
                    .onSubmit(save).accessibilityLabel("Web address of that folder")
            }
            if let why = PackPublish.problem(settings) { Hint(why) }
            ForEach(recipeNames.filter { !ResourcePacks.history($0).isEmpty }, id: \.self) { name in recipeRow(name) }
            if let problem { Callout(tone: .danger, title: "Not published", detail: problem) }
            Hint("Packmule can't be told the new link yet: put it in Packmule's config.yml and run /packmule reload. When Packmule offers a command for it, LeafJuice will send it for you.")
        }
        .onAppear { settings = server.packPublishSettings }
    }

    @ViewBuilder private func recipeRow(_ name: String) -> some View {
        let key = ResourcePacks.slug(name)
        let builds = settings.builds[key] ?? []
        let newest = ResourcePacks.history(name).first
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.body.weight(.semibold)).foregroundStyle(Juice.ink)
            if let current = builds.first {
                HStack {
                    Text(current.url).font(.callout.monospaced()).foregroundStyle(Juice.ink).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Button(copied == current.url ? "Copied" : "Copy Link") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current.url, forType: .string); copied = current.url
                    }
                    .buttonStyle(.juice).accessibilityLabel("Copy the link for \(name)")
                }
                Hint("Published \(current.publishedAt.formatted(.relative(presentation: .named))). SHA-1 \(current.sha1).")
                if builds.count > 1 { Hint("\(builds.count - 1) older build\(builds.count == 2 ? " is" : "s are") still there, and go once everyone online at the switch has left (at least \(PackPublish.graceMinutes) minutes).") }
            } else {
                Hint("Not published yet.")
            }
            if let newest, newest.sha1 != builds.first?.sha1 {
                Button("Publish the Newest Build") { publish(name, newest.sha1) }
                    .buttonStyle(.juicePrimary).disabled(PackPublish.problem(settings) != nil)
                    .accessibilityLabel("Publish the newest build of \(name)")
            }
        }
        .padding(.vertical, 4)
    }

    private func save() { var s = server.packPublishSettings; s.folder = settings.folder; s.baseURL = settings.baseURL; server.packPublishSettings = s; settings = s }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.folder = url.path
        save()
    }

    private func publish(_ name: String, _ sha1: String) {
        save()
        do { try server.publishPack(recipe: name, sha1: sha1); problem = nil } catch { problem = error.localizedDescription }
        settings = server.packPublishSettings
    }
}
