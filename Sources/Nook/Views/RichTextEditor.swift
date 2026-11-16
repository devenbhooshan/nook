import AppKit
import NookCore
import SwiftUI

/// Edits a formatted draft: links, bold, italics and bullet lists, the things Nook sends as HTML.
/// Reads the draft's HTML, and writes clean HTML back on every change (no fonts or styles from the editor).
struct RichTextEditor: NSViewRepresentable {
    @Binding var html: String
    var focusOnAppear: Bool

    static let font = NSFont.systemFont(ofSize: 14.5)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1: TextKit 2 draws its own list markers over the ones in the text and hides the items.
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView(usingTextLayoutManager: false)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        text.isRichText = true
        text.allowsUndo = true
        text.drawsBackground = false
        text.importsGraphics = false
        text.isAutomaticLinkDetectionEnabled = true
        text.font = Self.font
        text.textContainerInset = NSSize(width: 0, height: 4)
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        text.typingAttributes = Self.baseAttributes
        text.delegate = context.coordinator
        context.coordinator.load(html, into: text)
        if focusOnAppear {
            DispatchQueue.main.async { text.window?.makeFirstResponder(text) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // A new version from outside (an assistant updated the draft): show it. Our own edits come back equal.
        if html != context.coordinator.lastHTML, let text = scroll.documentView as? NSTextView {
            context.coordinator.load(html, into: text)
        }
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        return [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastHTML: String?

        init(_ parent: RichTextEditor) { self.parent = parent }

        func load(_ html: String, into text: NSTextView) {
            lastHTML = html
            text.textStorage?.setAttributedString(RichTextHTML.attributed(fromHTML: html))
        }

        func textDidChange(_ notification: Notification) {
            guard let text = notification.object as? NSTextView, let storage = text.textStorage else { return }
            let html = RichTextHTML.html(from: storage)
            lastHTML = html
            parent.html = html
        }
    }
}

/// Between a draft's HTML and what the editor shows.
enum RichTextHTML {
    /// The HTML as text to edit, in Nook's font and colours, keeping bold, italics, links and lists.
    static func attributed(fromHTML html: String) -> NSAttributedString {
        let source = "<meta charset=\"utf-8\">" + html
        guard let imported = try? NSMutableAttributedString(
            data: Data(source.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        ) else { return NSAttributedString(string: RichText.plainText(fromHTML: html), attributes: RichTextEditor.baseAttributes) }
        // The importer ends with a line break of its own.
        while imported.string.hasSuffix("\n") { imported.deleteCharacters(in: NSRange(location: imported.length - 1, length: 1)) }

        let result = NSMutableAttributedString(string: imported.string, attributes: RichTextEditor.baseAttributes)
        let whole = NSRange(location: 0, length: imported.length)
        imported.enumerateAttributes(in: whole) { attributes, range, _ in
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits.intersection([.bold, .italic])
                if !traits.isEmpty {
                    let descriptor = RichTextEditor.font.fontDescriptor.withSymbolicTraits(traits)
                    result.addAttribute(.font, value: NSFont(descriptor: descriptor, size: RichTextEditor.font.pointSize) ?? RichTextEditor.font, range: range)
                }
            }
            if let link = attributes[.link] { result.addAttribute(.link, value: link, range: range) }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil {
                result.addAttribute(.underlineStyle, value: underline, range: range)
            }
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineSpacing = 5
                paragraph.textLists = style.textLists
                paragraph.headIndent = style.headIndent
                paragraph.firstLineHeadIndent = style.firstLineHeadIndent
                paragraph.tabStops = style.tabStops
                result.addAttribute(.paragraphStyle, value: paragraph, range: range)
            }
        }
        return result
    }

    /// Clean HTML for what's in the editor: a `<div>` per line, lists as lists, and only b, i, u and links inside.
    static func html(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        var out = ""
        var openList: String?
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let style = range.length > 0 ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil
            if let list = style?.textLists.first {
                let tag = list.isOrdered ? "ol" : "ul"
                if openList != tag {
                    if let openList { out += "</\(openList)>" }
                    out += "<\(tag)>"
                    openList = tag
                }
                // The list marker ("\t•\t") is drawn text, not part of the item.
                var itemRange = range
                let line = string.substring(with: range) as NSString
                let marker = line.range(of: "^\t[^\t]*\t", options: .regularExpression)
                if marker.location != NSNotFound {
                    itemRange.location += marker.length
                    itemRange.length -= marker.length
                }
                out += "<li>\(inline(text, in: itemRange))</li>"
            } else {
                if let list = openList {
                    out += "</\(list)>"
                    openList = nil
                }
                out += range.length == 0 ? "<div><br></div>" : "<div>\(inline(text, in: range))</div>"
            }
        }
        if let openList { out += "</\(openList)>" }
        return out
    }

    private static func inline(_ text: NSAttributedString, in range: NSRange) -> String {
        guard range.length > 0 else { return "<br>" }
        var out = ""
        text.enumerateAttributes(in: range) { attributes, run, _ in
            var piece = EmailHTML.escape((text.string as NSString).substring(with: run))
            let traits = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if (attributes[.underlineStyle] as? Int ?? 0) != 0, attributes[.link] == nil { piece = "<u>\(piece)</u>" }
            if traits.contains(.italic) { piece = "<i>\(piece)</i>" }
            if traits.contains(.bold) { piece = "<b>\(piece)</b>" }
            let link = (attributes[.link] as? URL)?.absoluteString ?? attributes[.link] as? String
            if let link { piece = "<a href=\"\(EmailHTML.escape(link))\">\(piece)</a>" }
            out += piece
        }
        return out
    }
}
