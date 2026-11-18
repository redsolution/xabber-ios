import UIKit
import ImageIO
import UniformTypeIdentifiers
import XMPPFramework

struct ChatStickerDescriptor: Equatable, Sendable {
    let name: String
    let packURL: URL
    let imageURL: URL
    let emoji: String
    let mediaType: String
    let filename: String
    let width: Int
    let height: Int
    let inlineThumbnail: Data?

    init(
        name: String,
        packURL: URL,
        imageURL: URL,
        emoji: String,
        mediaType: String = "image/webp",
        filename: String = "",
        width: Int = 0,
        height: Int = 0,
        inlineThumbnail: Data? = nil
    ) {
        self.name = name
        self.packURL = packURL
        self.imageURL = imageURL
        self.emoji = emoji
        self.mediaType = mediaType
        self.filename = filename.isEmpty ? imageURL.lastPathComponent : filename
        self.width = width
        self.height = height
        self.inlineThumbnail = inlineThumbnail
    }
}

enum ChatStickerWireCodec {
    static let namespace = "https://xabber.com/protocol/stickers"
    static let packMetadataKey = "sticker-pack"
    private static let thumbnailMetadataKey = "sticker-inline-thumbnail"
    private static let referencesNamespace = "https://xabber.com/protocol/references"
    private static let filesNamespace = "https://xabber.com/protocol/files"
    private static let thumbnailsNamespace = "urn:xmpp:thumbs:1"
    private static let maximumThumbnailBytes = 12_288
    private static let maximumThumbnailSide: CGFloat = 48

    struct StickerReference {
        let name: String
        let packURL: URL?
        let imageURL: URL
        let mediaType: String
        let filename: String
        let width: Int
        let height: Int
        let inlineThumbnail: Data?

        var metadata: [String: Any] {
            var values: [String: Any] = [
                "name": name, "filename": filename, "uri": imageURL.absoluteString,
                "media-type": mediaType, "width": width, "height": height
            ]
            values[ChatStickerWireCodec.packMetadataKey] = packURL?.absoluteString
            values[ChatStickerWireCodec.thumbnailMetadataKey] = inlineThumbnail?.base64EncodedString()
            return values
        }
    }

    static func makeMessage(
        _ sticker: ChatStickerDescriptor,
        owner: String,
        conversation: String,
        conversationType: ClientSynchronizationManager.ConversationType
    ) -> XMPPMessage? {
        guard [.regular, .group, .saved, .omemo].contains(conversationType),
              XMPPJID(string: owner)?.bare == owner,
              XMPPJID(string: conversation)?.bare == conversation,
              let destination = MessageManager.outboundDestinationJID(
                  for: conversation, conversationType: conversationType, resource: nil
              ),
              remoteURL(sticker.packURL.absoluteString) != nil,
              remoteURL(sticker.imageURL.absoluteString) != nil,
              isImage(sticker.mediaType) else { return nil }
        let body = sticker.emoji.count == 1 ? sticker.emoji : "🖼️"
        let messageID = UUID().uuidString
        let message = XMPPMessage(messageType: .chat, to: destination, elementID: messageID, child: nil)
        message.setXmlns(SCEReceivePolicy.client)
        message.addAttribute(withName: "from", stringValue: owner)
        message.addBody(body)
        message.addOriginId(messageID)
        if conversationType == .group {
            message.addChild(DDXMLElement(name: "private", xmlns: "urn:xmpp:carbons:2"))
        }
        let decoded = StickerReference(
            name: sticker.name, packURL: sticker.packURL, imageURL: sticker.imageURL,
            mediaType: sticker.mediaType, filename: sticker.filename, width: dimension(sticker.width),
            height: dimension(sticker.height), inlineThumbnail: validatedThumbnail(sticker.inlineThumbnail)
        )
        let reference = DDXMLElement(name: "reference", xmlns: referencesNamespace)
        reference.addAttribute(withName: "type", stringValue: "decoration")
        reference.addAttribute(withName: "begin", integerValue: 0)
        reference.addAttribute(withName: "end", integerValue: body.xmlEscaping(reverse: false).unicodeScalars.count)
        reference.addChild(stickerElement(decoded))
        message.addChild(reference)
        guard (try? MessageManager.validatePreparedContentSize(message)) != nil else { return nil }
        // Resolve the inherited file metadata namespaces for validation and
        // encryption before the caller submits the prepared packet.
        return try? XMPPMessage(xmlString: message.xmlString)
    }

    static func containsSticker(in message: DDXMLElement) -> Bool {
        sticker(in: message) != nil
    }

    static func inlineThumbnail(in message: DDXMLElement) -> Data? {
        sticker(in: message)?.inlineThumbnail
    }

    static func inlineThumbnail(metadata: [String: Any]?) -> Data? {
        decodeBase64(metadata?[thumbnailMetadataKey] as? String)
    }

    static func sticker(in message: DDXMLElement) -> StickerReference? {
        SCEReceivePolicy.children(of: message, named: "reference", xmlns: referencesNamespace)
            .compactMap(decode).first
    }

    static func decode(_ reference: DDXMLElement) -> StickerReference? {
        let children = (reference.children ?? []).compactMap { $0 as? DDXMLElement }
        let typeAttribute = "type"
        let decorationType = "decoration"
        guard SCEReceivePolicy.matches(reference, name: "reference", namespace: referencesNamespace),
              reference.attributeStringValue(forName: typeAttribute) == decorationType,
              children.count == 1, let sticker = children.first,
              SCEReceivePolicy.matches(sticker, name: "sticker", namespace: namespace),
              let sharing = onlyChild(sticker, name: "file-sharing", namespace: filesNamespace),
              let file = onlyChild(sharing, name: "file", namespace: filesNamespace),
              SCEReceivePolicy.children(of: file, named: "encrypted", xmlns: "urn:xmpp:esfs:0").isEmpty,
              let sources = onlyChild(sharing, name: "sources", namespace: filesNamespace),
              let imageURL = SCEReceivePolicy.children(of: sources, named: "uri", xmlns: filesNamespace)
                  .compactMap({ remoteURL($0.stringValue) }).first,
              let mediaType = onlyChild(file, name: "media-type", namespace: filesNamespace)?.stringValue,
              isImage(mediaType) else { return nil }
        let thumbElementName = "thumbnail"
        let thumbnail = onlyChild(file, name: thumbElementName, namespace: thumbnailsNamespace)
            ?? onlyChild(file, name: thumbElementName, namespace: filesNamespace)
        let filenameElement = "name"
        return StickerReference(
            name: sticker.attributeStringValue(forName: "name") ?? "",
            packURL: remoteURL(sticker.attributeStringValue(forName: "pack")),
            imageURL: imageURL,
            mediaType: mediaType,
            filename: onlyChild(file, name: filenameElement, namespace: filesNamespace)?.stringValue ?? imageURL.lastPathComponent,
            width: dimension(onlyChild(file, name: "width", namespace: filesNamespace)?.stringValueAsNSInteger() ?? 0),
            height: dimension(onlyChild(file, name: "height", namespace: filesNamespace)?.stringValueAsNSInteger() ?? 0),
            inlineThumbnail: decodeDataURI(thumbnail?.attributeStringValue(forName: "uri"))
        )
    }

    static func stickerElement(for reference: MessageReferenceStorageItem) -> DDXMLElement? {
        guard reference.kind == .sticker,
              let metadata = reference.metadata,
              let imageURL = remoteURL(reference.fileSharingURI),
              let mediaType = metadata["media-type"] as? String,
              isImage(mediaType) else { return nil }
        let filenameKey = "filename"
        return stickerElement(StickerReference(
            name: metadata["name"] as? String ?? "",
            packURL: remoteURL(metadata[packMetadataKey] as? String),
            imageURL: imageURL,
            mediaType: mediaType,
            filename: metadata[filenameKey] as? String ?? imageURL.lastPathComponent,
            width: dimension(metadata["width"] as? Int ?? 0),
            height: dimension(metadata["height"] as? Int ?? 0),
            inlineThumbnail: inlineThumbnail(metadata: metadata)
        ))
    }

    private static func stickerElement(_ sticker: StickerReference) -> DDXMLElement {
        let element = DDXMLElement(name: "sticker", xmlns: namespace)
        element.addAttribute(withName: "name", stringValue: sticker.name)
        if let packURL = sticker.packURL {
            element.addAttribute(withName: "pack", stringValue: packURL.absoluteString)
        }
        let sharing = DDXMLElement(name: "file-sharing", xmlns: filesNamespace)
        let file = DDXMLElement(name: "file")
        file.addChild(DDXMLElement(name: "name", stringValue: sticker.filename))
        file.addChild(DDXMLElement(name: "media-type", stringValue: sticker.mediaType))
        if sticker.width > 0 {
            file.addChild(DDXMLElement(name: "width", stringValue: String(sticker.width)))
        }
        if sticker.height > 0 {
            file.addChild(DDXMLElement(name: "height", stringValue: String(sticker.height)))
        }
        if let data = sticker.inlineThumbnail, let mime = thumbnailMIMEType(data) {
            let thumbElementName = "thumbnail"
            let thumbnail = DDXMLElement(name: thumbElementName, xmlns: thumbnailsNamespace)
            thumbnail.addAttribute(withName: "media-type", stringValue: mime)
            thumbnail.addAttribute(withName: "uri", stringValue: "data:\(mime);base64,\(data.base64EncodedString())")
            file.addChild(thumbnail)
        }
        sharing.addChild(file)
        let sources = DDXMLElement(name: "sources")
        sources.addChild(DDXMLElement(name: "uri", stringValue: sticker.imageURL.absoluteString))
        sharing.addChild(sources)
        element.addChild(sharing)
        return element
    }

    static func thumbnail(from image: UIImage) -> Data? {
        let source = image.size
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else { return nil }
        let scale = min(1, maximumThumbnailSide / max(source.width, source.height))
        let size = CGSize(width: max(1, source.width * scale), height: max(1, source.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let data = UIGraphicsImageRenderer(size: size, format: format).pngData { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return validatedThumbnail(data)
    }

    private static func onlyChild(_ element: DDXMLElement, name: String, namespace: String) -> DDXMLElement? {
        let matches = SCEReceivePolicy.children(of: element, named: name, xmlns: namespace)
        return matches.count == 1 ? matches.first : nil
    }

    private static func remoteURL(_ raw: String?) -> URL? {
        guard let raw, raw.utf8.count <= 4_096,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              components.host?.isEmpty == false, components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    private static func isImage(_ mime: String) -> Bool {
        mime.hasPrefix("image/") && mime.utf8.count <= 64
    }

    private static func dimension(_ value: Int) -> Int { (1...32_768).contains(value) ? value : 0 }

    private static func decodeDataURI(_ raw: String?) -> Data? {
        guard let raw, raw.utf8.count <= maximumThumbnailBytes / 3 * 4 + 64,
              let separator = raw.firstIndex(of: ","),
              raw[..<separator].hasPrefix("data:image/"),
              raw[..<separator].hasSuffix(";base64") else { return nil }
        return decodeBase64(String(raw[raw.index(after: separator)...]))
    }

    private static func decodeBase64(_ raw: String?) -> Data? {
        guard let raw, raw.utf8.count <= maximumThumbnailBytes / 3 * 4,
              let data = Data(base64Encoded: raw) else { return nil }
        return validatedThumbnail(data)
    }

    private static func validatedThumbnail(_ data: Data?) -> Data? {
        guard let data, thumbnailMIMEType(data) != nil else { return nil }
        return data
    }

    private static func thumbnailMIMEType(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumThumbnailBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...128).contains(width), (1...128).contains(height) else { return nil }
        switch type as String {
        case UTType.png.identifier: return "image/png"
        case UTType.jpeg.identifier: return "image/jpeg"
        case UTType.webP.identifier: return "image/webp"
        default: return nil
        }
    }
}

enum ChatStickerLayoutPolicy {
    static let maximumSide: CGFloat = 192

    static func renderedSize(
        sourceSize: CGSize,
        availableWidth: CGFloat
    ) -> CGSize {
        let maximum = max(1, min(maximumSide, availableWidth))
        guard sourceSize.width.isFinite,
              sourceSize.height.isFinite,
              sourceSize.width > 0,
              sourceSize.height > 0 else {
            return CGSize(width: maximum, height: maximum)
        }
        let scale = min(maximum / sourceSize.width, maximum / sourceSize.height, 1)
        return CGSize(
            width: max(1, (sourceSize.width * scale).rounded(.toNearestOrAwayFromZero)),
            height: max(1, (sourceSize.height * scale).rounded(.toNearestOrAwayFromZero))
        )
    }
}
