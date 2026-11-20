import dnssd
import Foundation

/// Looks up DNS TXT records. The app uses the system resolver; tests use a fake.
public protocol TXTResolver: Sendable {
    /// Each record's text, with its strings joined. Empty when there's no record or the lookup fails.
    func txt(_ name: String) async -> [String]
}

/// Brand logos for senders, from BIMI: a company publishes its logo's address in a DNS record on its mail domain,
/// `default._bimi.<domain>`. Off unless you turn it on, because looking a domain up and fetching its logo lets that
/// company see the request.
public enum BrandLogos {
    public static let enabledKey = "photos.brandLogos"

    /// The logo address in a BIMI record such as `v=BIMI1; l=https://example.com/logo.svg; a=…`. HTTPS only.
    static func logoURL(fromRecords records: [String]) -> URL? {
        for record in records {
            let fields = record.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.first?.lowercased() == "v=bimi1" else { continue }
            for field in fields where field.lowercased().hasPrefix("l=") {
                let value = field.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if let url = URL(string: value), url.scheme?.lowercased() == "https" { return url }
            }
        }
        return nil
    }

    /// The domain, then its parents down to two labels: `email.apple.com`, then `apple.com`.
    static func candidates(for domain: String) -> [String] {
        let labels = domain.lowercased().split(separator: ".")
        guard labels.count >= 2 else { return [] }
        return (0...(labels.count - 2)).map { labels[$0...].joined(separator: ".") }
    }

    /// Finds each domain's logo and downloads the ones that are new or changed, a batch at a time, so logos appear as
    /// they arrive. Then checks the Verified Mark Certificate of any domain whose certificate is new or changed
    /// (`VerifiedMarks`). `onBatch` gets each batch's domains with a new logo or a changed mark. Returns all of them.
    public static func refresh(
        domains: [String], store: AvatarStore, dns: TXTResolver = SystemDNS(timeout: 2),
        transport: HTTPTransport = AvatarStore.session, batchSize: Int = 16, now: Date = Date(),
        onBatch: @Sendable (Set<String>) async -> Void = { _ in }
    ) async -> Set<String> {
        var updated: Set<String> = []
        for start in stride(from: 0, to: domains.count, by: max(1, batchSize)) {
            let batch = Array(domains[start..<min(start + max(1, batchSize), domains.count)])
            let found = await withTaskGroup(of: (String, Record?).self, returning: [String: Record].self) { group in
                for domain in batch {
                    group.addTask { (domain, await record(for: domain, dns: dns)) }
                }
                var found: [String: Record] = [:]
                for await (domain, record) in group { if let record { found[domain] = record } }
                return found
            }
            let logos = Dictionary(uniqueKeysWithValues: found.map { (key(for: $0.key), $0.value.logo) })
            var changed = Set(await store.download(logos, transport: transport).map { String($0.dropFirst()) })
            changed.formUnion(await checkMarks(batch: batch, found: found, store: store, transport: transport, now: now))
            updated.formUnion(changed)
            if !changed.isEmpty { await onBatch(changed) }
        }
        return updated
    }

    /// A domain's BIMI record: its logo, its Verified Mark Certificate if it has one, and the domain it was found on
    /// (the sender's own domain or a parent), which is the name the certificate has to carry.
    struct Record: Sendable {
        var logo: URL
        var certificate: URL?
        var domain: String
    }

    /// The first BIMI record with a logo, for the domain or one of its parents.
    static func record(for domain: String, dns: TXTResolver) async -> Record? {
        for candidate in candidates(for: domain) {
            let records = await dns.txt("default._bimi.\(candidate)")
            if let logo = logoURL(fromRecords: records) {
                return Record(logo: logo, certificate: VerifiedMarks.certificateURL(fromRecords: records), domain: candidate)
            }
        }
        return nil
    }

    /// Updates the batch's verified marks, checking a certificate only when `VerifiedMark.needsCheck` says so; an
    /// expired one stops counting on its own (`AvatarStore.isVerified`). Returns the domains whose verified state changed.
    static func checkMarks(
        batch: [String], found: [String: Record], store: AvatarStore, transport: HTTPTransport, now: Date = Date()
    ) async -> Set<String> {
        await withTaskGroup(of: String?.self, returning: Set<String>.self) { group in
            for domain in batch {
                group.addTask {
                    guard let record = found[domain], let certificate = record.certificate,
                          let logo = store.image(for: key(for: domain)) else {
                        return store.setVerifiedMark(nil, for: domain, at: now) ? domain : nil
                    }
                    if let last = store.verifiedMark(for: domain), !last.needsCheck(of: certificate.absoluteString, at: now) { return nil }
                    var expires: Date?
                    if let (pem, response) = try? await transport.send(URLRequest(url: certificate)),
                       response.statusCode == 200, pem.count < 200_000 {
                        expires = VerifiedMarks.verify(pem: pem, domain: record.domain, logo: logo, at: now)
                    }
                    let mark = AvatarStore.VerifiedMark(certificate: certificate.absoluteString, expires: expires, checked: now)
                    return store.setVerifiedMark(mark, for: domain, at: now) ? domain : nil
                }
            }
            var changed: Set<String> = []
            for await domain in group { if let domain { changed.insert(domain) } }
            return changed
        }
    }

    /// Where a domain's logo is kept in the photo store, beside people's photos.
    public static func key(for domain: String) -> String {
        "@" + domain.lowercased()
    }

    public static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...].lowercased()
        return domain.contains(".") ? domain : nil
    }
}

/// TXT lookups through the system resolver (DNS-SD), so they follow the Mac's own DNS settings.
public struct SystemDNS: TXTResolver {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func txt(_ name: String) async -> [String] {
        await withCheckedContinuation { continuation in
            let query = Query(continuation: continuation)
            query.start(name: name, timeout: timeout)
        }
    }

    /// One lookup. Finishes once, on the first answer, an error, or the timeout.
    private final class Query: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String], Never>?
        private var ref: DNSServiceRef?
        private var records: [String] = []
        private static let queue = DispatchQueue(label: "nook.dns")

        init(continuation: CheckedContinuation<[String], Never>) {
            self.continuation = continuation
        }

        func start(name: String, timeout: TimeInterval) {
            let context = Unmanaged.passRetained(self).toOpaque()
            var ref: DNSServiceRef?
            let status = DNSServiceQueryRecord(
                &ref, 0, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
                { _, flags, _, error, _, _, _, length, data, _, context in
                    guard let context else { return }
                    let query = Unmanaged<Query>.fromOpaque(context).takeUnretainedValue()
                    if error == kDNSServiceErr_NoError, let data {
                        query.add(Query.strings(data.assumingMemoryBound(to: UInt8.self), length: Int(length)))
                    }
                    if error != kDNSServiceErr_NoError || flags & kDNSServiceFlagsMoreComing == 0 {
                        query.finish()
                    }
                },
                context
            )
            guard status == kDNSServiceErr_NoError, let ref else {
                Unmanaged<Query>.fromOpaque(context).release()
                return finish(releasing: false)
            }
            lock.withLock { self.ref = ref }
            DNSServiceSetDispatchQueue(ref, Self.queue)
            Self.queue.asyncAfter(deadline: .now() + timeout) { [self] in finish() }
        }

        private func add(_ text: String) {
            lock.withLock { records.append(text) }
        }

        private func finish(releasing: Bool = true) {
            let (continuation, ref, records) = lock.withLock { () -> (CheckedContinuation<[String], Never>?, DNSServiceRef?, [String]) in
                defer { self.continuation = nil; self.ref = nil }
                return (self.continuation, self.ref, self.records)
            }
            guard let continuation else { return }
            if let ref { DNSServiceRefDeallocate(ref) }
            if releasing { Unmanaged.passUnretained(self).release() }
            continuation.resume(returning: records)
        }

        /// A TXT record is a run of length-prefixed strings; BIMI records may be split across several.
        static func strings(_ bytes: UnsafePointer<UInt8>, length: Int) -> String {
            var text = ""
            var index = 0
            while index < length {
                let count = Int(bytes[index])
                index += 1
                guard index + count <= length else { break }
                text += String(decoding: UnsafeBufferPointer(start: bytes + index, count: count), as: UTF8.self)
                index += count
            }
            return text
        }
    }
}
