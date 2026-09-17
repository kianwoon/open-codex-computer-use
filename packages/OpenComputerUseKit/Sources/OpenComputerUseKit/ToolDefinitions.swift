import Foundation

public struct ToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let annotations: [String: Any]
    public let inputSchema: [String: Any]

    public init(name: String, description: String, annotations: [String: Any], inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.annotations = annotations
        self.inputSchema = inputSchema
    }

    public var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]

        if !annotations.isEmpty {
            dictionary["annotations"] = annotations
        }

        return dictionary
    }
}

public enum ToolDefinitions {
    public static let all: [ToolDefinition] = [
        ToolDefinition(
            name: "click",
            description: "Click an element by index or pixel coordinates from screenshot. Requires the snapshot_id from the latest get_app_state. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element index to click. Provide this or element_key."),
                    "element_key": stringProperty(description: "Stable AX identifier of the element to click (the `ID:` shown in the tree). Prefer over element_index: it survives list reordering. Provide this or element_index."),
                    "x": numberProperty(description: "X coordinate in screenshot pixel coordinates"),
                    "y": numberProperty(description: "Y coordinate in screenshot pixel coordinates"),
                    "click_count": integerProperty(description: "Number of clicks. Defaults to 1"),
                    "mouse_button": stringProperty(
                        description: "Mouse button to click. Defaults to left.",
                        enumValues: ["left", "right", "middle"]
                    ),
                    "click_method": stringProperty(
                        description: "Click implementation: auto (default), accessibility, app_post, sky_click, or global. Accessibility requires element_index. app_post sends a public event directly to the target app. sky_click uses the macOS SkyLight background window path. Global may move the system pointer and requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1.",
                        enumValues: ClickMethod.allCases.map(\.rawValue)
                    ),
                    "snapshot_id": snapshotIDProperty(),
                ],
                required: ["app", "snapshot_id"]
            )
        ),
        ToolDefinition(
            name: "focus_window",
            description: "Raise and focus an already-running app's window so subsequent get_app_state snapshots target the correct window. Never launches the app: if the app is not running this fails with appNotFound. Optionally select a window by title substring or explicit pid, then verifies the frontmost window belongs to the app. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "title_contains": stringProperty(description: "Case-insensitive substring of the target window title. Omit to focus the frontmost/main window."),
                    "pid": integerProperty(description: "Explicit process id of the already-running app. Must match a running process."),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "drag",
            description: "Drag from one point to another using pixel coordinates. By default mouse events are posted directly to the target app and the system pointer does not move; that path cannot drive window-server drag sessions such as window moves, text selection, or Finder drag-and-drop. Those require OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 in the server process environment, which may move the real pointer. The result reports which path was used. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "from_x": numberProperty(description: "Start X coordinate"),
                    "from_y": numberProperty(description: "Start Y coordinate"),
                    "to_x": numberProperty(description: "End X coordinate"),
                    "to_y": numberProperty(description: "End Y coordinate"),
                ],
                required: ["app", "from_x", "from_y", "to_x", "to_y"]
            )
        ),
        ToolDefinition(
            name: "get_app_state",
            description: "Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text_limit": textLimitProperty(description: "Maximum text characters to return. Use \"max\" for full text. Defaults to 500."),
                    "max_tree_nodes": positiveIntegerProperty(description: "Maximum accessibility tree nodes to render. Defaults to 1200."),
                    "max_tree_depth": positiveIntegerProperty(description: "Maximum accessibility tree depth to render. Defaults to 64."),
                    "maxDimension": boundedIntegerProperty(description: "Longest edge of the returned window screenshot in pixels. Lower values shrink the image. Defaults to 1280.", minimum: 320, maximum: 4096),
                    "region": captureRegionProperty(description: "Crop the window screenshot to this rectangle, in per-window screenshot pixels. Returned coordinates stay per-window screenshot pixels, so a click at local (lx, ly) maps to window pixel (region.x + lx, region.y + ly). Omit to capture the whole window."),
                    "title_hint": stringProperty(description: "Optional case-insensitive substring the snapshot window title must contain. On mismatch the call fails with staleSnapshot — call focus_window first. Omit for current behavior."),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "list_apps",
            description: "List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Invoke a secondary accessibility action exposed by an element. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "action": stringProperty(description: "Secondary accessibility action name"),
                ],
                required: ["app", "element_index", "action"]
            )
        ),
        ToolDefinition(
            name: "press_key",
            description: "Press a key or key-combination on the keyboard, including modifier and navigation keys.\n  - This supports xdotool's `key` syntax.\n  - Examples: \"a\", \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\" (for the numpad 0 key). This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "key": stringProperty(description: "Key or key combination to press"),
                ],
                required: ["app", "key"]
            )
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll an element in a direction by a number of pages. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "direction": stringProperty(description: "Scroll direction: up, down, left, or right"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "pages": numberProperty(description: "Number of pages to scroll. Fractional values are supported. Defaults to 1"),
                ],
                required: ["app", "element_index", "direction"]
            )
        ),
        ToolDefinition(
            name: "set_value",
            description: "Set the value of a settable accessibility element. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "element_key": stringProperty(description: "Stable AX identifier of the element (the `ID:` shown in the tree). Prefer over element_index: it survives list reordering. Provide this or element_index."),
                    "value": stringProperty(description: "Value to assign"),
                    "snapshot_id": snapshotIDProperty(),
                ],
                required: ["app", "value", "snapshot_id"]
            )
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type literal text using keyboard input. Requires the snapshot_id from the latest get_app_state. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Literal text to type"),
                    "snapshot_id": snapshotIDProperty(),
                ],
                required: ["app", "text", "snapshot_id"]
            )
        ),
        ToolDefinition(
            name: "select_option",
            description: "Select an option from a popup button/menu by visible label. Opens the popup, presses the matching menu item (case-insensitive substring), then dismisses the menu with Escape and verifies it closed. Requires the snapshot_id from the latest get_app_state. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Popup button element index to open"),
                    "option": stringProperty(description: "Visible menu item text to select (case-insensitive substring match)"),
                    "snapshot_id": snapshotIDProperty(),
                ],
                required: ["app", "element_index", "option", "snapshot_id"]
            )
        ),
        ToolDefinition(
            name: "fill_form",
            description: "Set values on up to 30 elements in one call from a single snapshot. Validates the snapshot once, writes each field natively with no intermediate refresh, and returns per-item results plus the next snapshot_id. Continue-on-error: each item reports ok or an error. Requires the snapshot_id from the latest get_app_state. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "items": arrayProperty(
                        description: "Fields to fill, in order. Each item is {index: integer, value: string}.",
                        itemSchema: objectSchema(
                            properties: [
                                "index": integerProperty(description: "Element index to set"),
                                "value": stringProperty(description: "Value to assign"),
                            ],
                            required: ["index", "value"]
                        ),
                        maximum: 30
                    ),
                    "snapshot_id": snapshotIDProperty(),
                ],
                required: ["app", "items", "snapshot_id"]
            )
        ),
    ]
}

private func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]

    if !required.isEmpty {
        schema["required"] = required
    }

    return schema
}

private func defaultAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "openWorldHint": false,
    ]
}

private func readOnlyAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
        "readOnlyHint": true,
    ]
}

private func stringProperty(description: String, enumValues: [String]? = nil) -> [String: Any] {
    var property: [String: Any] = [
        "type": "string",
        "description": description,
    ]

    if let enumValues {
        property["enum"] = enumValues
    }

    return property
}

private func integerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "description": description,
    ]
}

private func arrayProperty(description: String, itemSchema: [String: Any], maximum: Int? = nil) -> [String: Any] {
    var property: [String: Any] = [
        "type": "array",
        "description": description,
        "items": itemSchema,
    ]

    if let maximum {
        property["maxItems"] = maximum
    }

    return property
}

private func positiveIntegerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "minimum": 1,
        "description": description,
    ]
}

private func boundedIntegerProperty(description: String, minimum: Int, maximum: Int) -> [String: Any] {
    [
        "type": "integer",
        "minimum": minimum,
        "maximum": maximum,
        "description": description,
    ]
}

private func captureRegionProperty(description: String) -> [String: Any] {
    [
        "type": "object",
        "description": description,
        "properties": [
            "x": integerProperty(description: "Region origin X in per-window screenshot pixels. Must be >= 0."),
            "y": integerProperty(description: "Region origin Y in per-window screenshot pixels. Must be >= 0."),
            "width": integerProperty(description: "Region width in per-window screenshot pixels. Must be > 0."),
            "height": integerProperty(description: "Region height in per-window screenshot pixels. Must be > 0."),
        ],
        "required": ["x", "y", "width", "height"],
        "additionalProperties": false,
    ]
}

private func textLimitProperty(description: String) -> [String: Any] {
    [
        "anyOf": [
            [
                "type": "integer",
                "minimum": 1,
            ],
            [
                "type": "string",
                "enum": [SnapshotTextLimit.maxKeyword],
            ],
        ],
        "description": description,
    ]
}

private func numberProperty(description: String) -> [String: Any] {
    [
        "type": "number",
        "description": description,
    ]
}

private func snapshotIDProperty() -> [String: Any] {
    stringProperty(
        description: "Required snapshot ID from the latest get_app_state (its `Snapshot ID:` line). If it does not match the current snapshot, the action is rejected as stale — call get_app_state again."
    )
}
