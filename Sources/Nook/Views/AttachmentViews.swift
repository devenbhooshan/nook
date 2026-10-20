import AppKit
import NookCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// The files under a message: a card each, with a preview for images and PDFs.
struct AttachmentStrip: View {
    @EnvironmentObject private var store: AppStore
    let message: MailMessage

    private var refs: [AttachmentRef] {
        message.listedAttachments.map { AttachmentRef(attachment: $0, account: message.account, messageId: message.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 8) {
                ForEach(refs) { ref in
                    AttachmentCard(ref: ref)
                }
            }
            if refs.count > 1 {
                Button {
                    store.saveAttachments(refs)
                } label: {
                    Label("Save all to Downloads", systemImage: "arrow.down.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.textLink)
                .clickable()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

struct AttachmentCard: View {
    @EnvironmentObject private var store: AppStore
    let ref: AttachmentRef

    @State private var hovering = false
    @State private var preview: NSImage?

    static let width: CGFloat = 176
    static let previewHeight: CGFloat = 104

    private var attachment: Attachment { ref.attachment }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewArea
            HStack(spacing: 7) {
                Image(nsImage: attachment.icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !attachment.formattedSize.isEmpty {
                        Text(attachment.formattedSize)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
        }
        .frame(width: Self.width)
        .background(Color.primary.opacity(hovering ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .overlay(alignment: .topTrailing) {
            if hovering { hoverActions.padding(6) }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .clickable()
        .onTapGesture(count: 2) { store.openAttachment(ref) }
        .onTapGesture { store.quickLook(ref) }
        .onDrag { dragProvider() }
        .contextMenu { menu }
        .help("\(attachment.filename) · Click to preview, double-click to open, drag to copy")
        .task(id: ref.id) { await loadPreview() }
    }

    private var previewArea: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.04))
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: attachment.isImage ? .fill : .fit)
                    .frame(width: Self.width, height: Self.previewHeight)
                    .clipped()
                    .transition(.opacity)
            } else {
                Image(nsImage: attachment.icon)
                    .resizable()
                    .frame(width: 44, height: 44)
            }
        }
        .frame(width: Self.width, height: Self.previewHeight)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10, style: .continuous))
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            cardButton("eye", help: "Quick Look") { store.quickLook(ref) }
            cardButton("arrow.down", help: "Save to Downloads") { store.saveAttachments([ref]) }
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func cardButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
        .help(help)
    }

    @ViewBuilder private var menu: some View {
        Button("Quick Look") { store.quickLook(ref) }
        Button("Open") { store.openAttachment(ref) }
        Divider()
        Button("Save to Downloads") { store.saveAttachments([ref]) }
        Button("Save As…") { store.saveAttachmentAs(ref) }
        Button("Show in Finder") { store.revealAttachment(ref) }
    }

    /// Dragging hands over a real file, fetched when it's dropped.
    private func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = AttachmentFiles.safeFilename(attachment.filename)
        let type = UTType(mimeType: attachment.mimeType) ?? UTType(filenameExtension: (attachment.filename as NSString).pathExtension) ?? .data
        let files = store.attachmentFiles
        let ref = ref
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                do {
                    completion(try await files.temporaryFile(ref), false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }
        return provider
    }

    /// Images and PDFs get a picture of what's inside. Big files keep their icon rather than download on sight.
    private func loadPreview() async {
        let isPDF = attachment.mimeType.lowercased() == "application/pdf" || attachment.filename.lowercased().hasSuffix(".pdf")
        guard attachment.isImage || isPDF else { return }
        let files = store.attachmentFiles
        let cached = files.cachedData(ref)
        guard cached != nil || attachment.size <= 10 * 1024 * 1024 else { return }
        let data: Data
        if let cached {
            data = cached
        } else {
            guard let fetched = try? await files.data(ref) else { return }
            data = fetched
        }
        let size = CGSize(width: Self.width * 2, height: Self.previewHeight * 2)
        let image = await Task.detached(priority: .utility) {
            isPDF ? Self.pdfThumbnail(data, size: size) : Self.imageThumbnail(data, maxPixels: Int(size.width))
        }.value
        guard let image, !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) { preview = image }
    }

    nonisolated static func imageThumbnail(_ data: Data, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    nonisolated static func pdfThumbnail(_ data: Data, size: CGSize) -> NSImage? {
        // A page only weakly holds its document, so keep the document alive while drawing.
        guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return nil }
        return withExtendedLifetime(document) { page.thumbnail(of: size, for: .cropBox) }
    }
}

/// A file going out with a draft, with a button to take it off.
struct OutgoingAttachmentChip: View {
    let attachment: OutgoingAttachment
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: attachment.icon)
                .resizable()
                .frame(width: 18, height: 18)
            Text(attachment.filename)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            Text(attachment.formattedSize)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(hovering ? .primary : .tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.quiet)
            .help("Remove")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Color.primary.opacity(hovering ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// Lays children out in rows, wrapping to the next row when one fills up.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
