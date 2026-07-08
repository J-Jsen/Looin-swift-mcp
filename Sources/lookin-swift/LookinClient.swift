import Foundation
import ImageIO

enum LookinError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

/// LookinServer request frame types (LookinDefines.h).
private enum RequestType {
    static let ping: UInt32 = 200
    static let hierarchy: UInt32 = 202
    static let hierarchyDetails: UInt32 = 203
    static let inbuiltAttrModification: UInt32 = 204
}

/// Mirrors LookinAttributeModification's coding keys/types so the server can
/// apply the change. Class name is remapped at archive time.
final class ReqModification: NSObject, NSCoding {
    let oid: UInt64, setter: String, attrType: Int, value: Any, version: String
    init(oid: UInt64, setter: String, attrType: Int, value: Any, version: String) {
        self.oid = oid; self.setter = setter; self.attrType = attrType
        self.value = value; self.version = version
        super.init()
    }
    func encode(with c: NSCoder) {
        c.encode(NSNumber(value: oid), forKey: "targetOid")   // encodeObject:@(oid)
        c.encode(setter as NSString, forKey: "setterSelector") // NSStringFromSelector
        c.encode(attrType, forKey: "attrType")                 // encodeInteger
        c.encode(value, forKey: "value")                       // encodeObject
        c.encode(version as NSString, forKey: "clientReadableVersion")
    }
    required init?(coder: NSCoder) { return nil }
}

// MARK: - 203 request encoder stand-ins

/// Mirrors LookinStaticAsyncUpdateTask's coding keys/types exactly so the server
/// decodes our request. Class names are remapped at archive time.
final class ReqTask: NSObject, NSCoding {
    let oid: UInt64, taskType: Int, attrRequest: Int, needBasis: Bool, needSub: Bool, version: String
    init(oid: UInt64, taskType: Int, attrRequest: Int, needBasis: Bool, needSub: Bool, version: String) {
        self.oid = oid; self.taskType = taskType; self.attrRequest = attrRequest
        self.needBasis = needBasis; self.needSub = needSub; self.version = version
        super.init()
    }
    func encode(with c: NSCoder) {
        c.encode(NSNumber(value: oid), forKey: "oid")     // encodeObject:@(oid)
        c.encode(taskType, forKey: "taskType")            // encodeInteger
        c.encode(version as NSString, forKey: "clientReadableVersion")
        c.encode(attrRequest, forKey: "attrRequest")      // encodeInteger
        c.encode(needBasis, forKey: "needBasisVisualInfo")// encodeBool
        c.encode(needSub, forKey: "needSubitems")         // encodeBool
    }
    required init?(coder: NSCoder) { return nil }
}

final class ReqPackage: NSObject, NSCoding {
    let tasks: [ReqTask]
    init(tasks: [ReqTask]) { self.tasks = tasks; super.init() }
    func encode(with c: NSCoder) { c.encode(tasks as NSArray, forKey: "tasks") }
    required init?(coder: NSCoder) { return nil }
}

/// High-level client: connects to LookinServer over Peertalk, issues requests,
/// and turns the archived responses into JSON for the MCP tools.
final class LookinClient {
    static let shared = LookinClient()
    private let clientVersion = "1.2.8"

    // MARK: - Tools

    func getHierarchyJSON(maxDepth: Int?) throws -> String {
        let payload = try LookinClient.encodeRequest(["clientVersion": clientVersion])
        let response = try roundTrip(type: RequestType.hierarchy, payload: payload)
        let info = try decodeHierarchy(response)
        return try LookinClient.buildHierarchyJSON(info, maxDepth: maxDepth)
    }

    static func buildHierarchyJSON(_ info: LKSHierarchyInfo, maxDepth: Int?) throws -> String {
        var count = 0
        let tree = info.displayItems.map { node -> [String: Any] in
            jsonNode(node, depth: 0, maxDepth: maxDepth, count: &count)
        }
        let root: [String: Any] = ["totalViews": count, "hierarchy": tree]
        return try jsonString(root)
    }

    func getAttributesJSON(oid: UInt64) throws -> String {
        let details = try fetchDetails(oids: [oid], taskType: 0 /* NoScreenshot */, needAttrs: true)
        guard let detail = details.first(where: { $0.oid == oid }) ?? details.first else {
            throw LookinError.message("LookinServer returned no attributes for oid \(oid).")
        }
        let groups = detail.attributesGroupList.map { group -> [String: Any] in
            var g: [String: Any] = [:]
            if let id = group.identifier { g["identifier"] = id }
            if let t = group.userCustomTitle { g["title"] = t }
            g["sections"] = group.sections.map { section -> [String: Any] in
                var s: [String: Any] = [:]
                if let id = section.identifier { s["identifier"] = id }
                s["attributes"] = section.attributes.map { attr -> [String: Any] in
                    var a: [String: Any] = ["attrType": attr.attrType]
                    if let id = attr.identifier { a["identifier"] = id }
                    if let t = attr.displayTitle { a["title"] = t }
                    a["value"] = LookinClient.attrValueToJSON(attr.value, attrType: attr.attrType)
                    return a
                }
                return s
            }
            return g
        }
        return try LookinClient.jsonString(["oid": oid, "attributeGroups": groups])
    }

    /// Convert a decoded attribute value into a JSON-friendly form based on its
    /// LookinAttrType. Numbers/strings pass through; geometry NSValues become
    /// number arrays; UIColor becomes an rgba array.
    static func attrValueToJSON(_ value: Any?, attrType: Int) -> Any {
        guard let value = value else { return NSNull() }
        if let color = value as? LKSColor { return color.rgba ?? NSNull() }
        if let s = value as? String { return s }
        if let n = value as? NSNumber {
            return attrType == 14 ? n.boolValue : n // 14 = BOOL
        }
        if let v = value as? NSValue {
            // 17 CGPoint, 18 CGVector, 19 CGSize, 23 UIOffset = 2 floats;
            // 20 CGRect, 22 UIEdgeInsets = 4; 21 CGAffineTransform = 6.
            let count: Int
            switch attrType {
            case 17, 18, 19, 23: count = 2
            case 20, 22: count = 4
            case 21: count = 6
            default: count = 0
            }
            if count > 0 {
                var buf = [Double](repeating: 0, count: count)
                v.getValue(&buf, size: count * MemoryLayout<Double>.size)
                return buf
            }
        }
        return String(describing: value)
    }

    /// Apply a setter to the object at `oid` (a UIView or CALayer). Returns a
    /// short confirmation string. Sends 204 and reads the single response frame.
    func modifyAttribute(oid: UInt64, setter: String, attrType: Int, value: Any) throws -> String {
        let modValue = try LookinClient.makeModificationValue(attrType: attrType, value: value)
        let mod = ReqModification(oid: oid, setter: setter, attrType: attrType, value: modValue, version: clientVersion)
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("LookinAttributeModification", for: ReqModification.self)
        archiver.encode(mod, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()

        let response = try roundTrip(type: RequestType.inbuiltAttrModification, payload: archiver.encodedData)

        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: response)
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        LookinModel.register(on: unarchiver)
        guard let attachment = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? LKSResponseAttachment else {
            throw LookinError.message("Failed to decode modification response")
        }
        if let err = attachment.error {
            throw LookinError.message("Modification failed: \(err)")
        }
        return "OK: \(setter) applied to oid \(oid)."
    }

    /// Convert a JSON tool argument into the object the server expects for a
    /// given LookinAttrType. Covers the common, modifiable types.
    static func makeModificationValue(attrType: Int, value: Any) throws -> Any {
        func nums(_ keys: [String]) throws -> [Double] {
            if let arr = value as? [Any] {
                return arr.compactMap { ($0 as? NSNumber)?.doubleValue }
            }
            if let dict = value as? [String: Any] {
                return try keys.map { k in
                    guard let n = (dict[k] as? NSNumber)?.doubleValue else {
                        throw LookinError.message("value is missing key '\(k)'")
                    }
                    return n
                }
            }
            throw LookinError.message("value must be an object or array of numbers")
        }
        switch attrType {
        case 2...13, 25, 26: // char/int/short/long/.../float/double/enum
            guard let n = value as? NSNumber else { throw LookinError.message("value must be a number") }
            return n
        case 14: // BOOL
            if let b = value as? Bool { return NSNumber(value: b) }
            if let n = value as? NSNumber { return n }
            throw LookinError.message("value must be a boolean")
        case 24, 15, 16: // NSString, Sel, Class
            guard let s = value as? String else { throw LookinError.message("value must be a string") }
            return s as NSString
        case 17: let p = try nums(["x", "y"]); return NSValue(point: CGPoint(x: p[0], y: p[1]))
        case 19: let s = try nums(["width", "height"]); return NSValue(size: CGSize(width: s[0], height: s[1]))
        case 20:
            let r = try nums(["x", "y", "width", "height"])
            return NSValue(rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]))
        case 27: // UIColor as [r,g,b,a] 0-1
            let c = try nums(["r", "g", "b", "a"])
            return c.map { NSNumber(value: $0) } as NSArray
        default:
            throw LookinError.message("attrType \(attrType) is not supported for modification yet (supported: numbers, BOOL, string, CGPoint/CGSize/CGRect, UIColor).")
        }
    }

    /// Screenshot a view. If `oid` is nil, screenshots the key window. If
    /// `maxSize` is set, the PNG is downscaled so its longest side ≤ maxSize px
    /// (smaller payload, faster to transfer and read).
    func getScreenshotPNG(oid: UInt64?, maxSize: Int? = nil) throws -> Data {
        let targetOid = try oid ?? keyWindowOid()
        let details = try fetchDetails(oids: [targetOid], taskType: 2 /* GroupScreenshot */, needAttrs: false)
        guard let png = details.first(where: { $0.oid == targetOid })?.screenshot ?? details.first?.screenshot else {
            throw LookinError.message("LookinServer returned no screenshot for oid \(targetOid). The view may be off-screen or too large.")
        }
        if let maxSize = maxSize, maxSize > 0 {
            return LookinClient.downscalePNG(png, maxSize: maxSize) ?? png
        }
        return png
    }

    /// The key window's (layer) oid, from a fresh hierarchy fetch.
    func keyWindowOid() throws -> UInt64 {
        let payload = try LookinClient.encodeRequest(["clientVersion": clientVersion])
        let response = try roundTrip(type: RequestType.hierarchy, payload: payload)
        let info = try decodeHierarchy(response)
        let item = info.displayItems.first(where: { $0.representedAsKeyWindow }) ?? info.displayItems.first
        guard let oid = item?.oid else {
            throw LookinError.message("Empty hierarchy — is the app in the foreground?")
        }
        return oid
    }

    /// Run the HierarchyDetails(203) flow for the given oids. The server may
    /// answer in several frames (dataTotalCount / currentDataCount); we read
    /// until every requested detail has arrived.
    private func fetchDetails(oids: [UInt64], taskType: Int, needAttrs: Bool) throws -> [LKSDisplayItemDetail] {
        let payload = try LookinClient.encodeDetailRequest(oids: oids, taskType: taskType, needAttrs: needAttrs, version: clientVersion)

        let fd = try DeviceSelection.shared.connect()
        defer { close(fd) }
        try Peertalk.sendFrame(fd, type: RequestType.hierarchyDetails, tag: 1, payload: payload)

        var details: [LKSDisplayItemDetail] = []
        var total = oids.count
        while details.count < total {
            let frame = try Peertalk.readFrame(fd)
            if frame.type == Peertalk.frameTypeEndOfStream { break }
            if frame.payload.isEmpty { continue }
            let (chunk, dataTotal) = try LookinClient.decodeDetails(frame.payload)
            if ProcessInfo.processInfo.environment["LOOIN_DEBUG"] != nil {
                for d in chunk {
                    FileHandle.standardError.write("[detail] oid=\(d.oid) group=\(d.groupScreenshot?.count ?? -1) solo=\(d.soloScreenshot?.count ?? -1)\n".data(using: .utf8)!)
                }
                FileHandle.standardError.write("[detail] chunk=\(chunk.count) dataTotal=\(dataTotal ?? -1)\n".data(using: .utf8)!)
            }
            details.append(contentsOf: chunk)
            if let dataTotal = dataTotal, dataTotal > 0 { total = dataTotal }
            if chunk.isEmpty { break } // guard against a stall
        }
        return details
    }

    // MARK: - Transport

    /// Open a fresh connection, send one request frame, read the response frame
    /// with the matching tag, and return its payload. A new connection per call
    /// keeps things simple and matches the request/response nature of the tools.
    private func roundTrip(type: UInt32, payload: Data) throws -> Data {
        let fd = try DeviceSelection.shared.connect()
        defer { close(fd) }

        let tag: UInt32 = 1
        try Peertalk.sendFrame(fd, type: type, tag: tag, payload: payload)

        // The base hierarchy response is a single frame. Read until we get one
        // carrying a payload for our tag (ignore any zero-payload acks).
        while true {
            let frame = try Peertalk.readFrame(fd)
            if frame.type == Peertalk.frameTypeEndOfStream {
                throw LookinError.message("LookinServer ended the stream before responding")
            }
            if !frame.payload.isEmpty {
                return frame.payload
            }
        }
    }

    // MARK: - Codec

    static func encodeRequest(_ dict: [String: Any]) throws -> Data {
        // LookinServer reads the request as a bare NSDictionary (non-secure).
        return try NSKeyedArchiver.archivedData(withRootObject: dict, requiringSecureCoding: false)
    }

    /// Archive a 203 request: an array of task packages, one task per oid.
    /// attrRequest: 1 = Need, 2 = NotNeed. taskType: 1 = Solo, 2 = Group.
    static func encodeDetailRequest(oids: [UInt64], taskType: Int, needAttrs: Bool, version: String) throws -> Data {
        let tasks = oids.map {
            ReqTask(oid: $0, taskType: taskType, attrRequest: needAttrs ? 1 : 2,
                    needBasis: needAttrs, needSub: false, version: version)
        }
        let packages = [ReqPackage(tasks: tasks)]
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("LookinStaticAsyncUpdateTask", for: ReqTask.self)
        archiver.setClassName("LookinStaticAsyncUpdateTasksPackage", for: ReqPackage.self)
        archiver.encode(packages as NSArray, forKey: NSKeyedArchiveRootObjectKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Decode a 203 response frame into its detail chunk and the overall total.
    static func decodeDetails(_ payload: Data) throws -> ([LKSDisplayItemDetail], Int?) {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: payload)
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        LookinModel.register(on: unarchiver)

        guard let attachment = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? LKSResponseAttachment else {
            throw LookinError.message("Failed to decode LookinServer detail response")
        }
        let chunk = (attachment.data as? [Any])?.compactMap { $0 as? LKSDisplayItemDetail } ?? []
        return (chunk, attachment.dataTotalCount)
    }

    private func decodeHierarchy(_ payload: Data) throws -> LKSHierarchyInfo {
        return try LookinClient.decodeHierarchyInfo(from: payload)
    }

    /// Decode a LookinServer response payload into its hierarchy. Static so the
    /// self-test can exercise the exact same path with a synthetic payload.
    static func decodeHierarchyInfo(from payload: Data) throws -> LKSHierarchyInfo {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: payload)
        unarchiver.requiresSecureCoding = false
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        LookinModel.register(on: unarchiver)

        guard let attachment = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? LKSResponseAttachment
        else {
            throw LookinError.message("Failed to decode LookinServer response (unexpected root object)")
        }
        if let err = attachment.error {
            throw LookinError.message("LookinServer returned an error: \(err)")
        }
        guard let info = attachment.data as? LKSHierarchyInfo else {
            throw LookinError.message("LookinServer response did not contain a hierarchy")
        }
        return info
    }

    // MARK: - JSON

    private static func jsonNode(_ item: LKSDisplayItem, depth: Int, maxDepth: Int?, count: inout Int) -> [String: Any] {
        count += 1
        var node: [String: Any] = [
            "oid": item.oid,
            "className": item.lookinClassName,
            "frame": [item.frame.origin.x, item.frame.origin.y, item.frame.size.width, item.frame.size.height],
        ]
        if let viewOid = item.viewOid, viewOid != item.oid { node["viewOid"] = viewOid }
        if item.isHidden { node["hidden"] = true }
        if item.alpha < 1.0 { node["alpha"] = item.alpha }
        if item.representedAsKeyWindow { node["keyWindow"] = true }
        if let title = item.customDisplayTitle { node["title"] = title }

        let atMaxDepth = maxDepth.map { depth + 1 >= $0 } ?? false
        if !item.subitems.isEmpty && !atMaxDepth {
            node["children"] = item.subitems.map {
                jsonNode($0, depth: depth + 1, maxDepth: maxDepth, count: &count)
            }
        }
        return node
    }

    /// Downscale a PNG so its longest side ≤ maxSize px, re-encoded as PNG.
    /// Returns nil on failure (caller falls back to the original).
    static func downscalePNG(_ data: Data, maxSize: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    static func jsonString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
