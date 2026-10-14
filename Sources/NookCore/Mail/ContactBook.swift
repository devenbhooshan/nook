import Foundation

/// Someone you could write to, with how strongly to suggest them.
public struct Contact: Equatable, Hashable, Sendable {
    public var name: String
    public var email: String
    public var score: Double

    public init(name: String, email: String, score: Double) {
        self.name = name
        self.email = email
        self.score = score
    }

    public var address: EmailAddress { EmailAddress(name: name, email: email) }
}

/// What the mail store knows about the people you correspond with.
public struct ContactHistory: Sendable, Equatable {
    /// One entry per address that has written to you.
    public struct Sender: Sendable, Equatable {
        public var name: String
        public var email: String
        public var count: Int
        public var lastDate: Date

        public init(name: String, email: String, count: Int, lastDate: Date) {
            self.name = name
            self.email = email
            self.count = count
            self.lastDate = lastDate
        }
    }

    /// One entry per message you sent, with its raw To and Cc headers.
    public struct Sent: Sendable, Equatable {
        public var to: String
        public var cc: String
        public var date: Date

        public init(to: String, cc: String, date: Date) {
            self.to = to
            self.cc = cc
            self.date = date
        }
    }

    public var senders: [Sender]
    public var sent: [Sent]

    public init(senders: [Sender] = [], sent: [Sent] = []) {
        self.senders = senders
        self.sent = sent
    }
}

/// Recipient suggestions for the To and Cc fields, from past mail and the Mac's Contacts.
///
/// People you've written to rank far above people who've only written to you, and recent ones above old ones.
/// Automated senders (no-reply and the like) are left out unless you've written to them yourself.
public struct ContactBook: Sendable, Equatable {
    public private(set) var contacts: [Contact]
    /// Each contact's searchable words, worked out once rather than on every keystroke.
    private var words: [[String]]

    public init(contacts: [Contact] = []) {
        self.contacts = contacts.sorted { $0.score > $1.score }
        words = self.contacts.map(Self.searchableWords)
    }

    /// - Parameters:
    ///   - history: Senders and sent mail from the store.
    ///   - addressBook: Entries from the Mac's Contacts, which fill in names and are always suggested.
    ///   - own: Your own addresses, which are never suggested.
    public init(history: ContactHistory, addressBook: [EmailAddress] = [], own: Set<String> = [], now: Date = Date()) {
        var entries: [String: Contact] = [:]
        var written: Set<String> = []
        let own = Set(own.map { $0.lowercased() })

        func add(_ name: String, _ email: String, weight: Double, date: Date?) {
            let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = email.lowercased()
            guard Self.looksLikeAddress(key), !own.contains(key) else { return }
            let name = name == email ? "" : name.trimmingCharacters(in: .whitespacesAndNewlines)
            let points = weight * (date.map { Self.recency($0, now: now) } ?? 1)
            if var existing = entries[key] {
                existing.score += points
                if existing.name.isEmpty { existing.name = name }
                entries[key] = existing
            } else {
                entries[key] = Contact(name: name, email: email, score: points)
            }
        }

        for message in history.sent {
            for address in Addresses.parseList(message.to) + Addresses.parseList(message.cc) {
                written.insert(address.email.lowercased())
                add(address.name, address.email, weight: Self.sentWeight, date: message.date)
            }
        }
        for sender in history.senders where written.contains(sender.email.lowercased()) || !Self.isAutomated(sender.email) {
            add(sender.name, sender.email, weight: Double(sender.count), date: sender.lastDate)
        }
        // Your Contacts' names are the ones you chose, so they win.
        for entry in addressBook {
            let key = entry.email.lowercased()
            add(entry.name, entry.email, weight: Self.addressBookWeight, date: nil)
            if !entry.name.isEmpty, entry.name != entry.email { entries[key]?.name = entry.name }
        }
        self.init(contacts: Array(entries.values))
    }

    /// Suggestions for what's been typed so far, best first.
    ///
    /// Every word typed has to start a word of the name or the address: "jan" finds Jane Doe and jan@example.com,
    /// "doe ja" finds Jane Doe, "acme" finds anyone at acme.com.
    public func suggestions(for query: String, excluding: Set<String> = [], limit: Int = 6) -> [Contact] {
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" || $0 == "<" || $0 == "\"" })
        guard !words.isEmpty else { return [] }
        let excluded = Set(excluding.map { $0.lowercased() })
        var matches: [Contact] = []
        for (contact, parts) in zip(contacts, self.words) where !excluded.contains(contact.email.lowercased()) {
            guard words.allSatisfy({ word in parts.contains { $0.hasPrefix(word) } }) else { continue }
            matches.append(contact)
            if matches.count == limit { break }
        }
        return matches
    }

    // MARK: Scoring

    static let sentWeight = 10.0
    static let addressBookWeight = 2.0

    /// Halves a contact's weight every 90 days.
    static func recency(_ date: Date, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        return pow(0.5, days / 90)
    }

    static func looksLikeAddress(_ email: String) -> Bool {
        guard let at = email.firstIndex(of: "@"), at != email.startIndex else { return false }
        let domain = email[email.index(after: at)...]
        return domain.contains(".") && !email.contains(where: \.isWhitespace)
    }

    static func isAutomated(_ email: String) -> Bool {
        let local = email.lowercased().split(separator: "@").first.map(String.init) ?? ""
        let markers = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "mailer-daemon", "postmaster",
                       "notification", "bounce", "alerts", "newsletter", "updates"]
        return markers.contains { local.contains($0) }
    }

    static func searchableWords(_ contact: Contact) -> [String] {
        let email = contact.email.lowercased()
        let separators: (Character) -> Bool = { $0.isWhitespace || ".,_-+@'\"()".contains($0) }
        var words = [email]
        words += contact.name.lowercased().split(whereSeparator: separators).map(String.init)
        guard let at = email.lastIndex(of: "@") else { return words }
        words += email[..<at].split(whereSeparator: separators).map(String.init)
        // The domain and its parts, but not ".com" or ".io": typing "c" shouldn't match everyone.
        let domain = email[email.index(after: at)...]
        words.append(String(domain))
        words += domain.split(separator: ".").dropLast().map(String.init)
        return words
    }
}
