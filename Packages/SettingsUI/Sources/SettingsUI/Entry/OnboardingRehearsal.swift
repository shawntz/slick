import Foundation
import KitHosting

/// Onboarding's Optional Features step without its window, for scenarios: the model the window
/// shows, walked from Welcome to the step, its switches set as a person would leave them, then
/// Continue, which applies them. Nothing is shown and onboarding is not marked done.
public enum OnboardingRehearsal {
    /// Sets each optional feature's switch by feature ID and continues past the step. Returns the
    /// problems: a feature the step does not list, or a step that cannot be reached.
    public static func chooseOptionalFeatures(
        _ choices: [String: Bool], dependencies: SettingsDependencies
    ) async -> [String] {
        let model = OnboardingModel(context: SettingsContext(dependencies), onFinish: {})
        var problems: [String] = []
        while model.step < .features {
            let before = model.step
            await model.next()
            if model.step == before { break }
        }
        guard model.step == .features else {
            return ["onboarding has no Optional Features step: no feature is off by default"]
        }
        let listed = Set(model.optionalFeatures.map(\.id))
        for (featureID, isOn) in choices.sorted(by: { $0.key < $1.key }) {
            guard listed.contains(featureID) else {
                problems.append("onboarding lists no optional feature \(featureID); it lists \(listed.sorted())")
                continue
            }
            model.setEnabled(isOn, feature: featureID)
        }
        await model.next()
        return problems
    }
}
