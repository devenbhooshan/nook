import Foundation
import Testing
@testable import NookCore

@Suite("Verified marks")
struct VerifiedMarksTests {
    let pem = Data(VerifiedMarkFixtures.esriPEM.utf8)
    let logo = VerifiedMarkFixtures.esriLogo
    /// The day these fixtures were fetched; esri's certificate is valid then.
    let today = ISO8601DateFormatter().date(from: "2026-11-20T00:00:00Z")!

    @Test func esrisRealCertificateIsAValidMark() throws {
        let expires = try #require(VerifiedMarks.verify(pem: pem, domain: "esri.com", logo: logo, at: today))
        #expect(expires == ISO8601DateFormatter().date(from: "2027-08-30T23:59:59Z"))
    }

    @Test func aMarkOnlyCountsForItsDomainLogoRootsAndDates() {
        // Another domain, or the right domain with a different logo.
        #expect(VerifiedMarks.verify(pem: pem, domain: "esri.org", logo: logo, at: today) == nil)
        #expect(VerifiedMarks.verify(pem: pem, domain: "esri.com", logo: Data("<svg/>".utf8), at: today) == nil)
        // A chain that doesn't lead to a trusted root: DigiCert's isn't among these.
        let others = [VerifiedMarkRoots.globalSign, VerifiedMarkRoots.sslCom].compactMap { Data(base64Encoded: $0) }
        #expect(VerifiedMarks.verify(pem: pem, domain: "esri.com", logo: logo, at: today, roots: others) == nil)
        // After it expires.
        #expect(VerifiedMarks.verify(pem: pem, domain: "esri.com", logo: logo, at: today.addingTimeInterval(365 * 86_400)) == nil)
        // Not a certificate at all.
        #expect(VerifiedMarks.verify(pem: Data("nope".utf8), domain: "esri.com", logo: logo, at: today) == nil)
    }

    @Test func aRecordOnASubdomainMayUseTheOrganisationsCertificate() {
        // Shopify publishes its record on email.shopify.com with a certificate for shopify.com.
        #expect(VerifiedMarks.verify(pem: pem, domain: "news.esri.com", logo: logo, at: today) != nil)
        #expect(VerifiedMarks.verify(pem: pem, domain: "esri.com.evil.example", logo: logo, at: today) == nil)
    }

    @Test func onlyRegisteredMarksGetTheCheck() throws {
        #expect(VerifiedMarks.markType(in: try #require(VerifiedMarks.certificates(inPEM: pem).first)) == "Registered Mark")
        func subject(_ type: String) -> Data {
            VerifiedMarks.markTypeAttribute + Data([0x0C, UInt8(type.utf8.count)] + Array(type.utf8))
        }
        #expect(VerifiedMarks.markType(in: subject("Prior Use Mark")) == "Prior Use Mark")
        #expect(!VerifiedMarks.verifiedMarkTypes.contains("Prior Use Mark"))
        #expect(!VerifiedMarks.verifiedMarkTypes.contains("Modified Registered Mark"))
        #expect(VerifiedMarks.verifiedMarkTypes.contains("Government Mark"))
        #expect(VerifiedMarks.markType(in: Data([0x30, 0x00])) == nil)
    }

    @Test func aChainWithoutItsRootStillVerifiesAgainstTheBundledOne() {
        // Like Entrust's chains: leaf and intermediate only.
        let withoutRoot = VerifiedMarks.certificates(inPEM: pem).prefix(2).map {
            "-----BEGIN CERTIFICATE-----\n\($0.base64EncodedString(options: .lineLength64Characters))\n-----END CERTIFICATE-----\n"
        }.joined()
        #expect(VerifiedMarks.verify(pem: Data(withoutRoot.utf8), domain: "esri.com", logo: logo, at: today) != nil)
    }

    @Test func readsTheCertificateFromABIMIRecord() {
        #expect(VerifiedMarks.certificateURL(fromRecords: [
            "v=BIMI1;l=https://vmc.digicert.com/a.svg;a=https://vmc.digicert.com/a.pem",
        ]) == URL(string: "https://vmc.digicert.com/a.pem"))
        #expect(VerifiedMarks.certificateURL(fromRecords: ["v=BIMI1; l=https://x.com/l.svg"]) == nil)
        #expect(VerifiedMarks.certificateURL(fromRecords: ["v=BIMI1; l=https://x.com/l.svg; a=http://x.com/a.pem"]) == nil)
    }

    // MARK: DMARC

    /// The header Gmail added to Greg Dermond's reaction (19 Nov 2026).
    static let gmailResults = """
    mx.google.com;
           arc=pass (i=1 spf=pass spfdomain=esri.com dkim=pass dkdomain=esri.com dmarc=pass fromdomain=esri.com);
           dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=esri.com
    """

    @Test(arguments: [
        ([("Authentication-Results", gmailResults)], "gdermond@esri.com", true),
        // Gmail's header comes first; one further down was written before Gmail and proves nothing.
        ([("Authentication-Results", "mx.google.com; dmarc=fail (p=REJECT) header.from=esri.com"),
          ("Authentication-Results", gmailResults)], "gdermond@esri.com", false),
        ([("Authentication-Results", "mx.microsoft.com 1; dmarc=pass action=none header.from=esri.com"),
          ("Authentication-Results", gmailResults)], "gdermond@esri.com", false),
        // Passing a policy that lets failures through isn't enough for BIMI.
        ([("Authentication-Results", "mx.google.com; dmarc=pass (p=NONE sp=NONE dis=NONE) header.from=x.com")], "a@x.com", false),
        // A different From domain, or no results at all.
        ([("Authentication-Results", gmailResults)], "gdermond@other.com", false),
        ([], "gdermond@esri.com", false),
        // A subdomain falls under the subdomain policy.
        ([("Authentication-Results", "mx.google.com; dmarc=pass (p=REJECT sp=NONE dis=NONE) header.from=news.x.com")], "a@news.x.com", false),
        ([("Authentication-Results", "mx.google.com; dmarc=pass (p=REJECT sp=NONE dis=NONE) header.from=x.com")], "a@x.com", true),
        ([("Authentication-Results", "mx.google.com; dmarc=pass (p=QUARANTINE sp=QUARANTINE dis=NONE) header.from=news.x.com")], "a@news.x.com", true),
    ] as [([(String, String)], String, Bool)])
    func readsGmailsDMARCResult(headers: [(String, String)], from: String, expected: Bool) {
        #expect(VerifiedMarks.passedDMARC(headers: headers.map { (name: $0.0, value: $0.1) }, fromEmail: from) == expected)
    }

    @Test func theDMARCResultIsStoredAndOlderMailIsFoundToFillIn() throws {
        let repo = try makeRepository()
        try repo.addAccount(email: "me@example.com", name: "Me")
        var checked = MailMessage.fixture(id: "1", thread: "T", from: "gdermond@esri.com")
        checked.passedDMARC = true
        var failed = MailMessage.fixture(id: "2", thread: "T", from: "gdermond@esri.com")
        failed.passedDMARC = false
        let older = MailMessage.fixture(id: "3", thread: "T", from: "gdermond@esri.com")
        try repo.upsert([checked, failed, older])

        #expect(repo.message(account: "me@example.com", id: "1")?.passedDMARC == true)
        #expect(repo.message(account: "me@example.com", id: "2")?.passedDMARC == false)
        #expect(repo.message(account: "me@example.com", id: "3")?.passedDMARC == nil)
        #expect(repo.messagesMissingDMARC(account: "me@example.com", threadId: "T").map(\.id) == ["3"])
    }

    // MARK: Refresh

    @Test func brandLogoRefreshChecksTheMarkOnceAndRemembersIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nook-marks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AvatarStore(directory: directory)
        let dns = BrandLogosTests.FakeDNS(records: [
            "default._bimi.esri.com": ["v=BIMI1;l=https://vmc.digicert.com/esri.svg;a=https://vmc.digicert.com/esri.pem"],
        ])
        let server = PhotoServer([
            "https://vmc.digicert.com/esri.svg": [.init(200, String(decoding: logo, as: UTF8.self))],
            // Only one answer: a second download of the certificate would fail the test below.
            "https://vmc.digicert.com/esri.pem": [.init(200, VerifiedMarkFixtures.esriPEM)],
        ])

        let updated = await BrandLogos.refresh(domains: ["esri.com"], store: store, dns: dns, transport: server, now: today)
        #expect(updated == ["esri.com"])
        #expect(store.isVerified("esri.com", at: today))

        // The next refresh finds the same certificate and leaves it.
        let again = await BrandLogos.refresh(domains: ["esri.com"], store: store, dns: dns, transport: server, now: today)
        #expect(again.isEmpty)
        #expect(AvatarStore(directory: directory).isVerified("esri.com", at: today))

        // A domain that drops its record loses its mark.
        let gone = await BrandLogos.refresh(domains: ["esri.com"], store: store, dns: BrandLogosTests.FakeDNS(records: [:]), transport: server, now: today)
        #expect(gone == ["esri.com"])
        #expect(!store.isVerified("esri.com", at: today))
    }

    @Test func aFailedOrExpiredMarkIsRetriedWeeklyAndAChangedOneAtOnce() {
        let failed = AvatarStore.VerifiedMark(certificate: "https://x/a.pem", expires: nil, checked: today)
        #expect(!failed.needsCheck(of: "https://x/a.pem", at: today.addingTimeInterval(86_400)))
        #expect(failed.needsCheck(of: "https://x/a.pem", at: today.addingTimeInterval(8 * 86_400)))
        #expect(failed.needsCheck(of: "https://x/b.pem", at: today))
        let valid = AvatarStore.VerifiedMark(certificate: "https://x/a.pem", expires: today.addingTimeInterval(30 * 86_400), checked: today)
        #expect(!valid.needsCheck(of: "https://x/a.pem", at: today.addingTimeInterval(20 * 86_400)))
    }
}
