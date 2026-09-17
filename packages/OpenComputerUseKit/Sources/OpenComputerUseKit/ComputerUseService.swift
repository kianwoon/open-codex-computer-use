import AppKit
import ApplicationServices
import Foundation
import ImageIO

struct VisualCursorTarget: Equatable {
    let point: CGPoint
    let window: CursorTargetWindow?
}

public enum ClickMethod: String, CaseIterable, Sendable {
    case auto
    case accessibility
    case appPost = "app_post"
    case skyClick = "sky_click"
    case global
}

func clickActionSnapshotRecoveryPolicy(for method: ClickMethod) -> SnapshotRecoveryPolicy {
    method == .skyClick ? .readOnly : .allowActivation
}

func parseClickMethod(_ rawValue: String?) throws -> ClickMethod {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ClickMethod.auto.rawValue

    guard let method = ClickMethod(rawValue: normalized) else {
        let expected = ClickMethod.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid click_method '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return method
}

func validateClickMethod(
    _ method: ClickMethod,
    hasElementIndex: Bool,
    environment: [String: String]
) throws {
    if method == .accessibility, !hasElementIndex {
        throw ComputerUseError.message("click_method 'accessibility' requires element_index")
    }

    if method == .global, !globalPointerFallbacksEnabled(environment: environment) {
        throw ComputerUseError.message(
            "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
        )
    }
}

func validateSkyClickArguments(
    method: ClickMethod,
    mouseButton: String,
    clickCount: Int
) throws {
    guard method == .skyClick else {
        return
    }

    guard mouseButton.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == MouseButtonKind.left.rawValue else {
        throw ComputerUseError.message(
            "click_method 'sky_click' only supports mouse_button 'left'"
        )
    }

    guard (1...2).contains(clickCount) else {
        throw ComputerUseError.message(
            "click_method 'sky_click' supports click_count 1 or 2"
        )
    }
}

struct VisualCursorScreenMapping: Equatable {
    let screenStateFrame: CGRect
    let appKitFrame: CGRect
}

func currentVisualCursorScreenMappings() -> [VisualCursorScreenMapping] {
    NSScreen.screens.compactMap { screen in
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }

        return VisualCursorScreenMapping(
            screenStateFrame: CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value)),
            appKitFrame: screen.frame
        )
    }
}

func screenStatePointToAppKitGlobalPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    guard let mapping = screenMappings.first(where: { $0.screenStateFrame.contains(point) }) else {
        return point
    }

    let localX = point.x - mapping.screenStateFrame.minX
    let localY = point.y - mapping.screenStateFrame.minY

    return CGPoint(
        x: mapping.appKitFrame.minX + localX,
        y: mapping.appKitFrame.maxY - localY
    )
}

func visualCursorAppKitPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    screenStatePointToAppKitGlobalPoint(
        fromScreenStatePoint: point,
        screenMappings: screenMappings
    )
}

func inputEventPoint(
    fromScreenStatePoint point: CGPoint,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> CGPoint {
    point
}

func makeVisualCursorTarget(
    at point: CGPoint,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> VisualCursorTarget {
    VisualCursorTarget(
        point: screenStatePointToAppKitGlobalPoint(
            fromScreenStatePoint: point,
            screenMappings: screenMappings
        ),
        window: targetWindowID.map { CursorTargetWindow(windowID: $0, layer: targetWindowLayer ?? 0) }
    )
}

func makeVisualCursorTarget(
    localFrame: CGRect?,
    windowBounds: CGRect?,
    targetWindowID: CGWindowID?,
    targetWindowLayer: Int?,
    screenMappings: [VisualCursorScreenMapping] = currentVisualCursorScreenMappings()
) -> VisualCursorTarget? {
    guard let localFrame, let windowBounds else {
        return nil
    }

    let point = CGPoint(
        x: windowBounds.minX + localFrame.midX,
        y: windowBounds.minY + localFrame.midY
    )
    return makeVisualCursorTarget(
        at: point,
        targetWindowID: targetWindowID,
        targetWindowLayer: targetWindowLayer,
        screenMappings: screenMappings
    )
}

func inputFallbackDebugEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_DEBUG_INPUT_FALLBACKS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

func globalPointerFallbacksEnabled(environment: [String: String]) -> Bool {
    guard let rawValue = environment["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS"]?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    else {
        return false
    }

    return ["1", "true", "yes", "on"].contains(rawValue)
}

/// How a `drag` is delivered. `drag` has no method argument; the path is decided
/// by the same process-level gate that authorizes `click_method=global`.
enum DragDeliveryPath: String, CaseIterable {
    /// `CGEvent.postToPid`: never moves the system pointer, but the events do not
    /// pass through the window server, so window-server drag sessions (window
    /// moves, text selection, Finder drag-and-drop) are not driven.
    case appPost = "app_post"
    /// `.cghidEventTap`: drives window-server drag sessions and may move the
    /// real pointer or change foreground focus.
    case global
}

func dragDeliveryPath(environment: [String: String]) -> DragDeliveryPath {
    globalPointerFallbacksEnabled(environment: environment) ? .global : .appPost
}

func dragDeliveryNote(for path: DragDeliveryPath) -> String {
    switch path {
    case .appPost:
        return "Drag delivered via app_post: mouse events were posted directly to the target process and the system pointer did not move. This path cannot drive window-server drag sessions such as window moves, text selection, or Finder drag-and-drop. If the drag had no effect, set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 in the server process environment to use the global pointer path, which may move the real pointer and change foreground focus."
    case .global:
        return "Drag delivered via global pointer path: OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS is enabled, so the real pointer may have moved and foreground focus may have changed."
    }
}

/// Inserts the delivery note after the snapshot text and before any screenshot,
/// so `primaryText` remains the snapshot for existing consumers.
func appendingDragDeliveryNote(to result: ToolCallResult, path: DragDeliveryPath) -> ToolCallResult {
    var content = result.content
    let insertIndex = content.firstIndex { $0.dictionary["type"] as? String == "image" } ?? content.endIndex
    content.insert(.text(dragDeliveryNote(for: path)), at: insertIndex)
    return ToolCallResult(content: content, isError: result.isError)
}

func screenshotPixelScale(
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGSize {
    guard
        let screenshotPixelSize,
        let windowBounds,
        windowBounds.width > 0,
        windowBounds.height > 0,
        screenshotPixelSize.width > 0,
        screenshotPixelSize.height > 0
    else {
        return CGSize(width: 1, height: 1)
    }

    return CGSize(
        width: screenshotPixelSize.width / windowBounds.width,
        height: screenshotPixelSize.height / windowBounds.height
    )
}

func screenshotPixelToWindowPoint(
    _ point: CGPoint,
    screenshotPixelSize: CGSize?,
    windowBounds: CGRect?
) -> CGPoint {
    let scale = screenshotPixelScale(
        screenshotPixelSize: screenshotPixelSize,
        windowBounds: windowBounds
    )
    return CGPoint(
        x: point.x / scale.width,
        y: point.y / scale.height
    )
}

let nonSettableSetValueErrorMessage = "Cannot set a value for an element that is not settable"
let settableTextRoles: Set<String> = [
    kAXTextFieldRole as String,
    "AXSecureTextField",
    kAXComboBoxRole as String,
]

/// When the caller points `set_value` at a label (e.g. a StaticText sibling of
/// the real field), append the nearest settable text neighbor so the model can
/// self-correct without another `get_app_state` roundtrip.
func nonSettableSetValueErrorMessage(record: ElementRecord, snapshot: AppSnapshot) -> String {
    let targetRole = displaySetValueRole(record.role)
    let targetLabel = setValueElementLabel(record: record)
    var message = "\(nonSettableSetValueErrorMessage): element \(record.index) is \(targetRole)"

    if let targetLabel {
        message += " '\(targetLabel)'"
    }

    guard let neighbor = nearestSettableTextNeighbor(around: record.index, in: snapshot) else {
        return message
    }

    return message + "; did you mean \(neighbor.index) (\(displaySetValueRole(neighbor.role)))?"
}

/// Scans ±3 indices for the first settable text field/secure field/combobox.
func nearestSettableTextNeighbor(around index: Int, in snapshot: AppSnapshot) -> (index: Int, role: String?)? {
    for offset in 1...3 {
        for candidate in [index + offset, index - offset] {
            guard let record = snapshot.elements[candidate],
                  let role = record.role,
                  settableTextRoles.contains(role)
            else {
                continue
            }

            return (candidate, role)
        }
    }

    return nil
}

func optionNotFoundMessage(option: String, elementIndex: String, availableTitles: [String]) -> String {
    let available = availableTitles.joined(separator: ", ")
    return "no menu item matching '\(option)' for element \(elementIndex)"
        + (available.isEmpty ? "" : " (available: \(available))")
}

/// A menu/popup choice reduced to the fields that matter for matching. Native
/// HTML selects surface menu items under a transient AXMenu window (not the
/// popup subtree) and often as AXRow/AXCell rather than AXMenuItem, so matching
/// must not assume the popup subtree or the AXMenuItem role.
struct MenuOptionCandidate: Equatable {
    let role: String?
    let title: String?
    let value: String?
}

func isSelectableMenuOptionRole(_ role: String?) -> Bool {
    switch role {
    case kAXMenuItemRole as String,
         kAXRowRole as String,
         "AXCell",
         kAXStaticTextRole as String:
        return true
    default:
        return false
    }
}

/// Case-insensitive substring match against both the title and the value, since
/// native selects sometimes carry the label only in AXValue.
func menuOptionCandidateMatches(_ candidate: MenuOptionCandidate, option: String) -> Bool {
    guard isSelectableMenuOptionRole(candidate.role) else {
        return false
    }

    return [candidate.title, candidate.value]
        .compactMap { $0 }
        .contains { !$0.isEmpty && $0.range(of: option, options: .caseInsensitive) != nil }
}

func firstMatchingMenuOptionIndex(in candidates: [MenuOptionCandidate], option: String) -> Int? {
    candidates.firstIndex { menuOptionCandidateMatches($0, option: option) }
}

enum FocusVerificationOutcome: Equatable {
    case focused
    case retry
    case failed
}

func focusTitleMatches(_ focusedTitle: String?, _ expectedTitle: String?) -> Bool {
    expectedTitle == nil || focusedTitle == expectedTitle || (focusedTitle?.isEmpty ?? true)
}

/// Decides whether a raised window counts as focused. The system-wide
/// `kAXFocusedWindowAttribute` is nil (pid 0) whenever our process is not the
/// active app, so a pid-0 read is only accepted when the target app is the
/// frontmost application and it exposes its main window — never when a
/// different app is frontmost.
func focusVerificationOutcome(
    focusedPID: pid_t,
    focusedTitle: String?,
    appPID: pid_t,
    expectedTitle: String?,
    frontmostAppPID: pid_t?,
    targetMainWindowTitle: String?
) -> FocusVerificationOutcome {
    if focusedPID == appPID, focusTitleMatches(focusedTitle, expectedTitle) {
        return .focused
    }

    if focusedPID == 0 {
        guard frontmostAppPID == appPID, targetMainWindowTitle != nil else {
            return .failed
        }
        return focusTitleMatches(targetMainWindowTitle, expectedTitle) ? .focused : .retry
    }

    if frontmostAppPID == appPID {
        return .retry
    }

    return .failed
}

func displaySetValueRole(_ role: String?) -> String {    switch role {
    case kAXTextFieldRole as String:
        return "TextField"
    case "AXSecureTextField":
        return "SecureTextField"
    case kAXComboBoxRole as String:
        return "ComboBox"
    case kAXStaticTextRole as String:
        return "StaticText"
    case let role?:
        return role
    default:
        return "element"
    }
}

func setValueElementLabel(record: ElementRecord) -> String? {
    guard let element = record.element else {
        return record.identifier
    }

    for attribute in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXPlaceholderValueAttribute as String] {
        if let value = stringValue(of: element, attribute: attribute), !value.isEmpty {
            return value
        }
    }

    return record.identifier
}
let staleSnapshotErrorMessage = "stale snapshot — call get_app_state again"
let staleElementErrorMessage = "stale element handle — call get_app_state again"
let snapshotIDRequiredErrorMessage = "snapshot_id required — pass Snapshot ID from latest get_app_state"

/// Ensures an action carries the snapshot id from the latest `get_app_state`.
/// A missing or mismatched id means the caller is acting on stale data.
func requireSnapshotID(_ provided: String?) throws {
    guard let provided, !provided.isEmpty else {
        throw ComputerUseError.staleSnapshot(snapshotIDRequiredErrorMessage)
    }
}

func validateSnapshotIDValue(_ provided: String?, snapshot: AppSnapshot) throws {
    try requireSnapshotID(provided)

    guard provided == snapshot.snapshotID else {
        throw ComputerUseError.staleSnapshot(staleSnapshotErrorMessage)
    }
}

/// Optional `title_hint` guard for `get_app_state`: when provided, the built
/// snapshot's window title must contain the hint (case-insensitive).
func validateWindowTitleHint(_ hint: String?, snapshot: AppSnapshot) throws {
    guard let normalizedHint = hint?.trimmingCharacters(in: .whitespacesAndNewlines), !normalizedHint.isEmpty else {
        return
    }

    let title = snapshot.windowTitle ?? ""
    guard title.range(of: normalizedHint, options: .caseInsensitive) != nil else {
        throw ComputerUseError.staleSnapshot(
            "window mismatch: expected '\(normalizedHint)', got '\(title)' — call focus_window first"
        )
    }
}

/// Click safety gate: a click target must belong to the snapshot's app. A
/// mismatched pid means we would be clicking/activating a different app.
func validateClickOwnership(elementPID: pid_t, snapshotPID: pid_t) throws {
    guard elementPID == snapshotPID else {
        throw ComputerUseError.staleSnapshot(staleSnapshotErrorMessage)
    }
}

func setValueAttributeIsSettable(result: AXError, settable: Bool, attribute: String) throws -> Bool {
    if result == .invalidUIElement {
        throw ComputerUseError.staleElement(staleElementErrorMessage)
    }

    guard result == .success else {
        throw ComputerUseError.message("AXUIElementIsAttributeSettable(\(attribute)) failed with \(result.rawValue)")
    }

    return settable
}

func invalidSecondaryActionErrorMessage(action: String, elementIndex: Int) -> String {
    "\(action) is not a valid secondary action for \(elementIndex)"
}

func localClickActionPoints(frame: CGRect, isSyntheticText: Bool) -> [CGPoint] {
    let center = CGPoint(x: frame.midX, y: frame.midY)
    let leading = CGPoint(
        x: frame.minX + min(max(frame.width * 0.3, 20), max(frame.width - 4, 20)),
        y: frame.midY
    )

    if isSyntheticText {
        return [leading]
    }

    if abs(leading.x - center.x) < 1 {
        return [center]
    }

    return [center, leading]
}

func isLikelySyntheticSideActionCandidate(
    parentFrame: CGRect?,
    candidateFrame: CGRect?,
    hasPrimaryAction: Bool,
    labels: [String]
) -> Bool {
    let hasSideActionLabel = labels.contains { label in
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else {
            return false
        }

        if normalized == "完成" || normalized == "done" || normalized == "complete" || normalized == "archive" {
            return true
        }

        if normalized.count <= 24 {
            if normalized.contains("完成") {
                return true
            }

            if normalized.contains("mark") && (normalized.contains("done") || normalized.contains("complete")) {
                return true
            }
        }

        return false
    }

    guard let parentFrame, let candidateFrame else {
        return false
    }

    let trailingBandWidth = min(max(parentFrame.width * 0.22, 56), 140)
    let isTrailing = candidateFrame.midX >= parentFrame.maxX - trailingBandWidth
    let compactWidth = candidateFrame.width <= max(88, parentFrame.width * 0.18)
    let compactHeight = candidateFrame.height <= max(44, parentFrame.height * 1.2)
    let isCompact = compactWidth && compactHeight

    if hasSideActionLabel && hasPrimaryAction && isCompact {
        return true
    }

    return isTrailing && isCompact && (hasPrimaryAction || hasSideActionLabel)
}

func shouldScanDescendantsOfHitRecord(originalFrame: CGRect?, hitFrame: CGRect?) -> Bool {
    guard let originalFrame, let hitFrame else {
        return true
    }

    let originalArea = max(originalFrame.width * originalFrame.height, 1)
    let hitArea = hitFrame.width * hitFrame.height
    if hitArea > max(originalArea * 12, 20_000) {
        return false
    }

    if hitFrame.height > max(originalFrame.height * 4, 96),
       hitFrame.width > max(originalFrame.width * 2, 240)
    {
        return false
    }

    return true
}

func isLikelyContainingRowActionFrame(
    targetFrame: CGRect,
    candidateFrame: CGRect?,
    hasPrimaryAction: Bool
) -> Bool {
    let targetCenter = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
    guard
        hasPrimaryAction,
        let candidateFrame,
        candidateFrame.insetBy(dx: -2, dy: -2).contains(targetCenter),
        candidateFrame.width >= targetFrame.width,
        candidateFrame.height >= targetFrame.height,
        candidateFrame.height <= max(targetFrame.height + 32, targetFrame.height * 2)
    else {
        return false
    }

    return true
}

func canUseActivationOnlyClickFallback(role: String?) -> Bool {
    guard let role else {
        return false
    }

    return role == kAXWindowRole as String
}

func canUseKeyboardTextFallback(role: String?, roleDescription: String?, isValueSettable: Bool) -> Bool {
    if isValueSettable {
        return true
    }

    guard let role else {
        return false
    }

    if role == kAXTextFieldRole as String || role == "AXTextArea" || role == "AXTextView" {
        return true
    }

    guard let roleDescription = roleDescription?.lowercased() else {
        return false
    }

    return roleDescription.contains("text field")
        || roleDescription.contains("text area")
        || roleDescription.contains("text entry")
}

func isElectronScopedWebRowClickOptimizationTarget(appName: String, bundleIdentifier: String?) -> Bool {
    let normalizedBundleIdentifier = bundleIdentifier?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let normalizedName = appName
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()

    if let normalizedBundleIdentifier,
       normalizedBundleIdentifier.hasPrefix("com.electron.")
            || normalizedBundleIdentifier.contains(".electron.")
            || normalizedBundleIdentifier.contains("lark")
            || normalizedBundleIdentifier.contains("feishu")
    {
        return true
    }

    return normalizedName == "lark" || normalizedName == "feishu" || normalizedName == "飞书"
}

func shouldPreferContainingWebRowAXClickCandidate(
    role: String?,
    isSyntheticText: Bool,
    hasWebAreaAncestor: Bool,
    appName: String,
    bundleIdentifier: String?
) -> Bool {
    guard hasWebAreaAncestor,
          isElectronScopedWebRowClickOptimizationTarget(
            appName: appName,
            bundleIdentifier: bundleIdentifier
          )
    else {
        return false
    }

    guard let role else {
        return isSyntheticText
    }

    return role == kAXStaticTextRole as String || role == kAXGroupRole as String || isSyntheticText
}

public final class ComputerUseService {
    private var snapshotsByApp: [String: AppSnapshot] = [:]

    public init() {}

    public func listApps() -> ToolCallResult {
        ToolCallResult.text(
            AppDiscovery.listCatalog()
                .map(\.renderedLine)
                .joined(separator: "\n")
        )
    }

    public func getAppState(
        app query: String,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        screenshotMaxDimension: CGFloat = screenshotResultMaxDimension,
        screenshotRegion: CaptureRegion? = nil,
        titleHint: String? = nil
    ) throws -> ToolCallResult {
        let snapshot = try refreshSnapshot(
            for: query,
            textLimit: textLimit,
            treeLimits: treeLimits,
            screenshotMaxDimension: screenshotMaxDimension,
            screenshotRegion: screenshotRegion
        )
        try validateWindowTitleHint(titleHint, snapshot: snapshot)
        return snapshotResult(for: snapshot, style: .fullState)
    }

    /// Raises and activates an already-running app's window without ever
    /// launching the app. When `titleContains` is nil the frontmost/main window
    /// is used. After raising, verifies the system-wide focused window belongs
    /// to the target pid and its title matches, otherwise throws `focusFailed`.
    public func focusWindow(app query: String, titleContains: String? = nil, pid: Int? = nil) throws -> ToolCallResult {
        let explicitPID = pid.map { pid_t($0) }
        let app = try AppDiscovery.resolveRunningOnly(query, pid: explicitPID)
        let appElement = AXUIElementCreateApplication(app.pid)
        enableBestEffortAccessibilityModes(appElement)

        let windows = copyArray(appElement, attribute: kAXWindowsAttribute) ?? []
        guard !windows.isEmpty else {
            throw ComputerUseError.focusFailed("no windows for app '\(app.name)' (pid \(app.pid))")
        }

        let normalizedTitle = titleContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetWindow: AXUIElement
        if let normalizedTitle, !normalizedTitle.isEmpty {
            guard let matched = windows.first(where: { window in
                guard let title = stringValue(of: window, attribute: kAXTitleAttribute) else {
                    return false
                }
                return title.range(of: normalizedTitle, options: .caseInsensitive) != nil
            }) else {
                let available = windows
                    .compactMap { stringValue(of: $0, attribute: kAXTitleAttribute) }
                    .joined(separator: ", ")
                throw ComputerUseError.focusFailed(
                    "no window title contains '\(normalizedTitle)' for app '\(app.name)' (available: \(available))"
                )
            }
            targetWindow = matched
        } else {
            let systemWide = AXUIElementCreateSystemWide()
            let focusedApplication = copyElement(systemWide, attribute: kAXFocusedApplicationAttribute)
            targetWindow = SnapshotBuilder.currentWindow(
                appElement: appElement,
                appPID: app.pid,
                focusedApplication: focusedApplication
            ) ?? windows[0]
        }

        let expectedTitle = stringValue(of: targetWindow, attribute: kAXTitleAttribute)
        _ = AXUIElementSetAttributeValue(targetWindow, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        _ = AXUIElementPerformAction(targetWindow, kAXRaiseAction as CFString)
        _ = app.runningApplication.activate(options: [.activateAllWindows])

        try verifyFrontmostWindow(app: app, expectedTitle: expectedTitle)

        return ToolCallResult.text(
            "Focused window '\(expectedTitle ?? "")' of \(app.name) (pid \(app.pid))."
        )
    }

    private func verifyFrontmostWindow(app: RunningAppDescriptor, expectedTitle: String?) throws {
        let systemWide = AXUIElementCreateSystemWide()
        let appElement = AXUIElementCreateApplication(app.pid)

        // The window server needs a beat to finish AXRaise + activation; the
        // system-wide focused window is also nil while our process is inactive,
        // so retry up to 3 attempts over ~1.5s before deciding.
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.5)

            let focusedWindow = copyElement(systemWide, attribute: kAXFocusedWindowAttribute)
            let focusedPID = focusedWindow.map { pid(of: $0) } ?? 0
            let focusedTitle = focusedWindow.flatMap { stringValue(of: $0, attribute: kAXTitleAttribute) }
            let mainWindow = copyElement(appElement, attribute: kAXMainWindowAttribute)
            let mainWindowTitle = mainWindow.flatMap { stringValue(of: $0, attribute: kAXTitleAttribute) }
            let frontmostAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

            let outcome = focusVerificationOutcome(
                focusedPID: focusedPID,
                focusedTitle: focusedTitle,
                appPID: app.pid,
                expectedTitle: expectedTitle,
                frontmostAppPID: frontmostAppPID,
                targetMainWindowTitle: mainWindowTitle
            )

            switch outcome {
            case .focused:
                return
            case .retry, .failed:
                continue
            }
        }

        let focusedWindow = copyElement(systemWide, attribute: kAXFocusedWindowAttribute)
        let focusedPID = focusedWindow.map { pid(of: $0) } ?? 0
        let focusedTitle = focusedWindow.flatMap { stringValue(of: $0, attribute: kAXTitleAttribute) } ?? ""
        throw ComputerUseError.focusFailed(
            "frontmost window is pid \(focusedPID) '\(focusedTitle)', expected pid \(app.pid) '\(expectedTitle ?? "")'"
        )
    }

    public func click(
        app query: String,
        elementIndex: String?,
        x: Double?,
        y: Double?,
        clickCount: Int,
        mouseButton: String,
        clickMethod: ClickMethod = .auto,
        snapshotID: String? = nil,
        elementKey: String? = nil
    ) throws -> ToolCallResult {
        try performWithStaleRetry(query: query, snapshotID: snapshotID) { effectiveID in
            try performClick(
                app: query,
                elementIndex: elementIndex,
                x: x,
                y: y,
                clickCount: clickCount,
                mouseButton: mouseButton,
                clickMethod: clickMethod,
                snapshotID: effectiveID,
                elementKey: elementKey
            )
        }
    }

    /// Runs `body`; on a stale snapshot/element failure it refreshes the
    /// snapshot natively once and retries with the fresh id. Callers only see
    /// the error if the second attempt is also stale, turning two LLM
    /// roundtrips into zero for the common stale-handle case.
    func performWithStaleRetry(
        query: String,
        snapshotID: String?,
        refresh: (() throws -> String)? = nil,
        _ body: (String?) throws -> ToolCallResult
    ) throws -> ToolCallResult {
        do {
            return try body(snapshotID)
        } catch let error as ComputerUseError where error.isStale {
            guard snapshotID != nil else {
                throw error
            }

            let refreshedID = try refresh?() ?? refreshSnapshot(for: query, allowLaunch: false).snapshotID
            return try body(refreshedID)
        }
    }

    private func performClick(
        app query: String,
        elementIndex: String?,
        x: Double?,
        y: Double?,
        clickCount: Int,
        mouseButton: String,
        clickMethod: ClickMethod = .auto,
        snapshotID: String? = nil,
        elementKey: String? = nil
    ) throws -> ToolCallResult {
        try validateClickMethod(
            clickMethod,
            hasElementIndex: elementIndex != nil || elementKey != nil,
            environment: ProcessInfo.processInfo.environment
        )
        try validateSkyClickArguments(
            method: clickMethod,
            mouseButton: mouseButton,
            clickCount: clickCount
        )
        try requireSnapshotID(snapshotID)

        let snapshot = try currentSnapshot(for: query, allowLaunch: false)
        try validateSnapshotID(snapshotID, snapshot: snapshot)
        try revalidateClickWindow(snapshot: snapshot)
        let button = MouseButtonKind(rawValue: mouseButton.lowercased()) ?? .left
        if snapshot.mode == .fixture {
            guard clickMethod == .auto else {
                throw ComputerUseError.message(
                    "click_method '\(clickMethod.rawValue)' is not supported for fixture apps"
                )
            }

            let cursorTarget: VisualCursorTarget?
            if elementIndex != nil || elementKey != nil {
                let record = try lookupElement(snapshot: snapshot, index: elementIndex, elementKey: elementKey)
                guard let identifier = record.identifier else {
                    throw ComputerUseError.invalidArguments("fixture click requires an identifier-backed element")
                }
                cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)
                try FixtureBridge.post(FixtureCommand(kind: "click", identifier: identifier))
            } else if let x, let y {
                let identifier = try fixtureIdentifier(at: CGPoint(x: x, y: y), snapshot: snapshot)
                cursorTarget = fixtureVisualCursorTarget(identifier: identifier, snapshot: snapshot)
                moveVisualCursor(to: cursorTarget)
                try FixtureBridge.post(FixtureCommand(kind: "click", identifier: identifier, x: x, y: y))
            } else {
                throw ComputerUseError.invalidArguments("click requires either element_index or x/y")
            }

            Thread.sleep(forTimeInterval: 0.15)
            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
            return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
        }

        if elementIndex != nil || elementKey != nil {
            let record = try lookupElement(snapshot: snapshot, index: elementIndex, elementKey: elementKey)
            let targetDescription = record.identifier.map { "element_key=\($0)" } ?? "element_index=\(elementIndex ?? "")"
            try validateClickElement(record: record, snapshot: snapshot)
            guard let windowPoint = clickPoint(for: record, snapshot: snapshot) else {
                throw ComputerUseError.stateUnavailable("element \(targetDescription) has no clickable frame")
            }
            let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: windowPoint)
            let cursorTarget = makeVisualCursorTarget(
                at: targetPoint,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer
            )

            moveVisualCursor(to: cursorTarget)

            do {
                switch clickMethod {
                case .auto:
                    if !(try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount,
                        includeNearbyHitTesting: true,
                        allowActivationFallback: true
                    )) {
                        try performNonAXClickFallback(
                            at: targetPoint,
                            button: button,
                            clickCount: clickCount,
                            targetDescription: targetDescription,
                            snapshot: snapshot
                        )
                    }
                case .accessibility:
                    guard try performAXClickSequence(
                        on: record,
                        snapshot: snapshot,
                        button: button,
                        clickCount: clickCount,
                        includeNearbyHitTesting: true,
                        allowActivationFallback: true
                    ) else {
                        throw ComputerUseError.message(
                            "click_method 'accessibility' could not click \(targetDescription)"
                        )
                    }
                case .appPost, .skyClick, .global:
                    try performExplicitMouseClick(
                        method: clickMethod,
                        at: targetPoint,
                        windowPoint: windowPoint,
                        button: button,
                        clickCount: clickCount,
                        targetDescription: targetDescription,
                        snapshot: snapshot
                    )
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
            dismissMenuAfterMenuClick(snapshot: snapshot, record: record)
        } else if let x, let y {
            let screenshotPoint = CGPoint(x: x, y: y)
            let point = screenshotPixelToWindowPointInSnapshot(snapshot: snapshot, point: screenshotPoint)
            let targetPoint = try windowPointToGlobalPoint(snapshot: snapshot, point: point)
            let cursorTarget = makeVisualCursorTarget(
                at: targetPoint,
                targetWindowID: snapshot.targetWindowID,
                targetWindowLayer: snapshot.targetWindowLayer
            )

            moveVisualCursor(to: cursorTarget)

            do {
                switch clickMethod {
                case .auto:
                    let candidates = try clickCandidates(at: point, in: snapshot)
                    var handled = false
                    for record in candidates {
                        if try performAXClickSequence(
                            on: record,
                            snapshot: snapshot,
                            button: button,
                            clickCount: clickCount,
                            includeNearbyHitTesting: false,
                            allowActivationFallback: false
                        ) {
                            handled = true
                            break
                        }
                    }

                    if !handled {
                        try performNonAXClickFallback(
                            at: targetPoint,
                            button: button,
                            clickCount: clickCount,
                            targetDescription: "x=\(Int(screenshotPoint.x)) y=\(Int(screenshotPoint.y))",
                            snapshot: snapshot
                        )
                    }
                case .accessibility:
                    throw ComputerUseError.message("click_method 'accessibility' requires element_index")
                case .appPost, .skyClick, .global:
                    try performExplicitMouseClick(
                        method: clickMethod,
                        at: targetPoint,
                        windowPoint: point,
                        button: button,
                        clickCount: clickCount,
                        targetDescription: "x=\(Int(screenshotPoint.x)) y=\(Int(screenshotPoint.y))",
                        snapshot: snapshot
                    )
                }
            } catch {
                settleVisualCursor(at: cursorTarget)
                throw error
            }

            pulseVisualCursor(at: cursorTarget, clickCount: clickCount, mouseButton: button)
        } else {
            throw ComputerUseError.invalidArguments("click requires either element_index or x/y")
        }

        return snapshotResult(
            for: try refreshSnapshot(
                for: query,
                recoveryPolicy: clickActionSnapshotRecoveryPolicy(for: clickMethod),
                allowLaunch: false
            ),
            style: .actionResult
        )
    }

    public func selectOption(
        app query: String,
        elementIndex: String,
        option: String,
        snapshotID: String? = nil
    ) throws -> ToolCallResult {
        try requireSnapshotID(snapshotID)
        let snapshot = try currentSnapshot(for: query, allowLaunch: false)
        try validateSnapshotID(snapshotID, snapshot: snapshot)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture select_option requires an identifier-backed element")
            }

            try FixtureBridge.post(FixtureCommand(kind: "select_option", identifier: identifier, value: option))
            Thread.sleep(forTimeInterval: 0.15)
            return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }

        guard axElementIsValid(element) else {
            throw ComputerUseError.staleElement(staleElementErrorMessage)
        }

        try validateClickOwnership(elementPID: pid(of: element), snapshotPID: snapshot.app.pid)

        // Open the popup.
        let pressResult = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard pressResult == .success else {
            throw ComputerUseError.message("AXUIElementPerformAction(AXPress) on popup \(elementIndex) failed with \(pressResult.rawValue)")
        }

        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        guard let menuItem = waitForMenuItem(titleContaining: option, in: element, appElement: appElement, pid: snapshot.app.pid) else {
            throw ComputerUseError.optionNotFound(
                optionNotFoundMessage(
                    option: option,
                    elementIndex: elementIndex,
                    availableTitles: menuItemTitles(in: element, appElement: appElement)
                )
            )
        }

        let itemPress = AXUIElementPerformAction(menuItem.element, kAXPressAction as CFString)
        guard itemPress == .success else {
            throw ComputerUseError.optionNotFound(
                "AXUIElementPerformAction(AXPress) on menu item '\(menuItem.title)' failed with \(itemPress.rawValue)"
            )
        }

        Thread.sleep(forTimeInterval: 0.15)
        let dismissal = dismissMenu(pid: snapshot.app.pid)
        guard dismissal.dismissed else {
            throw ComputerUseError.dismissFailed(dismissal.message)
        }

        return snapshotResult(for: try refreshSnapshot(for: query, allowLaunch: false), style: .actionResult)
    }

    /// Selects one item from a popup/menu. Opens via AXPress, polls for a
    /// matching menu-item child (case-insensitive substring on title or value),
    /// presses it, then posts Escape and verifies the menu is gone so it never
    /// stays open.
    private struct MenuItemMatch {
        let element: AXUIElement
        let title: String
    }

    private struct MenuDismissal {
        let dismissed: Bool
        let message: String
    }

    /// Native selects render their menu under a transient AXMenu window owned by
    /// the app rather than under the popup, and may not appear until well after
    /// AXPress returns, so poll app-wide for up to ~2s.
    private func waitForMenuItem(
        titleContaining option: String,
        in popup: AXUIElement,
        appElement: AXUIElement,
        pid: pid_t
    ) -> MenuItemMatch? {
        let deadline = Date().addingTimeInterval(2.0)

        while Date() < deadline {
            if let match = firstMenuItem(in: popup, appElement: appElement, titleContaining: option) {
                return match
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        return nil
    }

    private func firstMenuItem(in popup: AXUIElement, appElement: AXUIElement, titleContaining option: String) -> MenuItemMatch? {
        // Prefer the popup subtree, then fall back to the app-wide menu windows
        // (native <select> menus hang off the app, not the popup).
        for root in [popup] + menuRoots(appElement: appElement) {
            if let match = firstMenuItemDescending(root, titleContaining: option, depth: 0) {
                return match
            }
        }

        return nil
    }

    private func firstMenuItemDescending(_ root: AXUIElement, titleContaining option: String, depth: Int) -> MenuItemMatch? {
        guard depth < 8 else {
            return nil
        }

        for candidate in menuCandidates(of: root) {
            let role = stringValue(of: candidate, attribute: kAXRoleAttribute)
            let candidateValue = MenuOptionCandidate(
                role: role,
                title: menuItemTitle(of: candidate),
                value: stringValue(of: candidate, attribute: kAXValueAttribute as String)
            )

            if let title = candidateValue.title ?? candidateValue.value,
               menuOptionCandidateMatches(candidateValue, option: option)
            {
                return MenuItemMatch(element: candidate, title: title)
            }

            if let match = firstMenuItemDescending(candidate, titleContaining: option, depth: depth + 1) {
                return match
            }
        }

        return nil
    }

    private func menuItemTitles(in popup: AXUIElement, appElement: AXUIElement) -> [String] {
        var titles: [String] = []
        for root in [popup] + menuRoots(appElement: appElement) {
            titles.append(contentsOf: menuItemTitlesDescending(root, depth: 0))
        }
        return titles
    }

    private func menuItemTitlesDescending(_ root: AXUIElement, depth: Int) -> [String] {
        guard depth < 8 else {
            return []
        }

        var titles: [String] = []
        for candidate in menuCandidates(of: root) {
            let role = stringValue(of: candidate, attribute: kAXRoleAttribute)
            guard isSelectableMenuOptionRole(role) else {
                continue
            }

            if let title = menuItemTitle(of: candidate) {
                titles.append(title)
            }

            titles.append(contentsOf: menuItemTitlesDescending(candidate, depth: depth + 1))
        }

        return titles
    }

    private func menuItemTitle(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute as String, kAXValueAttribute as String, kAXDescriptionAttribute as String] {
            if let value = stringValue(of: element, attribute: attribute), !value.isEmpty {
                return value
            }
        }

        return nil
    }

    /// Menu children hang off a popup via AXChildren, AXChildrenInNavigationOrder
    /// or a transient AXMenu window, so probe the common attributes. The app's
    /// own AXMenu windows are included so native selects are discoverable even
    /// when they are not descended from the popup.
    private func menuCandidates(of element: AXUIElement) -> [AXUIElement] {
        var candidates: [AXUIElement] = []

        for attribute in [kAXChildrenAttribute as String, "AXChildrenInNavigationOrder", "AXVisibleChildren", kAXContentsAttribute as String] {
            if let children = copyArray(element, attribute: attribute) {
                candidates.append(contentsOf: children)
            }
        }

        return candidates
    }

    /// App-owned menu windows. Native <select> popups are not descendants of the
    /// trigger element, so they must be located from the application root.
    private func menuRoots(appElement: AXUIElement) -> [AXUIElement] {
        var roots: [AXUIElement] = []

        if let focusedWindow = copyElement(appElement, attribute: kAXFocusedWindowAttribute) {
            roots.append(focusedWindow)
        }

        for window in copyArray(appElement, attribute: kAXWindowsAttribute) ?? [] {
            roots.append(window)
        }

        return roots
    }

    /// Best-effort dismissal: if the clicked element is a menu item, or the
    /// popup still exposes menu children, post Escape and confirm removal.
    @discardableResult
    private func dismissMenu(pid: pid_t) -> MenuDismissal {
        try? InputSimulation.pressKey("Escape", pid: pid)

        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            let systemWide = AXUIElementCreateSystemWide()
            if !hasOpenMenu(pid: pid, systemWide: systemWide) {
                return MenuDismissal(dismissed: true, message: "menu dismissed")
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        return MenuDismissal(dismissed: false, message: "menu still visible after Escape on pid \(pid)")
    }

    private func hasOpenMenu(pid: pid_t, systemWide: AXUIElement) -> Bool {
        guard let focusedElement = copyElement(systemWide, attribute: kAXFocusedUIElementAttribute)
            ?? copyElement(AXUIElementCreateApplication(pid), attribute: kAXFocusedUIElementAttribute)
        else {
            return false
        }

        var current: AXUIElement? = focusedElement
        for _ in 0..<8 {
            guard let element = current else {
                break
            }

            let role = stringValue(of: element, attribute: kAXRoleAttribute)
            if role == kAXMenuRole as String || role == kAXMenuItemRole as String {
                return true
            }

            current = copyParent(of: element)
        }

        return false
    }

    /// After any click that landed on an AXMenuItem, post Escape so the menu
    /// does not stay open (the manual-click path parallel to select_option).
    private func dismissMenuAfterMenuClick(snapshot: AppSnapshot, record: ElementRecord?) {
        guard snapshot.mode == .accessibility else {
            return
        }

        let landedOnMenuItem = record?.role == kAXMenuItemRole as String
        guard landedOnMenuItem || hasOpenMenu(pid: snapshot.app.pid, systemWide: AXUIElementCreateSystemWide()) else {
            return
        }

        dismissMenu(pid: snapshot.app.pid)
    }

    struct FillFormItem {
        let index: Int
        let value: String
    }

    /// Batch-fills N fields from a single validated snapshot with no
    /// intermediate refreshes, then refreshes once at the end. Continue-on-error
    /// so the model gets a per-item report instead of failing the whole batch.
    public func fillForm(
        app query: String,
        items: [[String: Any]],
        snapshotID: String? = nil
    ) throws -> ToolCallResult {
        try requireSnapshotID(snapshotID)
        guard items.count <= 30 else {
            throw ComputerUseError.invalidArguments("fill_form supports at most 30 items (got \(items.count))")
        }

        let parsedItems = try items.map(parseFillFormItem(_:))
        let snapshot = try currentSnapshot(for: query, allowLaunch: false)
        try validateSnapshotID(snapshotID, snapshot: snapshot)

        var results: [[String: Any]] = []
        for item in parsedItems {
            results.append(fillFormItem(item, query: query, snapshot: snapshot))
        }

        let refreshed = try refreshSnapshot(for: query, allowLaunch: false)
        let payload: [String: Any] = [
            "results": results,
            "snapshot_id": refreshed.snapshotID,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"results\":[]}"

        return ToolCallResult.text("filled \(results.filter { $0["ok"] as? Bool == true }.count)/\(results.count) fields\n\(json)")
    }

    func parseFillFormItem(_ raw: [String: Any]) throws -> FillFormItem {
        guard let index = optionalIntValue(raw["index"]) else {
            throw ComputerUseError.invalidArguments("fill_form item requires an integer 'index'")
        }

        guard let value = raw["value"] as? String else {
            throw ComputerUseError.invalidArguments("fill_form item \(index) requires a string 'value'")
        }

        return FillFormItem(index: index, value: value)
    }

    func fillFormItem(_ item: FillFormItem, query: String, snapshot: AppSnapshot) -> [String: Any] {
        func failure(_ message: String) -> [String: Any] {
            ["index": item.index, "ok": false, "error": message]
        }

        guard let record = snapshot.elements[item.index] else {
            return failure("unknown element_index '\(item.index)'")
        }

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                return failure("fixture set_value requires a known element identifier")
            }

            do {
                try FixtureBridge.post(FixtureCommand(kind: "set_value", identifier: identifier, value: item.value))
                return ["index": item.index, "ok": true]
            } catch {
                return failure((error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
        }

        guard let element = record.element else {
            return failure("element \(item.index) has no backing accessibility object")
        }

        guard axElementIsValid(element) else {
            return failure(staleElementErrorMessage)
        }

        guard (try? isSettableForSetValue(element: element, attribute: kAXValueAttribute)) == true else {
            return failure(nonSettableSetValueErrorMessage(record: record, snapshot: snapshot))
        }

        guard pid(of: element) == snapshot.app.pid else {
            return failure(staleSnapshotErrorMessage)
        }

        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, item.value as CFString)
        switch result {
        case .success:
            return ["index": item.index, "ok": true]
        case .invalidUIElement:
            return failure(staleElementErrorMessage)
        default:
            return failure("AXUIElementSetAttributeValue failed with \(result.rawValue)")
        }
    }

    private func optionalIntValue(_ value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }

        if let double = value as? Double, double.rounded(.towardZero) == double,
           double >= Double(Int.min), double <= Double(Int.max)
        {
            return Int(double)
        }

        return nil
    }

    public func performSecondaryAction(app query: String, elementIndex: String, action: String) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard action.caseInsensitiveCompare("Raise") == .orderedSame else {
                throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
            }

            return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
        }

        guard let rawAction = matchingAction(requested: action, record: record) else {
            throw ComputerUseError.message(invalidSecondaryActionMessage(action: action, record: record))
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no backing accessibility object")
        }

        let result = AXUIElementPerformAction(element, rawAction as CFString)
        guard result == .success else {
            throw ComputerUseError.message("AXUIElementPerformAction failed with \(result.rawValue)")
        }

        Thread.sleep(forTimeInterval: 0.15)
        return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
    }

    public func scroll(app query: String, direction: String, elementIndex: String, pages: Double) throws -> ToolCallResult {
        let normalized = direction.lowercased()
        guard ["up", "down", "left", "right"].contains(normalized) else {
            throw ComputerUseError.message("Invalid scroll direction: \(direction)")
        }
        guard pages.isFinite, pages > 0 else {
            throw ComputerUseError.message("pages must be > 0")
        }

        let snapshot = try currentSnapshot(for: query)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex)

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture scroll requires an identifier-backed element")
            }
            try FixtureBridge.post(FixtureCommand(kind: "scroll", identifier: identifier, direction: normalized, pages: pages))
            Thread.sleep(forTimeInterval: 0.15)
            return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
        }

        if let repeatCount = integralScrollPageCount(pages),
           let rawAction = record.rawActions.first(where: { $0.caseInsensitiveCompare("AXScroll\(normalized.capitalized)ByPage") == .orderedSame }),
           let element = record.element {
            for _ in 0..<repeatCount {
                _ = AXUIElementPerformAction(element, rawAction as CFString)
                Thread.sleep(forTimeInterval: 0.05)
            }
        } else if let point = try globalPoint(for: record, snapshot: snapshot) {
            try performScrollEvent(
                at: point,
                direction: normalized,
                pages: pages,
                targetDescription: "element_index=\(elementIndex)",
                snapshot: snapshot
            )
        } else {
            throw ComputerUseError.stateUnavailable("element \(elementIndex) has no scrollable frame")
        }

        return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
    }

    public func drag(app query: String, fromX: Double, fromY: Double, toX: Double, toY: Double) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        if snapshot.mode == .fixture {
            try FixtureBridge.post(FixtureCommand(kind: "drag", identifier: "fixture-drag-pad", x: fromX, y: fromY, toX: toX, toY: toY))
            Thread.sleep(forTimeInterval: 0.15)
            return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
        }

        let start = try screenshotToGlobalPoint(snapshot: snapshot, x: fromX, y: fromY)
        let end = try screenshotToGlobalPoint(snapshot: snapshot, x: toX, y: toY)
        let path = try performDragEvent(
            from: start,
            to: end,
            targetDescription: "from=(\(Int(fromX)), \(Int(fromY))) to=(\(Int(toX)), \(Int(toY)))",
            snapshot: snapshot
        )
        return appendingDragDeliveryNote(
            to: snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult),
            path: path
        )
    }

    public func typeText(app query: String, text: String, snapshotID: String? = nil) throws -> ToolCallResult {
        try performWithStaleRetry(query: query, snapshotID: snapshotID) { effectiveID in
            try performTypeText(app: query, text: text, snapshotID: effectiveID)
        }
    }

    private func performTypeText(app query: String, text: String, snapshotID: String? = nil) throws -> ToolCallResult {
        try requireSnapshotID(snapshotID)
        let snapshot = try currentSnapshot(for: query, allowLaunch: false)
        try validateSnapshotID(snapshotID, snapshot: snapshot)
        if snapshot.mode == .fixture {
            try FixtureBridge.post(FixtureCommand(kind: "type_text", identifier: "fixture-input", value: text))
            Thread.sleep(forTimeInterval: 0.15)
            return snapshotResult(for: try refreshSnapshot(for: query, allowLaunch: false), style: .actionResult)
        }

        if try typeTextBySettingFocusedValueIfAvailable(text, in: snapshot) {
            Thread.sleep(forTimeInterval: 0.1)
            return snapshotResult(for: try refreshSnapshot(for: query, allowLaunch: false), style: .actionResult)
        }

        guard try canTypeTextUsingKeyboardFallback(in: snapshot) else {
            throw ComputerUseError.stateUnavailable("type_text requires a focused editable text element. Click a text entry area first, or use set_value on a settable text element.")
        }

        try InputSimulation.typeText(text, pid: snapshot.app.pid)
        return snapshotResult(for: try refreshSnapshot(for: query, allowLaunch: false), style: .actionResult)
    }

    public func pressKey(app query: String, key: String) throws -> ToolCallResult {
        let snapshot = try currentSnapshot(for: query)
        if snapshot.mode == .fixture {
            try FixtureBridge.post(FixtureCommand(kind: "press_key", identifier: "fixture-key-capture", value: key))
            Thread.sleep(forTimeInterval: 0.15)
            return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
        }

        try InputSimulation.pressKey(key, pid: snapshot.app.pid)
        return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
    }

    public func setValue(app query: String, elementIndex: String?, value: String, snapshotID: String? = nil, elementKey: String? = nil) throws -> ToolCallResult {
        try performWithStaleRetry(query: query, snapshotID: snapshotID) { effectiveID in
            try performSetValue(app: query, elementIndex: elementIndex, value: value, snapshotID: effectiveID, elementKey: elementKey)
        }
    }

    private func performSetValue(app query: String, elementIndex: String?, value: String, snapshotID: String? = nil, elementKey: String? = nil) throws -> ToolCallResult {
        try requireSnapshotID(snapshotID)
        let snapshot = try currentSnapshot(for: query, allowLaunch: false)
        try validateSnapshotID(snapshotID, snapshot: snapshot)
        let record = try lookupElement(snapshot: snapshot, index: elementIndex, elementKey: elementKey)
        let targetDescription = record.identifier.map { "element_key=\($0)" } ?? "element_index=\(elementIndex ?? "")"

        if snapshot.mode == .fixture {
            guard let identifier = record.identifier else {
                throw ComputerUseError.invalidArguments("fixture set_value requires a known element identifier")
            }

            let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
            moveVisualCursor(to: cursorTarget)
            try FixtureBridge.post(FixtureCommand(kind: "set_value", identifier: identifier, value: value))
            Thread.sleep(forTimeInterval: 0.15)
            settleVisualCursor(at: cursorTarget)
            return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
        }

        guard let element = record.element else {
            throw ComputerUseError.stateUnavailable("element \(targetDescription) has no backing accessibility object")
        }

        guard axElementIsValid(element) else {
            throw ComputerUseError.staleElement(staleElementErrorMessage)
        }

        guard try isSettableForSetValue(element: element, attribute: kAXValueAttribute) else {
            throw ComputerUseError.message(nonSettableSetValueErrorMessage(record: record, snapshot: snapshot))
        }

        let cursorTarget = visualCursorTarget(for: record, snapshot: snapshot)
        moveVisualCursor(to: cursorTarget)

        do {
            try revalidateTargetWindow(for: snapshot, record: record, element: element)

            let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            switch result {
            case .success:
                break
            case .invalidUIElement:
                throw ComputerUseError.staleElement(staleElementErrorMessage)
            default:
                throw ComputerUseError.message("AXUIElementSetAttributeValue failed with \(result.rawValue)")
            }

            Thread.sleep(forTimeInterval: 0.1)
        } catch {
            settleVisualCursor(at: cursorTarget)
            throw error
        }

        settleVisualCursor(at: cursorTarget)
        return snapshotResult(for: try refreshSnapshot(for: query), style: .actionResult)
    }

    private func validateSnapshotID(_ provided: String?, snapshot: AppSnapshot) throws {
        try validateSnapshotIDValue(provided, snapshot: snapshot)
    }

    private func revalidateClickWindow(snapshot: AppSnapshot) throws {
        let currentTitle = currentWindowTitle(for: snapshot)
        if let expectedTitle = snapshot.windowTitle,
           let currentTitle,
           currentTitle != expectedTitle
        {
            throw ComputerUseError.staleSnapshot(staleSnapshotErrorMessage)
        }
    }

    /// Live liveness + ownership probe before any click is performed. A stale
    /// element handle or an element that belongs to a different app than the
    /// snapshot is rejected so we never blind-fire at the wrong window/app.
    private func validateClickElement(record: ElementRecord, snapshot: AppSnapshot) throws {
        guard let element = record.element else {
            return
        }

        guard axElementIsValid(element) else {
            throw ComputerUseError.staleElement(staleElementErrorMessage)
        }

        try validateClickOwnership(elementPID: pid(of: element), snapshotPID: snapshot.app.pid)
    }

    private func revalidateTargetWindow(for snapshot: AppSnapshot, record: ElementRecord, element: AXUIElement) throws {
        guard axElementIsValid(element) else {
            throw ComputerUseError.staleElement(staleElementErrorMessage)
        }

        guard pid(of: element) == snapshot.app.pid else {
            throw ComputerUseError.staleSnapshot(staleSnapshotErrorMessage)
        }

        let currentTitle = currentWindowTitle(for: snapshot)
        if let expectedTitle = snapshot.windowTitle,
           let currentTitle,
           currentTitle != expectedTitle
        {
            throw ComputerUseError.staleSnapshot(staleSnapshotErrorMessage)
        }
    }

    private func currentWindowTitle(for snapshot: AppSnapshot) -> String? {
        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        let focusedApplication = copyElement(AXUIElementCreateSystemWide(), attribute: kAXFocusedApplicationAttribute)
        guard let window = SnapshotBuilder.currentWindow(
            appElement: appElement,
            appPID: snapshot.app.pid,
            focusedApplication: focusedApplication
        ) else {
            return nil
        }

        return stringValue(of: window, attribute: kAXTitleAttribute)
    }

    private func currentSnapshot(for query: String, allowLaunch: Bool = true) throws -> AppSnapshot {
        if let snapshot = snapshotsByApp[query.lowercased()] {
            return snapshot
        }

        return try refreshSnapshot(for: query, allowLaunch: allowLaunch)
    }

    @discardableResult
    private func refreshSnapshot(
        for query: String,
        textLimit: SnapshotTextLimit = .defaults,
        treeLimits: AccessibilityTreeLimits = .defaults,
        recoveryPolicy: SnapshotRecoveryPolicy = .allowActivation,
        screenshotMaxDimension: CGFloat = screenshotResultMaxDimension,
        screenshotRegion: CaptureRegion? = nil,
        allowLaunch: Bool = true
    ) throws -> AppSnapshot {
        // Click/type/set_value must never launch the app; only get_app_state may.
        let app = allowLaunch ? try AppDiscovery.resolve(query) : try AppDiscovery.resolveRunningOnly(query)
        let snapshot = try SnapshotBuilder.build(
            for: app,
            textLimit: textLimit,
            treeLimits: treeLimits,
            recoveryPolicy: recoveryPolicy,
            screenshotMaxDimension: screenshotMaxDimension,
            screenshotRegion: screenshotRegion
        )

        let keys = Set([
            query.lowercased(),
            app.name.lowercased(),
            (app.bundleIdentifier ?? "").lowercased(),
        ].filter { !$0.isEmpty })

        let previous = keys.compactMap { snapshotsByApp[$0] }.first { $0.mode == snapshot.mode }
        let stableSnapshot = snapshot.preservingSnapshotID(from: previous)

        for key in keys {
            snapshotsByApp[key] = stableSnapshot
        }

        return stableSnapshot
    }

    private func lookupElement(snapshot: AppSnapshot, index: String) throws -> ElementRecord {
        guard let parsedIndex = Int(index), let record = snapshot.elements[parsedIndex] else {
            throw ComputerUseError.invalidArguments("unknown element_index '\(index)'")
        }

        return record
    }

    /// Resolve by AX identifier first (stable across reorder), falling back to
    /// the numeric index. `element_key` is the cheaper, churn-resistant handle.
    func lookupElement(snapshot: AppSnapshot, index: String?, elementKey: String?) throws -> ElementRecord {
        if let elementKey, !elementKey.isEmpty {
            if let record = snapshot.elements.values.first(where: { $0.identifier == elementKey }) {
                return record
            }

            guard let index else {
                throw ComputerUseError.invalidArguments("unknown element_key '\(elementKey)'")
            }

            return try lookupElement(snapshot: snapshot, index: index)
        }

        guard let index else {
            throw ComputerUseError.missingArgument("element_index")
        }

        return try lookupElement(snapshot: snapshot, index: index)
    }

    func matchingAction(requested: String, record: ElementRecord) -> String? {
        if let exact = record.rawActions.first(where: { $0.caseInsensitiveCompare(requested) == .orderedSame }) {
            return exact
        }
        let visibleActions = record.role.map { meaningfulRawActions(record.rawActions, role: $0) } ?? record.rawActions
        let matches = visibleActions.filter { rawAction in
            secondaryActionNamesEquivalent(requested, secondaryActionDisplayName(rawAction))
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func invalidSecondaryActionMessage(action: String, record: ElementRecord) -> String {
        invalidSecondaryActionErrorMessage(action: action, elementIndex: record.index)
    }

    private func performPreferredClick(on record: ElementRecord, button: MouseButtonKind, clickCount: Int) throws -> Bool {
        guard let element = record.element else {
            return false
        }

        switch button {
        case .left:
            if clickCount <= 1,
               !hasAncestorRole("AXWebArea", of: element),
               try selectContainingListItem(for: element)
            {
                return true
            }

            if try performAction(named: kAXPressAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }

            if try performAction(named: kAXConfirmAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }

            if try performAction(named: "AXOpen", on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .right:
            if try performAction(named: kAXShowMenuAction as String, on: element, availableActions: record.rawActions, repeatCount: clickCount) {
                return true
            }
        case .middle:
            break
        }

        return false
    }

    private func clickCandidates(at point: CGPoint, in snapshot: AppSnapshot) throws -> [ElementRecord] {
        var candidates: [ElementRecord] = []

        if let bestRecord = bestElement(containing: point, in: snapshot) {
            candidates.append(bestRecord)
        }

        if let hitRecord = try hitTestElement(at: point, in: snapshot) {
            candidates.append(hitRecord)
        }

        return candidates.reduce(into: []) { uniqueCandidates, candidate in
            if !uniqueCandidates.contains(where: { sameElement($0.element, candidate.element) }) {
                uniqueCandidates.append(candidate)
            }
        }
    }

    private func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return CFEqual(lhs, rhs)
    }

    private func selectContainingListItem(for element: AXUIElement) throws -> Bool {
        guard let target = selectableListItem(containing: element) else {
            return false
        }

        let result = AXUIElementSetAttributeValue(
            target.list,
            kAXSelectedChildrenAttribute as CFString,
            [target.item] as CFArray
        )

        switch result {
        case .success:
            Thread.sleep(forTimeInterval: 0.15)
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue(\(kAXSelectedChildrenAttribute)) failed with \(result.rawValue)")
        }
    }

    private func selectableListItem(containing element: AXUIElement) -> (list: AXUIElement, item: AXUIElement)? {
        var current = element
        var directChild = element

        for _ in 0..<8 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if stringValue(of: parent, attribute: kAXRoleAttribute) == kAXListRole as String,
               isSettable(element: parent, attribute: kAXSelectedChildrenAttribute)
            {
                return (parent, directChild)
            }

            directChild = parent
            current = parent
        }

        return nil
    }

    private func performAXClickSequence(
        on record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int,
        includeNearbyHitTesting: Bool,
        allowActivationFallback: Bool
    ) throws -> Bool {
        let preferContainingWebRowAXClick = shouldPreferContainingWebRowAXClick(record, in: snapshot)
        debugClickDecision("record=\(clickDebugDescription(record)) preferContainingWebRowAXClick=\(preferContainingWebRowAXClick)")

        if preferContainingWebRowAXClick,
           try performContainingWebRowClick(for: record, snapshot: snapshot, button: button, clickCount: clickCount)
        {
            Thread.sleep(forTimeInterval: 0.15)
            return true
        }

        if !preferContainingWebRowAXClick {
            if try performPreferredClick(on: record, button: button, clickCount: clickCount) {
                debugClickDecision("handled by preferred target \(clickDebugDescription(record))")
                Thread.sleep(forTimeInterval: 0.15)
                return true
            }

            for candidate in descendantClickCandidates(for: record, snapshot: snapshot) {
                if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                    debugClickDecision("handled by descendant \(clickDebugDescription(candidate))")
                    Thread.sleep(forTimeInterval: 0.15)
                    return true
                }
            }

            if includeNearbyHitTesting {
                for localPoint in clickActionPoints(for: record, snapshot: snapshot) {
                    guard let hitRecord = try hitTestElement(at: localPoint, in: snapshot) ?? bestElement(containing: localPoint, in: snapshot) else {
                        continue
                    }

                    if !isLikelySyntheticSideAction(hitRecord, in: record),
                       try performPreferredClick(on: hitRecord, button: button, clickCount: clickCount)
                    {
                        debugClickDecision("handled by hit record \(clickDebugDescription(hitRecord))")
                        Thread.sleep(forTimeInterval: 0.15)
                        return true
                    }

                    if shouldScanDescendantsOfHitRecord(
                        originalFrame: clickFrame(for: record, snapshot: snapshot),
                        hitFrame: hitRecord.localFrame
                    ) {
                        for candidate in descendantClickCandidates(
                            for: hitRecord,
                            snapshot: snapshot,
                            sideActionScope: record
                        ) {
                            if try performPreferredClick(on: candidate, button: button, clickCount: clickCount) {
                                debugClickDecision("handled by hit descendant \(clickDebugDescription(candidate))")
                                Thread.sleep(forTimeInterval: 0.15)
                                return true
                            }
                        }
                    }
                }
            }
        }

        guard
            allowActivationFallback,
            !record.isSyntheticText,
            button == .left,
            let element = record.element,
            canUseActivationOnlyClickFallback(role: stringValue(of: element, attribute: kAXRoleAttribute))
        else {
            return false
        }

        if try activateClickTarget(element: element, availableActions: record.rawActions) {
            debugClickDecision("handled by activation fallback \(clickDebugDescription(record))")
            Thread.sleep(forTimeInterval: 0.15)
            return true
        }

        return false
    }

    private func performAction(named action: String, on element: AXUIElement, availableActions: [String], repeatCount: Int = 1) throws -> Bool {
        guard availableActions.contains(where: { $0.caseInsensitiveCompare(action) == .orderedSame }) else {
            return false
        }

        let attempts = max(repeatCount, 1)
        for index in 0..<attempts {
            let result = AXUIElementPerformAction(element, action as CFString)
            switch result {
            case .success:
                if index < attempts - 1 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            case .attributeUnsupported where action.caseInsensitiveCompare("AXOpen") == .orderedSame:
                return true
            case .failure, .actionUnsupported, .attributeUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
                return false
            default:
                throw ComputerUseError.message("AXUIElementPerformAction(\(action)) failed with \(result.rawValue)")
            }
        }

        return true
    }

    private func activateClickTarget(element: AXUIElement, availableActions: [String]) throws -> Bool {
        var activated = false

        if try performAction(named: kAXRaiseAction as String, on: element, availableActions: availableActions) {
            activated = true
        }

        if try setBoolAttribute(named: kAXMainAttribute, on: element) {
            activated = true
        }

        if try setBoolAttribute(named: kAXFocusedAttribute, on: element) {
            activated = true
        }

        return activated
    }

    private func setBoolAttribute(named attribute: String, on element: AXUIElement) throws -> Bool {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, kCFBooleanTrue)
        switch result {
        case .success:
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue(\(attribute)) failed with \(result.rawValue)")
        }
    }

    private func isSettable(element: AXUIElement, attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return result == .success && settable.boolValue
    }

    private func isSettableForSetValue(element: AXUIElement, attribute: String) throws -> Bool {
        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return try setValueAttributeIsSettable(
            result: result,
            settable: settable.boolValue,
            attribute: attribute
        )
    }

    private func bestElement(containing point: CGPoint, in snapshot: AppSnapshot) -> ElementRecord? {
        snapshot.elements.values
            .filter { $0.localFrame?.contains(point) ?? false }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
            .first
    }

    private func hitTestElement(at point: CGPoint, in snapshot: AppSnapshot) throws -> ElementRecord? {
        let appElement = AXUIElementCreateApplication(snapshot.app.pid)
        let globalPoint = try screenshotToGlobalPoint(snapshot: snapshot, x: Double(point.x), y: Double(point.y))
        var hitElement: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(appElement, Float(globalPoint.x), Float(globalPoint.y), &hitElement)
        guard result == .success, let hitElement else {
            return nil
        }

        let rawActions = copyActions(for: hitElement) ?? []
        return ElementRecord(
            index: -1,
            identifier: nil,
            element: hitElement,
            localFrame: localFrame(of: hitElement, windowBounds: snapshot.windowBounds),
            rawActions: rawActions,
            prettyActions: rawActions
        )
    }

    private func clickPriority(for record: ElementRecord) -> Int {
        if record.rawActions.contains(where: {
            $0.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame ||
            $0.caseInsensitiveCompare(kAXRaiseAction as String) == .orderedSame
        }) {
            return 0
        }

        if let element = record.element,
           isSettable(element: element, attribute: kAXMainAttribute) ||
           isSettable(element: element, attribute: kAXFocusedAttribute) {
            return 1
        }

        return 2
    }

    private func frameArea(of record: ElementRecord) -> CGFloat {
        guard let frame = record.localFrame else {
            return .greatestFiniteMagnitude
        }

        return frame.width * frame.height
    }

    private func localCenter(for record: ElementRecord) -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        return CGPoint(x: frame.midX, y: frame.midY)
    }

    private func clickActionPoints(for record: ElementRecord, snapshot: AppSnapshot) -> [CGPoint] {
        guard let frame = clickFrame(for: record, snapshot: snapshot) else {
            return []
        }

        return localClickActionPoints(frame: frame, isSyntheticText: record.isSyntheticText)
    }

    private func descendantClickCandidates(
        for record: ElementRecord,
        snapshot: AppSnapshot,
        sideActionScope: ElementRecord? = nil
    ) -> [ElementRecord] {
        guard let element = record.element else {
            return []
        }

        let sideActionParent = sideActionScope ?? record
        return descendantClickCandidates(of: element, windowBounds: snapshot.windowBounds)
            .filter { candidate in
                !isLikelySyntheticSideAction(candidate, in: sideActionParent)
            }
            .sorted { lhs, rhs in
                let lhsPriority = clickPriority(for: lhs)
                let rhsPriority = clickPriority(for: rhs)
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }

                return frameArea(of: lhs) < frameArea(of: rhs)
            }
    }

    private func descendantClickCandidates(of element: AXUIElement, windowBounds: CGRect?, depth: Int = 0) -> [ElementRecord] {
        guard depth < 3 else {
            return []
        }

        var results: [ElementRecord] = []
        for child in copyChildren(of: element) {
            let rawActions = copyActions(for: child) ?? []
            results.append(
                ElementRecord(
                    index: -1,
                    identifier: nil,
                    element: child,
                    localFrame: localFrame(of: child, windowBounds: windowBounds),
                    rawActions: rawActions,
                    prettyActions: rawActions
                )
            )
            results.append(contentsOf: descendantClickCandidates(of: child, windowBounds: windowBounds, depth: depth + 1))
        }

        return results
    }

    private func isLikelySyntheticSideAction(_ candidate: ElementRecord, in parent: ElementRecord) -> Bool {
        isLikelySyntheticSideActionCandidate(
            parentFrame: parent.localFrame,
            candidateFrame: candidate.localFrame,
            hasPrimaryAction: hasPrimaryClickAction(candidate),
            labels: accessibilityLabels(for: candidate.element)
        )
    }

    private func hasPrimaryClickAction(_ record: ElementRecord) -> Bool {
        record.rawActions.contains { action in
            action.caseInsensitiveCompare(kAXPressAction as String) == .orderedSame ||
                action.caseInsensitiveCompare(kAXConfirmAction as String) == .orderedSame ||
                action.caseInsensitiveCompare("AXOpen") == .orderedSame ||
                action.caseInsensitiveCompare(kAXShowMenuAction as String) == .orderedSame
        }
    }

    private func shouldPreferContainingWebRowAXClick(_ record: ElementRecord, in snapshot: AppSnapshot) -> Bool {
        guard
            let element = record.element
        else {
            return false
        }

        return shouldPreferContainingWebRowAXClickCandidate(
            role: stringValue(of: element, attribute: kAXRoleAttribute),
            isSyntheticText: record.isSyntheticText,
            hasWebAreaAncestor: hasAncestorRole("AXWebArea", of: element),
            appName: snapshot.app.name,
            bundleIdentifier: snapshot.app.bundleIdentifier
        )
    }

    private func performContainingWebRowClick(
        for record: ElementRecord,
        snapshot: AppSnapshot,
        button: MouseButtonKind,
        clickCount: Int
    ) throws -> Bool {
        guard
            button == .left,
            clickCount <= 1,
            let element = record.element,
            let targetFrame = record.localFrame
        else {
            return false
        }

        var current = element

        for _ in 0..<6 {
            guard let parent = copyParent(of: current) else {
                return false
            }

            let rawActions = copyActions(for: parent) ?? []
            let candidate = ElementRecord(
                index: -1,
                identifier: nil,
                element: parent,
                localFrame: localFrame(of: parent, windowBounds: snapshot.windowBounds),
                rawActions: rawActions,
                prettyActions: rawActions
            )

            if isLikelyContainingWebRowAction(targetFrame: targetFrame, candidate: candidate),
               !isLikelySyntheticSideAction(candidate, in: record),
               try performAction(named: kAXPressAction as String, on: parent, availableActions: rawActions)
            {
                debugClickDecision("handled by containing web row \(clickDebugDescription(candidate))")
                return true
            }

            current = parent
        }

        return false
    }

    private func isLikelyContainingWebRowAction(
        targetFrame: CGRect,
        candidate: ElementRecord
    ) -> Bool {
        isLikelyContainingRowActionFrame(
            targetFrame: targetFrame,
            candidateFrame: candidate.localFrame,
            hasPrimaryAction: hasPrimaryClickAction(candidate)
        )
    }

    private func hasAncestorRole(_ role: String, of element: AXUIElement) -> Bool {
        var current = element

        for _ in 0..<12 {
            guard let parent = copyParent(of: current) else {
                return false
            }

            if stringValue(of: parent, attribute: kAXRoleAttribute) == role {
                return true
            }

            current = parent
        }

        return false
    }

    private func accessibilityLabels(for element: AXUIElement?) -> [String] {
        guard let element else {
            return []
        }

        return [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXHelpAttribute as String,
            kAXValueAttribute as String,
            "AXIdentifier"
        ].compactMap { attribute in
            stringValue(of: element, attribute: attribute)
        }
    }

    private func typeTextBySettingFocusedValueIfAvailable(_ text: String, in snapshot: AppSnapshot) throws -> Bool {
        guard let element = snapshot.focusedElement else {
            return false
        }

        guard try isSettableForSetValue(element: element, attribute: kAXValueAttribute) else {
            return false
        }

        let baseValue = editableBaseValue(for: element)
        let result = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, (baseValue + text) as CFString)
        switch result {
        case .success:
            return true
        case .failure, .attributeUnsupported, .actionUnsupported, .cannotComplete, .noValue, .invalidUIElement, .illegalArgument:
            return false
        default:
            throw ComputerUseError.message("AXUIElementSetAttributeValue failed with \(result.rawValue)")
        }
    }

    private func canTypeTextUsingKeyboardFallback(in snapshot: AppSnapshot) throws -> Bool {
        guard let element = snapshot.focusedElement else {
            return false
        }

        let role = stringValue(of: element, attribute: kAXRoleAttribute)
        let roleDescription = role.flatMap {
            stringValue(of: element, attribute: kAXRoleDescriptionAttribute) ?? humanizedRoleDescription(for: $0)
        }
        return canUseKeyboardTextFallback(
            role: role,
            roleDescription: roleDescription,
            isValueSettable: try isSettableForSetValue(element: element, attribute: kAXValueAttribute)
        )
    }

    private func humanizedRoleDescription(for role: String) -> String {
        if role == kAXTextFieldRole as String {
            return "text field"
        }

        switch role {
        case "AXTextArea", "AXTextView":
            return "text entry area"
        default:
            return ""
        }
    }

    private func editableBaseValue(for element: AXUIElement) -> String {
        let childTextValues = editableDescendantTextValues(in: element)
            .filter { !looksLikeEditablePlaceholder($0) }
        if !childTextValues.isEmpty {
            return childTextValues.joined()
        }

        guard let currentValue = stringValue(of: element, attribute: kAXValueAttribute) else {
            return ""
        }

        let normalizedValue = normalizeEditablePlaceholderText(currentValue)
        if normalizedValue.isEmpty || looksLikeEditablePlaceholder(normalizedValue) {
            return ""
        }

        for attribute in ["AXPlaceholderValue", "AXPlaceholder"] {
            guard let placeholder = stringValue(of: element, attribute: attribute) else {
                continue
            }

            if normalizedValue == normalizeEditablePlaceholderText(placeholder) {
                return ""
            }
        }

        return currentValue
    }

    private func editableDescendantTextValues(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 4 else {
            return []
        }

        var values: [String] = []
        for child in copyChildren(of: element) {
            if stringValue(of: child, attribute: kAXRoleAttribute) == kAXStaticTextRole as String,
               let value = stringValue(of: child, attribute: kAXValueAttribute)
                    ?? stringValue(of: child, attribute: kAXTitleAttribute)
            {
                let normalized = normalizeEditablePlaceholderText(value)
                if !normalized.isEmpty {
                    values.append(normalized)
                }
            }

            values.append(contentsOf: editableDescendantTextValues(in: child, depth: depth + 1))
        }

        return values
    }

    private func looksLikeEditablePlaceholder(_ value: String) -> Bool {
        let normalized = normalizeEditablePlaceholderText(value)
        return normalized == "沟通时请保持“公开可接受”"
    }

    private func normalizeEditablePlaceholderText(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func clickFrame(for record: ElementRecord, snapshot: AppSnapshot) -> CGRect? {
        guard let frame = record.localFrame else {
            return nil
        }

        guard
            !record.isSyntheticText,
            let element = record.element,
            stringValue(of: element, attribute: kAXRoleAttribute) == kAXStaticTextRole as String,
            let rowFrame = containingRowFrame(for: element, textFrame: frame, windowBounds: snapshot.windowBounds)
        else {
            return frame
        }

        return rowFrame
    }

    private func containingRowFrame(for element: AXUIElement, textFrame: CGRect, windowBounds: CGRect?) -> CGRect? {
        let textCenter = CGPoint(x: textFrame.midX, y: textFrame.midY)
        var current = element

        for _ in 0..<4 {
            guard let parent = copyParent(of: current) else {
                return nil
            }

            if let frame = localFrame(of: parent, windowBounds: windowBounds),
               frame.insetBy(dx: -2, dy: -2).contains(textCenter),
               frame.width >= textFrame.width + 40,
               frame.height >= textFrame.height,
               frame.height <= max(textFrame.height * 4, 96)
            {
                return frame
            }

            current = parent
        }

        return nil
    }

    private func copyActions(for element: AXUIElement) -> [String]? {
        var actions: CFArray?
        let result = AXUIElementCopyActionNames(element, &actions)
        guard result == .success else {
            return nil
        }

        return actions as? [String]
    }

    private func copyChildren(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let value else {
            return []
        }

        return value as? [AXUIElement] ?? []
    }

    private func copyParent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func stringValue(of element: AXUIElement, attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        return value as? String
    }

    private func localFrame(of element: AXUIElement, windowBounds: CGRect?) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        let positionResult = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
        let sizeResult = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)

        guard
            positionResult == .success,
            sizeResult == .success,
            let positionValue,
            let sizeValue
        else {
            return nil
        }

        let positionAXValue = positionValue as! AXValue
        let sizeAXValue = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAXValue, .cgPoint, &position), AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }

        let frame = CGRect(origin: position, size: size)
        guard let windowBounds else {
            return frame
        }

        return windowRelativeFrame(elementFrame: frame, windowBounds: windowBounds)
    }

    private func globalPoint(for record: ElementRecord, snapshot: AppSnapshot) throws -> CGPoint? {
        guard let frame = record.localFrame else {
            return nil
        }

        return try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: CGPoint(x: frame.midX, y: frame.midY)
        )
    }

    private func clickPoint(for record: ElementRecord, snapshot: AppSnapshot) -> CGPoint? {
        clickActionPoints(for: record, snapshot: snapshot).first ?? localCenter(for: record)
    }

    private func screenshotToGlobalPoint(snapshot: AppSnapshot, x: Double, y: Double) throws -> CGPoint {
        try windowPointToGlobalPoint(
            snapshot: snapshot,
            point: screenshotPixelToWindowPointInSnapshot(
                snapshot: snapshot,
                point: CGPoint(x: x, y: y)
            )
        )
    }

    private func screenshotPixelToWindowPointInSnapshot(snapshot: AppSnapshot, point: CGPoint) -> CGPoint {
        screenshotPixelToWindowPoint(
            point,
            screenshotPixelSize: screenshotPixelSize(snapshot: snapshot),
            windowBounds: snapshot.windowBounds
        )
    }

    private func screenshotPixelSize(snapshot: AppSnapshot) -> CGSize? {
        guard
            let screenshotPNGData = snapshot.screenshotPNGData,
            let imageSource = CGImageSourceCreateWithData(screenshotPNGData as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
            let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat,
            let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat,
            pixelWidth > 0,
            pixelHeight > 0
        else {
            return nil
        }

        return CGSize(width: pixelWidth, height: pixelHeight)
    }

    private func windowPointToGlobalPoint(snapshot: AppSnapshot, point: CGPoint) throws -> CGPoint {
        guard let windowBounds = snapshot.windowBounds else {
            let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
            throw ComputerUseError.stateUnavailable("No window bounds are available for \(appReference). Run get_app_state after bringing the app on screen.")
        }

        return CGPoint(x: windowBounds.minX + point.x, y: windowBounds.minY + point.y)
    }

    private func fixtureIdentifier(at point: CGPoint, snapshot: AppSnapshot) throws -> String {
        let candidates = snapshot.elements.values
            .filter { $0.identifier != nil && ($0.localFrame?.contains(point) ?? false) }
            .sorted { lhs, rhs in
                let lhsArea = (lhs.localFrame?.width ?? 0) * (lhs.localFrame?.height ?? 0)
                let rhsArea = (rhs.localFrame?.width ?? 0) * (rhs.localFrame?.height ?? 0)
                return lhsArea < rhsArea
            }

        guard let identifier = candidates.first?.identifier else {
            throw ComputerUseError.invalidArguments("No fixture element contains coordinate (\(Int(point.x)), \(Int(point.y)))")
        }

        return identifier
    }

    private func visualCursorTarget(for record: ElementRecord, snapshot: AppSnapshot) -> VisualCursorTarget? {
        makeVisualCursorTarget(
            localFrame: record.localFrame,
            windowBounds: snapshot.windowBounds,
            targetWindowID: snapshot.targetWindowID,
            targetWindowLayer: snapshot.targetWindowLayer
        )
    }

    private func fixtureVisualCursorTarget(identifier: String, snapshot: AppSnapshot) -> VisualCursorTarget? {
        let record = snapshot.elements.values.first { $0.identifier == identifier }
        return record.flatMap { visualCursorTarget(for: $0, snapshot: snapshot) }
    }

    private func moveVisualCursor(to target: VisualCursorTarget?) {
        guard let target else {
            return
        }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.moveCursor(to: target.point, in: target.window)
        }
    }

    private func settleVisualCursor(at target: VisualCursorTarget?) {
        guard let target else {
            return
        }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.settle(at: target.point, in: target.window)
        }
    }

    private func pulseVisualCursor(at target: VisualCursorTarget?, clickCount: Int, mouseButton: MouseButtonKind) {
        guard let target else {
            return
        }

        VisualCursorSupport.performOnMain {
            SoftwareCursorOverlay.pulseClick(
                at: target.point,
                clickCount: clickCount,
                mouseButton: mouseButton,
                in: target.window
            )
        }
    }

    private func debugInputFallback(tool: String, targetDescription: String, snapshot: AppSnapshot) {
        guard inputFallbackDebugEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }

        let appReference = snapshot.app.bundleIdentifier ?? snapshot.app.name
        fputs(
            "[open-computer-use] global pointer fallback tool=\(tool) app=\(appReference) target=\(targetDescription)\n",
            stderr
        )
    }

    private func debugClickDecision(_ message: String) {
        guard inputFallbackDebugEnabled(environment: ProcessInfo.processInfo.environment) else {
            return
        }

        fputs("[open-computer-use] click decision \(message)\n", stderr)
    }

    private func clickDebugDescription(_ record: ElementRecord) -> String {
        let role = record.element.flatMap { stringValue(of: $0, attribute: kAXRoleAttribute) } ?? "nil"
        let actions = record.rawActions.joined(separator: ",")
        let frame = record.localFrame.map { "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))" } ?? "nil"
        return "index=\(record.index) role=\(role) synthetic=\(record.isSyntheticText) actions=[\(actions)] frame=\(frame)"
    }

    private func integralScrollPageCount(_ pages: Double) -> Int? {
        let rounded = pages.rounded(.toNearestOrAwayFromZero)
        guard abs(pages - rounded) < 0.000001 else {
            return nil
        }
        return max(Int(rounded), 1)
    }

    private func performScrollEvent(
        at point: CGPoint,
        direction: String,
        pages: Double,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        if globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) {
            debugInputFallback(
                tool: "scroll",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.scrollGlobally(at: eventPoint, direction: direction, pages: pages)
            return
        }

        try InputSimulation.scrollTargeted(at: eventPoint, direction: direction, pages: pages, pid: snapshot.app.pid)
    }

    private func performDragEvent(
        from start: CGPoint,
        to end: CGPoint,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws -> DragDeliveryPath {
        let eventStart = inputEventPoint(fromScreenStatePoint: start)
        let eventEnd = inputEventPoint(fromScreenStatePoint: end)
        let path = dragDeliveryPath(environment: ProcessInfo.processInfo.environment)

        switch path {
        case .global:
            debugInputFallback(
                tool: "drag",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.dragGlobally(from: eventStart, to: eventEnd)
        case .appPost:
            try InputSimulation.dragTargeted(from: eventStart, to: eventEnd, pid: snapshot.app.pid)
        }

        return path
    }

    private func performNonAXClickFallback(
        at point: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        if globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) {
            debugInputFallback(
                tool: "click",
                targetDescription: targetDescription,
                snapshot: snapshot
            )
            InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.clickGlobally(at: eventPoint, button: button, clickCount: clickCount)
            return
        }

        do {
            try InputSimulation.clickTargeted(
                at: eventPoint,
                button: button,
                clickCount: clickCount,
                pid: snapshot.app.pid
            )
            return
        } catch {
            guard globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) else {
                throw ComputerUseError.message(
                    "click could not be handled through accessibility, and global pointer fallback is disabled. Set OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 to allow physical-pointer fallback for this process."
                )
            }
        }
    }

    private func performExplicitMouseClick(
        method: ClickMethod,
        at point: CGPoint,
        windowPoint: CGPoint,
        button: MouseButtonKind,
        clickCount: Int,
        targetDescription: String,
        snapshot: AppSnapshot
    ) throws {
        let eventPoint = inputEventPoint(fromScreenStatePoint: point)

        switch method {
        case .appPost:
            debugClickDecision("requested=app_post executed=pid_post target=\(targetDescription)")
            try InputSimulation.clickTargeted(
                at: eventPoint,
                button: button,
                clickCount: clickCount,
                pid: snapshot.app.pid
            )
        case .skyClick:
            guard let windowBounds = snapshot.windowBounds, let windowID = snapshot.targetWindowID else {
                throw ComputerUseError.stateUnavailable(
                    "click_method 'sky_click' requires a current on-screen target window. Run get_app_state again."
                )
            }
            debugClickDecision("requested=sky_click executed=skylight_pid_post target=\(targetDescription)")
            try InputSimulation.clickWithSkyLight(
                at: eventPoint,
                windowPoint: windowPoint,
                windowBounds: windowBounds,
                windowID: windowID,
                clickCount: clickCount,
                pid: snapshot.app.pid
            )
        case .global:
            guard globalPointerFallbacksEnabled(environment: ProcessInfo.processInfo.environment) else {
                throw ComputerUseError.message(
                    "click_method 'global' requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1 because it may move the system pointer and change foreground focus"
                )
            }
            debugClickDecision("requested=global executed=global_hid target=\(targetDescription)")
            InputSimulation.prepareAppForGlobalPointerInput(snapshot.app)
            try InputSimulation.clickGlobally(at: eventPoint, button: button, clickCount: clickCount)
        case .auto, .accessibility:
            throw ComputerUseError.message(
                "click_method '\(method.rawValue)' is not a direct mouse event method"
            )
        }
    }

    private func snapshotResult(for snapshot: AppSnapshot, style: SnapshotTextStyle) -> ToolCallResult {
        var content = [ToolResultContentItem.text(snapshot.renderedText(style: style))]
        if let screenshotPNGData = snapshot.screenshotPNGData {
            content.append(.pngImage(screenshotPNGData))
        }
        return ToolCallResult(content: content)
    }
}
