import AppKit
import NookCore

/// Profile photos for avatars, read from the files on disk and kept decoded while Nook runs.
/// Views never load photos from the network.
@MainActor
final class AvatarImages: ObservableObject {
    static let shared = AvatarImages()

    private var store: AvatarStore?
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    /// Changes when photos arrive, so avatars on screen pick them up.
    @Published private(set) var version = 0

    /// Points at the photo files, and forgets what it knew about addresses that just got a new photo.
    func loaded(_ store: AvatarStore, updated: Set<String>) {
        let first = self.store == nil
        self.store = store
        for email in updated {
            images[email] = nil
            missing.remove(email)
        }
        if first || !updated.isEmpty { version += 1 }
    }

    func image(for email: String) -> NSImage? {
        let key = email.lowercased()
        if let image = images[key] { return image }
        guard let store, !missing.contains(key) else { return nil }
        guard let data = store.image(for: key), let image = NSImage(data: data), Self.isRealImage(image) else {
            missing.insert(key)
            return nil
        }
        images[key] = image
        return image
    }

    /// Something that decodes to actual pixels, not an empty or 1×1 placeholder.
    static func isRealImage(_ image: NSImage) -> Bool {
        guard image.isValid, image.size.width >= 8, image.size.height >= 8 else { return false }
        return image.representations.contains { $0.pixelsWide >= 8 && $0.pixelsHigh >= 8 }
    }
}
