import Testing
@testable import GoIDECore

@Suite struct EditPreviewTests {
    private func edit(_ l1: Int, _ c1: Int, _ l2: Int, _ c2: Int, _ text: String) -> TextEdit {
        TextEdit(start: TextPosition(line: l1, character: c1), end: TextPosition(line: l2, character: c2), newText: text)
    }

    @Test func groupsEditsByLine() {
        let text = "func fib(n int) int {\n\treturn fib(n-1) + fib(n-2)\n}\n\nvar x = fib(3)\n"
        let hunks = EditPreview.hunks([
            edit(1, 19, 1, 22, "Fib"), edit(0, 5, 0, 8, "Fib"), edit(1, 8, 1, 11, "Fib"), edit(4, 8, 4, 11, "Fib"),
        ], in: text)
        #expect(hunks.map(\.line) == [0, 1, 4])
        #expect(hunks[0].before == "func fib(n int) int {")
        #expect(hunks[0].after == "func Fib(n int) int {")
        #expect(hunks[1].after == "\treturn Fib(n-1) + Fib(n-2)")
        #expect(hunks[2].after == "var x = Fib(3)")
    }

    @Test func multiLineEditFormsOneHunk() {
        let text = "a\nb\nc\nd"
        let hunks = EditPreview.hunks([edit(1, 0, 2, 1, "X"), edit(2, 1, 2, 1, "!")], in: text)
        #expect(hunks.count == 1)
        #expect(hunks[0].line == 1)
        #expect(hunks[0].before == "b\nc")
        #expect(hunks[0].after == "X!")
    }
}
