//
//
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License as
//  published by the Free Software Foundation; either version 3 of the
//  License.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
//  General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//
//

import Foundation

let DEFAULT_MIME_TYPE = "application/octet-stream"
let mimeTypes = [
    "html": "text/html",
    "htm": "text/html",
    "shtml": "text/html",
    "css": "text/css",
    "xml": "text/xml",
    "gif": "image/gif",
    "jpeg": "image/jpeg",
    "jpg": "image/jpeg",
    "js": "application/javascript",
    "atom": "application/atom+xml",
    "rss": "application/rss+xml",
    "mml": "text/mathml",
    "txt": "text/plain",
    "jad": "text/vnd.sun.j2me.app-descriptor",
    "wml": "text/vnd.wap.wml",
    "htc": "text/x-component",
    "png": "image/png",
    "tif": "image/tiff",
    "tiff": "image/tiff",
    "wbmp": "image/vnd.wap.wbmp",
    "ico": "image/x-icon",
    "jng": "image/x-jng",
    "bmp": "image/x-ms-bmp",
    "svg": "image/svg+xml",
    "svgz": "image/svg+xml",
    "webp": "image/webp",
    "woff": "application/font-woff",
    "jar": "application/java-archive",
    "war": "application/java-archive",
    "ear": "application/java-archive",
    "json": "application/json",
    "hqx": "application/mac-binhex40",
    "doc": "application/msword",
    "pdf": "application/pdf",
    "ps": "application/postscript",
    "eps": "application/postscript",
    "ai": "application/postscript",
    "rtf": "application/rtf",
    "m3u8": "application/vnd.apple.mpegurl",
    "xls": "application/vnd.ms-excel",
    "eot": "application/vnd.ms-fontobject",
    "ppt": "application/vnd.ms-powerpoint",
    "wmlc": "application/vnd.wap.wmlc",
    "kml": "application/vnd.google-earth.kml+xml",
    "kmz": "application/vnd.google-earth.kmz",
    "7z": "application/x-7z-compressed",
    "cco": "application/x-cocoa",
    "jardiff": "application/x-java-archive-diff",
    "jnlp": "application/x-java-jnlp-file",
    "run": "application/x-makeself",
    "pl": "application/x-perl",
    "pm": "application/x-perl",
    "prc": "application/x-pilot",
    "pdb": "application/x-pilot",
    "rar": "application/x-rar-compressed",
    "rpm": "application/x-redhat-package-manager",
    "sea": "application/x-sea",
    "swf": "application/x-shockwave-flash",
    "sit": "application/x-stuffit",
    "tcl": "application/x-tcl",
    "tk": "application/x-tcl",
    "der": "application/x-x509-ca-cert",
    "pem": "application/x-x509-ca-cert",
    "crt": "application/x-x509-ca-cert",
    "xpi": "application/x-xpinstall",
    "xhtml": "application/xhtml+xml",
    "xspf": "application/xspf+xml",
    "zip": "application/zip",
    "bin": "application/octet-stream",
    "exe": "application/octet-stream",
    "dll": "application/octet-stream",
    "deb": "application/octet-stream",
    "dmg": "application/octet-stream",
    "iso": "application/octet-stream",
    "img": "application/octet-stream",
    "msi": "application/octet-stream",
    "msp": "application/octet-stream",
    "msm": "application/octet-stream",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "mid": "audio/midi",
    "midi": "audio/midi",
    "kar": "audio/midi",
    "mp3": "audio/mpeg",
    "ogg": "audio/ogg",
    "m4a": "audio/x-m4a",
    "ra": "audio/x-realaudio",
    "3gpp": "video/3gpp",
    "3gp": "video/3gpp",
    "ts": "video/mp2t",
    "mp4": "video/mp4",
    "mpeg": "video/mpeg",
    "mpg": "video/mpeg",
    "mov": "video/quicktime",
    "webm": "video/webm",
    "flv": "video/x-flv",
    "m4v": "video/x-m4v",
    "mng": "video/x-mng",
    "asx": "video/x-ms-asf",
    "asf": "video/x-ms-asf",
    "wmv": "video/x-ms-wmv",
    "avi": "video/x-msvideo"
]

public enum MimeIconTypes: String {
    case image = "image"
    case audio = "audio"
    case video = "video"
    case document = "document"
    case pdf = "pdf"
    case table = "table"
    case presentation = "presentation"
    case archive = "archive"
    case file = "file"
}
let DEFAULT_MIME_ICON: MimeIconTypes = .file
let mimeIcon: [String: MimeIconTypes] = [
    "image/gif": .image,
    "image/jpeg": .image,
    "image/pjpeg": .image,
    "image/png": .image,
    "image/svg+xml": .image,
    "image/tiff": .image,
    "image/vnd.microsoft.icon": .image,
    "image/vnd.wap.wbmp": .image,
    "image/webp": .image,
    
    "audio/basic": .audio,
    "audio/L24": .audio,
    "audio/mp4": .audio,
    "audio/aac": .audio,
    "audio/mpeg": .audio,
    "audio/ogg": .audio,
    "audio/vorbis": .audio,
    "audio/x-ms-wma": .audio,
    "audio/x-ms-wax": .audio,
    "audio/vnd.rn-realaudio": .audio,
    "audio/vnd.wave": .audio,
    "audio/webm": .audio,
    "audio": .audio,
    
    "video/mpeg": .video,
    "video/mp4": .video,
    "video/ogg": .video,
    "video/quicktime": .video,
    "video/webm": .video,
    "video/x-ms-wmv": .video,
    "video/x-flv": .video,
    "video/3gpp": .video,
    "video/3gpp2": .video,
    
    "text/cmd": .document,
    "text/css": .document,
    "text/csv": .document,
    "text/html": .document,
    "text/javascript": .document,
    "text/plain": .document,
    "text/php": .document,
    "text/xml": .document,
    "text/markdown": .document,
    "text/cache-manifest": .document,
    "application/json": .document,
    "application/xml": .document,
    "application/vnd.oasis.opendocument.text": .document,
    "application/vnd.oasis.opendocument.graphics": .document,
    "application/msword": .document,
    
    "application/pdf": .pdf,
    
    "application/vnd.oasis.opendocument.spreadsheet": .table,
    "application/vnd.ms-excel": .table,
    
    "application/vnd.ms-powerpoint": .presentation,
    "application/vnd.oasis.opendocument.presentation": .presentation,
    
    "application/zip": .archive,
    "application/gzip": .archive,
    "application/x-rar-compressed": .archive,
    "application/x-tar": .archive,
    "application/x-7z-compressed": .archive,
    "application/archive": .archive,
]

public struct MimeType {
    let ext: String?
    public var value: String {
        guard let ext = ext else {
            return DEFAULT_MIME_TYPE
        }
        return mimeTypes[ext.lowercased()] ?? DEFAULT_MIME_TYPE
    }
    
    public init(path: String) {
        ext = NSString(string: path).pathExtension
    }
    
    public init(path: NSString) {
        ext = path.pathExtension
    }
    
    public init(url: URL) {
        ext = url.pathExtension
    }
    
    static public func mime(_ mime: String) -> MimeIconTypes {
        switch mime {
        case MimeIconTypes.image.rawValue: return .image
        case MimeIconTypes.audio.rawValue: return .audio
        case MimeIconTypes.video.rawValue: return .video
        case MimeIconTypes.document.rawValue: return .document
        case MimeIconTypes.pdf.rawValue: return .pdf
        case MimeIconTypes.table.rawValue: return .table
        case MimeIconTypes.presentation.rawValue: return .presentation
        case MimeIconTypes.archive.rawValue: return .archive
        case MimeIconTypes.file.rawValue: return .file
        default: return .file
        }
    }
}

public struct MimeIcon {
    let mime: String?
    
    public var value: MimeIconTypes {
        guard let mime = self.mime else {
            return DEFAULT_MIME_ICON
        }
        return mimeIcon[mime] ?? DEFAULT_MIME_ICON
    }
    
    public init(_ mimeType: String) {
        mime = mimeType
    }
}
