import Kit

extension FeatureHarness {
    /// Chooses an option of a picker in the feature's settings pane, both by title, as the settings
    /// window does. When the choice asks first, the question is recorded in ``confirmations`` and
    /// answered with ``confirmationAnswer``. Returns true when the value was stored. Follow it with
    /// ``settle()`` to let the feature handle the change.
    @discardableResult
    public func chooseSetting(_ title: String, option: String) throws -> Bool {
        let items = feature.settingsPane?.sections.flatMap(\.items) ?? []
        guard let item = items.first(where: { $0.title == title }), case .picker(let key, let options) = item.control
        else {
            throw HarnessError.noSuchSettingsPicker(title)
        }
        guard let choice = options.first(where: { $0.title == option }) else { throw HarnessError.noSuchOption(option) }
        let name = context.settings.storageName(for: key.name)
        if let confirmation = item.confirmation(choosing: choice.value, stored: fakes.settings.storage(for: name)) {
            confirmations.append(confirmation)
            guard confirmationAnswer else { return false }
        }
        fakes.settings.set(choice.value, for: name)
        return true
    }
}
