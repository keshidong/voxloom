import Foundation
import SpeechFoundation
import SpeechInput
import Testing

private let root = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { path, _ in path.deletingLastPathComponent() }
private let bundleResources = ProcessInfo.processInfo.environment["VOICE_INPUT_DEMO_RESOURCES"].map { URL(fileURLWithPath: $0) }
private let model = bundleResources?.appendingPathComponent("Qwen3-4B-Instruct-2507-Q4_K_M.gguf") ?? root.appendingPathComponent("models/Qwen3-4B-Instruct-2507-Q4_K_M.gguf")
private let engine = bundleResources?.appendingPathComponent("llama-completion") ?? root.appendingPathComponent(".runtime/llama-build/bin/llama-completion")

@Suite(.serialized) struct QwenE2ETests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLOOM_TEST_OMNI_CONTEXT_FIXTURES"] != nil))
    func omniUsesContextForAmbiguousNearSoundsAndRetainsClearSpeech() async throws {
        let fixturePath = try #require(ProcessInfo.processInfo.environment["VOXLOOM_TEST_OMNI_CONTEXT_FIXTURES"])
        let fixtures = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let engine = bundleResources?.appending(path: "llama-mtmd-cli") ?? root.appending(path: ".runtime/llama-build/bin/llama-mtmd-cli")
        let server = ProcessInfo.processInfo.environment["VOXLOOM_TEST_OMNI_SERVER"].map {
            QwenOmniServer(executable: URL(fileURLWithPath: $0))
        }
        let reviewer = QwenOmniAudioReviewer(configuration: .init(
            executable: server == nil ? engine : URL(fileURLWithPath: "/usr/bin/false"),
            model: root.appending(path: "models/Qwen3-Omni-30B-A3B-Instruct-Q4_K_M.gguf"),
            projector: root.appending(path: "models/mmproj-Qwen3-Omni-30B-A3B-Instruct-Q8_0.gguf")), server: server)
        let examples = [
            (file: "review.wav", draft: "负荷约用6.1秒。", context: "语音 转写 实测 音频 复核 约用 秒",
             required: "复核", rejected: ["负荷"], number: "6.1"),
            (file: "deploy.wav", draft: "刚才部属只用了9.2秒。", context: "服务 更新 环境 部署 记录 已完成",
             required: "部署", rejected: ["部属"], number: "9.2"),
            (file: "load.wav", draft: "设备负荷达到6.1千瓦。", context: "试验 报表 复核 耗时 项目",
             required: "负荷", rejected: ["复核"], number: "6.1"),
            (file: "load.wav", draft: "设备复核达到6.1千瓦。", context: "试验 设备 负荷 千瓦 工况 报表 复核",
             required: "负荷", rejected: ["复核"], number: "6.1"),
            (file: "selection.wav", draft: "复核耗时1.09到1.14秒，选选制都正确。", context: "语音 复核 耗时 选 字 都 正确",
             required: "选字都正确", rejected: ["选制", "选选"], number: "1.09到1.14秒"),
        ]
        do {
            let filler = "部署 清单 服务 检查 review release status notes 环境 确认".split(separator: " ")
            for example in examples {
                let audio = try WAVCodec.decode(Data(contentsOf: fixtures.appending(path: example.file)))
                let terms = example.context.split(separator: " ")
                let context = server == nil ? example.context :
                    ((0..<(300 - terms.count)).map { filler[$0 % filler.count] } + terms).joined(separator: " ")
                let application = DictationApplication(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
                await reviewer.prepare(application: application, context: context)
                let start = ContinuousClock.now
                let text = try await reviewer.review(.init(audio: audio, transcript: example.draft,
                    application: application, applicationContext: context))
                if server != nil { print("Prepared Omni review \(example.file): \(start.duration(to: .now))") }
                #expect(text.contains(example.required), Comment(rawValue: example.file))
                #expect(!example.rejected.contains(where: text.contains), Comment(rawValue: example.file))
                #expect(text.contains(example.number), Comment(rawValue: example.file))
                #expect(!text.contains("〔") && !text.contains("／"), Comment(rawValue: example.file))
            }
        } catch {
            await server?.shutdown()
            throw error
        }
        await server?.shutdown()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXLOOM_TEST_OMNI"] == "1"))
    func omniReviewsActualAudioAndKeepsAppContextOutOfTheTranscript() async throws {
        let asr = QwenASRRecognizer(configuration: .init(executable: root.appending(path: ".runtime/qwen-asr-runtime/qwen-asr"),
            model: root.appending(path: "models/Qwen3-ASR-1.7B-4bit")))
        let omniEngine = bundleResources?.appending(path: "llama-mtmd-cli") ?? root.appending(path: ".runtime/llama-build/bin/llama-mtmd-cli")
        let contextLog = root.appending(path: ".build/reports/omni-public-sample-app-context.json")
        let reviewer = QwenOmniAudioReviewer(configuration: .init(executable: omniEngine,
            model: root.appending(path: "models/Qwen3-Omni-30B-A3B-Instruct-Q4_K_M.gguf"),
            projector: root.appending(path: "models/mmproj-Qwen3-Omni-30B-A3B-Instruct-Q8_0.gguf")), appContextLog: contextLog)
        do {
            let audio = try WAVCodec.decode(Data(contentsOf: root.appending(path: ".runtime/asr_zh.wav")))
            let original = try await asr.transcribe(audio, options: .init(language: .chinese))
            try #require(original.text.contains("交易几乎停滞"))
            let draft = original.text.replacingOccurrences(of: "交易几乎停滞", with: "交易几乎几乎停纸")
            let fixtureWords = "部署 清单 服务 检查 review release status notes 环境 确认".split(separator: " ")
            let snapshot = (0..<297).map { fixtureWords[$0 % fixtureWords.count] }.joined(separator: " ")
                + " 窗口 档案 ZEN-729"
            let start = ContinuousClock.now
            let text = try await reviewer.review(.init(audio: audio, transcript: draft, precedingText: "档案号 ZEN-731。",
                application: .init(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit"),
                applicationContext: snapshot))
            print("Cold Omni audio review: \(start.duration(to: .now))")
            let entry = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: contextLog)) as? [String: Any])
            #expect(entry["applicationName"] as? String == "TextEdit")
            #expect(entry["applicationBundleIdentifier"] as? String == "com.apple.TextEdit")
            #expect(entry["contextBytes"] as? Int == snapshot.utf8.count)
            #expect(text.contains("交易几乎停滞"))
            #expect(!text.contains("几乎几乎"))
            #expect(!text.contains("ZEN-731"))
            #expect(!text.contains("ZEN-729"))
            #expect(!text.contains("TextEdit"))
            await asr.shutdown()
        } catch {
            await asr.shutdown()
            throw error
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path) && FileManager.default.fileExists(atPath: model.path)),
          arguments: [
              CorrectionRequest(text: "哦哦，寄去南桥，南桥，好像还得等三天。", vocabulary: "北桥"),
              CorrectionRequest(text: "先确认 cache 里存了两份，两份，然后把第二份给……", vocabulary: "Cash Flow")
          ])
    func interactiveVocabularyPreservesSpokenWordsWhenATermIsOnlyAPartialMatch(_ request: CorrectionRequest) async throws {
        let corrector = QwenTextCorrector(configuration: .init(executable: engine, model: model, mode: .interactive))
        let result = try await corrector.correct(request)
        #expect(result.text == request.text)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path) && FileManager.default.fileExists(atPath: model.path)))
    func interactiveDictationRepairsTermsAndRetainsNumbersAndSpokenText() async throws {
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(executable: engine, model: model, mode: .interactive))
        let examples: [(request: CorrectionRequest, required: [String])] = [
            (.init(text: "图舒卡的充直额图以USD即价，每刺最少充直20。", vocabulary: "图书卡 充值额度 USD 计价"),
             ["图书卡", "充值额度", "计价", "USD", "20"]),
            (.init(text: "语文老师在四号窗口等我，后来送我回家。晚饭前加热1杯牛奶。",
                   surroundingText: "档案号 ZEN-731，先前讨论的是图书馆。"),
             ["语文老师", "四号窗口", "送我回家", "加热1杯牛奶"])
        ]
        for (index, example) in examples.enumerated() {
            let start = ContinuousClock.now
            let result = try await corrector.correct(example.request)
            print("Interactive correction fixture \(index + 1): \(start.duration(to: .now))")
            #expect(result.original == example.request.text)
            #expect(!result.numbersChanged)
            #expect(!result.text.contains("ZEN-731"))
            for term in example.required { #expect(result.text.contains(term)) }
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path) && FileManager.default.fileExists(atPath: model.path)))
    func pronunciationHintsHelpRepairContextualNearSoundsWithoutChangingCorrectWords() async throws {
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(executable: engine, model: model))
        let original = "请语文老司东计校刊共收到多少篇稿件，然后把贫审结果发给主编。茶已经凉了，先加乐到60度。"
        let repaired = try await corrector.correct(.init(text: original))
        #expect(repaired.original == original)
        for phrase in ["老师", "统计", "评审", "加热"] { #expect(repaired.text.contains(phrase)) }
        #expect(!repaired.numbersChanged)

        let correct = "语文老师在四号窗口等我，后来送我回家。晚饭前加热1杯牛奶。"
        let preserved = try await corrector.correct(.init(text: correct))
        for phrase in ["老师", "四号窗口", "送我回家", "加热"] { #expect(preserved.text.contains(phrase)) }
        #expect(!preserved.numbersChanged)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path) && FileManager.default.fileExists(atPath: model.path)))
    func varyingPromptLengthsProduceNonemptyJSONCandidates() async throws {
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(executable: engine, model: model))
        for padding in [0, 21, 59, 117] {
            let text = String(repeating: "请核对书目。", count: padding) + "今天下午确认图书卡信息。"
            let result = try await corrector.correct(.init(text: text, vocabulary: "图书卡"))
            #expect(!result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(result.original == text)
        }
    }
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path) && FileManager.default.fileExists(atPath: model.path)))
    func repeatedReferencesKeepTheObjectOfTheActionConsistent() async throws {
        let original = "我请师傅把纸箱搬进仓库，师傅说纸箱必须搬到仓库里面，后来又说必须把我搬到仓库里面。"
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(executable: engine, model: model))
        let result = try await corrector.correct(.init(text: original))
        #expect(result.original == original)
        #expect(!result.text.contains("把我搬"))
        #expect(result.text.contains("纸箱"))
        #expect(result.text.contains("仓库"))
        let normal = "他送我回家，我让他在家门口停车。"
        let preserved = try await corrector.correct(.init(text: normal))
        #expect(preserved.text.contains("送我回家"))
        let delivery = "这箱书不能放在店门口，店员说必须送我上门，这些书必须直接送我上门。"
        let delivered = try await corrector.correct(.init(text: delivery))
        #expect(!delivered.text.contains("送我上门"))
        #expect(!delivered.text.contains("送他上门"))
        #expect(delivered.text.contains("上门") || delivered.text.contains("到家"))
        #expect(delivered.text.contains("书") || delivered.text.contains("货"))

        let mixed = "书已经装进纸箱，司机说纸箱不能放在马路边，两个箱子都要送我上门，请你留下收件人的电话，不要把收据交给司机，明天上午十点以前送到就可以，楼下社区服务台可以代收。司机送我回家以后，再回到店里取第二件货。"
        let exact = try await corrector.correct(.init(text: mixed))
        #expect(exact.text == mixed.replacingOccurrences(of: "送我上门", with: "送货上门"))

        // Optional local-only diagnostics. Text comes from an explicitly named
        // private file, never from committed fixtures or test output.
        if let path = ProcessInfo.processInfo.environment["VOXLOOM_DIAGNOSTIC_CASE"] {
            let cases = try JSONDecoder().decode([DiagnosticCase].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            for input in cases {
                let candidate = try await corrector.correct(.init(text: input.text))
                let forbiddenCount = input.forbidden.filter { candidate.text.contains($0) }.count
                let requiredCount: Int
                if let pattern = input.pattern {
                    requiredCount = try NSRegularExpression(pattern: pattern).numberOfMatches(in: candidate.text,
                        range: NSRange(candidate.text.startIndex..., in: candidate.text))
                } else { requiredCount = candidate.text.components(separatedBy: input.required).count - 1 }
                #expect(forbiddenCount == 0)
                #expect(requiredCount >= input.minimumOccurrences)
            }
        }
    }
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path) && FileManager.default.fileExists(atPath: model.path)))
    func longDictationReturnsACompleteCandidateIncludingTheLastSentence() async throws {
        let sentences = [
            "今天我们讨论图书馆新系统的上线安排，首先需要整理现有书目并检查每一本书的编号。",
            "管理员会在周一完成数据核对，周二安排志愿者测试借书和还书，发现问题要及时登记。",
            "测试期间保留旧系统作为备用，新旧数据需要每天核对，避免重复借阅或者遗漏归还记录。",
            "读者可以使用图书卡查询借阅历史，也可以搜索作者和书名，暂时不要开放批量删除功能。",
            "如果遇到无法识别的条码，请记录设备型号和出现时间，然后联系值班人员协助处理。",
            "下一阶段还要完善无障碍操作，让不同年龄的读者都能够方便地查询书籍和预约座位。",
            "所有通知发布之前都需要经过核对，不要把测试环境的截图当作正式操作说明发给读者。",
            "图书采购需要保留每一笔订单的记录，工作人员应当在收货之后检查书籍数量和外观是否符合要求。",
            "对于已经损坏或者缺页的书籍，需要在系统中标记原因，等待管理员核实以后再决定后续处理方式。",
            "周末开放时间可能会根据读者的预约情况调整，具体安排应当提前发布并在入口处放置清晰的提示。",
            "场地维护期间不安排大型讲座，阅读区保持安静，工作人员可以在服务台回答查询和预约方面的问题。",
            "新的培训材料应当包含常见错误和恢复步骤，方便第一次使用系统的志愿者独立完成日常操作。",
            "每一轮测试结束后都要确认临时账号已经停用，并把发现的问题按照影响范围整理成清楚的清单。",
            "图书馆还计划增设安静的自习区域，桌椅和照明需要在开放之前完成检查，以免影响读者正常学习。",
            "宣传海报上的时间和地点必须与预约页面保持一致，如果安排发生变化，需要及时通知已经报名的读者。",
            "培训活动结束后可以收集参与者的意见，优先处理影响正常借阅的问题，再逐步完善其他操作细节。",
            "工作人员应当了解如何导出查询结果和检查预约状态，但不要随意修改其他岗位负责的数据记录。",
            "在正式上线前需要完成最后一轮核对，确认书目检索和借阅记录能够正常显示，并保留必要的回退步骤。",
            "每一个待处理事项都要有明确的负责人和完成时间，交接时说明目前进度以及还需要进一步确认的问题。",
            "如果用户不小心关闭了页面，应当能够重新打开并看到最近的操作结果，而不需要重复提交同一个请求。",
            "最后请记住把蓝色图书卡放回服务台。"
        ]
        let original = sentences.joined()
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(executable: engine, model: model))
        let result = try await corrector.correct(.init(text: original))
        #expect(result.original == original)
        #expect(result.text.contains("蓝色图书卡"))
        #expect(result.text.count > original.count * 3 / 4)
    }
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: engine.path) && FileManager.default.fileExists(atPath: model.path),
                   "Local Qwen resources and access to Metal required"))
    func actualOfflineModelRepairsDomainWordsAndRetainsAReviewableOriginal() async throws {
        let original = "图舒卡的充直额图以USD即价，每刺最少充直20。"
        let corrector: any TextCorrecting = QwenTextCorrector(configuration: .init(executable: engine, model: model))
        let result = try await corrector.correct(.init(text: original, vocabulary: "图书卡 充值额度 USD 计价"))
        #expect(result.text.contains("充值额度"))
        #expect(result.text.contains("USD"))
        #expect(result.text.contains("计价"))
        #expect(result.containsNumbers)
    }
}

private struct DiagnosticCase: Decodable {
    let text: String
    let forbidden: [String]
    let required: String
    let minimumOccurrences: Int
    let pattern: String?
}
