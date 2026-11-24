import Testing
@testable import VoxloomDesktop

struct ConversationHistoryTests {
    @Test func readsRecentMessagesNearTheComposerWithinItsPage() {
        let children = [0: [1, 10], 1: [2, 3], 3: [4], 4: Array(20..<30), 10: [11]]
        let parents = Dictionary(uniqueKeysWithValues: children.flatMap { parent, children in
            children.map { ($0, parent) }
        })
        let source = ConversationHistory(isSame: ==, parent: { parents[$0] },
            recentChildren: { node, limit, _ in Array((children[node] ?? []).suffix(limit)) },
            kind: { node in
                switch node {
                case 0, 1: .scopeBoundary
                case 3, 10: .history
                case 11, 20..<30: .text
                case 2: .ignored
                default: .container
                }
            }, text: { "message \($0)" }, canContinue: { true })

        #expect(source.read(near: 2, isCurrent: { true }) == .success((24..<30).map { "message \($0)" }))
        #expect(source.read(near: 2, messageLimit: 2, isCurrent: { true }) == .success(["message 28", "message 29"]))
        #expect(source.read(near: 2, isCurrent: { false }) == .failure(.targetChanged))
    }

    @Test func collectsExactTextBeforeTheComposerWithinItsOwnPage() {
        let children = [0: [1, 7], 1: [8, 2, 6], 8: [3, 4], 2: [5]]
        let parents = Dictionary(uniqueKeysWithValues: children.flatMap { parent, children in
            children.map { ($0, parent) }
        })
        let values = [3: "先看  Voxloom", 4: "今天继续\n测试 ASR", 5: "输入框", 6: "发送按钮", 7: "其他页面"]
        let source = ConversationHistory(isSame: ==, parent: { parents[$0] },
            recentChildren: { node, limit, _ in Array((children[node] ?? []).suffix(limit)) },
            kind: { node in
                switch node {
                case 0, 1: .scopeBoundary
                case 5, 6: .ignored
                case 3, 4, 7: .text
                default: .container
                }
            }, text: { values[$0] }, canContinue: { true })

        #expect(source.readNearbyText(near: 2, isCurrent: { true }) == ["先看  Voxloom", "今天继续\n测试 ASR"])
        #expect(source.readNearbyText(near: 2, isCurrent: { false }).isEmpty)
    }

    @Test func skipsAnAmbiguousConversationArea() {
        let source = ConversationHistory(isSame: ==, parent: { $0 == 1 ? 0 : nil },
            recentChildren: { node, _, _ in node == 0 ? [1, 2, 3] : [4] },
            kind: { node in
                switch node {
                case 0: .scopeBoundary
                case 2, 3: .history
                case 4: .text
                default: .ignored
                }
            }, text: { _ in
                Issue.record("An ambiguous history must be rejected before reading its messages")
                return "Message"
            }, canContinue: { true })

        #expect(source.read(near: 1, isCurrent: { true }) == .failure(.ambiguousHistoryArea))
    }

    @Test(arguments: [false, true])
    func distinguishesAnAbsentHistoryFromAnEmptyHistory(foundHistory: Bool) {
        let source = ConversationHistory(isSame: ==, parent: { $0 == 1 ? 0 : nil },
            recentChildren: { node, _, _ in node == 0 ? [1, 2] : [] },
            kind: { node in
                if node == 0 { return .scopeBoundary }
                return node == 2 && foundHistory ? .history : .ignored
            }, text: { _ in nil }, canContinue: { true })

        let expected: ConversationReadError = foundHistory ? .noMessageText : .noHistoryArea
        #expect(source.read(near: 1, isCurrent: { true }) == .failure(expected))
    }

    @Test func discardsMessagesWhenTheSameComposerIsReusedForAnotherConversation() {
        var lastMessage = 3
        let source = ConversationHistory(isSame: ==, parent: { $0 == 1 ? 0 : nil },
            recentChildren: { node, _, _ in
                switch node {
                case 0: [1, 2]
                case 2: [lastMessage]
                default: []
                }
            }, kind: { node in
                switch node {
                case 0: .scopeBoundary
                case 2: .history
                case 3, 4: .text
                default: .ignored
                }
            }, text: { _ in
                lastMessage = 4
                return "Previous conversation"
            }, canContinue: { true })

        #expect(source.read(near: 1, isCurrent: { true }) == .failure(.targetChanged))
    }

    @Test func dropsPartialMessagesWhenTheReadRunsOutOfTime() {
        var withinDeadline = true
        let source = ConversationHistory(isSame: ==, parent: { $0 == 1 ? 0 : nil },
            recentChildren: { node, _, _ in node == 0 ? [1, 2] : [3] },
            kind: { node in
                switch node {
                case 0: .scopeBoundary
                case 2: .history
                case 3: .text
                default: .ignored
                }
            }, text: { _ in
                withinDeadline = false
                return "Partial result"
            }, canContinue: { withinDeadline })

        #expect(source.read(near: 1, isCurrent: { true }) == .failure(.timedOut))
    }
}
