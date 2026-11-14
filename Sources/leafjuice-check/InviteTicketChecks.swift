import CoreImage
import Foundation
import LeafJuiceCore

/// Printed invite tickets (D187): what WelcomeWagon's ticket may say, the QR code, and the text version.
@MainActor func inviteTicketChecks() {
    section("Invite tickets")
    func wire(server: String? = "Made-up Realm", join: String? = "https://join.example.test/", link: String? = "https://join.example.test/#{code}", expires: Double? = 4_000_000_000) -> InviteTicket.Wire {
        try! JSONDecoder().decode(InviteTicket.Wire.self, from: JSONSerialization.data(withJSONObject: ["server": server as Any, "join": join as Any, "link": link as Any, "expires": expires as Any].compactMapValues { $0 is NSNull ? nil : $0 }))
    }
    let t = InviteTicket.make(wire(), code: "QW3RTY")
    equal(t?.link, "https://join.example.test/#QW3RTY", "the code goes after #, so it never reaches a server's logs")
    equal(t?.expires, Date(timeIntervalSince1970: 4_000_000_000), "the expiry is WelcomeWagon's")
    equal(t?.spokenCode, "QW3 RTY", "the code reads in threes")
    equal(InviteTicket.make(wire(join: "https://example.test/join/", link: "https://example.test/join/#{code}"), code: "QW3RTY")?.link,
          "https://example.test/join/#QW3RTY", "a join address under a path is used exactly as given")
    check(InviteTicket.make(nil, code: "QW3RTY") == nil, "no ticket from WelcomeWagon: none to print")
    for (label, w) in [("plain http", wire(join: "http://join.example.test/", link: "http://join.example.test/#{code}")),
                       ("a user name in the address", wire(join: "https://kid@join.example.test/", link: "https://kid@join.example.test/#{code}")),
                       ("a query", wire(join: "https://join.example.test/?a=1", link: "https://join.example.test/?a=1#{code}")),
                       ("a link to another site", wire(link: "https://elsewhere.example.test/#{code}")),
                       ("a link that adds a query", wire(link: "https://join.example.test/?x=1#{code}")),
                       ("a link with the code twice", wire(link: "https://join.example.test/#{code}{code}")),
                       ("a link with no code", wire(link: "https://join.example.test/")),
                       ("no join address", wire(join: nil)),
                       ("no expiry", wire(expires: nil)),
                       ("a join address that isn't one", wire(join: "not a url", link: "not a url#{code}"))] {
        check(InviteTicket.make(w, code: "QW3RTY") == nil, "refused: \(label)")
    }
    for bad in ["QW3", "QW3RTY<script>", "QW3 RTY", "QW3RTY#x", "ÄBCDEF"] {
        check(InviteTicket.make(wire(), code: bad) == nil, "a code that isn't plain letters and digits isn't put in a link: \(bad)")
    }
    equal(InviteTicket.make(wire(server: "Made-up\nRealm\u{0007}"), code: "QW3RTY")?.server, "Made-upRealm", "line breaks and control characters are taken out of the name")
    equal(InviteTicket.make(wire(server: ""), code: "QW3RTY")?.server, "join.example.test", "no name: the site's own name")
    // The QR code really opens the link, read back with macOS's own reader.
    if let t, let image = t.qrCode(scale: 8),
       let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) {
        let found = detector.features(in: CIImage(cgImage: image)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        equal(found, [t.link], "the QR code reads back as the link, code and all")
    } else { check(false, "a QR code was made and read") }
    let text = t?.text { _ in "a made-up date" } ?? ""
    check(text.contains("https://join.example.test/") && text.contains("QW3 RTY") && text.contains("a made-up date") && text.contains("Made-up Realm"), "the text version has every step, for screen readers and copying")
    check(!text.contains("#QW3RTY"), "and spells the code out rather than burying it in the link")
}
