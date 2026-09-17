import Foundation

let computerUseNoWindowFoundMessage = "Apple event error -10005: cgWindowNotFound"

public enum ComputerUseError: Error, LocalizedError {
    case message(String)
    case unsupportedTool(String)
    case invalidArguments(String)
    case appNotFound(String)
    case permissionDenied(String)
    case stateUnavailable(String)
    case staleSnapshot(String)
    case staleElement(String)
    case focusFailed(String)
    case optionNotFound(String)
    case dismissFailed(String)

    public var errorDescription: String? {
        switch self {
        case .message(let value):
            return value
        case .unsupportedTool(let name):
            return "unsupportedTool(\"\(name)\")"
        case .invalidArguments(let message):
            return "invalidArguments(\"\(message)\")"
        case .appNotFound(let app):
            return "appNotFound(\"\(app)\")"
        case .permissionDenied(let message):
            return message
        case .stateUnavailable(let message):
            return message
        case .staleSnapshot(let message):
            return message
        case .staleElement(let message):
            return message
        case .focusFailed(let message):
            return message
        case .optionNotFound(let message):
            return message
        case .dismissFailed(let message):
            return message
        }
    }

    var toolResultIsError: Bool {
        true
    }

    /// True for the recoverable "your snapshot is out of date" failures. These
    /// are retried once internally after a native refresh before surfacing.
    var isStale: Bool {
        switch self {
        case .staleSnapshot, .staleElement:
            return true
        default:
            return false
        }
    }
}

extension ComputerUseError {
    static func missingArgument(_ name: String) -> ComputerUseError {
        .message("Missing required argument: \(name)")
    }
}
