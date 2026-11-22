import XCTest
import SwiftUI
import UIKit
@testable import SimpleX
@testable import SimpleXChat

final class LinkPreviewTests: XCTestCase {
    private let sendCmd = sendSimpleXCmdStr
    private let parseMarkdown = parseSimpleXMarkdownText
    private let lock = NSLock()
    private var requested: [String] = []
    private var unrecorded: [String] = []
    private var held: [String: DispatchSemaphore] = [:]
    private var commands: [String: Any] = [:]
    private var window: UIWindow?
    private let settings: [(defaults: UserDefaults, key: String, value: Bool)] = [
        (UserDefaults.standard, DEFAULT_DEVELOPER_TOOLS, false),
        (UserDefaults.standard, DEFAULT_SHOW_LINK_PREVIEW_ERRORS, false),
        (UserDefaults.standard, DEFAULT_PRIVACY_SAVE_LAST_DRAFT, true),
        (groupDefaults, GROUP_DEFAULT_PRIVACY_LINK_PREVIEWS, true),
        (groupDefaults, GROUP_DEFAULT_PRIVACY_SANITIZE_LINKS, false)
    ]
    private var savedSettings: [Any?] = []

    @MainActor
    override func setUp() async throws {
        savedSettings = settings.map { $0.defaults.object(forKey: $0.key) }
        for s in settings { s.defaults.set(s.value, forKey: s.key) }
        let recording = try XCTUnwrap(try fixtureJSON("previews/link_preview") as? [String: [String: Any]])
        let commands = recording["commands"] ?? [:]
        let markdown = recording["markdown"] ?? [:]
        self.commands = commands
        sendSimpleXCmdStr = { [unowned self] cmd, _, _ in
            guard let match = self.recorded(cmd, commands) else { self.locked { self.unrecorded.append(cmd) }; return nil }
            let gate: DispatchSemaphore? = self.locked { self.requested.append(match.key); return self.held[match.key] }
            gate?.wait()
            return try? JSONSerialization.data(withJSONObject: singleFieldJSON(match.response))
        }
        parseSimpleXMarkdownText = { [unowned self] str in
            let recorded: Any? = str.isEmpty ? [String: Any]() : markdown[str]
            guard let parsed = recorded else { self.locked { self.unrecorded.append("markdown \(str)") }; return nil }
            return try? jsonDecoder.decode(ParsedMarkdown.self, from: JSONSerialization.data(withJSONObject: singleFieldJSON(parsed)))
        }
    }

    @MainActor
    override func tearDown() async throws {
        locked { held.values }.forEach { $0.signal() }
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        if let alert = shownAlert() {
            try await waitFor { !alert.isBeingPresented }
            await withCheckedContinuation { done in alert.dismiss(animated: false) { done.resume() } }
        }
        for (s, saved) in zip(settings, savedSettings) { s.defaults.set(saved, forKey: s.key) }
        sendSimpleXCmdStr = sendCmd
        parseSimpleXMarkdownText = parseMarkdown
        XCTAssertEqual(locked { unrecorded }, [], "requests without recorded responses")
    }

    @MainActor
    func testPreviewIsRecordedResponse() async throws {
        let linkPreview = await apiGetLinkPreview("LINK_URL/page")
        assertRecordedPreview(linkPreview)
        XCTAssertEqual(requests(), ["/_link preview LINK_URL/page"])
        XCTAssertNil(shownAlert())
    }

    @MainActor
    func testFailureShowsNoAlertWithoutBothToggles() async throws {
        for (developerTools, showLinkPreviewErrors) in [(false, false), (true, false), (false, true)] {
            UserDefaults.standard.set(developerTools, forKey: DEFAULT_DEVELOPER_TOOLS)
            UserDefaults.standard.set(showLinkPreviewErrors, forKey: DEFAULT_SHOW_LINK_PREVIEW_ERRORS)
            let linkPreview = await apiGetLinkPreview("LINK_URL/no-image")
            XCTAssertNil(linkPreview)
            XCTAssertNil(shownAlert(), "developer options \(developerTools), link preview errors \(showLinkPreviewErrors)")
        }
    }

    @MainActor
    func testFailureShowsCoreErrorWithBothToggles() async throws {
        UserDefaults.standard.set(true, forKey: DEFAULT_DEVELOPER_TOOLS)
        UserDefaults.standard.set(true, forKey: DEFAULT_SHOW_LINK_PREVIEW_ERRORS)
        let linkPreview = await apiGetLinkPreview("LINK_URL/no-image")
        XCTAssertNil(linkPreview)
        try await waitFor { self.shownAlert()?.isBeingPresented == false }
        let alert = try XCTUnwrap(shownAlert())
        XCTAssertEqual([alert.title, alert.message], ["Link preview error", "no image"])
        XCTAssertEqual(alert.actions.map(\.title), ["Ok"])
    }

    @MainActor
    func testComposeShowsRecordedPreview() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { compose.composeState.linkPreview != nil }
        assertRecordedPreview(compose.composeState.linkPreview)
        XCTAssertEqual(requests(), ["/_link preview LINK_URL/page"])
        XCTAssertNil(shownAlert())
    }

    @MainActor
    func testComposeShowsNoPreviewOnFailureAndDoesNotFetchItAgain() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image"] }
        try await waitFor { compose.composeState.noPreview }
        XCTAssertNil(shownAlert())
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { compose.composeState.linkPreview != nil }
        compose.composeState.message = "LINK_URL/no-image"
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(compose.composeState.noPreview)
        XCTAssertEqual(requests(), ["/_link preview LINK_URL/no-image", "/_link preview LINK_URL/page"])
    }

    @MainActor
    func testComposeSendsCardOfNextLinkAndFetchesFailedLinkAfterSend() async throws {
        let presetTags = ChatTagsModel.shared.presetTags
        defer { ChatTagsModel.shared.presetTags = presetTags }
        let note = try XCTUnwrap(commands.keys.first { $0.hasPrefix("/_create ") })
        let compose = try await showCompose(ComposeHostState(chat: Chat(chatInfo: .local(noteFolder: NoteFolder.sampleData))))
        compose.composeState.liveMessage = LiveMessage(chatItem: ChatItem.liveDummy(.local), typedMsg: "", sentMsg: nil)
        compose.composeState.message = "LINK_URL/no-image LINK_URL/page"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image"] }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        compose.composeState.message = "LINK_URL/no-image LINK_URL/page "
        try await waitFor { compose.composeState.linkPreview != nil }
        assertRecordedPreview(compose.composeState.linkPreview)
        compose.shown = false
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image", "/_link preview LINK_URL/page", note] }
        try await waitFor { compose.composeState.message.isEmpty }
        XCTAssertNil(shownAlert())
        try await show(compose)
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image", "/_link preview LINK_URL/page", note, "/_link preview LINK_URL/no-image"] }
    }

    @MainActor
    func testNewComposeFetchesFailedLinkAgain() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image"] }
        try await waitFor { compose.composeState.noPreview }
        let newCompose = try await showCompose()
        newCompose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image", "/_link preview LINK_URL/no-image"] }
    }

    @MainActor
    func testOpenedChatFetchesFailedLinkAgain() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image"] }
        try await waitFor { compose.composeState.noPreview }
        compose.chatModel.chatId = "@2"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image", "/_link preview LINK_URL/no-image"] }
    }

    @MainActor
    func testClearedComposeFetchesFailedLinkAgain() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image"] }
        try await waitFor { compose.composeState.noPreview }
        compose.composeState.message = ""
        try await waitFor { compose.composeState.parsedMessage.isEmpty }
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image", "/_link preview LINK_URL/no-image"] }
    }

    @MainActor
    func testComposeKeepsNewerPreviewWhenOlderLinkResponds() async throws {
        let older = hold("/_link preview LINK_URL/no-image")
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image"] }
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { compose.composeState.linkPreview != nil }
        older.signal()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        assertRecordedPreview(compose.composeState.linkPreview)
        XCTAssertEqual(requests(), ["/_link preview LINK_URL/no-image", "/_link preview LINK_URL/page"])
    }

    @MainActor
    func testComposeRequestsRestoredLinkAgainAndNotTheReplacedOne() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { compose.composeState.linkPreview != nil }
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "LINK_URL/no-image" }
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "LINK_URL/page" }
        try await waitFor { self.requests().count == 2 }
        try await waitFor { compose.composeState.linkPreview != nil }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        assertRecordedPreview(compose.composeState.linkPreview)
        XCTAssertEqual(requests(), ["/_link preview LINK_URL/page", "/_link preview LINK_URL/page"])
    }

    @MainActor
    func testComposeRequestsLinkChangedAndRestoredBeforeItsRequestOnce() async throws {
        _ = hold("/_link preview LINK_URL/page")
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "LINK_URL/page" }
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "LINK_URL/no-image" }
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "LINK_URL/page" }
        try await waitFor { self.requests() == ["/_link preview LINK_URL/page"] }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(requests(), ["/_link preview LINK_URL/page"])
    }

    @MainActor
    func testComposeKeepsCardOfEditedMessageWhenDiscardedLinkResponds() async throws {
        let response = hold("/_link preview LINK_URL/page")
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/page"] }
        let edited = LinkPreview(uri: "LINK_URL/no-image", title: "Edited message", image: "")
        compose.composeState = ComposeState(editingItem: ChatItem(
            chatDir: .directSnd,
            meta: CIMeta.getSample(1, .now, "LINK_URL/no-image"),
            content: .sndMsgContent(msgContent: .link(text: "LINK_URL/no-image", preview: edited))
        ))
        try await waitFor { compose.composeState.parsedMessage.first?.linkUri == "LINK_URL/no-image" }
        response.signal()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(compose.composeState.linkPreview, edited)
        XCTAssertEqual(requests(), ["/_link preview LINK_URL/page"])
    }

    @MainActor
    func testComposeKeepsSendInProgressWhenPreviewLoads() async throws {
        let response = hold("/_link preview LINK_URL/page")
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/page"] }
        compose.composeState.inProgress = true
        response.signal()
        try await waitFor { compose.composeState.linkPreview != nil }
        XCTAssertTrue(compose.composeState.inProgress)
    }

    @MainActor
    func testComposeKeepsAttachmentChosenBeforeLinkPreviewLoads() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { !compose.composeState.parsedMessage.isEmpty }
        attachFile(compose)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(compose.composeState.attachmentPreview)
        XCTAssertEqual(requests(), [])
    }

    @MainActor
    func testComposeKeepsAttachmentChosenWhileLinkPreviewLoads() async throws {
        let response = hold("/_link preview LINK_URL/page")
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/page"] }
        attachFile(compose)
        response.signal()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(compose.composeState.attachmentPreview)
    }

    @MainActor
    func testComposeKeepsAttachmentChosenBeforeViewUpdate() async throws {
        let response = hold("/_link preview LINK_URL/page")
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/page"] }
        response.signal()
        Thread.sleep(forTimeInterval: 0.5)
        attachFile(compose)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(compose.composeState.attachmentPreview)
    }

    @MainActor
    func testComposeKeepsFailedLinkAfterAttachmentRemoved() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/no-image"] }
        try await waitFor { compose.composeState.noPreview }
        try await typeWithAttachment(compose)
        compose.composeState.message = "LINK_URL/no-image"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "LINK_URL/no-image" }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(compose.composeState.noPreview)
        XCTAssertEqual(requests(), ["/_link preview LINK_URL/no-image"])
    }

    @MainActor
    func testComposeDropsPreviewOfLinkRemovedBeforeItLoads() async throws {
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { !compose.composeState.parsedMessage.isEmpty }
        compose.composeState.message = "text without a link"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "text without a link" }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertTrue(compose.composeState.noPreview)
        XCTAssertEqual(requests(), [])
    }

    @MainActor
    func testComposeDropsPreviewOfLinkRemovedWhileItLoads() async throws {
        let response = hold("/_link preview LINK_URL/page")
        let compose = try await showCompose()
        compose.composeState.message = "LINK_URL/page"
        try await waitFor { self.requests() == ["/_link preview LINK_URL/page"] }
        compose.composeState.message = "text without a link"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "text without a link" }
        response.signal()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(compose.composeState.noPreview)
    }

    private func withFile(_ s: ComposeState) -> ComposeState {
        s.copy(preview: .filePreview(fileName: "test.pdf", file: URL(fileURLWithPath: "test.pdf")))
    }

    @MainActor
    private func attachFile(_ compose: ComposeHostState) {
        compose.composeState = withFile(compose.composeState)
    }

    @MainActor
    private func typeWithAttachment(_ compose: ComposeHostState) async throws {
        attachFile(compose)
        try await Task.sleep(nanoseconds: 200_000_000)
        compose.composeState.message = "text without a link"
        try await waitFor { compose.composeState.parsedMessage.first?.text == "text without a link" }
        compose.composeState = compose.composeState.copy(preview: .noPreview)
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    private func hold(_ cmd: String) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        locked { held[cmd] = gate }
        return gate
    }

    private func recorded(_ cmd: String, _ commands: [String: Any]) -> (key: String, response: Any)? {
        if let response = commands[cmd] { return (cmd, response) }
        guard let sent = jsonCommand(cmd) else { return nil }
        for (key, response) in commands {
            if let command = jsonCommand(key), command.prefix == sent.prefix, command.json.isEqual(sent.json) {
                return (key, response)
            }
        }
        return nil
    }

    private func jsonCommand(_ cmd: String) -> (prefix: Substring, json: NSObject)? {
        guard let r = cmd.range(of: " json "),
              let json = try? JSONSerialization.jsonObject(with: Data(cmd[r.upperBound...].utf8)) as? NSObject
        else { return nil }
        return (cmd[..<r.lowerBound], json)
    }

    private func assertRecordedPreview(_ linkPreview: LinkPreview?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(linkPreview?.uri, "LINK_URL/page", file: file, line: line)
        XCTAssertEqual(linkPreview?.title, "Link preview title", file: file, line: line)
        XCTAssertEqual(linkPreview?.description, "Link preview description", file: file, line: line)
        XCTAssertNotNil(linkPreview.flatMap { imageFromBase64($0.image) }, "image not decoded", file: file, line: line)
    }

    private func requests() -> [String] {
        locked { requested }
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    @MainActor
    private func shownAlert() -> UIAlertController? {
        getTopViewController() as? UIAlertController
    }

    @MainActor
    private func showCompose(_ compose: ComposeHostState = ComposeHostState()) async throws -> ComposeHostState {
        self.window?.isHidden = true
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first))
        window.rootViewController = UIHostingController(rootView: ComposeHost(state: compose))
        window.isHidden = false
        self.window = window
        try await Task.sleep(nanoseconds: 100_000_000)
        return compose
    }

    @MainActor
    private func show(_ compose: ComposeHostState) async throws {
        compose.shown = true
        try await Task.sleep(nanoseconds: 100_000_000)
    }
}

private final class ComposeHostState: ObservableObject {
    let chat: Chat
    let chatModel = ChatModel()
    @Published var shown = true
    @Published var composeState = ComposeState()
    @Published var showCommandsMenu = false
    @Published var keyboardVisible = false
    @Published var keyboardHiddenDate = Date.now
    @Published var selectedRange = NSRange()

    init(chat: Chat = Chat(chatInfo: .direct(contact: Contact.sampleData))) {
        self.chat = chat
    }
}

private struct ComposeHost: View {
    @ObservedObject var state: ComposeHostState
    let theme = CurrentColors.toAppTheme()

    var body: some View {
        if state.shown {
            ComposeView(
                chat: state.chat,
                im: ItemsModel.shared,
                composeState: $state.composeState,
                showCommandsMenu: $state.showCommandsMenu,
                keyboardVisible: $state.keyboardVisible,
                keyboardHiddenDate: $state.keyboardHiddenDate,
                selectedRange: $state.selectedRange
            )
            .environmentObject(state.chatModel)
            .environmentObject(theme)
        }
    }
}
