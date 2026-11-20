import Foundation
import Security

/// Verified Mark Certificates (VMCs): a certificate authority's confirmation that a company owns the logo it publishes
/// with BIMI. Gmail shows a blue check for a sender whose logo has one and whose email passed DMARC; Nook does the same.
///
/// A mark counts as verified when its chain leads to one of `VerifiedMarkRoots`, it's valid today, it's issued for
/// brand indicators (BIMI's extended key usage), it names the domain, and the logo inside it is the logo the domain
/// publishes. Revocation isn't checked.
public enum VerifiedMarks {
    /// The certificate address in a BIMI record such as `v=BIMI1; l=…; a=https://example.com/vmc.pem`. HTTPS only.
    static func certificateURL(fromRecords records: [String]) -> URL? {
        for record in records {
            let fields = record.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.first?.lowercased() == "v=bimi1" else { continue }
            for field in fields where field.lowercased().hasPrefix("a=") {
                let value = field.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value), url.scheme?.lowercased() == "https" { return url }
            }
        }
        return nil
    }

    /// When the mark for `domain` stops being valid, or nil when it isn't a valid mark for this domain and logo.
    /// `roots` defaults to `VerifiedMarkRoots`.
    public static func verify(pem: Data, domain: String, logo: Data, at date: Date = Date(), roots: [Data]? = nil) -> Date? {
        let ders = certificates(inPEM: pem)
        guard let leafDER = ders.first else { return nil }
        let certificates = ders.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        let rootDERs = roots ?? VerifiedMarkRoots.all.compactMap { Data(base64Encoded: $0) }
        let anchors = rootDERs.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard certificates.count == ders.count, !anchors.isEmpty else { return nil }

        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateBasicX509(), &trust) == errSecSuccess,
              let trust else { return nil }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, date as CFDate)
        SecTrustSetNetworkFetchAllowed(trust, false)
        guard SecTrustEvaluateWithError(trust, nil) else { return nil }

        // The certificate may name the record's domain or, as BIMI allows, its organisational domain: a record on
        // email.shopify.com has a certificate for shopify.com.
        let names = [domain] + BrandLogos.candidates(for: domain).dropFirst()
        guard leafDER.range(of: brandIndicatorUsage) != nil,
              names.contains(where: { leafDER.range(of: dnsName($0)) != nil }),
              let type = markType(in: leafDER), verifiedMarkTypes.contains(type),
              let embedded = embeddedLogo(in: leafDER), embedded == logo,
              let leaf = certificates.first else { return nil }
        return notAfter(leaf)
    }

    /// `id-kp-BrandIndicatorforMessageIdentification` (1.3.6.1.5.5.7.3.31) as it appears in the certificate (DER).
    static let brandIndicatorUsage = Data([0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x1F])

    /// The subject's mark type attribute (1.3.6.1.4.1.53087.1.13), as it appears in the certificate (DER).
    static let markTypeAttribute = Data([0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x83, 0x9E, 0x5F, 0x01, 0x0D])

    /// The mark types of a Verified Mark Certificate. A Common Mark Certificate ("Prior Use Mark", "Modified
    /// Registered Mark") shows the logo but, as in Gmail, no check.
    static let verifiedMarkTypes: Set<String> = ["Registered Mark", "Government Mark"]

    /// The subject's mark type, such as "Registered Mark": the string right after the attribute's identifier.
    static func markType(in der: Data) -> String? {
        guard let range = der.range(of: markTypeAttribute) else { return nil }
        let bytes = [UInt8](der)
        let tag = range.upperBound - der.startIndex
        // A UTF8String or PrintableString, short enough for a one-byte length.
        guard tag + 2 <= bytes.count, [0x0C, 0x13].contains(bytes[tag]), bytes[tag + 1] < 0x80,
              tag + 2 + Int(bytes[tag + 1]) <= bytes.count else { return nil }
        return String(decoding: bytes[(tag + 2)..<(tag + 2 + Int(bytes[tag + 1]))], as: UTF8.self)
    }

    /// A subject alternative name of type dNSName (context tag 2), as it appears in the certificate.
    static func dnsName(_ domain: String) -> Data {
        let bytes = Array(domain.lowercased().utf8)
        return Data([0x82, UInt8(truncatingIfNeeded: bytes.count)] + bytes)
    }

    /// Each certificate in a PEM file, as DER.
    static func certificates(inPEM pem: Data) -> [Data] {
        let text = String(decoding: pem, as: UTF8.self)
        var result: [Data] = []
        var rest = text[...]
        while let begin = rest.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = rest.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<rest.endIndex) {
            let body = rest[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
            if let der = Data(base64Encoded: String(body)) { result.append(der) }
            rest = rest[end.upperBound...]
        }
        return result
    }

    /// The SVG in the certificate's logotype extension: a `data:` address holding the gzipped logo. The address is a
    /// DER IA5String, so its length comes from the tag and length bytes in front of it; the bytes after it can be
    /// letters too, so scanning for the end of the base64 would run on into the rest of the certificate.
    static func embeddedLogo(in der: Data) -> Data? {
        let prefix = Data("data:image/svg+xml;base64,".utf8)
        guard let range = der.range(of: prefix) else { return nil }
        let bytes = [UInt8](der)
        let start = range.lowerBound - der.startIndex
        var length: Int?
        // Short form (one length byte), then long forms with one to three length bytes after 0x81…0x83.
        if start >= 2, bytes[start - 2] == 0x16, bytes[start - 1] < 0x80 {
            length = Int(bytes[start - 1])
        } else {
            for count in 1...3 where start >= count + 2 && bytes[start - count - 2] == 0x16 && bytes[start - count - 1] == 0x80 + UInt8(count) {
                length = bytes[(start - count)..<start].reduce(0) { $0 << 8 | Int($1) }
            }
        }
        guard let length, length > prefix.count, start + length <= bytes.count else { return nil }
        let base64 = Data(bytes[(start + prefix.count)..<(start + length)])
        guard let gzipped = Data(base64Encoded: base64) else { return nil }
        return gunzip(gzipped)
    }

    /// Unpacks gzip (RFC 1952): skips the header, then inflates the raw DEFLATE data that follows.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + Int(bytes[index]) + Int(bytes[index + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index < bytes.count - 8 else { return nil }
        let deflated = Data(bytes[index..<(bytes.count - 8)])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }

    /// The certificate's expiry date.
    static func notAfter(_ certificate: SecCertificate) -> Date? {
        let key = kSecOIDX509V1ValidityNotAfter
        guard let values = SecCertificateCopyValues(certificate, [key] as CFArray, nil) as? [CFString: Any],
              let entry = values[key] as? [CFString: Any],
              let seconds = entry[kSecPropertyKeyValue] as? NSNumber else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.doubleValue)
    }

    /// Whether Gmail found that this email passed DMARC for its sender, under a policy that rejects or quarantines
    /// mail that fails (BIMI's requirement). Reads Gmail's own `Authentication-Results`, the first one in the
    /// headers: any further down were written before the message reached Gmail and prove nothing.
    public static func passedDMARC(headers: [(name: String, value: String)], fromEmail: String) -> Bool {
        guard let results = headers.first(where: { $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame })?.value
        else { return false }
        let text = results.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
        let parts = text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.first?.lowercased() == "mx.google.com",
              let dmarc = parts.dropFirst().first(where: { $0.lowercased().hasPrefix("dmarc=") }),
              dmarc.lowercased().hasPrefix("dmarc=pass") else { return false }
        let lowered = dmarc.lowercased()
        func policy(_ name: String) -> String? {
            guard let range = lowered.range(of: #"(?<![a-z])\#(name)=([a-z]+)"#, options: .regularExpression) else { return nil }
            return String(lowered[range].split(separator: "=").last ?? "")
        }
        let enforced: Set<String> = ["quarantine", "reject"]
        guard let p = policy("p"), enforced.contains(p),
              let range = lowered.range(of: #"header\.from=[a-z0-9.-]+"#, options: .regularExpression),
              let headerFrom = lowered[range].split(separator: "=").last.map(String.init),
              let domain = BrandLogos.domain(of: fromEmail), headerFrom == domain else { return false }
        // Mail from a subdomain (news.example.com) falls under the subdomain policy, when there is one.
        if domain.split(separator: ".").count > 2, let sp = policy("sp"), !enforced.contains(sp) { return false }
        return true
    }
}
