import XCTest
import SwiftUI
import UIKit
@testable import SimpleX
@testable import SimpleXChat

final class SnapshotTests: XCTestCase {
    private var fixedQRCode: UIImage?

    override func setUp() async throws {
        fixedQRCode = await generateImage(previewQRLink, tintColor: UIColor(red: 0.023, green: 0.176, blue: 0.337, alpha: 1), errorLevel: "M")
    }

    @MainActor
    func testPreviews() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["SNAPSHOT_DIR"] ?? NSTemporaryDirectory() + "snapshots", isDirectory: true)
        let size = env["SNAPSHOT_SIZE"] ?? "large"
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        ChatModel.shared.currentUser = User.sampleData
        var index: [[String: Any]] = []
        for dark in [false, true] {
            let theme = snapshotTheme(dark)
            CurrentColors = theme
            for scene in previewScenes() where scene.allSizes || size == "large" {
                let themeName = dark ? "dark" : "light"
                let file = "\(scene.name)-\(themeName)-\(size).png"
                let image = try renderScene(scene, theme.toAppTheme(), dark: dark, fixedQRCode: fixedQRCode, in: windowScene)
                try XCTUnwrap(image.pngData()).write(to: dir.appendingPathComponent(file))
                index.append([
                    "scene": scene.name,
                    "theme": themeName,
                    "size": size,
                    "file": file,
                    "width": Int((image.size.width * image.scale).rounded()),
                    "height": Int((image.size.height * image.scale).rounded()),
                    "scale": image.scale,
                    "contentSizeCategory": UIApplication.shared.preferredContentSizeCategory.rawValue
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("index-\(size).json"))
    }

    @MainActor
    func testFirstLayout() throws {
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let env = ProcessInfo.processInfo.environment
        let size = env["SNAPSHOT_SIZE"] ?? "large"
        let dir = layoutCheckDir(env)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        ChatModel.shared.currentUser = User.sampleData
        let theme = snapshotTheme(false)
        CurrentColors = theme
        let appTheme = theme.toAppTheme()
        let fixtures = SnapshotFixtures()
        var index: [[String: Any]] = []
        for terminal in [true, false] {
            let chats = [("direct", fixtures.overviewDirect(terminal: terminal)), ("group", fixtures.overviewGroup(terminal: terminal)), ("channel", fixtures.overviewChannel(terminal: terminal))]
            for (name, rows) in chats {
                let scene = "\(name)-\(terminal ? "terminal" : "classic")-\(size)"
                let scrollView = EndlessScrollView<MergedItem>(frame: .zero)
                let host = UIHostingController(rootView: ScrollRepresentable(scrollView: scrollView) { (i: Int, item: MergedItem) in
                    rows.row(i, item)
                        .environmentObject(ChatModel.shared)
                        .environmentObject(appTheme)
                })
                let window = UIWindow(windowScene: windowScene)
                window.overrideUserInterfaceStyle = .light
                window.rootViewController = host
                window.frame = windowScene.screen.bounds
                window.isHidden = false
                settle()
                scrollView.updateItems(rows.mergedItems.items)
                settle()
                let first = scrollView.listState.visibleItems.map { $0.view.frame.height }
                try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("\(scene)-first.png"))
                scrollView.updateItems(rows.mergedItems.items, true)
                settle()
                let reloaded = scrollView.listState.visibleItems.map { $0.view.frame.height }
                try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("\(scene)-reloaded.png"))
                window.isHidden = true
                window.rootViewController = nil
                index.append(["scene": scene, "first": first, "reloaded": reloaded])
                print("first layout \(scene): first \(first), reloaded \(reloaded)")
                XCTAssertEqual(first.count, reloaded.count, scene)
                for (a, b) in zip(first, reloaded) {
                    XCTAssertEqual(a, b, accuracy: 0.5, scene)
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("first-layout-\(size).json"))
    }

    @MainActor
    func testLayoutSwitch() throws {
        let env = ProcessInfo.processInfo.environment
        guard (env["SNAPSHOT_SIZE"] ?? "large") == "large" else { return }
        let dir = layoutCheckDir(env)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        ChatModel.shared.currentUser = User.sampleData
        let theme = snapshotTheme(false)
        CurrentColors = theme
        let appTheme = theme.toAppTheme()
        let sceneDelegate = SceneDelegate()
        let appearance = {
            UIHostingController(rootView: AppearanceSettings()
                .environmentObject(ChatModel.shared)
                .environmentObject(sceneDelegate)
                .environmentObject(appTheme))
        }
        chatLayoutDefault.set(.classic)
        let window = UIWindow(windowScene: windowScene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = appearance()
        window.frame = windowScene.screen.bounds
        window.isHidden = false
        settle()
        try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("appearance-1-classic.png"))
        chatLayoutDefault.set(.terminal)
        settle()
        try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("appearance-2-terminal-switched.png"))
        window.rootViewController = appearance()
        settle()
        try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("appearance-3-terminal-reopened.png"))
        chatLayoutDefault.set(.classic)
        settle()
        try XCTUnwrap(windowImage(window).pngData()).write(to: dir.appendingPathComponent("appearance-4-classic-switched.png"))
        window.isHidden = true
        window.rootViewController = nil
    }
}

private func layoutCheckDir(_ env: [String: String]) -> URL {
    URL(fileURLWithPath: env["SNAPSHOT_DIR"] ?? NSTemporaryDirectory() + "snapshots", isDirectory: true)
        .deletingLastPathComponent()
        .appendingPathComponent("layout-checks", isDirectory: true)
}

private func windowImage(_ window: UIWindow) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.preferredRange = .standard
    format.opaque = true
    return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
}

private struct SnapshotScene {
    var name: String
    var height: CGFloat? = nil
    var allSizes: Bool
    var view: AnyView

    init<P: PreviewProvider>(_ preview: P.Type, allSizes: Bool = false) {
        name = String(describing: preview).replacingOccurrences(of: "_Previews", with: "")
        self.allSizes = allSizes
        view = AnyView(preview.previews)
    }
}

private func previewScenes() -> [SnapshotScene] {
    [
        SnapshotScene(ActiveCallOverlay_Previews.self),
        SnapshotScene(AddChannelView_Previews.self),
        SnapshotScene(AddContactLearnMore_Previews.self),
        SnapshotScene(AddGroupMembersView_Previews.self),
        SnapshotScene(AddGroupView_Previews.self),
        SnapshotScene(AdvancedNetworkSettings_Previews.self),
        SnapshotScene(BadgesCheckOrderView_Previews.self),
        SnapshotScene(BadgesHowItWorksView_Previews.self),
        SnapshotScene(BadgesHowLongView_Previews.self),
        SnapshotScene(BadgesRedeemCodeView_Previews.self),
        SnapshotScene(BadgesSupportSimplexView_Previews.self),
        SnapshotScene(CallSettings_Previews.self),
        SnapshotScene(ChannelMembersView_Previews.self),
        SnapshotScene(ChannelRelaysView_Previews.self),
        SnapshotScene(ChatHelp_Previews.self),
        SnapshotScene(ChatInfoImage_Previews.self),
        SnapshotScene(ChatInfoToolbar_Previews.self),
        SnapshotScene(ChatInfoView_Previews.self),
        SnapshotScene(ChatItemForwardingView_Previews.self),
        SnapshotScene(ChatItemInfoView_Previews.self),
        SnapshotScene(ChatItemView_NonMsgContentDeleted_Previews.self, allSizes: true),
        SnapshotScene(ChatItemView_Previews.self, allSizes: true),
        SnapshotScene(ChatListConnecting_Previews.self, allSizes: true),
        SnapshotScene(ChatListContacts_Previews.self, allSizes: true),
        SnapshotScene(ChatListDeleted_Previews.self, allSizes: true),
        SnapshotScene(ChatListFlags_Previews.self, allSizes: true),
        SnapshotScene(ChatListGroupStates_Previews.self, allSizes: true),
        SnapshotScene(ChatListGroups_Previews.self, allSizes: true),
        SnapshotScene(ChatListLong_Previews.self, allSizes: true),
        SnapshotScene(ChatListMarks_Previews.self, allSizes: true),
        SnapshotScene(ChatListMedia_Previews.self, allSizes: true),
        SnapshotScene(ChatListNavLink_Previews.self),
        SnapshotScene(ChatListPending_Previews.self, allSizes: true),
        SnapshotScene(ChatListText_Previews.self, allSizes: true),
        SnapshotScene(ChatListUnread_Previews.self, allSizes: true),
        SnapshotScene(ChatListView_Previews.self),
        SnapshotScene(ChatPreviewView_Previews.self),
        SnapshotScene(ChatView_Previews.self),
        SnapshotScene(CIChatFeatureView_Previews.self, allSizes: true),
        SnapshotScene(CIEventView_Previews.self, allSizes: true),
        SnapshotScene(CIFeaturePreferenceView_Previews.self, allSizes: true),
        SnapshotScene(CIFileView_Previews.self, allSizes: true),
        SnapshotScene(CIGroupInvitationView_Previews.self, allSizes: true),
        SnapshotScene(CIInvalidJSONView_Previews.self, allSizes: true),
        SnapshotScene(CIMemberCreatedContactView_Previews.self, allSizes: true),
        SnapshotScene(CIMetaView_Previews.self, allSizes: true),
        SnapshotScene(CIVoiceView_Previews.self, allSizes: true),
        SnapshotScene(ClassicAvatars_Previews.self, allSizes: true),
        SnapshotScene(ClassicOverviewChannel_Previews.self),
        SnapshotScene(ClassicOverviewDirect_Previews.self),
        SnapshotScene(ClassicOverviewGroup_Previews.self),
        SnapshotScene(ComposeVoiceView_Previews.self),
        SnapshotScene(ConnectDesktopView_Previews.self),
        SnapshotScene(ContactConnectionInfo_Previews.self),
        SnapshotScene(ContactConnectionView_Previews.self),
        SnapshotScene(ContactPreferencesView_Previews.self),
        SnapshotScene(ContactRequestView_Previews.self),
        SnapshotScene(ContextContactRequestActionsView_Previews.self),
        SnapshotScene(ContextItemView_Previews.self),
        SnapshotScene(ContextMemberContactActionsView_Previews.self),
        SnapshotScene(ContextPendingMemberActionsView_Previews.self),
        SnapshotScene(ContextProfilePickerView_Previews.self),
        SnapshotScene(CreateProfile_Previews.self),
        SnapshotScene(CreateSimpleXAddress_Previews.self),
        SnapshotScene(CustomTimePicker_Previews.self),
        SnapshotScene(DatabaseEncryptionView_Previews.self),
        SnapshotScene(DatabaseErrorView_Previews.self),
        SnapshotScene(DatabaseView_Previews.self),
        SnapshotScene(DeletedItemView_Previews.self, allSizes: true),
        SnapshotScene(DetermineWidth_Previews.self),
        SnapshotScene(DeveloperView_Previews.self),
        SnapshotScene(EmojiItemView_Previews.self, allSizes: true),
        SnapshotScene(FramedCIVoiceView_Previews.self, allSizes: true),
        SnapshotScene(FramedItemView_Deleted_Previews.self, allSizes: true),
        SnapshotScene(FramedItemView_Edited_Previews.self, allSizes: true),
        SnapshotScene(FramedItemView_Previews.self, allSizes: true),
        SnapshotScene(GetStakeBanner_Previews.self),
        SnapshotScene(GroupChatInfoView_Previews.self),
        SnapshotScene(GroupLinkView_Previews.self),
        SnapshotScene(GroupMemberInfoView_Previews.self),
        SnapshotScene(GroupPreferencesView_Previews.self),
        SnapshotScene(GroupProfileView_Previews.self),
        SnapshotScene(GroupWelcomeView_Previews.self),
        SnapshotScene(IncognitoHelp_Previews.self),
        SnapshotScene(IncomingCallView_Previews.self),
        SnapshotScene(IntegrityErrorItemView_Previews.self, allSizes: true),
        SnapshotScene(LargeLinkPreview_Previews.self, allSizes: true),
        SnapshotScene(LocalAuthView_Previews.self),
        SnapshotScene(MarkdownHelp_Previews.self),
        SnapshotScene(MarkedDeletedItemView_Previews.self, allSizes: true),
        SnapshotScene(MemberAdmissionView_Previews.self),
        SnapshotScene(MemberSupportChatToolbar_Previews.self),
        SnapshotScene(MemberSupportView_Previews.self),
        SnapshotScene(MigrateToDevice_Previews.self),
        SnapshotScene(MigrateToGroupView_Previews.self),
        SnapshotScene(MsgContentView_Previews.self, allSizes: true),
        SnapshotScene(NativeTextEditor_Previews.self),
        SnapshotScene(NetworkServersView_Previews.self),
        SnapshotScene(NewChatMenuButton_Previews.self),
        SnapshotScene(NewFeaturesView_Previews.self),
        SnapshotScene(NewServerView_Previews.self),
        SnapshotScene(NotificationsModeView_Previews.self),
        SnapshotScene(NotificationsView_Previews.self),
        SnapshotScene(OnboardingConditionsView_Previews.self),
        SnapshotScene(OnboardingStepsView_Previews.self),
        SnapshotScene(OneHandUICard_Previews.self),
        SnapshotScene(OperatorView_Previews.self),
        SnapshotScene(PasscodeEntry_Previews.self),
        SnapshotScene(PasscodeViewView_Previews.self),
        SnapshotScene(PreferencesView_Previews.self),
        SnapshotScene(PrivacySettings_Previews.self),
        SnapshotScene(ProfileImage_Previews.self),
        SnapshotScene(ProfilePrivacyView_Previews.self),
        SnapshotScene(ProtocolServerView_Previews.self),
        SnapshotScene(QRCode_Previews.self),
        SnapshotScene(RTCServers_Previews.self),
        SnapshotScene(ScanCodeView_Previews.self),
        SnapshotScene(ScanProtocolServer_Previews.self),
        SnapshotScene(SecondaryChatView_Previews.self),
        SnapshotScene(SendMessageView_Previews.self),
        SnapshotScene(SetAppPasscodeView_Previews.self),
        SnapshotScene(SetDeliveryReceiptsView_Previews.self),
        SnapshotScene(SettingsView_Previews.self),
        SnapshotScene(SimpleXInfo_Previews.self),
        SnapshotScene(SmallLinkPreview_Previews.self),
        SnapshotScene(SupportSimpleXBanner_Previews.self),
        SnapshotScene(TerminalAvatars_Previews.self, allSizes: true),
        SnapshotScene(TerminalMedia_Previews.self),
        SnapshotScene(TerminalNames_Previews.self, allSizes: true),
        SnapshotScene(TerminalOverviewChannel_Previews.self),
        SnapshotScene(TerminalOverviewDirect_Previews.self),
        SnapshotScene(TerminalOverviewGroup_Previews.self),
        SnapshotScene(TerminalQuoteThumbnail_Previews.self, allSizes: true),
        SnapshotScene(TerminalRuleOnly_Previews.self, allSizes: true),
        SnapshotScene(UserAddressLearnMore_Previews.self),
        SnapshotScene(UserAddressView_Previews.self),
        SnapshotScene(UserPicker_Previews.self),
        SnapshotScene(VerifyCodeView_Previews.self),
        SnapshotScene(VersionView_Previews.self),
        SnapshotScene(WhySimpleX_Previews.self),
        SnapshotScene(YourServersView_Previews.self)
    ]
}

private func snapshotTheme(_ dark: Bool) -> ThemeManager.ActiveTheme {
    let base: DefaultTheme = dark ? .DARK : .LIGHT
    return ThemeManager.ActiveTheme(
        name: base.themeName,
        base: base,
        colors: (dark ? DarkColorPalette : LightColorPalette).clone(),
        appColors: (dark ? DarkColorPaletteApp : LightColorPaletteApp).clone(),
        wallpaper: AppWallpaper(background: nil, tint: nil, type: .empty)
    )
}

private let previewQRLink = "https://smp6.simplex.im/a#lrdvu2d8A1GumSmoKb2krQmtKhWXq-tyGpHuM7aMwsw"

@MainActor
private func renderScene(_ scene: SnapshotScene, _ theme: AppTheme, dark: Bool, fixedQRCode: UIImage?, in windowScene: UIWindowScene) throws -> UIImage {
    let screen = windowScene.screen
    let width = screen.bounds.width
    let root = VStack(spacing: 0) { scene.view }
        .environmentObject(ChatModel.shared)
        .environmentObject(theme)
        .environment(\.fixedQRCode, fixedQRCode)
        .frame(width: width, height: scene.height)
    let host = UIHostingController(rootView: AnyView(root))
    if #available(iOS 16.4, *) {
        host.safeAreaRegions = []
    }
    let window = UIWindow(windowScene: windowScene)
    window.overrideUserInterfaceStyle = dark ? .dark : .light
    window.rootViewController = host
    window.frame = CGRect(x: 0, y: 0, width: width, height: scene.height ?? screen.bounds.height)
    window.isHidden = false
    settle()
    if scene.height == nil {
        for _ in 0..<2 {
            let fit = host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            let fill = host.sizeThatFits(in: screen.bounds.size)
            window.frame = CGRect(x: 0, y: 0, width: width, height: ceil(max(fit.height, fill.height)))
            settle()
        }
    }
    window.endEditing(true)
    removeAnimations(window.layer)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.preferredRange = .standard
    format.opaque = true
    let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    window.isHidden = true
    window.rootViewController = nil
    return image
}

private func removeAnimations(_ layer: CALayer) {
    layer.removeAllAnimations()
    layer.sublayers?.forEach(removeAnimations)
}

private func settle() {
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
}

struct TerminalNames_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().names()
    }
}

struct TerminalQuoteThumbnail_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().quoteThumbnail()
    }
}

struct TerminalMedia_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().media()
    }
}

struct TerminalRuleOnly_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().ruleOnly()
    }
}

struct TerminalAvatars_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().avatars(terminal: true)
    }
}

struct ClassicAvatars_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().avatars(terminal: false)
    }
}

struct TerminalOverviewDirect_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewDirect(terminal: true)
    }
}

struct ClassicOverviewDirect_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewDirect(terminal: false)
    }
}

struct TerminalOverviewGroup_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewGroup(terminal: true)
    }
}

struct ClassicOverviewGroup_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewGroup(terminal: false)
    }
}

struct TerminalOverviewChannel_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewChannel(terminal: true)
    }
}

struct ClassicOverviewChannel_Previews: PreviewProvider {
    static var previews: some View {
        SnapshotFixtures().overviewChannel(terminal: false)
    }
}

struct ChatListContacts_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().contacts()
    }
}

struct ChatListConnecting_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().connecting()
    }
}

struct ChatListPending_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().pending()
    }
}

struct ChatListGroups_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().groups()
    }
}

struct ChatListGroupStates_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().groupStates()
    }
}

struct ChatListFlags_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().flags()
    }
}

struct ChatListUnread_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().unread()
    }
}

struct ChatListMarks_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().marks()
    }
}

struct ChatListMedia_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().media()
    }
}

struct ChatListText_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().text()
    }
}

struct ChatListDeleted_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().deleted()
    }
}

struct ChatListLong_Previews: PreviewProvider {
    static var previews: some View {
        ChatListFixtures().long()
    }
}

private struct ChatRows: View {
    @EnvironmentObject var theme: AppTheme
    let chat: Chat
    let im: ItemsModel
    let mergedItems: MergedItems
    let terminal: Bool
    var selected: Set<Int64>? = nil

    private var width: CGFloat {
        UIScreen.main.bounds.width
    }

    var body: some View {
        let wallpaperImage = theme.wallpaper.type.image
        let wallpaperType = theme.wallpaper.type
        let backgroundColor = theme.wallpaper.background ?? wallpaperType.defaultBackgroundColor(theme.base, theme.colors.background)
        let tintColor = theme.wallpaper.tint ?? wallpaperType.defaultTintColor(theme.base)
        let items = mergedItems.items
        VStack(spacing: 0) {
            ForEach(Array(items.indices.reversed()), id: \.self) { index in
                row(index, items[index]).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .frame(width: width)
        .background {
            if terminal {
                backgroundColor
            } else if let wallpaperImage {
                Color.clear.modifier(ChatViewBackground(image: wallpaperImage, imageType: wallpaperType, background: backgroundColor, tint: tintColor))
            } else {
                theme.colors.background
            }
        }
    }

    func row(_ index: Int, _ mergedItem: MergedItem) -> some View {
        let ci = switch mergedItem {
        case let .single(item, _, _): item.item
        case let .grouped(items, _, _, _, _, _, _, _): items.boxedValue.last!.item
        }
        return ChatView.ChatItemWithMenu(
            im: im,
            chat: .constant(ObservedObject(wrappedValue: chat)),
            index: index,
            isLastItem: index == mergedItems.items.count - 1,
            chatItem: ci,
            scrollToItem: { _ in },
            scrollToItemId: .constant(nil),
            merged: mergedItem,
            olderRow: mergedItems.items.indices.contains(index + 1) ? mergedItems.items[index + 1] : nil,
            listWidth: width,
            maxWidth: rowMaxWidth(ci, mergedItem, chat.chatInfo, width),
            composeState: .constant(ComposeState()),
            selectedMember: .constant(nil),
            showChatInfoSheet: .constant(false),
            revealedItems: .constant([]),
            selectedChatItems: .constant(selected),
            forwardedChatItems: .constant([]),
            searchText: .constant(""),
            contentFilter: .constant(nil),
            closeKeyboardAndRun: { $0() }
        )
        .environment(\.terminalLayout, terminal)
    }
}

private func rowMaxWidth(_ ci: ChatItem, _ merged: MergedItem, _ cInfo: ChatInfo, _ width: CGFloat) -> CGFloat {
    let voiceNoFrame = ci.content.msgContent?.isVoice == true && ci.content.text.count == 0 && ci.quotedItem == nil && ci.meta.itemForwarded == nil
    let channelReceived = !ci.chatDir.sent && cInfo.isChannel
    let channelReceivedNoAvatar = channelReceived && !showsAvatar(merged.newest().item, merged.oldest().nextItem)
    let avatarColumn = scaledMemberImageSize(DynamicTypeSize(UIApplication.shared.preferredContentSizeCategory) ?? .large) + 8
    return cInfo.chatType == .group
    ? channelReceivedNoAvatar
    ? width - 26
    : voiceNoFrame || channelReceived
    ? (width - 28) - avatarColumn
    : (width - 28) * 0.84 - avatarColumn
    : voiceNoFrame
    ? (width - 32)
    : (width - 32) * 0.84
}

private func showsAvatar(_ current: ChatItem, _ older: ChatItem?) -> Bool {
    let oldIsGroupRcv = switch older?.chatDir {
    case .groupRcv: true
    case .channelRcv: true
    default: false
    }
    let sameMember = switch (older?.chatDir, current.chatDir) {
    case let (.groupRcv(oldMember), .groupRcv(member)): oldMember.memberId == member.memberId
    case (.channelRcv, .channelRcv): true
    default: false
    }
    return switch current.chatDir {
    case .groupRcv, .channelRcv: older == nil || !oldIsGroupRcv || !sameMember
    default: false
    }
}

private func imageBase64(_ color: UIColor, _ size: CGSize) -> String {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        color.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
        UIColor.white.withAlphaComponent(0.4).setFill()
        ctx.cgContext.fillEllipse(in: CGRect(x: size.width * 0.55, y: size.height * 0.15, width: size.height * 0.4, height: size.height * 0.4))
    }
    return "data:image/jpg;base64," + (image.jpegData(compressionQuality: 0.8)?.base64EncodedString() ?? "")
}

private final class SnapshotFixtures {
    private var nextId: Int64 = 1
    let photo = imageBase64(UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1), CGSize(width: 120, height: 80))
    let landscape = imageBase64(UIColor(red: 0.25, green: 0.55, blue: 0.35, alpha: 1), CGSize(width: 320, height: 200))
    let alice: GroupMember
    let bob: GroupMember
    let carol: GroupMember
    let team: GroupInfo
    let news: GroupInfo
    let contact: Contact
    private let markdown: [String: ParsedMarkdown] = [
        "https://simplex.chat": ParsedMarkdown(formattedText: [
            FormattedText(text: "https://simplex.chat", format: .uri)
        ]),
        "---": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "---", format: .markup(token: .ruleMark))
            ],
            markdownBlocks: [
                .rule(mark: SegmentRange(from: 0, to: 1))
            ]
        ),
        "Hi! Did you see the **new release**?": ParsedMarkdown(formattedText: [
            FormattedText(text: "Hi! Did you see the "),
            FormattedText(text: "new release", format: .bold(singleStar: false)),
            FormattedText(text: "?")
        ]),
        "Yes, *great* changes 🎉": ParsedMarkdown(formattedText: [
            FormattedText(text: "Yes, "),
            FormattedText(text: "great", format: .bold(singleStar: true)),
            FormattedText(text: " changes 🎉")
        ]),
        "# Release notes\n- terminal layout\n- `code` blocks\n\n> quoted line": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "# ", format: .markup(token: .headingMark(level: 1))),
                FormattedText(text: "Release notes"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "terminal layout"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "code", format: .snippet),
                FormattedText(text: " blocks"),
                FormattedText(text: "\n\n", format: .markup(token: .paragraphBreak(lineBreaks: 2))),
                FormattedText(text: "> ", format: .markup(token: .quoteMark)),
                FormattedText(text: "quoted line")
            ],
            markdownBlocks: [
                .heading(level: 1, content: SegmentRange(from: 1, to: 2)),
                .list(items: [
                    ListEntry(number: nil, content: SegmentRange(from: 4, to: 5), items: []),
                    ListEntry(number: nil, content: SegmentRange(from: 7, to: 9), items: [])
                ]),
                .quote(content: SegmentRange(from: 11, to: 12))
            ]
        ),
        "Plan for today:\n1. review\n2. **release**": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "Plan for today:"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "1. ", format: .markup(token: .listMark(number: "1."))),
                FormattedText(text: "review"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "2. ", format: .markup(token: .listMark(number: "2."))),
                FormattedText(text: "release", format: .bold(singleStar: false))
            ],
            markdownBlocks: [
                .paragraph(content: SegmentRange(from: 0, to: 1)),
                .list(items: [
                    ListEntry(number: "1.", content: SegmentRange(from: 3, to: 4), items: []),
                    ListEntry(number: "2.", content: SegmentRange(from: 6, to: 7), items: [])
                ])
            ]
        ),
        "**Version 7.1** is out": ParsedMarkdown(formattedText: [
            FormattedText(text: "Version 7.1", format: .bold(singleStar: false)),
            FormattedText(text: " is out")
        ]),
        "## What's new\n- terminal layout\n- faster sync": ParsedMarkdown(
            formattedText: [
                FormattedText(text: "## ", format: .markup(token: .headingMark(level: 2))),
                FormattedText(text: "What's new"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "terminal layout"),
                FormattedText(text: "\n", format: .markup(token: .lineBreak)),
                FormattedText(text: "- ", format: .markup(token: .listMark(number: nil))),
                FormattedText(text: "faster sync")
            ],
            markdownBlocks: [
                .heading(level: 2, content: SegmentRange(from: 1, to: 2)),
                .list(items: [
                    ListEntry(number: nil, content: SegmentRange(from: 4, to: 5), items: []),
                    ListEntry(number: nil, content: SegmentRange(from: 7, to: 8), items: [])
                ])
            ]
        )
    ]

    init() {
        alice = Self.member(2, "alice", .admin, image: imageBase64(UIColor(red: 0.85, green: 0.45, blue: 0.3, alpha: 1), CGSize(width: 64, height: 64)))
        bob = Self.member(3, "bob", .member)
        carol = Self.member(4, "carol", .member, image: imageBase64(UIColor(red: 0.55, green: 0.35, blue: 0.75, alpha: 1), CGSize(width: 64, height: 64)))
        team = Self.group(1, "team", channel: false)
        news = Self.group(2, "SimpleX news", channel: true)
        var c = Contact.sampleData
        c.profile = LocalProfile(profileId: 2, displayName: "bob", fullName: "", localAlias: "")
        c.localDisplayName = "bob"
        contact = c
    }

    private static func member(_ id: Int64, _ name: String, _ role: GroupMemberRole, image: String? = nil) -> GroupMember {
        var m = GroupMember.sampleData
        m.groupMemberId = id
        m.memberId = "member-\(id)"
        m.memberRole = role
        m.localDisplayName = name
        m.memberProfile = LocalProfile(profileId: id, displayName: name, fullName: "", image: image, localAlias: "")
        return m
    }

    private static func group(_ id: Int64, _ name: String, channel: Bool) -> GroupInfo {
        var g = GroupInfo.sampleData
        g.groupId = id
        g.localDisplayName = name
        g.groupProfile = GroupProfile(displayName: name, fullName: "")
        if channel {
            g.useRelays = true
            g.groupProfile.publicGroup = PublicGroupProfile(groupType: .channel, groupLink: "", publicGroupId: "channel-\(id)")
        }
        g.membership = member(99, "me", .member)
        return g
    }

    private func id() -> Int64 {
        nextId += 1
        return nextId
    }

    private func ts(_ minutes: Double) -> Date {
        previewDate.addingTimeInterval(minutes * 60)
    }

    private func msg(_ dir: CIDirection, _ text: String, _ minutes: Double, quote: CIQuote? = nil, reactions: [CIReactionCount] = [], content: MsgContent? = nil, file: CIFile? = nil) -> ChatItem {
        let parsed = markdown[text]
        let mc = content ?? .text(text)
        return ChatItem(
            chatDir: dir,
            meta: CIMeta.getSample(id(), ts(minutes), text, dir.sent ? .sndSent(sndProgress: .complete) : .rcvRead),
            content: dir.sent ? .sndMsgContent(msgContent: mc) : .rcvMsgContent(msgContent: mc),
            formattedText: parsed?.formattedText,
            markdownBlocks: parsed?.markdownBlocks,
            quotedItem: quote,
            reactions: reactions,
            file: file
        )
    }

    private func event(_ dir: CIDirection, _ content: CIContent, _ minutes: Double) -> ChatItem {
        ChatItem(chatDir: dir, meta: CIMeta.getSample(id(), ts(minutes), content.text, .rcvRead), content: content)
    }

    private func quote(_ dir: CIDirection?, _ text: String, image: String? = nil) -> CIQuote {
        let parsed = markdown[text]
        return CIQuote(
            chatDir: dir,
            itemId: 1,
            sentAt: ts(-300),
            content: image.map { .image(text: text, image: $0) } ?? .text(text),
            formattedText: parsed?.formattedText,
            markdownBlocks: parsed?.markdownBlocks
        )
    }

    private func reaction(_ emoji: MREmojiChar, _ count: Int, mine: Bool = false) -> CIReactionCount {
        CIReactionCount(reaction: .emoji(emoji: emoji), userReacted: mine, totalReacted: count)
    }

    private func imageFile(_ name: String) -> CIFile {
        CIFile.getSample(fileId: id(), fileName: name, fileSize: 184_320, filePath: nil, fileStatus: .rcvInvitation)
    }

    private func chatRows(_ chatInfo: ChatInfo, _ items: [ChatItem], terminal: Bool, selected: Set<Int64>? = nil) -> ChatRows {
        let im = ItemsModel(secondaryIMFilter: nil)
        im.reversedChatItems = items.reversed()
        let merged = MergedItems.create(im, [])
        return ChatRows(chat: Chat(chatInfo: chatInfo), im: im, mergedItems: merged, terminal: terminal, selected: selected)
    }

    private var direct: ChatInfo { .direct(contact: contact) }
    private var teamChat: ChatInfo { .group(groupInfo: team, groupChatScope: nil) }
    private var newsChat: ChatInfo { .group(groupInfo: news, groupChatScope: nil) }

    func names() -> some View {
        chatRows(teamChat, [
            msg(.groupRcv(groupMember: alice), "Hi everyone, the build is green.", -30),
            msg(.groupRcv(groupMember: alice), "Release notes are in the channel.", -29),
            msg(.groupRcv(groupMember: bob), "Great, thanks!", -20, quote: quote(.groupRcv(groupMember: alice), "Hi everyone, the build is green.")),
            msg(.groupSnd, "I will check the release notes today.", -10)
        ], terminal: true)
    }

    func quoteThumbnail() -> some View {
        chatRows(direct, [
            msg(.directRcv, "nice", -10, quote: quote(.directSnd, "photo", image: photo)),
            msg(.directRcv, "a longer reply that wraps over two lines in the terminal row below the quote with the image", -9, quote: quote(.directSnd, "a long caption of the quoted image that wraps over more than one line of the quote", image: photo)),
            msg(.directRcv, "ok", -8, quote: quote(.directRcv, "", image: photo)),
            msg(.directRcv, "a reply wider than the quote above it, so that the quote is narrower than the item", -7, quote: quote(.directSnd, "photo", image: photo)),
            msg(.directRcv, "a reply a bit wider than its quote", -6, quote: quote(.directSnd, "photo", image: photo))
        ], terminal: true)
    }

    func media() -> some View {
        let link = MsgContent.link(text: "https://simplex.chat", preview: LinkPreview(uri: "https://simplex.chat", title: "SimpleX Chat: private and secure messenger without any user IDs", image: landscape))
        return VStack(spacing: 0) {
            chatRows(direct, [
                msg(.directRcv, "https://simplex.chat", -20, content: link)
            ], terminal: true)
            chatRows(newsChat, [
                msg(.channelRcv, "Links and videos", -12),
                msg(.channelRcv, "https://simplex.chat", -11, content: link),
                msg(.channelRcv, "", -10, content: .video(text: "", image: landscape, duration: 42), file: CIFile.getSample(fileId: id(), fileName: "video.mp4", fileSize: 1_048_576, filePath: nil, fileStatus: .rcvInvitation))
            ], terminal: true)
            chatRows(newsChat, [
                msg(.channelRcv, "Selected post", -5, content: .image(text: "Selected post", image: landscape), file: imageFile("post.jpg"))
            ], terminal: true, selected: [])
        }
    }

    func ruleOnly() -> some View {
        chatRows(direct, [
            msg(.directRcv, "---", -10),
            msg(.directRcv, "---", -9, quote: quote(.directSnd, "a quoted message that is much wider than the rule"))
        ], terminal: true)
    }

    func avatars(terminal: Bool) -> some View {
        chatRows(teamChat, [
            msg(.groupRcv(groupMember: alice), "Morning! Who is joining the call?", -40),
            msg(.groupRcv(groupMember: bob), "I am", -38),
            msg(.groupRcv(groupMember: bob), "Starting in 5 minutes", -37),
            msg(.groupRcv(groupMember: carol), "Count me in, a bit late", -35),
            msg(.groupSnd, "Great", -30)
        ], terminal: terminal)
    }

    func overviewDirect(terminal: Bool) -> ChatRows {
        chatRows(direct, [
            event(.directRcv, .rcvChatFeature(feature: .voice, enabled: FeatureEnabled(forUser: true, forContact: true), param: nil), -120),
            msg(.directRcv, "Hi! Did you see the **new release**?", -60),
            msg(.directSnd, "Yes, *great* changes 🎉", -58, reactions: [reaction(.thumbsup, 1)]),
            msg(.directRcv, "# Release notes\n- terminal layout\n- `code` blocks\n\n> quoted line", -50),
            msg(.directSnd, "Thanks for the summary", -45, quote: quote(.directRcv, "Release notes")),
            msg(.directRcv, "", -40, content: .image(text: "", image: landscape), file: imageFile("photo.jpg")),
            msg(.directRcv, "", -35, content: .file(""), file: CIFile.getSample(fileId: id(), fileName: "report.pdf", fileSize: 245_760, filePath: nil, fileStatus: .rcvInvitation)),
            msg(.directSnd, "", -30, content: .voice(text: "", duration: 12), file: CIFile.getSample(fileId: id(), fileName: "voice.m4a", fileSize: 20_480, filePath: nil, fileStatus: .sndComplete))
        ], terminal: terminal)
    }

    func overviewGroup(terminal: Bool) -> ChatRows {
        chatRows(teamChat, [
            event(.groupRcv(groupMember: carol), .rcvGroupEvent(rcvGroupEvent: .memberConnected), -130),
            msg(.groupRcv(groupMember: alice), "Welcome, carol!", -120, reactions: [reaction(.heart, 2, mine: true)]),
            msg(.groupRcv(groupMember: carol), "Thanks! Glad to be here", -118),
            msg(.groupRcv(groupMember: bob), "", -100, content: .image(text: "", image: landscape), file: imageFile("view.jpg")),
            msg(.groupSnd, "nice view", -95, quote: quote(.groupRcv(groupMember: bob), "", image: landscape)),
            msg(.groupRcv(groupMember: alice), "Plan for today:\n1. review\n2. **release**", -90),
            msg(.groupRcv(groupMember: bob), "", -80, content: .voice(text: "", duration: 21), file: CIFile.getSample(fileId: id(), fileName: "voice.m4a", fileSize: 30_720, filePath: nil, fileStatus: .rcvInvitation)),
            msg(.groupRcv(groupMember: carol), "", -70, content: .file(""), file: CIFile.getSample(fileId: id(), fileName: "notes.txt", fileSize: 2_048, filePath: nil, fileStatus: .rcvInvitation))
        ], terminal: terminal)
    }

    func overviewChannel(terminal: Bool) -> ChatRows {
        chatRows(newsChat, [
            event(.channelRcv, .rcvGroupEvent(rcvGroupEvent: .groupUpdated(groupProfile: news.groupProfile)), -210),
            msg(.channelRcv, "**Version 7.1** is out", -200, reactions: [reaction(.thumbsup, 12), reaction(.heart, 5, mine: true)]),
            msg(.channelRcv, "## What's new\n- terminal layout\n- faster sync", -190),
            msg(.channelRcv, "Screenshot of the new layout", -180, content: .image(text: "Screenshot of the new layout", image: landscape), file: imageFile("screenshot.jpg"))
        ], terminal: terminal)
    }
}

private struct ChatListRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var userFont: DynamicTypeSize
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().frame(height: dynamicSize(userFont).rowHeight)
    }
}

private final class ChatListFixtures {
    private static let photo = imageBase64(UIColor(red: 0.85, green: 0.45, blue: 0.3, alpha: 1), CGSize(width: 64, height: 64))
    private static let photo2 = imageBase64(UIColor(red: 0.55, green: 0.35, blue: 0.75, alpha: 1), CGSize(width: 64, height: 64))
    private static let landscape = imageBase64(UIColor(red: 0.25, green: 0.55, blue: 0.35, alpha: 1), CGSize(width: 320, height: 200))
    private static let link = CreatedConnLink(connFullLink: "https://simplex.chat/contact#/?v=2-7&smp=smp%3A%2F%2Fexample.simplex.im", connShortLink: nil)
    private static let hiddenPreviews: UserDefaults = {
        let defaults = UserDefaults(suiteName: "chat-list-hidden-previews")!
        defaults.set(false, forKey: DEFAULT_PRIVACY_SHOW_CHAT_PREVIEWS)
        return defaults
    }()
    private let alice = ChatListFixtures.member(2, "alice", image: ChatListFixtures.photo)
    private let bob = ChatListFixtures.member(3, "bob")
    private let carol = ChatListFixtures.member(4, "carol", image: ChatListFixtures.photo2)
    private var nextId: Int64 = 100

    private static func member(_ id: Int64, _ name: String, image: String? = nil) -> GroupMember {
        var m = GroupMember.sampleData
        m.groupMemberId = id
        m.memberId = "member-\(id)"
        m.memberRole = .member
        m.localDisplayName = name
        m.memberProfile = LocalProfile(profileId: id, displayName: name, fullName: "", image: image, localAlias: "")
        return m
    }

    private func newId() -> Int64 {
        nextId += 1
        return nextId
    }

    private func badge(_ type: BadgeType, _ status: BadgeStatus) -> LocalBadge {
        LocalBadge(badge: BadgeInfo(badgeType: type, badgeExpiry: previewDate), status: status)
    }

    private func contact(_ name: String, fullName: String = "", image: String? = nil, peerType: ChatPeerType? = nil, badge: LocalBadge? = nil, contactLink: String? = nil, ntfs: MsgFilter = .all, favorite: Bool = false) -> Contact {
        var c = Contact.sampleData
        c.contactId = newId()
        c.localDisplayName = name
        c.profile = LocalProfile(profileId: c.contactId, displayName: name, fullName: fullName, image: image, contactLink: contactLink, peerType: peerType, localBadge: badge, localAlias: "")
        c.chatSettings = ChatSettings(enableNtfs: ntfs, sendRcpts: nil, favorite: favorite)
        c.createdAt = previewDate
        c.updatedAt = previewDate
        c.chatTs = previewDate
        return c
    }

    private func group(_ name: String, fullName: String = "", status: GroupMemberStatus = .memComplete, incognito: Bool = false, ntfs: MsgFilter = .all) -> GroupInfo {
        var g = GroupInfo.sampleData
        g.groupId = newId()
        g.localDisplayName = name
        g.groupProfile = GroupProfile(displayName: name, fullName: fullName)
        g.membership.memberStatus = status
        if incognito {
            g.membership.memberProfile = LocalProfile(profileId: 50, displayName: "Fluffy Panda", fullName: "", localAlias: "")
        }
        g.chatSettings = ChatSettings(enableNtfs: ntfs, sendRcpts: nil, favorite: false)
        g.createdAt = previewDate
        g.updatedAt = previewDate
        g.chatTs = previewDate
        return g
    }

    private func business(_ name: String, _ type: BusinessChatType) -> GroupInfo {
        var g = group(name)
        g.businessChat = BusinessChatInfo(chatType: type, businessId: "business", customerId: "customer")
        return g
    }

    private func prepared(_ g: GroupInfo) -> GroupInfo {
        var g = g
        g.preparedGroup = PreparedGroup(connLinkToConnect: Self.link, connLinkPreparedConnection: false, connLinkStartedConnection: false)
        return g
    }

    private func connection(_ status: ConnStatus, viaContactUri: Bool, groupLinkId: String? = nil, incognito: Bool = false, alias: String = "") -> PendingContactConnection {
        var c = PendingContactConnection.getSampleData(status, viaContactUri: viaContactUri)
        c.pccConnId = newId()
        c.groupLinkId = groupLinkId
        c.customUserProfileId = incognito ? 50 : nil
        c.localAlias = alias
        c.createdAt = previewDate
        c.updatedAt = previewDate
        return c
    }

    private func file(_ name: String, sent: Bool = false) -> CIFile {
        CIFile.getSample(fileId: newId(), fileName: name, fileSize: 184_320, filePath: nil, fileStatus: sent ? .sndComplete : .rcvInvitation)
    }

    private func item(_ dir: CIDirection, _ text: String, _ content: MsgContent? = nil, status: CIStatus? = nil, file: CIFile? = nil, formattedText: [FormattedText]? = nil, mentions: [String: CIMention]? = nil, deleted: CIDeleted? = nil) -> ChatItem {
        let mc = content ?? .text(text)
        return ChatItem(
            chatDir: dir,
            meta: CIMeta.getSample(newId(), previewDate, text, status ?? (dir.sent ? CIStatus.sndSent(sndProgress: .complete) : CIStatus.rcvRead), itemDeleted: deleted),
            content: dir.sent ? .sndMsgContent(msgContent: mc) : .rcvMsgContent(msgContent: mc),
            formattedText: formattedText,
            mentions: mentions,
            file: file
        )
    }

    private func mentionItem(_ g: GroupInfo, _ sender: GroupMember, _ rest: String) -> ChatItem {
        item(
            .groupRcv(groupMember: sender),
            "@alice" + rest,
            formattedText: [FormattedText(text: "@alice", format: .mention(memberName: "alice")), FormattedText(text: rest)],
            mentions: ["alice": CIMention(groupMember: g.membership)]
        )
    }

    private func row(_ chatInfo: ChatInfo, _ items: [ChatItem] = [], _ stats: ChatStats = ChatStats()) -> some View {
        ChatListNavLink(chat: Chat(chatInfo: chatInfo, chatItems: items, chatStats: stats), parentSheet: .constant(nil))
    }

    private func previewRow(_ chatInfo: ChatInfo, _ items: [ChatItem] = [], progress: Bool = false, deleting: Bool = false) -> some View {
        ChatListRow {
            ChatPreviewView(chat: Chat(chatInfo: chatInfo, chatItems: items), progressByTimeout: .constant(progress), deleting: deleting)
        }
    }

    func contacts() -> some View {
        var verified = contact("alice", fullName: "Alice", image: Self.photo)
        verified.activeConn?.connectionCode = SecurityCode(securityCode: "123 456", verifiedAt: previewDate)
        let supporter = contact("bob", badge: badge(.supporter, .active))
        let expired = contact("carol", badge: badge(.legend, .expired))
        let unverified = contact("dan", badge: badge(.investor, .failed))
        let bot = contact("SimpleX Directory", peerType: .bot)
        let agent = contact("Assistant", peerType: .agent)
        var incognito = contact("erin")
        incognito.activeConn?.customUserProfileId = 50
        var deleted = contact("frank", badge: badge(.supporter, .active))
        deleted.contactStatus = .deleted
        deleted.activeConn?.connStatus = .deleted
        return VStack(spacing: 0) {
            row(.direct(contact: verified), [item(.directRcv, "Hi! Are you coming tonight?")])
            row(.direct(contact: supporter), [item(.directSnd, "Sure, see you at 7")])
            row(.direct(contact: expired), [item(.directRcv, "Thanks for the photos")])
            row(.direct(contact: unverified), [item(.directRcv, "Did you get my message?")])
            row(.direct(contact: bot), [item(.directRcv, "Send a group name to search")])
            row(.direct(contact: agent), [item(.directRcv, "Here is a summary of today's messages")])
            row(.direct(contact: incognito), [item(.directRcv, "Nice to meet you")])
            row(.direct(contact: deleted), [item(.directRcv, "Bye!")])
        }
    }

    func connecting() -> some View {
        var joining = contact("grace")
        joining.activeConn?.connStatus = .joined
        var shouldAccept = contact("heidi")
        shouldAccept.activeConn?.connStatus = .joined
        shouldAccept.preparedContact = PreparedContact(connLinkToConnect: Self.link, uiConnLinkType: .con)
        var preparedContact = contact("ivan")
        preparedContact.activeConn = nil
        preparedContact.preparedContact = PreparedContact(connLinkToConnect: Self.link, uiConnLinkType: .con)
        var preparedBot = contact("SimpleX Directory", peerType: .bot)
        preparedBot.activeConn = nil
        preparedBot.preparedContact = PreparedContact(connLinkToConnect: Self.link, uiConnLinkType: .con)
        var request = contact("judy")
        request.activeConn = nil
        request.contactRequestId = 7
        var memberRequest = contact("ken")
        memberRequest.activeConn = nil
        memberRequest.groupDirectInv = GroupDirectInvitation.sampleData
        var card = contact("laura", contactLink: Self.link.connFullLink)
        card.activeConn = nil
        var contactRequest = UserContactRequest.sampleData
        contactRequest.contactRequestId = newId()
        contactRequest.localDisplayName = "mike"
        contactRequest.profile = LocalProfile(profileId: contactRequest.contactRequestId, displayName: "mike", fullName: "Mike", localAlias: "")
        contactRequest.createdAt = previewDate
        contactRequest.updatedAt = previewDate
        return VStack(spacing: 0) {
            row(.direct(contact: joining))
            row(.direct(contact: shouldAccept))
            row(.direct(contact: preparedContact))
            row(.direct(contact: preparedBot))
            row(.direct(contact: request))
            row(.direct(contact: memberRequest))
            row(.direct(contact: card))
            row(.contactRequest(contactRequest: contactRequest))
        }
    }

    func pending() -> some View {
        VStack(spacing: 0) {
            row(.contactConnection(contactConnection: connection(.new, viaContactUri: false)))
            row(.contactConnection(contactConnection: connection(.new, viaContactUri: true)))
            row(.contactConnection(contactConnection: connection(.new, viaContactUri: true, groupLinkId: "group-link")))
            row(.contactConnection(contactConnection: connection(.joined, viaContactUri: false, incognito: true)))
            row(.contactConnection(contactConnection: connection(.new, viaContactUri: false, incognito: true, alias: "Bob's laptop")))
            row(.invalidJSON(json: nil))
        }
    }

    func groups() -> some View {
        var news = group("SimpleX news")
        news.useRelays = true
        news.groupProfile.publicGroup = PublicGroupProfile(groupType: .channel, groupLink: "", publicGroupId: "news")
        let notes = NoteFolder(noteFolderId: newId(), favorite: false, unread: false, createdAt: previewDate, updatedAt: previewDate, chatTs: previewDate)
        return VStack(spacing: 0) {
            row(.group(groupInfo: group("team", fullName: "My Team"), groupChatScope: nil), [item(.groupRcv(groupMember: alice), "Lunch at 1?")])
            row(.group(groupInfo: news, groupChatScope: nil), [item(.channelRcv, "Version 7.1 is out")])
            row(.group(groupInfo: business("Acme support", .business), groupChatScope: nil), [item(.groupRcv(groupMember: bob), "Your order has shipped")])
            row(.group(groupInfo: business("nina", .customer), groupChatScope: nil), [item(.groupSnd, "Thank you for your order!")])
            row(.local(noteFolder: notes), [item(.localSnd, "Buy milk and bread")])
            row(.group(groupInfo: group("book club", status: .memInvited), groupChatScope: nil))
            row(.group(groupInfo: group("night owls", status: .memInvited, incognito: true), groupChatScope: nil))
        }
    }

    func groupStates() -> some View {
        VStack(spacing: 0) {
            row(.group(groupInfo: group("hiking", status: .memAccepted), groupChatScope: nil))
            previewRow(.group(groupInfo: group("book club", status: .memInvited), groupChatScope: nil), progress: true)
            row(.group(groupInfo: group("neighbours", status: .memPendingReview), groupChatScope: nil))
            row(.group(groupInfo: prepared(group("SimpleX users")), groupChatScope: nil))
            row(.group(groupInfo: prepared(business("Acme support", .business)), groupChatScope: nil))
            row(.group(groupInfo: group("private club", status: .memRejected), groupChatScope: nil))
            row(.group(groupInfo: group("old team", status: .memLeft), groupChatScope: nil), [item(.groupRcv(groupMember: bob), "See you all next year")])
        }
    }

    func flags() -> some View {
        var support = group("helpdesk")
        support.membersRequireAttention = 1
        return VStack(spacing: 0) {
            row(.group(groupInfo: group("moderators"), groupChatScope: nil), [item(.groupRcv(groupMember: bob), "Please check the reports")], ChatStats(reportsCount: 2))
            row(.group(groupInfo: support, groupChatScope: nil), [item(.groupRcv(groupMember: carol), "How do I join?")])
            row(.group(groupInfo: group("night owls", incognito: true), groupChatScope: nil), [item(.groupRcv(groupMember: alice), "Good night everyone")])
            row(.group(groupInfo: group("old project", status: .memRemoved), groupChatScope: nil), [item(.groupRcv(groupMember: bob), "Closing this group")])
            row(.group(groupInfo: group("archive", status: .memGroupDeleted), groupChatScope: nil), [item(.groupRcv(groupMember: alice), "Thanks, everyone")])
        }
    }

    func unread() -> some View {
        let team = group("team", fullName: "My Team")
        return VStack(spacing: 0) {
            row(.direct(contact: contact("alice", fullName: "Alice", image: Self.photo)), [item(.directRcv, "All messages are read")])
            row(.direct(contact: contact("bob")), [item(.directRcv, "Three new messages")], ChatStats(unreadCount: 3))
            row(.direct(contact: contact("carol")), [item(.directRcv, "Over a thousand new messages")], ChatStats(unreadCount: 1234))
            row(.direct(contact: contact("dan", ntfs: .none)), [item(.directRcv, "Muted, five new messages")], ChatStats(unreadCount: 5))
            row(.group(groupInfo: team, groupChatScope: nil), [mentionItem(team, bob, " can you check the release notes?")], ChatStats(unreadCount: 4, unreadMentions: 1))
            row(.group(groupInfo: team, groupChatScope: nil), [mentionItem(team, carol, " are you there?")], ChatStats(unreadCount: 1, unreadMentions: 1))
            row(.direct(contact: contact("erin")), [item(.directRcv, "Marked as unread")], ChatStats(unreadChat: true))
        }
    }

    func marks() -> some View {
        let notes = NoteFolder(noteFolderId: newId(), favorite: false, unread: false, createdAt: previewDate, updatedAt: previewDate, chatTs: previewDate)
        let quiet = group("announcements", ntfs: .mentions)
        return VStack(spacing: 0) {
            row(.direct(contact: contact("alice", ntfs: .none)), [item(.directRcv, "Muted chat")])
            row(.group(groupInfo: quiet, groupChatScope: nil), [item(.groupRcv(groupMember: bob), "Mentions only")])
            row(.direct(contact: contact("carol", favorite: true)), [item(.directRcv, "Favorite chat")])
            row(.direct(contact: contact("dan", favorite: true)), [item(.directRcv, "Favorite chat with two new messages")], ChatStats(unreadCount: 2))
            row(.direct(contact: contact("erin", ntfs: .none, favorite: true)), [item(.directRcv, "Muted favorite chat")])
            row(.group(groupInfo: quiet, groupChatScope: nil), [mentionItem(quiet, bob, " the release is ready")], ChatStats(unreadCount: 3, unreadMentions: 1))
            row(.local(noteFolder: notes), [item(.localSnd, "Unread notes")], ChatStats(unreadCount: 2))
        }
    }

    func media() -> some View {
        let linkPreview = LinkPreview(uri: "https://simplex.chat", title: "SimpleX Chat: private and secure messenger without any user IDs", image: Self.landscape)
        return VStack(spacing: 0) {
            row(.direct(contact: contact("alice")), [item(.directRcv, "Sunset at the beach", .image(text: "Sunset at the beach", image: Self.landscape), file: file("sunset.jpg"))])
            row(.direct(contact: contact("bob")), [item(.directRcv, "", .image(text: "", image: Self.landscape), file: file("photo.jpg"))])
            row(.direct(contact: contact("carol")), [item(.directRcv, "", .video(text: "", image: Self.landscape, duration: 42), file: file("video.mp4"))])
            row(.direct(contact: contact("dan")), [item(.directRcv, "", .voice(text: "", duration: 12), file: file("voice.m4a"))])
            row(.direct(contact: contact("erin")), [item(.directSnd, "Listen to this", .voice(text: "Listen to this", duration: 34), file: file("voice.m4a", sent: true))])
            row(.direct(contact: contact("frank")), [item(.directRcv, "", .file(""), file: file("report.pdf"))])
            row(.direct(contact: contact("grace")), [item(.directRcv, "https://simplex.chat", .link(text: "https://simplex.chat", preview: linkPreview), formattedText: [FormattedText(text: "https://simplex.chat", format: .uri)])])
        }
    }

    func text() -> some View {
        let team = group("team", fullName: "My Team")
        let sharedContact = MsgChatLink.contact(connLink: Self.link.connFullLink, profile: Profile(displayName: "carol", fullName: "Carol", shortDescr: "Designer in Lisbon", image: Self.photo2), business: false)
        let sharedChannel = MsgChatLink.group(connLink: Self.link.connFullLink, groupProfile: GroupProfile(displayName: "SimpleX news", fullName: "", shortDescr: "Release announcements", publicGroup: PublicGroupProfile(groupType: .channel, groupLink: "", publicGroupId: "news")))
        return VStack(spacing: 0) {
            row(.direct(contact: contact("alice")), [item(.directSnd, "", .chat(text: "", chatLink: sharedContact, ownerSig: nil))])
            row(.direct(contact: contact("bob")), [item(.directRcv, "", .chat(text: "", chatLink: sharedChannel, ownerSig: nil))])
            row(.group(groupInfo: group("moderators"), groupChatScope: nil), [item(.groupRcv(groupMember: bob), "Spam links in every message", .report(text: "Spam links in every message", reason: .spam))])
            row(.direct(contact: contact("carol")), [item(.directSnd, "Are you there?", status: .sndError(agentError: .auth))])
            row(.direct(contact: contact("dan")), [item(.directSnd, "I will call you later", status: .sndWarning(agentError: .quota))])
            row(.direct(contact: contact("erin")), [item(.directRcv, "The door code is 4721", formattedText: [FormattedText(text: "The door code is "), FormattedText(text: "4721", format: .secret)])])
            row(.group(groupInfo: team, groupChatScope: nil), [mentionItem(team, bob, " please review the draft")])
        }
    }

    func deleted() -> some View {
        let team = group("team", fullName: "My Team")
        return VStack(spacing: 0) {
            row(.direct(contact: contact("alice")), [item(.directRcv, "", .image(text: "", image: Self.landscape), file: file("photo.jpg"), deleted: .deleted(deletedTs: previewDate))])
            row(.group(groupInfo: team, groupChatScope: nil), [item(.groupRcv(groupMember: bob), "Buy cheap watches", deleted: .moderated(deletedTs: previewDate, byGroupMember: alice))])
            row(.group(groupInfo: team, groupChatScope: nil), [item(.groupRcv(groupMember: carol), "Blocked message", deleted: .blocked(deletedTs: previewDate))])
            row(.group(groupInfo: team, groupChatScope: nil), [item(.groupRcv(groupMember: bob), "Blocked by admin", deleted: .blockedByAdmin(deletedTs: previewDate))])
            row(.group(groupInfo: group("moderators"), groupChatScope: nil), [item(.groupRcv(groupMember: bob), "Spam links in every message", .report(text: "Spam links in every message", reason: .spam), deleted: .deleted(deletedTs: previewDate))])
        }
    }

    func long() -> some View {
        let longText = "We are meeting at the station at eight, bring warm clothes, water and snacks for the whole day, the forecast says it will be cold"
        return VStack(spacing: 0) {
            row(.direct(contact: contact("Alexandra Konstantinopoulou", fullName: "Alexandra Konstantinopoulou-Papadimitriou", badge: badge(.supporter, .active))), [item(.directRcv, "Long names are cut at the end")])
            row(.group(groupInfo: group("Weekend trip planning committee", fullName: "Mountains, lakes and long walks"), groupChatScope: nil), [item(.groupRcv(groupMember: alice), longText)])
            row(.direct(contact: contact("لينا")), [item(.directRcv, "مرحبا! هل ستأتي إلى الاجتماع غدا في الساعة العاشرة؟")])
            row(.direct(contact: contact("bob")), [item(.directRcv, "Sunset at the beach", .image(text: "Sunset at the beach", image: Self.landscape), file: file("sunset.jpg"))])
                .defaultAppStorage(Self.hiddenPreviews)
            previewRow(.direct(contact: contact("carol")), [item(.directRcv, "This chat is being deleted")], deleting: true)
        }
    }
}
