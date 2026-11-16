import Foundation

extension Template {
    /// Renders the template. Placeholders with ``issues`` stay as typed; a missing clipboard entry,
    /// selection, snippet or argument without a default renders as empty text.
    public func render(in environment: TemplateEnvironment, style: TemplateStyle = .plain) async -> RenderedTemplate {
        await render(in: environment, style: style, embedded: false)
    }

    /// Parses and renders in one step.
    public static func render(_ source: String, in environment: TemplateEnvironment, style: TemplateStyle = .plain)
        async -> String
    {
        await Template(source).render(in: environment, style: style).text
    }

    private func render(in environment: TemplateEnvironment, style: TemplateStyle, embedded: Bool) async
        -> RenderedTemplate
    {
        var text = ""
        var cursorOffset: Int?
        for segment in segments {
            switch segment {
            case .text(let literal):
                text += literal
            case .placeholder(let placeholder):
                if case .cursor = placeholder.kind {
                    if style == .plain && !embedded && cursorOffset == nil { cursorOffset = text.count }
                    continue
                }
                var value = await resolve(placeholder.kind, in: environment, style: style, embedded: embedded)
                for modifier in placeholder.modifiers {
                    value = Self.apply(modifier, to: value, locale: environment.locale)
                }
                text += Self.styled(value, placeholder: placeholder, style: style)
            }
        }
        return RenderedTemplate(text: text, cursorOffset: cursorOffset)
    }

    private func resolve(
        _ kind: PlaceholderKind, in environment: TemplateEnvironment, style: TemplateStyle, embedded: Bool
    ) async -> String {
        switch kind {
        case .clipboard(let offset):
            return await environment.clipboard(offset) ?? ""
        case .selection:
            return await environment.selection() ?? ""
        case .date(let dateStyle, let options):
            return Self.formatDate(dateStyle, options, in: environment)
        case .uuid:
            return environment.makeUUID().uuidString
        case .cursor:
            return ""
        case .argument(let argument):
            if let value = environment.arguments[argument.key], !value.isEmpty { return value }
            return argument.defaultValue ?? ""
        case .snippet(let name):
            // One level only: a snippet inside an embedded snippet renders as nothing.
            guard !embedded, let source = await environment.snippet(name) else { return "" }
            return await Template(source).render(in: environment, style: .plain, embedded: true).text
        }
    }

    static func formatDate(_ style: DateStyle, _ options: DateOptions, in environment: TemplateEnvironment) -> String {
        let calendar = environment.calendar
        var date = environment.now
        for offset in options.offsets {
            let (component, amount): (Calendar.Component, Int) =
                switch offset.unit {
                case .second: (.second, offset.amount)
                case .minute: (.minute, offset.amount)
                case .hour: (.hour, offset.amount)
                case .day: (.day, offset.amount)
                case .week: (.day, offset.amount * 7)
                case .month: (.month, offset.amount)
                case .year: (.year, offset.amount)
                }
            date = calendar.date(byAdding: component, value: amount, to: date) ?? date
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = environment.timeZone
        if let format = options.format {
            formatter.locale = environment.locale
            formatter.dateFormat = format
        } else {
            formatter.locale = options.locale.map { Locale(identifier: $0) } ?? environment.locale
            switch style {
            case .date: (formatter.dateStyle, formatter.timeStyle) = (.medium, .none)
            case .time: (formatter.dateStyle, formatter.timeStyle) = (.none, .short)
            case .datetime: (formatter.dateStyle, formatter.timeStyle) = (.medium, .short)
            case .day: formatter.setLocalizedDateFormatFromTemplate("EEEE")
            }
        }
        return formatter.string(from: date)
    }

    static func apply(_ modifier: TemplateModifier, to value: String, locale: Locale) -> String {
        switch modifier {
        case .uppercase: value.uppercased(with: locale)
        case .lowercase: value.lowercased(with: locale)
        case .trim: value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .percentEncode: percentEncode(value)
        case .jsonStringify: jsonString(value)
        case .raw: value
        }
    }

    private static func styled(_ value: String, placeholder: Placeholder, style: TemplateStyle) -> String {
        guard !placeholder.modifiers.contains(.raw) else { return value }
        switch style {
        case .plain:
            return value
        case .url:
            return placeholder.modifiers.contains(.percentEncode) ? value : percentEncode(value)
        case .prompt:
            switch placeholder.kind {
            case .clipboard, .selection, .argument, .snippet: return fenced(value)
            default: return value
            }
        }
    }

    /// The value between two fences of double quotes, each one longer than the longest run of
    /// double quotes in the value and at least three, so text from a web page or an email cannot
    /// close the fence and go on as if it were the instruction. A quote at either end of the value
    /// gets a space between it and the fence, so the two never join into one longer run.
    private static func fenced(_ value: String) -> String {
        var longest = 0
        var run = 0
        for scalar in value.unicodeScalars {
            if scalar == "\"" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let fence = String(repeating: "\"", count: max(3, longest + 1))
        let start = value.hasPrefix("\"") ? " " : ""
        let end = value.hasSuffix("\"") ? " " : ""
        return fence + start + value + end + fence
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return value }
        return String(decoding: data, as: UTF8.self)
    }
}
