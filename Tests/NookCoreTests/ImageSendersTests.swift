import Testing
@testable import NookCore

@Suite("Image senders")
struct ImageSendersTests {
    @Test func acceptsAddressesAndDomains() {
        #expect(ImageSenders.normalize(" Sam@Acme.com ") == "sam@acme.com")
        #expect(ImageSenders.normalize("Sam Rivera <sam@acme.com>") == "sam@acme.com")
        #expect(ImageSenders.normalize("acme.com") == "acme.com")
        #expect(ImageSenders.normalize("@acme.com") == "acme.com")
        #expect(ImageSenders.normalize("*.acme.com") == "acme.com")
        #expect(ImageSenders.normalize("acme") == nil)
        #expect(ImageSenders.normalize("a@b@c.com") == nil)
        #expect(ImageSenders.normalize("sam@") == nil)
        #expect(ImageSenders.normalize("") == nil)
    }

    @Test func matchesTheAddressOrTheDomainAndItsSubdomains() {
        let entries = ["acme.com", "sam@other.org"]
        #expect(ImageSenders.matches("news@acme.com", in: entries))
        #expect(ImageSenders.matches("News@Mail.Acme.com", in: entries))
        #expect(!ImageSenders.matches("x@notacme.com", in: entries))
        #expect(ImageSenders.matches("sam@other.org", in: entries))
        #expect(!ImageSenders.matches("kim@other.org", in: entries))
        #expect(!ImageSenders.matches("nobody", in: entries))
        #expect(ImageSenders.match("news@mail.acme.com", in: entries) == "acme.com")
    }

    @Test func keepsOneEntryPerLine() {
        var stored = ImageSenders.adding("Acme.com", to: "")
        stored = ImageSenders.adding("acme.com", to: stored)
        stored = ImageSenders.adding("bob@b.io", to: stored)
        stored = ImageSenders.adding("junk", to: stored)
        #expect(ImageSenders.parse(stored) == ["acme.com", "bob@b.io"])
        #expect(ImageSenders.parse(ImageSenders.removing("acme.com", from: stored)) == ["bob@b.io"])
    }
}
