//
//  AttribFormatter.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//
//  Converts Drafty instance into attributed text suitable for display in UITextView

// For MIME -> UTI conversion
import MobileCoreServices
import TinodeSDK
import UIKit

// iOS's support for styled strings is much weaker than Android's and web. Some styles cannot be nested. They have to be constructed and applied all at once at the leaf level.
class AttribFormatter: DraftyFormatter {
    typealias Node = AttribFormatter.TreeNode

    private enum Constants {
        static let kDefaultFont: UIFont = UIFont.preferredFont(forTextStyle: .body)
        /// Size of the document icon in attachments.
        static let kAttachmentIconSize = CGSize(width: 24, height: 32)
        /// URL and Button text color
        static let kLinkColor = UIColor(red: 0, green: 122/255, blue: 1, alpha: 1)
        /// Minumum width of the button in fontHeights/2
        static let kMinButtonWidth: Int = 10
        // Line hight multiplier in forms.
        static let kFormLineSpacing: CGFloat = 1.5
    }

    typealias CharacterStyle = [NSAttributedString.Key: Any]

    let defaultAttrs: [NSAttributedString.Key: Any]

    init(defaultAttrs attrs: [NSAttributedString.Key: Any]) {
        defaultAttrs = attrs
    }

    // Inline image
    private func handleImage(content: TreeNode, attr: [String : JSONValue]?) {
        guard let attr = attr, let bits = attr["val"]?.asData() else { return }

        // FIXME: maybe cache result of converting Data to image.
        var attachment = Attachment()
        attachment.image = UIImage(data: bits)
        attachment.mime = attr["mime"]?.asString()
        attachment.name = attr["name"]?.asString()
        attachment.size = bits.count
        attachment.width = attr["width"]?.asInt()
        attachment.height = attr["height"]?.asInt()
        content.attachment(attachment)
    }

    private func handleAttachment(content: TreeNode, attr: [String : JSONValue]?) {
        guard let attr = attr, let bits = attr["val"]?.asData() else { return }

        var attachment = Attachment()
        attachment.data = bits
        attachment.mime = attr["mime"]?.asString()
        attachment.name = attr["name"]?.asString()
        attachment.size = bits.count
        content.attachment(attachment)
    }

    private func handleButton(content: TreeNode, attr: [String : JSONValue]?) {
        guard let urlStr = AttribFormatter.buttonDataAsUri(face: content, attr: attr), let url = URL(string: urlStr) else { return }

        var attachment = Attachment()
        attachment.button = url
        content.attachment(attachment)
    }

    // Convert button payload to an URL.
    // NSAttributedString.Key.link wants payload to be NSURL.
    private static func buttonDataAsUri(face: TreeNode, attr: [String : JSONValue]?) -> String? {
        guard let attr = attr, let actionType = attr["act"]?.asString() else { return nil }
        var baseUrl: URLComponents
        if actionType == "url" {
            guard let ref = attr["ref"]?.asString() else { return nil }
            guard let urlc = URLComponents(string: ref) else { return nil }
            baseUrl = urlc
            if let name = attr["name"]?.asString() {
                let actionValue = attr["val"]?.asString() ?? "1"
                if baseUrl.queryItems == nil {
                    baseUrl.queryItems = []
                }
                baseUrl.queryItems!.append(URLQueryItem(name: name, value: actionValue))
            }
        } else if actionType == "pub" {
            // Custom scheme usr to post back to the server:
            // tinode:default?name=value
            baseUrl = URLComponents()
            baseUrl.scheme = "tinode"
            baseUrl.host = ""
            baseUrl.path = "/post"
            baseUrl.queryItems = []
            baseUrl.queryItems!.append(URLQueryItem(name: "title", value: face.toString()))
            if let name = attr["name"]?.asString() {
                baseUrl.queryItems!.append(URLQueryItem(name: "name", value: name))
                let actionValue = attr["val"]?.asString() ?? "1"
                baseUrl.queryItems!.append(URLQueryItem(name: "val", value: actionValue))
            }
        } else {
            return nil
        }

        return baseUrl.url?.absoluteString
    }

    // Construct a tree representing formatting styles and content.
    private func apply(tp: String?, attr: [String : JSONValue]?, children: [TreeNode]?, content: String?) -> TreeNode {

        // Create unstyled node
        var span = TreeNode(text: content, nodes: children)
        switch tp {
        case "ST":
            span.style(fontTraits: .traitBold)
        case "EM":
            span.style(fontTraits: .traitItalic)
        case "DL":
            span.style(cstyle: [NSAttributedString.Key.strikethroughStyle: NSUnderlineStyle.single.rawValue])
        case "CO":
            // .traitMonoSpace is not a real font trait. It cannot be applied to an arbitrary font. A real
            // monospaced font must be selected manually.
            let baseFont = defaultAttrs[.font] as! UIFont
            var attributes = defaultAttrs
            attributes[.font] = UIFont(name: "Courier", size: baseFont.pointSize)!
            span.style(cstyle: attributes)
        case "BR":
            span = TreeNode(content: "\n")
        case "LN":
            if let urlString = attr?["url"]?.asString(), let url = NSURL(string: urlString) {
                span.style(cstyle: [NSAttributedString.Key.link: url])
            }
        case "MN": break // TODO: add fupport for @mentions
        case "HT": break // TODO: add support for #hashtangs
        case "HD": break // Hidden/ignored text
        case "IM":
            // Inline image
            handleImage(content: span, attr: attr)
        case "EX":
            // Attachment
            handleAttachment(content: span, attr: attr)
        case "BN":
            // Button
            handleButton(content: span, attr: attr)
        case "FM":
            // Form
            if var children = span.children, !children.isEmpty {
                // Add line breaks between form elements: each direct descendant is a paragraph.
                for i in stride(from: children.count-1, to: 0, by: -1) {
                    children.insert(TreeNode(content: "\n"), at: i);
                }
                span.children = children
            }
        case "RW":
            // Form element formatting is dependent on element content.
            // No additional handling is needed.
            break
        default:
            break // Unknown formatting, treat as plain text
        }
        return span
    }

    func apply(tp: String?, attr: [String : JSONValue]?, content: [AttribFormatter.TreeNode]) -> AttribFormatter.TreeNode {
        return apply(tp: tp, attr: attr, children: content, content: nil)
    }

    func apply(tp: String?, attr: [String : JSONValue]?, content: String?) -> AttribFormatter.TreeNode {
        return apply(tp: tp, attr: attr, children: nil, content: content)
    }

    /// Convert drafty object into NSAttributedString
    /// - Parameters:
    ///    - content: Drafty object to convert
    ///    - maxSize: maximum size of attached images
    ///    - defaultAttrs: default attribues to apply to all otherwise unstyled content.
    ///    - textColor: default text color.
    public static func toAttributed(_ content: Drafty, maxSize: CGSize, defaultAttrs: [NSAttributedString.Key : Any]? = nil) -> NSAttributedString {

        var attributes: [NSAttributedString.Key : Any] = defaultAttrs ?? [:]
        if attributes[.font] == nil {
            attributes[.font] = Constants.kDefaultFont
        }

        if content.isPlain {
            return NSMutableAttributedString(string: content.string, attributes: attributes)
        }

        let formatTree = content.format(formatter: AttribFormatter(defaultAttrs: attributes))
        return formatTree.toAttributed(defaultAttrs: attributes, fontTraits: nil, size: maxSize)
    }

    // File or image attachment.
    struct Attachment {
        var data: Data?
        var image: UIImage?
        var button: URL?

        var mime: String?
        var name: String?
        var ref: String?
        var size: Int?
        var width: Int?
        var height: Int?
    }

    // Class representing Drafty as a tree of nodes with content and styles attached.
    class TreeNode : CustomStringConvertible {

        // A set of font traits to apply at the leaf level
        var cFont: UIFontDescriptor.SymbolicTraits?
        // Character style which can be applied over leaf or subtree
        var cStyle: CharacterStyle?
        // Paragraph-level style to apply to leaf or subtree
        var pStyle: NSMutableParagraphStyle?
        // Attachment. Apple is really bad at designing interfaces.
        var attachment: Attachment?

        // Leaf
        var text: String?
        // Subtree
        var children: [TreeNode]?

        private init() {
            text = nil
            children = nil
        }

        // Create unstyled node
        init(text: String?, nodes: [TreeNode]?) {
            self.text = text
            self.children = nodes
        }

        private init(style: CharacterStyle, nodes: [TreeNode]) {
            self.cStyle = style
            self.text = nil
            self.children = nodes
        }

        convenience init(content: String) {
            self.init(text: content, nodes: nil)
        }

        init(content: [TreeNode]) {
            self.children = content
        }

        init(content: TreeNode) {
            if self.children == nil {
                self.children = []
            }
            self.children!.append(content)
        }

        var description: String {
            return text ?? children?.description ?? "nil"
        }

        func style(cstyle: CharacterStyle) {
            cStyle = cstyle
        }

        func style(pstyle: NSMutableParagraphStyle) {
            pStyle = pstyle
        }

        func style(fontTraits: UIFontDescriptor.SymbolicTraits) {
            cFont = fontTraits
        }

        func attachment(_ attachment: Attachment) {
            self.attachment = attachment
        }

        func addNode(node: TreeNode?) {
            guard let node = node else { return }

            if children == nil {
                children = []
            }
            children!.append(node)
        }

        func addNode(content: String?) {
            guard let content = content else { return }

            addNode(node: TreeNode(content: content))
        }

        var isEmpty: Bool {
            return (text == nil || text!.isEmpty) && (children == nil || children!.isEmpty)
        }

        /// Simple representation of an attachment as plain string.
        private func attachmentToString(_ attachment: Attachment) -> String {
            if let _ = attachment.image {
                return "[img \(attachment.name ?? "unnamed")]"
            }

            if let _ = attachment.button {
                if let text = text {
                    return "[btn \(text)]"
                }
                if let children = children {
                    var faceText = ""
                    for child in children {
                        faceText += child.toString()
                    }
                    return "[btn \(faceText)]"
                }
                return "[button]"
            }

            guard attachment.data != nil else { return "" }
            var fname = attachment.name ?? "unnamed"
            if fname.count > 32 {
                fname = fname.prefix(14) + "…" + fname.suffix(14)
            }
            return "[att \(fname)]"
        }

        /// Create custom layout for attachments.
        private func attachmentToAttributed(_ attachment: Attachment, defaultAttrs attributes: [NSAttributedString.Key : Any], fontTraits: UIFontDescriptor.SymbolicTraits?, maxSize size: CGSize) -> NSAttributedString {
            // Image handling is easy.
            if let image = attachment.image {
                let wrapper = NSTextAttachment()
                wrapper.image = image
                let (scaledSize, _) = image.sizeUnder(maxWidth: size.width, maxHeight: size.height, clip: false)
                wrapper.bounds = CGRect(origin: .zero, size: scaledSize)
                return NSAttributedString(attachment: wrapper)
            }

            // button is also not too hard
            if let buttonUrl = attachment.button {
                let faceText = NSMutableAttributedString()
                // Change color of text from default to link color.
                var attrs = attributes
                attrs[.foregroundColor] = Constants.kLinkColor
                if let text = text {
                    faceText.append(textToAttributed(text, defaultAttrs: attrs, fontTraits: fontTraits))
                } else if let children = children {
                    for child in children {
                        faceText.append(child.toAttributed(defaultAttrs: attrs, fontTraits: fontTraits, size: size))
                    }
                } else {
                    faceText.append(NSAttributedString(string: "button", attributes: attrs))
                }
                return NSAttributedString(attachment: DraftyButtonAttachment(face: faceText, data: buttonUrl))
            }

            // File attachment is harder: construct attributed string fr showing an attachment.

            guard let bits = attachment.data else { return NSAttributedString() }

            let attributed = NSMutableAttributedString()
            attributed.beginEditing()
            /*
             TODO: use provided mime type to show custom icons for different types.
             let unmanagedUti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (attachment.mime ?? "application/octet-stream") as CFString, nil)
             var uti = unmanagedUti?.takeRetainedValue() ?? kUTTypeData
             uti = kUTTypeData
             */
            // Using basic kUTTypeData to prevent iOS from displaying distorted previews.

            let wrapper = NSTextAttachment(data: bits, ofType: kUTTypeData as String)
            let baseFont = attributes[.font] as! UIFont
            wrapper.bounds = CGRect(origin: CGPoint(x: 0, y: baseFont.capHeight - Constants.kAttachmentIconSize.height), size: Constants.kAttachmentIconSize)
            attributed.append(NSAttributedString(attachment: wrapper))

            // Append document's file name.
            var fname = attachment.name ?? "tinode_file_attachment"
            if fname.count > 32 {
                fname = fname.prefix(14) + "…" + fname.suffix(14)
            }
            attributed.append(NSAttributedString(string: " "))
            attributed.append(NSAttributedString(string: fname, attributes: [NSAttributedString.Key.font : UIFont(name: "Courier", size: baseFont.pointSize)!]))

            // Append file size.
            if let size = attachment.size {
                attributed.append(NSAttributedString(string: " (" + UiUtils.bytesToHumanSize(Int64(size)) + ")", attributes: attributes))
            }

            // Insert linebreak then a clickable [↓ save] line
            attributed.append(NSAttributedString(string: "\u{2009}\n", attributes: [NSAttributedString.Key.font : baseFont]))

            // \u{2009} because iOS is buggy and bugs go unfixed for years.
            // https://stackoverflow.com/questions/29041458/how-to-set-color-of-templated-image-in-nstextattachment
            let second = NSMutableAttributedString(string: "\u{2009}")
            second.beginEditing()

            // Add 'download file' icon
            let icon = NSTextAttachment()
            icon.image = UIImage(named: "download-24")?.withRenderingMode(.alwaysTemplate)
            icon.bounds = CGRect(origin: CGPoint(x: 0, y: -2), size: CGSize(width: baseFont.lineHeight * 0.8, height: baseFont.lineHeight * 0.8))
            second.append(NSAttributedString(attachment: icon))

            // Add "save" text.
            // TODO: make it clickable
            second.append(NSAttributedString(string: " save", attributes: [NSAttributedString.Key.font : baseFont]))

            // Add paragraph style and coloring
            let paragraph = NSMutableParagraphStyle()
            paragraph.firstLineHeadIndent = Constants.kAttachmentIconSize.width + baseFont.capHeight * 0.25
            paragraph.lineSpacing = 0
            paragraph.maximumLineHeight = 4
            second.addAttributes([NSAttributedString.Key.paragraphStyle : paragraph, NSAttributedString.Key.foregroundColor : Constants.kLinkColor], range: NSRange(location: 0, length: second.length))

            second.endEditing()
            attributed.append(second)

            attributed.endEditing()
            return attributed
        }

        /// Plain text to attributed string.
        private func textToAttributed(_ text: String, defaultAttrs: [NSAttributedString.Key : Any], fontTraits: UIFontDescriptor.SymbolicTraits?) -> NSAttributedString {

            var attributes = defaultAttrs
            if let fontTraits = fontTraits {
                let font = defaultAttrs[NSAttributedString.Key.font] as! UIFont
                attributes[.font] = UIFont(descriptor: font.fontDescriptor.withSymbolicTraits(fontTraits)!, size: font.pointSize)
            }

            return NSAttributedString(string: text, attributes: attributes)
        }

        /// Convert tree of nodes into a plain string.
        func toString() -> String {
            var str: String = ""
            // First check for attachments.
            if let attachment = self.attachment {
                // Image or file attachment
                str += attachmentToString(attachment)
            } else if let text = self.text {
                str += text
            } else if let children = self.children {
                // Process children.
                for child in children {
                    str += child.toString()
                }
            }
            return str
        }

        /// Convert tree of nodes into an attributed string.
        func toAttributed(defaultAttrs attributes: [NSAttributedString.Key : Any], fontTraits parentFontTraits: UIFontDescriptor.SymbolicTraits?, size: CGSize) -> NSAttributedString {

            // Font traits for this substring and all its children.
            var fontTraits: UIFontDescriptor.SymbolicTraits? = cFont
            if let parentFontTraits = parentFontTraits {
                if fontTraits != nil {
                    fontTraits!.insert(parentFontTraits)
                } else {
                    fontTraits = parentFontTraits
                }
            }

            let attributed = NSMutableAttributedString()
            attributed.beginEditing()

            // First check for attachments.
            if let attachment = self.attachment {
                // Image or file attachment
                attributed.append(attachmentToAttributed(attachment, defaultAttrs: attributes, fontTraits: fontTraits, maxSize: size))
            } else if let text = self.text {
                // Uniformly styled substring. Apply uniform font style.
                attributed.append(textToAttributed(text, defaultAttrs: attributes, fontTraits: fontTraits))
            } else if let children = self.children {
                // Pass calculated font styles to children.
                for child in children {
                    attributed.append(child.toAttributed(defaultAttrs: attributes, fontTraits: fontTraits, size: size))
                }
            }

            // Then apply styles to the entire string.
            if let cstyle = cStyle {
                attributed.addAttributes(cstyle, range: NSRange(location: 0, length: attributed.length))
            } else if let pstyle = pStyle {
                attributed.addAttributes([.paragraphStyle: pstyle], range: NSRange(location: 0, length: attributed.length))
            }

            attributed.endEditing()
            return attributed
        }
    }
}
