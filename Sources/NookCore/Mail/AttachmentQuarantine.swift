import Foundation

/// Marks a file as downloaded, the way a browser does, so Gatekeeper checks it before it can run.
///
/// Nook writes attachments itself, so macOS has no idea they came from a stranger's email. Without
/// this, double-clicking an emailed `.terminal` file or a zipped app runs it with no warning.
/// `LSFileQuarantineEnabled` in Info.plist doesn't do this: files written with it on came out unflagged.
public enum AttachmentQuarantine {
    public static func mark(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineAgentName": "Nook",
            "LSQuarantineType": "LSQuarantineTypeOtherDownload",
        ]
        try url.setResourceValues(values)
    }
}
