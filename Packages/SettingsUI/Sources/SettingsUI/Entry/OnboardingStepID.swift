/// A step of onboarding by name, for a scenario that shows the window on one step with
/// ``OnboardingController/showForCapture(_:at:)``.
public enum OnboardingStepID: String, CaseIterable, Sendable {
    case welcome
    case hotkey
    case features
    case permissions
    case theme
    case done
}

extension OnboardingModel.Step {
    init(_ id: OnboardingStepID) {
        switch id {
        case .welcome: self = .welcome
        case .hotkey: self = .hotkey
        case .features: self = .features
        case .permissions: self = .permissions
        case .theme: self = .theme
        case .done: self = .done
        }
    }
}
