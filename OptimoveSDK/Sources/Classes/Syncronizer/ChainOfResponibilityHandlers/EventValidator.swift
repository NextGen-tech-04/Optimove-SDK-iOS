//  Copyright © 2017 Optimove. All rights reserved.

import Foundation
import OptimoveCore

final class EventValidator: Node {

    struct Constants {
        enum AllowedType: String, CaseIterable, RawRepresentable {
            case string = "String"
            case number = "Number"
            case boolean = "Boolean"

            init?(rawValue: String) {
                guard let type = AllowedType.allCases.first(where: { $0.rawValue == rawValue })
                    else { return nil }
                self = type
            }
        }
        static let legalParameterLength = 4_000
        static let legalUserIdLength = 200
    }

    private let configuration: Configuration
    private let storage: OptimoveStorage

    init(configuration: Configuration,
         storage: OptimoveStorage) {
        self.configuration = configuration
        self.storage = storage
    }

    override func execute(_ operation: CommonOperation) throws {
        let validationFunction = { [configuration] () -> CommonOperation in
            switch operation {
            case let .report(events: events):
                let validatedEvents: [Event] = try events.map { event in
                    let errors = try self.validate(event: event, withConfigs: configuration.events)
                    event.validations = errors.map(EventValidator.translateToValidationIssue)
                    return event
                }
                return CommonOperation.report(events: validatedEvents)
            default:
                return operation
            }
        }
        try next?.execute(validationFunction())
    }

    func verifyAllowedNumberOfParameters(_ event: Event) -> [ValidationError] {
        var errors: [ValidationError] = []
        let numberOfParamaters = event.context.count
        let allowedNumberOfParameters = configuration.optitrack.maxActionCustomDimensions
        if numberOfParamaters > allowedNumberOfParameters {
            errors.append(
                ValidationError.limitOfParameters(
                    name: event.name,
                    actual: numberOfParamaters,
                    limit: allowedNumberOfParameters
                )
            )
            /// Delete items out of the limit
            let diff = numberOfParamaters - allowedNumberOfParameters
            event.context = Dictionary(uniqueKeysWithValues: event.context.dropLast(diff))
        }
        return errors
    }

    func verifyMandatoryParameters(_ eventConfiguration: EventsConfig, _ event: Event) -> [ValidationError] {
        var errors: [ValidationError] = []
        for (key, parameter) in eventConfiguration.parameters {
            guard event.context[key] == nil else {
                continue
            }
            /// Check has mandatory parameter which is undefined
            if parameter.mandatory {
                errors.append(ValidationError.undefinedMandatoryParameter(name: event.name, key: key))
            }
        }
        return errors
    }

    func verifySetUserIdEvent(_ event: Event) -> [ValidationError] {
        var errors: [ValidationError] = []
        if event.name == SetUserIdEvent.Constants.name,
            let userID = event.context[SetUserIdEvent.Constants.Key.userId] as? String {
            let userID = userID.trimmingCharacters(in: .whitespaces)
            if userID.count > Constants.legalUserIdLength {
                errors.append(ValidationError.tooLongUserId(userId: userID, limit: Constants.legalUserIdLength))
                return errors
            }
            let validationResult = UserIDValidator(storage: storage).validateNewUserID(userID)
            switch validationResult {
            case .valid:
                NewUserIDHandler(storage: storage).handle(userID: userID)
            case .alreadySetIn:
                break
            case .notValid:
                errors.append(ValidationError.invalidUserId(userId: userID))
            }
        }
        return errors
    }

    func verifySetEmailEvent(_ event: Event) -> [ValidationError] {
        var errors: [ValidationError] = []
        if event.name == SetUserEmailEvent.Constants.name, let email = event.context[SetUserEmailEvent.Constants.Key.email] as? String {
            let validationResult = EmailValidator(storage: storage).isValid(email)
            switch validationResult {
            case .valid:
                NewEmailHandler(storage: storage).handle(email: email)
            case .alreadySetIn:
                break
            case .notValid:
                errors.append(ValidationError.invalidEmail(email: email))
            }
        }
        return errors
    }

    func verifyEventParameters(_ event: Event, _ eventConfiguration: EventsConfig) throws -> [ValidationError] {
        var errors: [ValidationError] = []
        for (key, value) in event.context {
            /// Check undefined parameter
            guard let parameter = eventConfiguration.parameters[key] else {
                errors.append(ValidationError.undefinedParameter(key: key))
                continue
            }
            do {
                try validateParameter(parameter, key, value)
            } catch {
                if let error = error as? ValidationError {
                    errors.append(error)
                }
                throw error
            }
        }
        return errors
    }

    func validate(event: Event, withConfigs configs: [String: EventsConfig]) throws -> [ValidationError] {
        guard let eventConfiguration = configs[event.name] else {
            return [ValidationError.undefinedName(name: event.name)]
        }
        return [
            verifyAllowedNumberOfParameters(event),
            verifyMandatoryParameters(eventConfiguration, event),
            verifySetUserIdEvent(event),
            verifySetEmailEvent(event),
            try verifyEventParameters(event, eventConfiguration)
        ].flatMap { $0 }
    }

    static func translateToValidationIssue(error: ValidationError) -> ValidationIssue {
        return ValidationIssue(
            status: error.status,
            message: error.localizedDescription
        )
    }

    func validateParameter(
        _ parameter: Parameter,
        _ key: String,
        _ value: Any
    ) throws {
        guard let parameterType = Constants.AllowedType(rawValue: parameter.type) else {
            throw ValidationError.unsupportedType(key: key)
        }
        switch parameterType {
        case .number:
            guard let numberValue = value as? NSNumber else {
                throw ValidationError.wrongType(key: key, expected: .number)
            }
            if String(describing: numberValue).count > Constants.legalParameterLength {
                throw ValidationError.limitOfCharacters(key: key, limit: Constants.legalParameterLength)
            }

        case .string:
            guard let stringValue = value as? String else {
                throw ValidationError.wrongType(key: key, expected: .string)
            }
            if stringValue.count > Constants.legalParameterLength {
                throw ValidationError.limitOfCharacters(key: key, limit: Constants.legalParameterLength)
            }

        case .boolean:
            guard value is Bool else {
                throw ValidationError.wrongType(key: key, expected: .boolean)
            }
        }
    }
}

enum ValidationError: LocalizedError, Equatable {
    case undefinedName(name: String)
    case limitOfParameters(name: String, actual: Int, limit: Int)
    case undefinedMandatoryParameter(name: String, key: String)
    case undefinedParameter(key: String)
    case limitOfCharacters(key: String, limit: Int)
    case unsupportedType(key: String)
    case wrongType(key: String, expected: EventValidator.Constants.AllowedType)
    case invalidUserId(userId: String)
    case tooLongUserId(userId: String, limit: Int)
    case invalidEmail(email: String)

    var errorDescription: String? {
        switch self {
        case let .undefinedName(name):
            return """
            '\(name)' is an undefined event
            """
        case let .limitOfParameters(name, actual, limit):
            return """
            event \(name) contains \(actual) parameters while the allowed number of parameters is \(limit). Some parameters were removed to process the event.
            """
        case let .undefinedParameter(key):
            return """
            \(key) is an undefined parameter. It will not be tracked and cannot be used within a trigger.
            """
        case let .undefinedMandatoryParameter(name, key):
            return """
            event \(name) has a mandatory parameter, \(key), which is undefined or empty.
            """
        case let .limitOfCharacters(key, limit):
            return """
            '\(key)' has exceeded the limit of allowed number of characters. The character limit is \(limit)
            """
        case let .unsupportedType(key):
            return """
            '\(key)' should be of only TYPE of boolean or string or number
            """
        case let .wrongType(key, expected):
            return """
            '\(key)' should be of TYPE \(expected.rawValue)
            """
        case let .invalidUserId(userId):
            return """
            userId, \(userId), is invalid
            """
        case let .tooLongUserId(userId, limit):
            return """
            "userId, '\(userId)', is too long, the userId limit is \(limit)."
            """
        case let .invalidEmail(email):
            return """
            email, '\(email)', is invalid.
            """
        }
    }

    var status: ValidationIssue.Status {
         switch self {
         case .undefinedName,
              .undefinedMandatoryParameter,
              .limitOfCharacters,
              .unsupportedType,
              .wrongType,
              .invalidUserId,
              .tooLongUserId,
              .invalidEmail:
             return .error
         case .limitOfParameters,
              .undefinedParameter:
             return .warning
         }
     }

}

extension String {

    private struct Constants {
        static let spaceCharacter = " "
        static let underscoreCharacter = "_"
    }

    func normilizeKey(with replacement: String = Constants.underscoreCharacter) -> String {
        return self.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: Constants.spaceCharacter, with: replacement)
    }
}
