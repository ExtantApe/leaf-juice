import AppKit
import LeafJuiceCore
import SwiftUI

struct LaunchPage: View {
    @Bindable var server: ServerController
    @State private var showFlags = false

    var body: some View {
        Page(title: "Launch", subtitle: "How the server starts: size, Java and flags.") {
            if server.launchChangedSinceStart {
                Callout(tone: .warning, title: "These changes apply at the next restart")
            }
            scalingCard
            memoryCard
            javaCard
            flagsCard
            behaviourCard
            commandCard
        }
    }

    private var scalingCard: some View {
        Card(title: "Quick size", systemImage: "square.resize") {
            Hint("Sets memory, view distance, simulation distance and player limit together. You can fine-tune them afterwards.")
            FlowRow(spacing: 8) {
                ForEach(ScalingPreset.all) { preset in
                    Button {
                        server.attempt {
                            try server.applyScaling(preset)
                            server.notice = "Applied \(preset.title). " + (server.state.canStart ? "" : "It takes effect at the next restart.")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(preset.title).font(.body.weight(.medium))
                            Text(preset.detail).font(.caption)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.juice)
                    .disabled(preset.memoryMB > SystemInfo.memoryMB)
                    .help(preset.memoryMB > SystemInfo.memoryMB ? "Needs more memory than this Mac has" : "\(Format.memory(mb: preset.memoryMB)), view \(preset.viewDistance), simulation \(preset.simulationDistance)")
                }
            }
        }
    }

    private var memoryCard: some View {
        Card(title: "Memory", systemImage: "memorychip") {
            memoryRow("Maximum", value: $server.profile.launch.maxMemoryMB)
            memoryRow("Minimum", value: $server.profile.launch.minMemoryMB)
            if server.profile.launch.minMemoryMB > server.profile.launch.maxMemoryMB {
                Callout(tone: .danger, title: "Minimum is above maximum")
            }
            if let warning = server.memoryWarning { Callout(tone: .warning, title: warning) }
            Hint("This Mac has \(Format.memory(mb: SystemInfo.memoryMB)). Setting both the same is usual for servers: Java then doesn't spend time resizing. More isn't always better; very large heaps can lengthen pauses.")
        }
    }

    private func memoryRow(_ label: String, value: Binding<Int>) -> some View {
        HStack {
            Text(label).foregroundStyle(Juice.ink).frame(width: 80, alignment: .leading)
            Slider(value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Int($0 / 256) * 256 }
            ), in: 512...Double(max(1024, SystemInfo.memoryMB)), step: 256)
            .accessibilityLabel("\(label) memory")
            .accessibilityValue(Format.memory(mb: value.wrappedValue))
            TextField(label, value: value, format: .number.grouping(.never))
                .labelsHidden().frame(width: 70).textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(label) memory in megabytes")
            Text("MB").foregroundStyle(Juice.muted)
        }
    }

    private var javaCard: some View {
        Card(title: "Java", systemImage: "cup.and.saucer") {
            let required = server.javaRequirement
            Picker("Runtime", selection: $server.profile.launch.javaPath) {
                Text(autoLabel).tag(String?.none)
                ForEach(server.runtimes) { runtime in
                    Text(runtime.label).tag(String?.some(runtime.path))
                }
                if let path = server.profile.launch.javaPath, !server.runtimes.contains(where: { $0.path == path }) {
                    Text(path).tag(String?.some(path))
                }
            }
            if let java = server.resolvedJava() {
                Hint(java.path)
                if java.major > 0, java.major < required {
                    Callout(tone: .danger, title: "This server needs Java \(required) or newer")
                }
            } else {
                Callout(tone: .warning, title: "Java \(required) isn't installed")
            }
            HStack {
                Button("Download Java \(required)") {
                    server.attempt { try await server.installJava(major: required) }
                }
                .buttonStyle(.juice).disabled(server.activity != nil || server.runtimes.contains { $0.major == required && $0.managed })
                Button("Choose a Java…") { chooseJava() }.buttonStyle(.juice)
                Button("Rescan") { Task { server.runtimes = await JavaManager.discover() } }.buttonStyle(.juice)
            }
            Hint("Downloads Eclipse Temurin into Leaf Juice's own folder. Your system's Java isn't changed.")
        }
    }

    private var autoLabel: String {
        if let best = JavaManager.best(for: server.javaRequirement, in: server.runtimes) { return "Automatic (Java \(best.major))" }
        return "Automatic"
    }

    private func chooseJava() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Library/Java/JavaVirtualMachines")
        panel.message = "Choose a java program, usually in Contents/Home/bin."
        if panel.runModal() == .OK, let url = panel.url { server.profile.launch.javaPath = url.path }
    }

    private var flagsCard: some View {
        Card(title: "Flags", systemImage: "flag") {
            Picker("JVM flags", selection: $server.profile.launch.preset) {
                ForEach(FlagPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Hint(presetHint)
            if server.profile.launch.preset == .recommended {
                DisclosureGroup("Show the flags", isExpanded: $showFlags) {
                    Text((server.profile.software.recommendedFlags.isEmpty ? fallbackRecommendedFlags : server.profile.software.recommendedFlags).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(Juice.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
                .foregroundStyle(Juice.ink)
            }
            LabeledContent("Extra JVM arguments") {
                TextField("Extra JVM arguments", text: $server.profile.launch.extraJVMArgs, prompt: Text("-Dfoo=bar"))
                    .labelsHidden().textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
            LabeledContent("Server arguments") {
                TextField("Server arguments", text: $server.profile.launch.serverArgs, prompt: Text("--port 25566 --world-dir worlds"))
                    .labelsHidden().textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
            }
            Toggle("Hide Minecraft's own server window (nogui)", isOn: $server.profile.launch.noGUI)
            Hint("Leave this on: Leaf Juice is your console, and the extra window uses memory.")
        }
    }

    private var presetHint: String {
        switch server.profile.launch.preset {
        case .recommended: server.profile.software.recommendedFlags.isEmpty ? "Aikar's garbage collection flags, well tested for Minecraft." : "The flags Paper recommends for this exact version."
        case .none: "Only memory and your own arguments."
        case .custom: "Only memory and your own arguments, such as those imported from a start script."
        }
    }

    private var behaviourCard: some View {
        Card(title: "Behavior", systemImage: "gearshape") {
            Toggle("Restart automatically after a crash", isOn: $server.profile.launch.restartOnCrash)
            Hint("Pauses after 3 crashes in 10 minutes rather than looping.")
            Toggle("Keep this Mac awake while the server runs", isOn: $server.profile.launch.keepAwake)
            Toggle("Start this server when Leaf Juice opens", isOn: $server.profile.launch.startWithApp)
            Toggle("Keep a log of Java's pauses", isOn: $server.profile.launch.logGC)
            Hint("Costs almost nothing, and shows on the History page whether stutters come from memory.")
        }
    }

    private var commandCard: some View {
        Card(title: "Full command", systemImage: "terminal") {
            let command = LaunchCommand.display(java: server.resolvedJava()?.path ?? "java", server.profile.launch, software: server.profile.software, javaMajor: server.resolvedJava()?.major ?? 0)
            Text(command).font(.system(.caption, design: .monospaced)).foregroundStyle(Juice.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .buttonStyle(.juice)
            Hint("Leaf Juice holds nothing back: this is exactly what runs, and you could run it yourself.")
        }
    }
}
