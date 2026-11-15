import AppKit

/// Builds the field editor for the query field: TextKit 1 with every per-keystroke text service
/// off.
///
/// In the lab this halved the per-keystroke cost of the default TextKit 2 editor (1.24 against
/// 2.14 ms p50 from dispatch to commit). Text services such as spelling or inline prediction were
/// not the cost; TextKit 1 is the lever. IME, undo, dictation and accessibility keep working.
public enum QueryFieldEditor {
    public static func make() -> NSTextView {
        let editor = NSTextView(usingTextLayoutManager: false)
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.usesFindBar = false
        editor.inlinePredictionType = .no
        editor.mathExpressionCompletionType = .no
        editor.writingToolsBehavior = .none
        editor.enabledTextCheckingTypes = 0
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        return editor
    }
}
