import CoreImage
import Foundation

/// A printable invite (D187): the server's name, where to go, the code, when it runs out, and a QR code whose link
/// carries the code after `#`, so the code never reaches a server's logs. The data comes from WelcomeWagon's answer
/// to `invite create`. Nothing secret beyond the invite's own one-time code is on it.
public struct InviteTicket: Equatable, Sendable, Identifiable {
    public var id: String { link }
    public let server: String
    /// Where to go, exactly as WelcomeWagon gives it, such as https://join.example.test/.
    public let join: String
    /// `join` + "#" + the code: what the QR code opens.
    public let link: String
    public let code: String
    public let expires: Date

    /// WelcomeWagon's `ticket` object, before the code is put in.
    public struct Wire: Decodable, Sendable {
        public let server: String?
        public let join: String?
        public let link: String?
        public let expires: Double?
    }

    /// Builds a ticket, or nil when anything is off. Fails closed: no ticket is better than one that sends someone
    /// somewhere unexpected.
    public static func make(_ wire: Wire?, code: String) -> InviteTicket? {
        guard let wire, let join = wire.join?.trimmingCharacters(in: .whitespaces), let template = wire.link, let expires = wire.expires else { return nil }
        // Only a plain https address: no user name, password, query or fragment of its own.
        guard let url = URL(string: join), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, !join.contains("#") else { return nil }
        // The link must be exactly the join address, "#", and the code. Nothing else may be added.
        guard template == join + "#{code}" else { return nil }
        // WelcomeWagon's codes are short letters and digits. Anything else isn't put into a link.
        guard (4...16).contains(code.count), code.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        let server = String((wire.server ?? "").filter { !$0.isNewline && !($0.asciiValue.map { $0 < 0x20 } ?? false) }.prefix(60))
            .trimmingCharacters(in: .whitespaces)
        return InviteTicket(server: server.isEmpty ? host : server, join: join, link: join + "#" + code, code: code,
                            expires: Date(timeIntervalSince1970: expires))
    }

    /// The code in groups of three, as it's easiest to read out and type: "K7Q 2MX".
    public var spokenCode: String {
        stride(from: 0, to: code.count, by: 3).map { i in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start..<code.index(start, offsetBy: min(3, code.count - i))])
        }.joined(separator: " ")
    }

    /// The whole ticket as plain text, for screen readers, copying, or a ticket that can't be printed.
    public func text(dateStyle: (Date) -> String = { $0.formatted(date: .long, time: .shortened) }) -> String {
        """
        Your invite to \(server)
        1. Go to \(join)
        2. Type the code \(spokenCode) and press Continue.
        Or scan the QR code, which fills the code in for you.
        Works once, until \(dateStyle(expires)).
        """
    }

    /// The QR code as an image, `scale` pixels per module, with the standard quiet zone. Medium error correction.
    public func qrCode(scale: Int = 8) -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(link.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
