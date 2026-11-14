import AppKit
import LeafJuiceCore
import SwiftUI

/// The printed invite: black on white whatever the app's appearance, big type, the code in groups of three, and a QR
/// code that fills the code in. VoiceOver reads it as one block of plain steps.
struct InviteTicketView: View {
    let ticket: InviteTicket
    static let size = CGSize(width: 420, height: 560)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your invite to").font(.system(size: 15, weight: .medium, design: .rounded))
            Text(ticket.server).font(.system(size: 26, weight: .bold, design: .rounded)).lineLimit(2).minimumScaleFactor(0.6)
            HStack(alignment: .top, spacing: 16) {
                if let qr = ticket.qrCode(scale: 6) {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().frame(width: 150, height: 150)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan to open the page with your code filled in.").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Text("Or go to").font(.system(size: 13))
                    Text(ticket.join).font(.system(size: 15, weight: .semibold, design: .monospaced)).lineLimit(3).minimumScaleFactor(0.7)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Your code").font(.system(size: 13, weight: .medium))
                Text(ticket.spokenCode).font(.system(size: 40, weight: .bold, design: .monospaced))
            }
            Text("Type the code on that page and press Continue.").font(.system(size: 14))
            Text("Works once, until \(ticket.expires.formatted(date: .long, time: .shortened)).").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 0)
            Text("Keep this to yourself: anyone with the code can use it first.").font(.system(size: 12))
        }
        .foregroundStyle(Color.black)
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Color.white)
        .overlay { Rectangle().strokeBorder(Color.black, style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
        .environment(\.colorScheme, .light)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ticket.text())
    }
}

/// Shows the ticket, with Print and Save as PDF. Nothing is kept: the ticket exists only while this is open.
struct InviteTicketSheet: View {
    let ticket: InviteTicket
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 14) {
            InviteTicketView(ticket: ticket)
            if let problem { Text(problem).foregroundStyle(Juice.danger).font(.callout) }
            HStack {
                Button("Copy as Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ticket.text(), forType: .string)
                }
                .buttonStyle(.juice)
                Button("Save as PDF…", action: savePDF).buttonStyle(.juice)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.juice)
                Button("Print…", action: print).keyboardShortcut(.defaultAction).buttonStyle(.juicePrimary)
            }
        }
        .padding(20)
    }

    @MainActor private func pdf() -> Data? {
        let renderer = ImageRenderer(content: InviteTicketView(ticket: ticket))
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: InviteTicketView.size)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle as String: "Invite to \(ticket.server)"] as CFDictionary) else { return nil }
        renderer.render { _, draw in
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A made-up ticket drawn to a PNG, to check the layout. Only used by LEAFJUICE_SAMPLE_TICKET.
    @MainActor static func writeSample(to url: URL) {
        let wire = try? JSONDecoder().decode(InviteTicket.Wire.self, from: Data(#"{"server":"Made-up Realm","join":"https://join.example.test/","link":"https://join.example.test/#{code}","expires":1795000000}"#.utf8))
        guard let ticket = InviteTicket.make(wire, code: "QW3RTY") else { return }
        let renderer = ImageRenderer(content: InviteTicketView(ticket: ticket))
        renderer.scale = 2
        guard let image = renderer.cgImage, let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    private func savePDF() {
        guard let data = pdf() else { problem = "The PDF couldn't be made."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Invite to \(ticket.server).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url); problem = nil } catch { problem = error.localizedDescription }
    }

    private func print() {
        let view = NSHostingView(rootView: InviteTicketView(ticket: ticket))
        view.frame = CGRect(origin: .zero, size: InviteTicketView.size)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = "Invite to \(ticket.server)"
        operation.run()
    }
}
