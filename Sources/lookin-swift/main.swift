import Foundation

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
}

if CommandLine.arguments.contains("--devices") {
    do {
        let devices = try UsbMux.listDevices()
        print("USB devices: \(devices.map { "\($0.udid) (id \($0.deviceId))" })")
    } catch {
        print("usbmux error: \(error.localizedDescription)")
    }
    exit(0)
}

func describeTarget(_ t: DeviceTarget) -> String {
    switch t {
    case .auto: return "auto"
    case .simulator: return "simulator"
    case .device(let udid): return "device \(udid)"
    }
}

let server = MCPServer(name: "lookin-swift", version: "0.1.0")

let oidSchema: [String: Any] = [
    "type": "object",
    "properties": [
        "oid": ["type": "number", "description": "Target view object ID (from lookin_get_hierarchy)"],
    ],
    "required": ["oid"],
]

server.register(Tool(
    name: "lookin_get_hierarchy",
    description: "Return the running iOS app's UI view hierarchy tree (oid, className, frame, hidden, alpha) via official LookinServer. Requires the iOS app with LookinServer running in a booted simulator.",
    inputSchema: [
        "type": "object",
        "properties": [
            "maxDepth": ["type": "number", "description": "Maximum hierarchy depth. Returns all levels if omitted."],
        ],
    ],
    handler: { args in
        let maxDepth = (args["maxDepth"] as? NSNumber)?.intValue
        let json = try LookinClient.shared.getHierarchyJSON(maxDepth: maxDepth)
        return [textContent(json)]
    }
))

server.register(Tool(
    name: "lookin_get_attributes",
    description: "Query all UI attributes (identifier, attrType, value) of a view by oid, grouped by section. Get the oid from lookin_get_hierarchy first.",
    inputSchema: oidSchema,
    handler: { args in
        guard let oid = (args["oid"] as? NSNumber)?.uint64Value else {
            throw LookinError.message("Missing required argument: oid")
        }
        let json = try LookinClient.shared.getAttributesJSON(oid: oid)
        return [textContent(json)]
    }
))

server.register(Tool(
    name: "lookin_modify_attribute",
    description: "Modify a live UI property on the device. Calls a setter on the object at `oid`. Use `viewOid` from the hierarchy for UIView setters (setAlpha:, setHidden:, setBackgroundColor:, setFrame:), or `oid` (layer) for CALayer setters (setCornerRadius:, setOpacity:). value format by attrType: 14 BOOL=true/false; 12/13/5 number; 24 NSString=string; 17 CGPoint={x,y}; 19 CGSize={width,height}; 20 CGRect={x,y,width,height}; 27 UIColor={r,g,b,a} (0-1).",
    inputSchema: [
        "type": "object",
        "properties": [
            "oid": ["type": "number", "description": "Object ID of the view/layer to modify"],
            "setterSelector": ["type": "string", "description": "Objective-C setter, e.g. \"setAlpha:\", \"setHidden:\", \"setBackgroundColor:\""],
            "attrType": ["type": "number", "description": "LookinAttrType of the value (14 BOOL, 12 float, 13 double, 5 long, 24 NSString, 17 CGPoint, 19 CGSize, 20 CGRect, 27 UIColor)"],
            "value": ["description": "New value; shape depends on attrType (see tool description)"],
        ],
        "required": ["oid", "setterSelector", "attrType", "value"],
    ],
    handler: { args in
        guard let oid = (args["oid"] as? NSNumber)?.uint64Value else { throw LookinError.message("Missing required argument: oid") }
        guard let setter = args["setterSelector"] as? String else { throw LookinError.message("Missing required argument: setterSelector") }
        guard let attrType = (args["attrType"] as? NSNumber)?.intValue else { throw LookinError.message("Missing required argument: attrType") }
        guard let value = args["value"] else { throw LookinError.message("Missing required argument: value") }
        let result = try LookinClient.shared.modifyAttribute(oid: oid, setter: setter, attrType: attrType, value: value)
        return [textContent(result)]
    }
))

server.register(Tool(
    name: "lookin_list_devices",
    description: "List connectable iOS targets: booted simulators and USB-connected devices. Use before lookin_connect_device when more than one is available.",
    inputSchema: ["type": "object", "properties": [String: Any]()],
    handler: { _ in
        let devices = DeviceSelection.shared.list()
        let json = try LookinClient.jsonString([
            "devices": devices.map { ["udid": $0.udid, "name": $0.name, "type": $0.type] },
            "current": describeTarget(DeviceSelection.shared.target),
        ])
        return [textContent(json)]
    }
))

server.register(Tool(
    name: "lookin_connect_device",
    description: "Select which target the other tools connect to. Pass a device UDID (from lookin_list_devices), \"simulator\" for the booted simulator, or \"auto\" to auto-detect.",
    inputSchema: [
        "type": "object",
        "properties": [
            "target": ["type": "string", "description": "A device UDID, or \"simulator\", or \"auto\""],
        ],
        "required": ["target"],
    ],
    handler: { args in
        guard let target = args["target"] as? String else { throw LookinError.message("Missing required argument: target") }
        switch target.lowercased() {
        case "auto": DeviceSelection.shared.target = .auto
        case "simulator", "sim": DeviceSelection.shared.target = .simulator
        default: DeviceSelection.shared.target = .device(udid: target)
        }
        return [textContent("Target set to \(describeTarget(DeviceSelection.shared.target)).")]
    }
))

server.register(Tool(
    name: "lookin_get_screenshot",
    description: "Screenshot (PNG). Omit oid to capture the whole key window (no need to look up an oid first). Pass maxSize to downscale for a smaller, faster image when you just need to see the layout.",
    inputSchema: [
        "type": "object",
        "properties": [
            "oid": ["type": "number", "description": "Target view oid (from lookin_get_hierarchy). Omit for the full key window."],
            "maxSize": ["type": "number", "description": "If set, longest side is scaled down to this many pixels (e.g. 800)."],
        ],
    ],
    handler: { args in
        let oid = (args["oid"] as? NSNumber)?.uint64Value
        let maxSize = (args["maxSize"] as? NSNumber)?.intValue
        let png = try LookinClient.shared.getScreenshotPNG(oid: oid, maxSize: maxSize)
        return [[
            "type": "image",
            "data": png.base64EncodedString(),
            "mimeType": "image/png",
        ]]
    }
))

// ── Control tools (require the LookinServer-Control pod in the app) ──

server.register(Tool(
    name: "lookin_tap",
    description: "Tap at a point on screen (points, same coordinate space as the hierarchy frames). Injects a real touch via LookinServer-Control. Tap a control's frame center from lookin_get_hierarchy.",
    inputSchema: [
        "type": "object",
        "properties": [
            "x": ["type": "number", "description": "X in screen points"],
            "y": ["type": "number", "description": "Y in screen points"],
        ],
        "required": ["x", "y"],
    ],
    handler: { args in
        guard let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue else {
            throw LookinError.message("Missing required arguments: x, y")
        }
        try ControlClient.send(["action": "tap", "x": x, "y": y])
        return [textContent("Tapped (\(x), \(y)).")]
    }
))

server.register(Tool(
    name: "lookin_long_press",
    description: "Press and hold at a point (screen points) for a duration, then release. Injects a real touch via LookinServer-Control.",
    inputSchema: [
        "type": "object",
        "properties": [
            "x": ["type": "number"], "y": ["type": "number"],
            "duration": ["type": "number", "description": "Seconds to hold (default 0.6)"],
        ],
        "required": ["x", "y"],
    ],
    handler: { args in
        guard let x = (args["x"] as? NSNumber)?.doubleValue, let y = (args["y"] as? NSNumber)?.doubleValue else {
            throw LookinError.message("Missing required arguments: x, y")
        }
        var cmd: [String: Any] = ["action": "longPress", "x": x, "y": y]
        if let d = (args["duration"] as? NSNumber)?.doubleValue { cmd["duration"] = d }
        try ControlClient.send(cmd)
        return [textContent("Long-pressed (\(x), \(y)).")]
    }
))

server.register(Tool(
    name: "lookin_swipe",
    description: "Swipe/drag from one point to another (screen points) over a duration. Injects a real touch via LookinServer-Control. Use to scroll lists or dismiss sheets.",
    inputSchema: [
        "type": "object",
        "properties": [
            "fromX": ["type": "number"], "fromY": ["type": "number"],
            "toX": ["type": "number"], "toY": ["type": "number"],
            "duration": ["type": "number", "description": "Seconds (default 0.3)"],
        ],
        "required": ["fromX", "fromY", "toX", "toY"],
    ],
    handler: { args in
        func num(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        guard let fx = num("fromX"), let fy = num("fromY"), let tx = num("toX"), let ty = num("toY") else {
            throw LookinError.message("Missing required arguments: fromX, fromY, toX, toY")
        }
        var cmd: [String: Any] = ["action": "swipe", "fromX": fx, "fromY": fy, "toX": tx, "toY": ty]
        if let d = num("duration") { cmd["duration"] = d }
        try ControlClient.send(cmd)
        return [textContent("Swiped (\(fx), \(fy)) → (\(tx), \(ty)).")]
    }
))

FileHandle.standardError.write("[lookin-swift] started (LookinServer: simulator :47164-47169, USB device :47175-47179; Control :47180)\n".data(using: .utf8)!)
server.run()
