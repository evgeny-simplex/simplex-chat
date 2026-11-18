package chat.simplex.app

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.width
import androidx.compose.material.MaterialTheme
import androidx.compose.material.ModalBottomSheetValue
import androidx.compose.material.rememberModalBottomSheetState
import androidx.compose.runtime.*
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.Modifier
import androidx.compose.ui.MotionDurationScale
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.DpSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.use
import androidx.compose.ui.window.WindowState
import chat.simplex.common.model.*
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.simplexWindowState
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.chat.*
import chat.simplex.common.views.chat.item.*
import chat.simplex.common.views.helpers.*
import kotlinx.coroutines.Dispatchers
import org.jetbrains.skia.EncodedImageFormat
import org.jetbrains.skia.Image
import org.jetbrains.skia.Surface
import java.io.File
import java.util.Locale
import java.util.TimeZone
import kotlin.math.roundToInt
import kotlin.test.Test
import kotlin.time.Duration.Companion.seconds

private object NoMotion : MotionDurationScale {
  override val scaleFactor = 0f
}

private const val WIDTH = 402
private const val BASE = "Thanks for the update. I read the whole thread this morning and I think we should move the release to Thursday, so that the translations are complete and the new screens can be checked on small phones first."

private val alice = GroupMember.sampleData.copy(groupMemberId = 11, memberId = "alice", localDisplayName = "alice", memberProfile = LocalProfile.sampleData.copy(profileId = 11, displayName = "alice", fullName = ""))
private val bob = GroupMember.sampleData.copy(groupMemberId = 12, memberId = "bob", localDisplayName = "bob", memberProfile = LocalProfile.sampleData.copy(profileId = 12, displayName = "bob", fullName = ""))

private fun rcv(id: Long, member: GroupMember, text: String, status: CIStatus, secondsAfter: Long = 0) =
  ChatItem.getSampleData(id, CIDirection.GroupRcv(member), previewDate.plus(secondsAfter.seconds), text, status = status)
    .copy(content = CIContent.RcvMsgContent(MsgContent.MCText(text)))

private val candidates: List<String> = BASE.split(" ").let { words -> (8..words.size).map { words.take(it).joinToString(" ") } }

class BlankLineRenderTest {
  private val outDir = File(System.getenv("BLANKLINE_DIR") ?: "build/blankline").apply { mkdirs() }

  @Composable
  private fun Scene(items: List<ChatItem>, terminal: Boolean) {
    CompositionLocalProvider(LocalTerminalLayout provides terminal, LocalBubbleLayout provides !terminal) {
      SimpleXTheme {
        ChatLayout(
          chatsCtx = remember { ChatModel.ChatsContext(secondaryContextFilter = null).also { it.chatItems.replaceAll(items) } },
          remoteHostId = remember { mutableStateOf(null) },
          chat = remember { mutableStateOf(Chat.sampleData.copy(chatInfo = ChatInfo.Group.sampleData)) },
          unreadCount = remember { mutableStateOf(items.count { it.isRcvNew }) },
          composeState = remember { mutableStateOf(ComposeState(useLinkPreviews = true)) },
          composeView = { _ -> },
          scrollToItemId = remember { mutableStateOf(null) },
          attachmentOption = remember { mutableStateOf<AttachmentOption?>(null) },
          attachmentBottomSheetState = rememberModalBottomSheetState(initialValue = ModalBottomSheetValue.Hidden),
          remember { mutableStateOf("") },
          useLinkPreviews = true,
          linkMode = SimplexLinkMode.DESCRIPTION,
          selectedChatItems = remember { mutableStateOf(null) },
          back = {}, info = {}, showReports = {}, showSupportChats = {}, showMemberInfo = { _, _ -> },
          loadMessages = { _, _, _ -> }, deleteMessage = { _, _ -> }, deleteMessages = {}, archiveReports = { _, _ -> },
          receiveFile = { _ -> }, cancelFile = {}, joinGroup = { _, _ -> }, startCall = {}, endCall = {}, acceptCall = { _ -> },
          acceptFeature = { _, _, _ -> }, openDirectChat = { _ -> }, forwardItem = { _, _ -> }, updateContactStats = { },
          updateMemberStats = { _, _ -> }, syncContactConnection = { }, syncMemberConnection = { _, _ -> },
          findModelChat = { null }, findModelMember = { null }, setReaction = { _, _, _, _ -> }, showItemDetails = { _, _ -> },
          addMembers = { _ -> }, openGroupLink = {}, markItemsRead = { _ -> }, markChatRead = {}, changeNtfsState = { _ -> },
          onSearchValueChanged = {}, closeSearch = {}, onComposed = {}, developerTools = false, showViaProxy = false,
          showSearch = remember { mutableStateOf(false) }, showCommandsMenu = remember { mutableStateOf(false) },
          contentFilter = remember { mutableStateOf(null) }, availableContent = remember { mutableStateOf(ContentFilter.initialList) },
          searchPlaceholder = null
        )
      }
    }
  }

  @Composable
  private fun MetaWidths(out: MutableMap<String, Int>) {
    val unread = rcv(1, alice, "x", CIStatus.RcvNew())
    val sent = ChatItem.getSampleData(2, CIDirection.GroupSnd(), previewDate, "x", status = CIStatus.SndRcvd(MsgReceiptStatus.Ok, SndCIStatusProgress.Complete))
    val measurer = androidx.compose.ui.text.rememberTextMeasurer()
    val style = MaterialTheme.typography.body1.merge(chatTextStyle(MaterialTheme.typography.body1.fontSize))
    for ((name, item) in listOf("unread" to unread, "sent" to sent)) {
      for ((mode, m) in listOf("master" to 0, "b" to 2)) {
        blankLineMode = m
        val copy = metaReserveCopy(item.meta, null, null, null, MaterialTheme.colors.secondary, showViaProxy = false, showTimestamp = false, breakBefore = true)
        out["reserve-$name-$mode"] = measurer.measure(copy, style).size.width
      }
      blankLineMode = 0
      Box(Modifier.onSizeChanged { out["meta-$name"] = it.width }) {
        CIMetaView(item, null, showTimestamp = false, showViaProxy = false)
      }
    }
  }

  private fun render(scale: Float, height: Int, content: @Composable () -> Unit): Image {
    simplexWindowState.windowState = WindowState(size = DpSize(WIDTH.dp, height.dp))
    ChatModel.terminalItems.value = listOf()
    var contentHeight = 0
    val w = (WIDTH * scale).roundToInt()
    val h = (height * scale).roundToInt()
    val frame = ImageComposeScene(width = w, height = h, density = Density(scale), coroutineContext = Dispatchers.Unconfined + NoMotion) {
      AppBarHandler.appBarMaxHeightPx = with(LocalDensity.current) { AppBarHeight.roundToPx() }
      Box(Modifier.width(WIDTH.dp).background(CurrentColors.collectAsState().value.colors.background).onSizeChanged { contentHeight = it.height }) {
        CompositionLocalProvider(LocalAppBarHandler provides rememberAppBarHandler(), content = content)
      }
    }.use { scene -> (0 until 4).map { scene.render(it * 1_000_000_000L) }.last() }
    return Surface.makeRasterN32Premul(w, contentHeight.coerceAtLeast(1)).run {
      canvas.drawImage(frame, 0f, 0f)
      makeImageSnapshot()
    }
  }

  private fun probe(text: String, status: CIStatus, showTimestamp: Boolean = false): BlankLineProbe? =
    blankLineProbes[blankLineKey(text, CIMeta.getSample(0, previewDate, text, status), showTimestamp)]

  private fun json(v: Any?): String = when (v) {
    null -> "null"
    is String -> "\"" + v.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
    is Number, is Boolean -> v.toString()
    is Map<*, *> -> v.entries.joinToString(",", "{", "}") { json(it.key.toString()) + ":" + json(it.value) }
    is List<*> -> v.joinToString(",", "[", "]") { json(it) }
    else -> json(v.toString())
  }

  private fun probeMap(p: BlankLineProbe?): Map<String, Any?>? = p?.let {
    mapOf("lines" to it.lines, "textEndLine" to it.textEndLine, "reserveStartLine" to it.reserveStartLine, "height" to it.height, "maxWidth" to it.maxWidth, "textEndX" to it.textEndX, "lineHeight" to it.lineHeight)
  }

  @Test
  fun renderBlankLineOptions() {
    val locale = Locale.getDefault()
    val timeZone = TimeZone.getDefault()
    val theme = appPrefs.currentTheme.get()!!
    val fontScale = appPrefs.fontScale.get()
    val densityScale = appPrefs.densityScale.get()
    val oneHandUI = appPrefs.oneHandUI.get()
    val chatBottomBar = appPrefs.chatBottomBar.get()
    val chatItemRoundness = appPrefs.chatItemRoundness.get()
    val chatItemTail = appPrefs.chatItemTail.get()
    val report = mutableMapOf<String, Any?>()
    try {
      Locale.setDefault(Locale.US)
      TimeZone.setDefault(TimeZone.getTimeZone("UTC"))
      appPrefs.densityScale.set(1f)
      appPrefs.oneHandUI.set(true)
      appPrefs.chatBottomBar.set(true)
      appPrefs.chatItemRoundness.set(0.75f)
      appPrefs.chatItemTail.set(true)
      ThemeManager.applyTheme(DefaultTheme.LIGHT.themeName)
      for (scale in listOf(1f, 1.5f)) {
        appPrefs.fontScale.set(scale)
        val widths = mutableMapOf<String, Int>()
        render(1f, 200) { SimpleXTheme { BubblePreview { MetaWidths(widths) } } }
        report["widths-${(scale * 100).roundToInt()}"] = widths.toMap()
      }
      val batches = candidates.chunked(6).map { batch -> batch.mapIndexed { i, t -> rcv(100L + i, alice, t, CIStatus.RcvRead()) } + rcv(999, alice, "ok", CIStatus.RcvRead()) }
      val layouts = listOf("classic" to (false to false), "flat" to (true to false), "flat8169" to (true to true))
      val modes = listOf("master" to 0, "a" to 1, "b" to 2, "c2" to 3, "c1" to 4)
      for ((layout, flags) in layouts) {
        val (terminal, flatBreak) = flags
        for (scale in listOf(1f, 1.5f)) {
          val font = (scale * 100).roundToInt()
          appPrefs.fontScale.set(scale)
          blankLineFlatBreak = flatBreak
          blankLineForcedTimestamps.clear()
          val sweep = mutableMapOf<String, Map<String, BlankLineProbe?>>()
          for ((mode, m) in modes.take(3)) {
            blankLineMode = m
            blankLineProbes.clear()
            for (batch in batches) render(2f, 3200) { Scene(batch, terminal) }
            sweep[mode] = candidates.associateWith { probe(it, CIStatus.RcvRead()) }
          }
          fun adds(mode: String, t: String): Boolean {
            val p = sweep[mode]?.get(t) ?: return false
            val base = sweep["a"]?.get(t) ?: return false
            return p.lines > base.lines
          }
          val masterHits = candidates.filter { adds("master", it) }
          val bHits = candidates.filter { adds("b", it) }
          val chosen = candidates.firstOrNull { it in masterHits && it in bHits } ?: masterHits.firstOrNull() ?: candidates.last()
          blankLineForcedTimestamps.addAll(masterHits)
          val items = listOf(
            rcv(1, bob, "Here is the plan for this week.", CIStatus.RcvRead(), 0),
            rcv(2, alice, "Agreed.", CIStatus.RcvRead(), 25),
            rcv(3, alice, chosen, CIStatus.RcvRead(), 30),
            rcv(4, alice, chosen, CIStatus.RcvNew(), 35),
            rcv(5, alice, "ok", CIStatus.RcvNew(), 40)
          )
          val finals = mutableMapOf<String, Any?>()
          for ((mode, m) in modes) {
            blankLineMode = m
            blankLineProbes.clear()
            val image = render(2f, 874) { Scene(items, terminal) }
            File(outDir, "blankline-$layout-$font-$mode.png").writeBytes(image.encodeToData(EncodedImageFormat.PNG)!!.bytes)
            val forced = m == 3 && chosen in blankLineForcedTimestamps
            finals[mode] = mapOf(
              "read" to probeMap(probe(chosen, CIStatus.RcvRead(), forced)),
              "unread" to probeMap(probe(chosen, CIStatus.RcvNew(), forced))
            )
          }
          report["$layout-$font"] = mapOf(
            "chosen" to chosen,
            "candidates" to candidates.size,
            "missingProbes" to modes.take(3).associate { (mode, _) -> mode to candidates.count { sweep[mode]?.get(it) == null } },
            "masterAddsLine" to masterHits.size,
            "bAddsLine" to bHits.size,
            "masterBlankLine" to candidates.count { t -> sweep["master"]?.get(t)?.let { it.reserveStartLine > it.textEndLine } == true },
            "bBlankLine" to candidates.count { t -> sweep["b"]?.get(t)?.let { it.reserveStartLine > it.textEndLine } == true },
            "sweep" to candidates.associateWith { t -> mapOf("master" to probeMap(sweep["master"]?.get(t)), "a" to probeMap(sweep["a"]?.get(t)), "b" to probeMap(sweep["b"]?.get(t))) },
            "finals" to finals
          )
        }
      }
      File(outDir, "blankline-measurements.json").writeText(json(report))
    } finally {
      blankLineMode = 0
      blankLineFlatBreak = false
      blankLineForcedTimestamps.clear()
      Locale.setDefault(locale)
      TimeZone.setDefault(timeZone)
      appPrefs.fontScale.set(fontScale)
      appPrefs.densityScale.set(densityScale)
      appPrefs.oneHandUI.set(oneHandUI)
      appPrefs.chatBottomBar.set(chatBottomBar)
      appPrefs.chatItemRoundness.set(chatItemRoundness)
      appPrefs.chatItemTail.set(chatItemTail)
      ThemeManager.applyTheme(theme)
    }
  }
}
