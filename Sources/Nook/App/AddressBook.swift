import Contacts
import NookCore

/// The Mac's Contacts, for recipient suggestions. macOS asks once; if you say no, suggestions come from mail alone.
enum AddressBook {
    static func entries() async -> [EmailAddress] {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            break
        case .notDetermined:
            guard (try? await store.requestAccess(for: .contacts)) == true else { return [] }
        default:
            return []
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey]
        let request = CNContactFetchRequest(keysToFetch: keys as [CNKeyDescriptor])
        var entries: [EmailAddress] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            let person = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let name = person.isEmpty ? contact.organizationName : person
            for email in contact.emailAddresses {
                entries.append(EmailAddress(name: name, email: email.value as String))
            }
        }
        return entries
    }
}
