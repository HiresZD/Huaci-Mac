import Foundation

@main
struct AIPresetRegression {
    static func main() {
        var state = AIPresetDraftState()
        let selection = "第一行：保留中文和空格。\n\n  Second line. 🐱\n"
        state.setSelectionContext(selection)
        let explained = state.prepare(.explain, currentDraft: "")
        require(explained.text.hasSuffix(selection), "Empty input must preserve the complete selection")
        require(state.canSubmit(explained.text), "A populated preset may be sent")
        require(explained.selectedRange == NSRange(location: explained.text.utf16.count, length: 0),
                "Caret positioning must use UTF-16 offsets")

        let summarized = state.prepare(.summarize, currentDraft: explained.text)
        require(summarized.text == AIPreset.summarize.prompt(for: selection),
                "Switching an unchanged preset must not nest its old instructions")
        let edited = summarized.text + "\n额外要求：使用两条要点。"
        let polished = state.prepare(.polish, currentDraft: edited)
        require(polished.text == AIPreset.polish.prompt(for: edited),
                "An edited user draft takes precedence over cached source and selection")

        state.setSelectionContext("新选区")
        require(state.prepare(.explain, currentDraft: "").text == AIPreset.explain.prompt(for: "新选区"),
                "New selections must replace stale material")
        state.resetGeneratedDraft()
        require(state.prepare(.summarize, currentDraft: "").text.hasSuffix("新选区"),
                "Clearing a sent draft must retain this conversation's selection")

        state.setSelectionContext("")
        let empty = state.prepare(.explain, currentDraft: "\n   ")
        require(empty.selectedRange.length > 0, "An empty source must offer a selected editable placeholder")
        require(!state.canSubmit(empty.text), "An unchanged empty-source preset must not be submitted")
        state.setSelectionContext("")
        require(!state.canSubmit(empty.text), "Resetting selection context must not make an old placeholder sendable")
        state = AIPresetDraftState()
        let anotherEmpty = state.prepare(.explain, currentDraft: "")
        let switchedEmpty = state.prepare(.polish, currentDraft: anotherEmpty.text)
        require(!state.canSubmit(switchedEmpty.text), "Switching presets must not treat the placeholder as material")
        let filled = (switchedEmpty.text as NSString).replacingCharacters(in: switchedEmpty.selectedRange, with: "新素材")
        require(state.canSubmit(filled), "Replacing the selected placeholder must allow sending")
        require(!state.canSubmit(" \n\t"), "Whitespace-only prompts must never be sent")
        require(state.prepare(.summarize, currentDraft: "用户草稿\n第二行").text.hasSuffix("用户草稿\n第二行"),
                "A real draft must be used even without a selection")
        print("AI preset draft regression checks passed.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
