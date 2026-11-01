package chat.simplex.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.WindowState
import boofcv.alg.fiducial.qrcode.QrCode
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.model.ChatModel
import chat.simplex.common.simplexWindowState
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.PreviewTerminalLayout
import chat.simplex.common.views.badges.PreviewPeriodCards
import chat.simplex.common.views.call.PreviewIncomingCallAlertLayout
import chat.simplex.common.views.chat.*
import chat.simplex.common.views.chat.group.*
import chat.simplex.common.views.chat.item.*
import chat.simplex.common.views.chatlist.*
import chat.simplex.common.views.database.*
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.newchat.*
import chat.simplex.common.views.onboarding.*
import chat.simplex.common.views.usersettings.*
import chat.simplex.common.views.usersettings.networkAndServers.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Image
import org.jetbrains.skia.Surface
import java.io.File
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.test.assertEquals

private const val SCENE_WIDTH = 402
private const val SCENE_MAX_HEIGHT = 874
private const val PREVIEW_QR_LINK = "https://smp6.simplex.im/a#lrdvu2d8A1GumSmoKb2krQmtKhWXq-tyGpHuM7aMwsw"

private val chatItemFontScales = listOf(1f, 1.4f, 1.5f)

private class SnapshotScene(val name: String, val fontScales: List<Float> = listOf(1f), val content: @Composable () -> Unit)

@Serializable
private class Snapshot(val scene: String, val theme: String, val fontScale: Float, val file: String, val width: Int, val height: Int)

private val indexJson = Json { prettyPrint = true }

private val previewScenes = listOf(
  SnapshotScene("TerminalView.PreviewTerminalLayout") { PreviewTerminalLayout() },
  SnapshotScene("IncomingCallAlertView.PreviewIncomingCallAlertLayout") { PreviewIncomingCallAlertLayout() },
  SnapshotScene("ChatInfoView.PreviewChatInfoLayout") { chat.simplex.common.views.chat.PreviewChatInfoLayout() },
  SnapshotScene("ChatView.PreviewChatLayout") { PreviewChatLayout() },
  SnapshotScene("ChatView.PreviewGroupChatLayout") { PreviewGroupChatLayout() },
  SnapshotScene("ComposeFileView.PreviewComposeFileView") { PreviewComposeFileView() },
  SnapshotScene("ComposeVoiceView.PreviewComposeAudioView") { PreviewComposeAudioView() },
  SnapshotScene("ContextItemView.PreviewContextItemView") { PreviewContextItemView() },
  SnapshotScene("SendMsgView.PreviewSendMsgView") { PreviewSendMsgView() },
  SnapshotScene("SendMsgView.PreviewSendMsgViewEditing") { PreviewSendMsgViewEditing() },
  SnapshotScene("SendMsgView.PreviewSendMsgViewInProgress") { PreviewSendMsgViewInProgress() },
  SnapshotScene("AddGroupMembersView.PreviewAddGroupMembersLayout") { PreviewAddGroupMembersLayout() },
  SnapshotScene("GroupChatInfoView.PreviewGroupChatInfoLayout") { PreviewGroupChatInfoLayout() },
  SnapshotScene("GroupMemberInfoView.PreviewGroupMemberInfoLayout") { PreviewGroupMemberInfoLayout() },
  SnapshotScene("CIEventView.CIEventViewPreview", chatItemFontScales) { CIEventViewPreview() },
  SnapshotScene("CIGroupInvitationView.PendingCIGroupInvitationViewPreview", chatItemFontScales) { PendingCIGroupInvitationViewPreview() },
  SnapshotScene("CIGroupInvitationView.CIGroupInvitationViewAcceptedPreview", chatItemFontScales) { CIGroupInvitationViewAcceptedPreview() },
  SnapshotScene("CIGroupInvitationView.CIGroupInvitationViewLongNamePreview", chatItemFontScales) { CIGroupInvitationViewLongNamePreview() },
  SnapshotScene("CIMetaView.PreviewCIMetaView", chatItemFontScales) { SimpleXTheme { PreviewCIMetaView() } },
  SnapshotScene("CIMetaView.PreviewCIMetaViewUnread", chatItemFontScales) { SimpleXTheme { PreviewCIMetaViewUnread() } },
  SnapshotScene("CIMetaView.PreviewCIMetaViewSendFailed", chatItemFontScales) { SimpleXTheme { PreviewCIMetaViewSendFailed() } },
  SnapshotScene("CIMetaView.PreviewCIMetaViewSendNoAuth", chatItemFontScales) { SimpleXTheme { PreviewCIMetaViewSendNoAuth() } },
  SnapshotScene("CIMetaView.PreviewCIMetaViewSendSent", chatItemFontScales) { SimpleXTheme { PreviewCIMetaViewSendSent() } },
  SnapshotScene("CIMetaView.PreviewCIMetaViewEdited", chatItemFontScales) { SimpleXTheme { PreviewCIMetaViewEdited() } },
  SnapshotScene("CIMetaView.PreviewCIMetaViewEditedUnread", chatItemFontScales) { SimpleXTheme { PreviewCIMetaViewEditedUnread() } },
  SnapshotScene("CIMetaView.PreviewCIMetaViewEditedSent", chatItemFontScales) { SimpleXTheme { PreviewCIMetaViewEditedSent() } },
  SnapshotScene("CIMetaView.PreviewCIMetaViewDeletedContent", chatItemFontScales) { SimpleXTheme { PreviewCIMetaViewDeletedContent() } },
  SnapshotScene("ChatItemView.PreviewChatItemView", chatItemFontScales) { SimpleXTheme { PreviewChatItemView() } },
  SnapshotScene("ChatItemView.PreviewChatItemViewDeletedContent", chatItemFontScales) { PreviewChatItemViewDeletedContent() },
  SnapshotScene("DeletedItemView.PreviewDeletedItemView", chatItemFontScales) { PreviewDeletedItemView() },
  SnapshotScene("IntegrityErrorItemView.IntegrityErrorItemViewPreview", chatItemFontScales) { IntegrityErrorItemViewPreview() },
  SnapshotScene("MarkedDeletedItemView.PreviewMarkedDeletedItemView", chatItemFontScales) { PreviewMarkedDeletedItemView() },
  SnapshotScene("ChatHelpView.PreviewChatHelpLayout") { PreviewChatHelpLayout() },
  SnapshotScene("ChatListNavLinkView.PreviewChatListNavLinkDirect") { PreviewChatListNavLinkDirect() },
  SnapshotScene("ChatListNavLinkView.PreviewChatListNavLinkGroup") { PreviewChatListNavLinkGroup() },
  SnapshotScene("ChatListNavLinkView.PreviewChatListNavLinkContactRequest") { PreviewChatListNavLinkContactRequest() },
  SnapshotScene("ChatPreviewView.PreviewChatPreviewView") { PreviewChatPreviewView() },
  SnapshotScene("DatabaseEncryptionView.PreviewDatabaseEncryptionLayout") { PreviewDatabaseEncryptionLayout() },
  SnapshotScene("DatabaseErrorView.PreviewChatInfoLayout") { chat.simplex.common.views.database.PreviewChatInfoLayout() },
  SnapshotScene("DatabaseView.PreviewDatabaseLayout") { PreviewDatabaseLayout() },
  SnapshotScene("ChatInfoImage.PreviewChatInfoImage") { PreviewChatInfoImage() },
  SnapshotScene("LinkPreviews.PreviewChatItemLinkView") { PreviewChatItemLinkView() },
  SnapshotScene("LinkPreviews.PreviewComposeLinkView") { PreviewComposeLinkView() },
  SnapshotScene("LinkPreviews.PreviewComposeLinkViewLoading") { PreviewComposeLinkViewLoading() },
  SnapshotScene("SimpleButton.PreviewShareButton") { PreviewShareButton() },
  SnapshotScene("ContactConnectionInfoView.PreviewContactConnectionInfoView") { PreviewContactConnectionInfoView() },
  SnapshotScene("NewChatSheet.PreviewNewChatSheet") { PreviewNewChatSheet() },
  SnapshotScene("QRCode.PreviewQRCode") { PreviewQRCode() },
  SnapshotScene("HowItWorks.PreviewHowItWorks") { PreviewHowItWorks() },
  SnapshotScene("SimpleXInfo.PreviewSimpleXInfo") { PreviewSimpleXInfo() },
  SnapshotScene("WhatsNewView.PreviewWhatsNewView") { PreviewWhatsNewView() },
  SnapshotScene("WhatsNewView.PreviewCrowdfundingBottomA") { PreviewCrowdfundingBottomA() },
  SnapshotScene("WhatsNewView.PreviewCrowdfundingBottomB") { PreviewCrowdfundingBottomB() },
  SnapshotScene("Texts.AlertLinkNotSupported") { AlertScene { showAlertMsg(title = generalGetString(chat.simplex.res.MR.strings.app_link_not_supported)) } },
  SnapshotScene("Texts.AlertSignMessages") { AlertScene { showAlertDialog(title = generalGetString(chat.simplex.res.MR.strings.sign_messages_question), text = generalGetString(chat.simplex.res.MR.strings.sign_messages_alert_desc), confirmText = generalGetString(chat.simplex.res.MR.strings.sign_messages_enable)) } },
  SnapshotScene("Texts.AlertSignatureMissing") { AlertScene { showAlertMsg(title = generalGetString(chat.simplex.res.MR.strings.signature_missing_alert_title), text = generalGetString(chat.simplex.res.MR.strings.signature_missing_alert_desc)) } },
  SnapshotScene("Texts.AlertUnsupportedVersion") { AlertScene { showAlertMsg(title = generalGetString(chat.simplex.res.MR.strings.badges_error_title), text = generalGetString(chat.simplex.res.MR.strings.badges_error_unsupported_version)) } },
  SnapshotScene("Texts.AlertReceiptUsed") { AlertScene { showAlertMsg(title = generalGetString(chat.simplex.res.MR.strings.badges_purchase_error), text = generalGetString(chat.simplex.res.MR.strings.badges_error_receipt_used)) } },
  SnapshotScene("Texts.AlertTestPurchase") { AlertScene { showAlertMsg(title = generalGetString(chat.simplex.res.MR.strings.badges_purchase_error), text = generalGetString(chat.simplex.res.MR.strings.badges_error_test_purchase)) } },
  SnapshotScene("Texts.AlertAlreadyOwned") { AlertScene { showAlertMsg(title = generalGetString(chat.simplex.res.MR.strings.badges_purchase_error), text = generalGetString(chat.simplex.res.MR.strings.badges_error_already_owned)) } },
  SnapshotScene("Texts.AlertStorePurchaseOpen") { AlertScene { showAlertMsg(title = generalGetString(chat.simplex.res.MR.strings.badges_error_title), text = generalGetString(chat.simplex.res.MR.strings.badges_error_store_purchase_open)) } },
  SnapshotScene("Texts.AlertAlreadyActive") { AlertScene { showAlertMsg(title = generalGetString(chat.simplex.res.MR.strings.badges_error_title), text = generalGetString(chat.simplex.res.MR.strings.badges_error_already_active)) } },
  SnapshotScene("Texts.YourBadgePaymentProblem") { YourBadgeScene(chat.simplex.common.model.BadgeSubscriptionState.BillingRetry, 20) },
  SnapshotScene("Texts.YourBadgeRenewing") { YourBadgeScene(chat.simplex.common.model.BadgeSubscriptionState.Renewing, -1) },
  SnapshotScene("Texts.YourBadgeRenews") { YourBadgeScene(chat.simplex.common.model.BadgeSubscriptionState.Renewing, 20) },
  SnapshotScene("Texts.YourBadgeEnded") { YourBadgeScene(chat.simplex.common.model.BadgeSubscriptionState.Ended, -1) },
  SnapshotScene("Texts.YourBadgePrepaid") { YourBadgeScene(null, 40, subscribed = false) },
  SnapshotScene("SetNotificationsMode.PreviewSetNotificationsMode") { PreviewSetNotificationsMode() },
  SnapshotScene("BadgesHowLongView.PreviewPeriodCards") { PreviewPeriodCards() },
  SnapshotScene("BadgesHowLongView.PreviewPlaySupportSimplex") { chat.simplex.common.views.badges.PreviewPlaySupportSimplex() },
  SnapshotScene("BadgesHowLongView.PreviewPlayChooseA") { chat.simplex.common.views.badges.PreviewPlayChooseA() },
  SnapshotScene("BadgesHowLongView.PreviewPlayChooseB") { chat.simplex.common.views.badges.PreviewPlayChooseB() },
  SnapshotScene("BadgesHowLongView.PreviewPlayHowLongA") { chat.simplex.common.views.badges.PreviewPlayHowLongA() },
  SnapshotScene("BadgesHowLongView.PreviewPlayHowLongB") { chat.simplex.common.views.badges.PreviewPlayHowLongB() },
  SnapshotScene("BadgesHowLongView.PreviewPlayCheckOrderA") { chat.simplex.common.views.badges.PreviewPlayCheckOrderA() },
  SnapshotScene("BadgesHowLongView.PreviewPlayCheckOrderB") { chat.simplex.common.views.badges.PreviewPlayCheckOrderB() },
  SnapshotScene("HelpView.PreviewHelpView") { PreviewHelpView() },
  SnapshotScene("MarkdownHelpView.PreviewMarkdownHelpView") { PreviewMarkdownHelpView() },
  SnapshotScene("SettingsView.PreviewSettingsLayout") { PreviewSettingsLayout() },
  SnapshotScene("UserAddressView.PreviewUserAddressLayoutNoAddress") { PreviewUserAddressLayoutNoAddress() },
  SnapshotScene("UserAddressView.PreviewUserAddressLayoutAddressCreated") { PreviewUserAddressLayoutAddressCreated() },
  SnapshotScene("AdvancedNetworkSettings.PreviewAdvancedNetworkSettingsLayout") { PreviewAdvancedNetworkSettingsLayout() },
  SnapshotScene("NetworkAndServers.PreviewNetworkAndServersLayout") { PreviewNetworkAndServersLayout() },
)

private val previewsCallingCore = listOf(
  "AddChannelView.PreviewAddChannelView",
  "AddGroupView.PreviewAddGroupLayout",
  "GroupProfileView.PreviewGroupProfileLayout",
  "UserProfileView.PreviewUserProfileLayoutEditOff",
  "UserProfileView.PreviewUserProfileLayoutEditOn",
)

private val previewFunction = Regex("""@Preview\s+(?:@Composable\s+)?(?:\w+\s+)*fun\s+(\w+)""")

class SnapshotTest {
  @Test
  fun everyPreviewIsRendered() {
    assertEquals(previewsInSources(), (previewScenes.map { it.name } + previewsCallingCore).sorted())
  }

  @Test
  fun renderPreviews() {
    val dir = File(System.getenv("SNAPSHOT_DIR") ?: "build/snapshots").apply { mkdirs() }
    val locale = Locale.getDefault()
    val timeZone = TimeZone.getDefault()
    val theme = appPrefs.currentTheme.get()!!
    val themeOverrides = appPrefs.themeOverrides.get()
    val fontScale = appPrefs.fontScale.get()
    val densityScale = appPrefs.densityScale.get()
    val oneHandUI = appPrefs.oneHandUI.get()
    val chatBottomBar = appPrefs.chatBottomBar.get()
    val chatItemRoundness = appPrefs.chatItemRoundness.get()
    val chatItemTail = appPrefs.chatItemTail.get()
    val privacyMediaBlurRadius = appPrefs.privacyMediaBlurRadius.get()
    val appearanceBarsBlurRadius = appPrefs.appearanceBarsBlurRadius.get()
    val inAppBarsAlpha = appPrefs.inAppBarsAlpha.get()
    val appBarMaxHeightPx = AppBarHandler.appBarMaxHeightPx
    val index = mutableListOf<Snapshot>()
    val failures = mutableListOf<String>()
    try {
      Locale.setDefault(Locale.US)
      TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
      simplexWindowState.windowState = WindowState(size = DpSize(SCENE_WIDTH.dp, SCENE_MAX_HEIGHT.dp))
      appPrefs.densityScale.set(1f)
      appPrefs.oneHandUI.set(true)
      appPrefs.chatBottomBar.set(true)
      appPrefs.chatItemRoundness.set(0.75f)
      appPrefs.chatItemTail.set(true)
      appPrefs.privacyMediaBlurRadius.set(0)
      appPrefs.appearanceBarsBlurRadius.set(if (appPrefs.deviceSupportsBlur) 50 else 0)
      appPrefs.inAppBarsAlpha.set(appPrefs.inAppBarsDefaultAlpha)
      appPrefs.themeOverrides.set(listOf(ThemeOverrides(base = DefaultTheme.LIGHT), ThemeOverrides(base = DefaultTheme.DARK)))
      for (base in listOf(DefaultTheme.LIGHT, DefaultTheme.DARK)) {
        ThemeManager.applyTheme(base.themeName)
        val themeName = base.name.lowercase()
        for (scene in previewScenes) {
          for (scale in scene.fontScales) {
            appPrefs.fontScale.set(scale)
            ChatModel.terminalItems.value = listOf()
            val file = "${scene.name}-$themeName-font-${(scale * 100).roundToInt()}.png"
            try {
              val image = renderSnapshot(scene.content)
              File(dir, file).writeBytes(image.encodeToData(EncodedImageFormat.PNG)!!.bytes)
              index += Snapshot(scene.name, themeName, scale, file, image.width, image.height)
            } catch (e: Throwable) {
              failures += "$file: ${e.stackTraceToString()}"
            }
          }
        }
      }
      File(dir, "index-desktop.json").writeText(indexJson.encodeToString(index))
    } finally {
      Locale.setDefault(locale)
      TimeZone.setDefault(timeZone)
      appPrefs.themeOverrides.set(themeOverrides)
      appPrefs.fontScale.set(fontScale)
      appPrefs.densityScale.set(densityScale)
      appPrefs.oneHandUI.set(oneHandUI)
      appPrefs.chatBottomBar.set(chatBottomBar)
      appPrefs.chatItemRoundness.set(chatItemRoundness)
      appPrefs.chatItemTail.set(chatItemTail)
      appPrefs.privacyMediaBlurRadius.set(privacyMediaBlurRadius)
      appPrefs.appearanceBarsBlurRadius.set(appearanceBarsBlurRadius)
      appPrefs.inAppBarsAlpha.set(inAppBarsAlpha)
      AppBarHandler.appBarMaxHeightPx = appBarMaxHeightPx
      ThemeManager.applyTheme(theme)
    }
    assertEquals(emptyList(), failures)
  }
}

@Composable
private fun AlertScene(show: AlertManager.() -> Unit) {
  val alertManager = androidx.compose.runtime.remember { AlertManager().apply(show) }
  SimpleXTheme {
    Box(Modifier.width(SCENE_WIDTH.dp).height(SCENE_MAX_HEIGHT.dp)) {
      alertManager.showInView()
    }
  }
}

@Composable
private fun YourBadgeScene(status: chat.simplex.common.model.BadgeSubscriptionState?, paidDays: Int, subscribed: Boolean = true) {
  androidx.compose.runtime.LaunchedEffect(Unit) { chat.simplex.common.views.badges.BadgeStore.load() }
  val paidThrough = kotlinx.datetime.Instant.fromEpochMilliseconds(kotlinx.datetime.Clock.System.now().toEpochMilliseconds() + paidDays * 86_400_000L)
  val state = chat.simplex.common.model.BadgeState(
    badgePurchaseId = 1,
    purchaseKey = "",
    badgeType = chat.simplex.common.model.BadgeType.Supporter,
    shown = true,
    monthsLeft = 1,
    paidThrough = paidThrough,
    willRenew = subscribed,
    subscription = if (subscribed) chat.simplex.common.model.BadgeSubscription(planMonths = 1, status = status) else null
  )
  SimpleXTheme {
    Box(Modifier.width(SCENE_WIDTH.dp).height(SCENE_MAX_HEIGHT.dp)) {
      chat.simplex.common.views.badges.BadgesYourBadgeView(state, ModalManager.start)
    }
  }
}

private fun renderSnapshot(content: @Composable () -> Unit): Image {
  var height = 0
  val fixedQRCode = qrCodeBitmap(PREVIEW_QR_LINK, 1024, QrCode.ErrorLevel.M)
  val frame = renderScene(width = SCENE_WIDTH, height = SCENE_MAX_HEIGHT, frames = 4) {
    AppBarHandler.appBarMaxHeightPx = with(LocalDensity.current) { AppBarHeight.roundToPx() }
    Box(Modifier.width(SCENE_WIDTH.dp).background(CurrentColors.collectAsState().value.colors.background).onSizeChanged { height = it.height }) {
      CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler(), LocalFixedQRCode provides fixedQRCode, content = content)
    }
  }
  return Surface.makeRasterN32Premul(SCENE_WIDTH, height).run {
    canvas.drawImage(frame, 0f, 0f)
    makeImageSnapshot()
  }
}

private fun previewsInSources(): List<String> =
  listOf("src/commonMain/kotlin", "src/desktopMain/kotlin")
    .flatMap { dir -> File(dir).walk().filter { it.extension == "kt" } }
    .flatMap { file -> previewFunction.findAll(withoutComments(file.readText())).map { "${file.nameWithoutExtension}.${it.groupValues[1]}" } }
    .sorted()

private fun withoutComments(source: String): String {
  val code = StringBuilder()
  var i = 0
  while (i < source.length) {
    val end = tokenEnd(source, i)
    if (source.startsWith("//", i) || source.startsWith("/*", i)) code.append(' ') else code.append(source, i, end)
    i = end
  }
  return code.toString()
}

private fun tokenEnd(source: String, start: Int): Int = when {
  source.startsWith("//", start) -> source.indexOf('\n', start).takeIf { it >= 0 } ?: source.length
  source.startsWith("/*", start) -> {
    var depth = 0
    var i = start
    do {
      when {
        source.startsWith("/*", i) -> { depth++; i += 2 }
        source.startsWith("*/", i) -> { depth--; i += 2 }
        else -> i++
      }
    } while (depth > 0)
    i
  }
  source.startsWith("\"\"\"", start) -> {
    var i = source.indexOf("\"\"\"", start + 3)
    while (source.startsWith("\"\"\"\"", i)) i++
    i + 3
  }
  source[start] == '"' || source[start] == '\'' -> {
    var i = start + 1
    while (source[i] != source[start]) i += if (source[i] == '\\') 2 else 1
    i + 1
  }
  else -> start + 1
}
