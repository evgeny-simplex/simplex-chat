package chat.simplex.app

import androidx.compose.desktop.ui.tooling.preview.Preview
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import chat.simplex.common.model.*
import chat.simplex.common.platform.chatModel
import chat.simplex.common.ui.theme.SimpleXTheme
import chat.simplex.common.views.chat.ComposeMessage
import chat.simplex.common.views.chat.ComposePreview
import chat.simplex.common.views.chat.ComposeState
import chat.simplex.common.views.chat.item.previewDate
import chat.simplex.common.views.chatlist.*
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.net.URI
import java.util.Base64
import javax.imageio.ImageIO

@Preview
@Composable
fun ChatListContacts() = ChatListScene { it.contacts() }

@Preview
@Composable
fun ChatListConnecting() = ChatListScene { it.connecting() }

@Preview
@Composable
fun ChatListPending() = ChatListScene { it.pending() }

@Preview
@Composable
fun ChatListGroups() = ChatListScene { it.groups() }

@Preview
@Composable
fun ChatListGroupStates() = ChatListScene { it.groupStates() }

@Preview
@Composable
fun ChatListFlags() = ChatListScene { it.flags() }

@Preview
@Composable
fun ChatListUnread() = ChatListScene { it.unread() }

@Preview
@Composable
fun ChatListMarks() = ChatListScene { it.marks() }

@Preview
@Composable
fun ChatListMedia() = ChatListScene { it.media() }

@Preview
@Composable
fun ChatListText() = ChatListScene { it.text() }

@Preview
@Composable
fun ChatListDeleted() = ChatListScene { it.deleted() }

@Preview
@Composable
fun ChatListLong() = ChatListScene { it.long() }

@Preview
@Composable
fun ChatListDrafts() = ChatListScene { it.drafts() }

@Composable
private fun ChatListScene(rows: @Composable (ChatListFixtures) -> Unit) {
  val fixtures = remember { ChatListFixtures() }
  SimpleXTheme {
    Column {
      rows(fixtures)
    }
  }
}

private fun imageBase64(color: java.awt.Color, width: Int, height: Int): String {
  val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
  val g = image.createGraphics()
  g.color = color
  g.fillRect(0, 0, width, height)
  g.color = java.awt.Color(255, 255, 255, 102)
  g.fillOval((width * 0.55).toInt(), (height * 0.15).toInt(), (height * 0.4).toInt(), (height * 0.4).toInt())
  g.dispose()
  val out = ByteArrayOutputStream()
  ImageIO.write(image, "png", out)
  return "data:image/png;base64," + Base64.getEncoder().encodeToString(out.toByteArray())
}

private class ChatListFixtures {
  private var nextId = 100L
  private val photo = imageBase64(java.awt.Color(217, 115, 77), 64, 64)
  private val photo2 = imageBase64(java.awt.Color(140, 89, 191), 64, 64)
  private val landscape = imageBase64(java.awt.Color(64, 140, 89), 320, 200)
  private val link = CreatedConnLink("https://simplex.chat/contact#/?v=2-7&smp=smp%3A%2F%2Fexample.simplex.im", null)
  private val alice = member(2, "alice", photo)
  private val bob = member(3, "bob")
  private val carol = member(4, "carol", photo2)

  private fun newId(): Long = ++nextId

  private fun member(id: Long, name: String, image: String? = null): GroupMember =
    GroupMember.sampleData.copy(
      groupMemberId = id,
      memberId = "member-$id",
      localDisplayName = name,
      memberProfile = LocalProfile(profileId = id, displayName = name, fullName = "", shortDescr = null, image = image, localAlias = "")
    )

  private fun badge(type: BadgeType, status: BadgeStatus) = LocalBadge(BadgeInfo(type, previewDate), status)

  private fun contact(
    name: String,
    fullName: String = "",
    image: String? = null,
    peerType: ChatPeerType? = null,
    badge: LocalBadge? = null,
    contactLink: String? = null,
    ntfs: MsgFilter = MsgFilter.All,
    favorite: Boolean = false,
    activeConn: Connection? = Connection.sampleData
  ): Contact {
    val id = newId()
    return Contact.sampleData.copy(
      contactId = id,
      localDisplayName = name,
      profile = LocalProfile(
        profileId = id, displayName = name, fullName = fullName, shortDescr = null, image = image, localAlias = "",
        contactLink = contactLink, peerType = peerType, localBadge = badge
      ),
      activeConn = activeConn,
      chatSettings = ChatSettings(enableNtfs = ntfs, sendRcpts = null, favorite = favorite),
      createdAt = previewDate,
      updatedAt = previewDate,
      chatTs = previewDate
    )
  }

  private fun group(
    name: String,
    fullName: String = "",
    status: GroupMemberStatus = GroupMemberStatus.MemComplete,
    incognito: Boolean = false,
    ntfs: MsgFilter = MsgFilter.All
  ): GroupInfo =
    GroupInfo.sampleData.copy(
      groupId = newId(),
      localDisplayName = name,
      groupProfile = GroupProfile(displayName = name, fullName = fullName, shortDescr = null),
      membership = GroupMember.sampleData.copy(
        memberRole = GroupMemberRole.Admin,
        memberStatus = status,
        memberProfile = if (incognito) LocalProfile(profileId = 50, displayName = "Fluffy Panda", fullName = "", shortDescr = null, localAlias = "") else LocalProfile.sampleData
      ),
      chatSettings = ChatSettings(enableNtfs = ntfs, sendRcpts = null, favorite = false),
      createdAt = previewDate,
      updatedAt = previewDate,
      chatTs = previewDate
    )

  private fun business(name: String, type: BusinessChatType): GroupInfo =
    group(name).copy(businessChat = BusinessChatInfo(chatType = type, businessId = "business", customerId = "customer"))

  private fun prepared(g: GroupInfo): GroupInfo =
    g.copy(preparedGroup = PreparedGroup(connLinkToConnect = link, connLinkPreparedConnection = false, connLinkStartedConnection = false))

  private fun channel(name: String): GroupInfo {
    val g = group(name)
    return g.copy(useRelays = true, groupProfile = g.groupProfile.copy(publicGroup = PublicGroupProfile(GroupType.Channel, "", "news")))
  }

  private fun notes(): NoteFolder =
    NoteFolder(noteFolderId = newId(), favorite = false, unread = false, createdAt = previewDate, updatedAt = previewDate, chatTs = previewDate)

  private fun connection(status: ConnStatus, viaContactUri: Boolean, groupLinkId: String? = null, incognito: Boolean = false, alias: String = "") =
    PendingContactConnection(
      pccConnId = newId(),
      pccAgentConnId = "agent-conn",
      pccConnStatus = status,
      viaContactUri = viaContactUri,
      groupLinkId = groupLinkId,
      customUserProfileId = if (incognito) 50 else null,
      localAlias = alias,
      createdAt = previewDate,
      updatedAt = previewDate
    )

  private fun file(name: String, sent: Boolean = false): CIFile =
    CIFile.getSample(fileId = newId(), fileName = name, fileSize = 184_320, filePath = null, fileStatus = if (sent) CIFileStatus.SndComplete else CIFileStatus.RcvInvitation)

  private fun item(
    dir: CIDirection,
    text: String,
    content: MsgContent = MsgContent.MCText(text),
    status: CIStatus? = null,
    file: CIFile? = null,
    formattedText: List<FormattedText>? = null,
    mentions: Map<String, CIMention>? = null,
    deleted: CIDeleted? = null
  ): ChatItem =
    ChatItem(
      chatDir = dir,
      meta = CIMeta.getSample(newId(), previewDate, text, status ?: if (dir.sent) CIStatus.SndSent(SndCIStatusProgress.Complete) else CIStatus.RcvRead(), itemDeleted = deleted),
      content = if (dir.sent) CIContent.SndMsgContent(content) else CIContent.RcvMsgContent(content),
      formattedText = formattedText,
      mentions = mentions,
      reactions = listOf(),
      file = file
    )

  private fun mentionItem(g: GroupInfo, sender: GroupMember, rest: String): ChatItem =
    item(
      CIDirection.GroupRcv(sender),
      "@alice$rest",
      formattedText = listOf(FormattedText("@alice", Format.Mention("alice")), FormattedText(rest)),
      mentions = mapOf("alice" to CIMention(g.membership))
    )

  @Composable
  private fun ChatRow(
    chatInfo: ChatInfo,
    items: List<ChatItem> = listOf(),
    stats: Chat.ChatStats = Chat.ChatStats(),
    showChatPreviews: Boolean = true,
    draft: ComposeState? = null,
    disabled: Boolean = false,
    progressByTimeout: Boolean = false,
    selected: Boolean = false,
    nextSelected: Boolean = false
  ) {
    val chat = Chat(remoteHostId = null, chatInfo = chatInfo, chatItems = items, chatStats = stats)
    ChatListNavLinkLayout(
      chatLinkPreview = {
        when (chatInfo) {
          is ChatInfo.ContactRequest -> ContactRequestView(chatInfo)
          is ChatInfo.ContactConnection -> ContactConnectionView(chatInfo.contactConnection)
          else -> ChatPreviewView(
            chat, showChatPreviews, draft, if (draft != null) chat.id else null, null, disabled, SimplexLinkMode.DESCRIPTION,
            inProgress = false, progressByTimeout = progressByTimeout, defaultClickAction = {}
          )
        }
      },
      click = {},
      dropdownMenuItems = null,
      showMenu = remember { mutableStateOf(false) },
      disabled = disabled,
      selectedChat = remember { mutableStateOf(selected) },
      nextChatSelected = remember { mutableStateOf(nextSelected) },
    )
  }

  @Composable
  private fun DeletingRow(chatInfo: ChatInfo, items: List<ChatItem>) {
    remember { chatModel.deletedChats.value = listOf<Pair<Long?, String>>(null to chatInfo.id) }
    DisposableEffect(Unit) { onDispose { chatModel.deletedChats.value = emptyList() } }
    ChatRow(chatInfo, items, disabled = true)
  }

  @Composable
  private fun ErrorRow() {
    ChatListNavLinkLayout(
      chatLinkPreview = { ErrorChatListItem() },
      click = {},
      dropdownMenuItems = null,
      showMenu = remember { mutableStateOf(false) },
      disabled = false,
      selectedChat = remember { mutableStateOf(false) },
      nextChatSelected = remember { mutableStateOf(false) },
    )
  }

  @Composable
  fun contacts() {
    ChatRow(
      ChatInfo.Direct(contact("alice", "Alice", photo, activeConn = Connection.sampleData.copy(connectionCode = SecurityCode("123 456", previewDate)))),
      listOf(item(CIDirection.DirectRcv(), "Hi! Are you coming tonight?"))
    )
    ChatRow(ChatInfo.Direct(contact("bob", badge = badge(BadgeType.Supporter, BadgeStatus.Active))), listOf(item(CIDirection.DirectSnd(), "Sure, see you at 7")))
    ChatRow(ChatInfo.Direct(contact("carol", badge = badge(BadgeType.Legend, BadgeStatus.Expired))), listOf(item(CIDirection.DirectRcv(), "Thanks for the photos")))
    ChatRow(ChatInfo.Direct(contact("dan", badge = badge(BadgeType.Investor, BadgeStatus.Failed))), listOf(item(CIDirection.DirectRcv(), "Did you get my message?")))
    ChatRow(ChatInfo.Direct(contact("SimpleX Directory", peerType = ChatPeerType.Bot)), listOf(item(CIDirection.DirectRcv(), "Send a group name to search")))
    ChatRow(ChatInfo.Direct(contact("Assistant", peerType = ChatPeerType.Agent)), listOf(item(CIDirection.DirectRcv(), "Here is a summary of today's messages")))
    ChatRow(ChatInfo.Direct(contact("erin", activeConn = Connection.sampleData.copy(customUserProfileId = 50))), listOf(item(CIDirection.DirectRcv(), "Nice to meet you")))
    ChatRow(
      ChatInfo.Direct(
        contact("frank", badge = badge(BadgeType.Supporter, BadgeStatus.Active), activeConn = Connection.sampleData.copy(connStatus = ConnStatus.Deleted))
          .copy(contactStatus = ContactStatus.Deleted)
      ),
      listOf(item(CIDirection.DirectRcv(), "Bye!"))
    )
  }

  @Composable
  fun connecting() {
    val joining = Connection.sampleData.copy(connStatus = ConnStatus.Joined)
    val preparedContact = PreparedContact(connLinkToConnect = link, uiConnLinkType = ConnectionMode.Con)
    val memberInvitation = GroupDirectInvitation("simplex_link", fromGroupId_ = 1, fromGroupMemberId_ = 1, fromGroupMemberConnId_ = 1, groupDirectInvStartedConnection = false)
    val requestId = newId()
    val request = UserContactRequest(
      contactRequestId = requestId,
      cReqChatVRange = VersionRange(1, 1),
      localDisplayName = "mike",
      profile = LocalProfile(profileId = requestId, displayName = "mike", fullName = "Mike", shortDescr = null, localAlias = ""),
      createdAt = previewDate,
      updatedAt = previewDate
    )
    ChatRow(ChatInfo.Direct(contact("grace", activeConn = joining)))
    ChatRow(ChatInfo.Direct(contact("heidi", activeConn = joining).copy(preparedContact = preparedContact)))
    ChatRow(ChatInfo.Direct(contact("ivan", activeConn = null).copy(preparedContact = preparedContact)))
    ChatRow(ChatInfo.Direct(contact("SimpleX Directory", peerType = ChatPeerType.Bot, activeConn = null).copy(preparedContact = preparedContact)))
    ChatRow(ChatInfo.Direct(contact("judy", activeConn = null).copy(contactRequestId = 7)))
    ChatRow(ChatInfo.Direct(contact("ken", activeConn = null).copy(groupDirectInv = memberInvitation)))
    ChatRow(ChatInfo.Direct(contact("laura", contactLink = link.connFullLink, activeConn = null)))
    ChatRow(ChatInfo.ContactRequest(request))
  }

  @Composable
  fun pending() {
    ChatRow(ChatInfo.ContactConnection(connection(ConnStatus.New, viaContactUri = false)))
    ChatRow(ChatInfo.ContactConnection(connection(ConnStatus.New, viaContactUri = true)))
    ChatRow(ChatInfo.ContactConnection(connection(ConnStatus.New, viaContactUri = true, groupLinkId = "group-link")))
    ChatRow(ChatInfo.ContactConnection(connection(ConnStatus.Joined, viaContactUri = false, incognito = true)))
    ChatRow(ChatInfo.ContactConnection(connection(ConnStatus.New, viaContactUri = false, incognito = true, alias = "Bob's laptop")))
    ChatListNavLinkView(Chat(remoteHostId = null, chatInfo = ChatInfo.InvalidJSON("{}"), chatItems = listOf()), remember { mutableStateOf(false) })
  }

  @Composable
  fun groups() {
    ChatRow(ChatInfo.Group(group("team", "My Team"), null), listOf(item(CIDirection.GroupRcv(alice), "Lunch at 1?")))
    ChatRow(ChatInfo.Group(channel("SimpleX news"), null), listOf(item(CIDirection.ChannelRcv(), "Version 7.1 is out")))
    ChatRow(ChatInfo.Group(business("Acme support", BusinessChatType.Business), null), listOf(item(CIDirection.GroupRcv(bob), "Your order has shipped")))
    ChatRow(ChatInfo.Group(business("nina", BusinessChatType.Customer), null), listOf(item(CIDirection.GroupSnd(), "Thank you for your order!")))
    ChatRow(ChatInfo.Local(notes()), listOf(item(CIDirection.LocalSnd(), "Buy milk and bread")))
    ChatRow(ChatInfo.Group(group("book club", status = GroupMemberStatus.MemInvited), null))
    ChatRow(ChatInfo.Group(group("night owls", status = GroupMemberStatus.MemInvited, incognito = true), null))
  }

  @Composable
  fun groupStates() {
    ChatRow(ChatInfo.Group(group("hiking", status = GroupMemberStatus.MemAccepted), null))
    ChatRow(ChatInfo.Group(group("book club", status = GroupMemberStatus.MemInvited), null), progressByTimeout = true)
    ChatRow(ChatInfo.Group(group("neighbours", status = GroupMemberStatus.MemPendingReview), null))
    ChatRow(ChatInfo.Group(prepared(group("SimpleX users")), null))
    ChatRow(ChatInfo.Group(prepared(business("Acme support", BusinessChatType.Business)), null))
    ChatRow(ChatInfo.Group(group("private club", status = GroupMemberStatus.MemRejected), null))
    ChatRow(ChatInfo.Group(group("old team", status = GroupMemberStatus.MemLeft), null), listOf(item(CIDirection.GroupRcv(bob), "See you all next year")))
  }

  @Composable
  fun flags() {
    ChatRow(ChatInfo.Group(group("moderators"), null), listOf(item(CIDirection.GroupRcv(bob), "Please check the reports")), Chat.ChatStats(reportsCount = 2))
    ChatRow(ChatInfo.Group(group("helpdesk").copy(membersRequireAttention = 1), null), listOf(item(CIDirection.GroupRcv(carol), "How do I join?")))
    ChatRow(ChatInfo.Group(group("night owls", incognito = true), null), listOf(item(CIDirection.GroupRcv(alice), "Good night everyone")))
    ChatRow(ChatInfo.Group(group("old project", status = GroupMemberStatus.MemRemoved), null), listOf(item(CIDirection.GroupRcv(bob), "Closing this group")))
    ChatRow(ChatInfo.Group(group("archive", status = GroupMemberStatus.MemGroupDeleted), null), listOf(item(CIDirection.GroupRcv(alice), "Thanks, everyone")))
  }

  @Composable
  fun unread() {
    val team = group("team", "My Team")
    ChatRow(ChatInfo.Direct(contact("alice", "Alice", photo)), listOf(item(CIDirection.DirectRcv(), "All messages are read")))
    ChatRow(ChatInfo.Direct(contact("bob")), listOf(item(CIDirection.DirectRcv(), "Three new messages")), Chat.ChatStats(unreadCount = 3))
    ChatRow(ChatInfo.Direct(contact("carol")), listOf(item(CIDirection.DirectRcv(), "Over a thousand new messages")), Chat.ChatStats(unreadCount = 1234))
    ChatRow(ChatInfo.Direct(contact("dan", ntfs = MsgFilter.None)), listOf(item(CIDirection.DirectRcv(), "Muted, five new messages")), Chat.ChatStats(unreadCount = 5))
    ChatRow(ChatInfo.Group(team, null), listOf(mentionItem(team, bob, " can you check the release notes?")), Chat.ChatStats(unreadCount = 4, unreadMentions = 1))
    ChatRow(ChatInfo.Group(team, null), listOf(mentionItem(team, carol, " are you there?")), Chat.ChatStats(unreadCount = 1, unreadMentions = 1))
    ChatRow(ChatInfo.Direct(contact("erin")), listOf(item(CIDirection.DirectRcv(), "Marked as unread")), Chat.ChatStats(unreadChat = true))
  }

  @Composable
  fun marks() {
    val quiet = group("announcements", ntfs = MsgFilter.Mentions)
    ChatRow(ChatInfo.Direct(contact("alice", ntfs = MsgFilter.None)), listOf(item(CIDirection.DirectRcv(), "Muted chat")))
    ChatRow(ChatInfo.Group(quiet, null), listOf(item(CIDirection.GroupRcv(bob), "Mentions only")))
    ChatRow(ChatInfo.Direct(contact("carol", favorite = true)), listOf(item(CIDirection.DirectRcv(), "Favorite chat")))
    ChatRow(ChatInfo.Direct(contact("dan", favorite = true)), listOf(item(CIDirection.DirectRcv(), "Favorite chat with two new messages")), Chat.ChatStats(unreadCount = 2))
    ChatRow(ChatInfo.Direct(contact("erin", ntfs = MsgFilter.None, favorite = true)), listOf(item(CIDirection.DirectRcv(), "Muted favorite chat")))
    ChatRow(ChatInfo.Group(quiet, null), listOf(mentionItem(quiet, bob, " the release is ready")), Chat.ChatStats(unreadCount = 3, unreadMentions = 1))
    ChatRow(ChatInfo.Local(notes()), listOf(item(CIDirection.LocalSnd(), "Unread notes")), Chat.ChatStats(unreadCount = 2))
  }

  @Composable
  fun media() {
    val linkPreview = LinkPreview(uri = "https://simplex.chat", title = "SimpleX Chat: private and secure messenger without any user IDs", description = "", image = landscape)
    ChatRow(ChatInfo.Direct(contact("alice")), listOf(item(CIDirection.DirectRcv(), "Sunset at the beach", MsgContent.MCImage("Sunset at the beach", landscape), file = file("sunset.jpg"))))
    ChatRow(ChatInfo.Direct(contact("bob")), listOf(item(CIDirection.DirectRcv(), "", MsgContent.MCImage("", landscape), file = file("photo.jpg"))))
    ChatRow(ChatInfo.Direct(contact("carol")), listOf(item(CIDirection.DirectRcv(), "", MsgContent.MCVideo("", landscape, 42), file = file("video.mp4"))))
    ChatRow(ChatInfo.Direct(contact("dan")), listOf(item(CIDirection.DirectRcv(), "", MsgContent.MCVoice("", 12), file = file("voice.m4a"))))
    ChatRow(ChatInfo.Direct(contact("erin")), listOf(item(CIDirection.DirectSnd(), "Listen to this", MsgContent.MCVoice("Listen to this", 34), file = file("voice.m4a", sent = true))))
    ChatRow(ChatInfo.Direct(contact("frank")), listOf(item(CIDirection.DirectRcv(), "", MsgContent.MCFile(""), file = file("report.pdf"))))
    ChatRow(
      ChatInfo.Direct(contact("grace")),
      listOf(item(CIDirection.DirectRcv(), "https://simplex.chat", MsgContent.MCLink("https://simplex.chat", linkPreview), formattedText = listOf(FormattedText("https://simplex.chat", Format.Uri()))))
    )
  }

  @Composable
  fun text() {
    val team = group("team", "My Team")
    val sharedContact = MsgChatLink.Contact(link.connFullLink, Profile(displayName = "carol", fullName = "Carol", shortDescr = "Designer in Lisbon", image = photo2), business = false)
    val sharedChannel = MsgChatLink.Group(
      link.connFullLink,
      GroupProfile(displayName = "SimpleX news", fullName = "", shortDescr = "Release announcements", publicGroup = PublicGroupProfile(GroupType.Channel, "", "news"))
    )
    ChatRow(ChatInfo.Direct(contact("alice")), listOf(item(CIDirection.DirectSnd(), "", MsgContent.MCChat("", sharedContact))))
    ChatRow(ChatInfo.Direct(contact("bob")), listOf(item(CIDirection.DirectRcv(), "", MsgContent.MCChat("", sharedChannel))))
    ChatRow(
      ChatInfo.Group(group("moderators"), null),
      listOf(item(CIDirection.GroupRcv(bob), "Spam links in every message", MsgContent.MCReport("Spam links in every message", ReportReason.Spam)))
    )
    ChatRow(ChatInfo.Direct(contact("carol")), listOf(item(CIDirection.DirectSnd(), "Are you there?", status = CIStatus.CISSndError(SndError.Auth()))))
    ChatRow(ChatInfo.Direct(contact("dan")), listOf(item(CIDirection.DirectSnd(), "I will call you later", status = CIStatus.SndWarning(SndError.Quota()))))
    ChatRow(
      ChatInfo.Direct(contact("erin")),
      listOf(item(CIDirection.DirectRcv(), "The door code is 4721", formattedText = listOf(FormattedText("The door code is "), FormattedText("4721", Format.Secret()))))
    )
    ChatRow(ChatInfo.Group(team, null), listOf(mentionItem(team, bob, " please review the draft")))
  }

  @Composable
  fun deleted() {
    val team = group("team", "My Team")
    ChatRow(ChatInfo.Direct(contact("alice")), listOf(item(CIDirection.DirectRcv(), "", MsgContent.MCImage("", landscape), file = file("photo.jpg"), deleted = CIDeleted.Deleted(previewDate))))
    ChatRow(ChatInfo.Group(team, null), listOf(item(CIDirection.GroupRcv(bob), "Buy cheap watches", deleted = CIDeleted.Moderated(previewDate, alice))))
    ChatRow(ChatInfo.Group(team, null), listOf(item(CIDirection.GroupRcv(carol), "Blocked message", deleted = CIDeleted.Blocked(previewDate))))
    ChatRow(ChatInfo.Group(team, null), listOf(item(CIDirection.GroupRcv(bob), "Blocked by admin", deleted = CIDeleted.BlockedByAdmin(previewDate))))
    ChatRow(
      ChatInfo.Group(group("moderators"), null),
      listOf(item(CIDirection.GroupRcv(bob), "Spam links in every message", MsgContent.MCReport("Spam links in every message", ReportReason.Spam), deleted = CIDeleted.Deleted(previewDate)))
    )
  }

  @Composable
  fun long() {
    val longText = "We are meeting at the station at eight, bring warm clothes, water and snacks for the whole day, the forecast says it will be cold"
    ChatRow(
      ChatInfo.Direct(contact("Alexandra Konstantinopoulou", "Alexandra Konstantinopoulou-Papadimitriou", badge = badge(BadgeType.Supporter, BadgeStatus.Active))),
      listOf(item(CIDirection.DirectRcv(), "Long names are cut at the end"))
    )
    ChatRow(ChatInfo.Group(group("Weekend trip planning committee", "Mountains, lakes and long walks"), null), listOf(item(CIDirection.GroupRcv(alice), longText)))
    ChatRow(ChatInfo.Direct(contact("لينا")), listOf(item(CIDirection.DirectRcv(), "مرحبا! هل ستأتي إلى الاجتماع غدا في الساعة العاشرة؟")))
    ChatRow(
      ChatInfo.Direct(contact("bob")),
      listOf(item(CIDirection.DirectRcv(), "Sunset at the beach", MsgContent.MCImage("Sunset at the beach", landscape), file = file("sunset.jpg"))),
      showChatPreviews = false
    )
    DeletingRow(ChatInfo.Direct(contact("carol")), listOf(item(CIDirection.DirectRcv(), "This chat is being deleted")))
    ChatRow(ChatInfo.Direct(contact("dan")), listOf(item(CIDirection.DirectRcv(), "Chat is stopped")), Chat.ChatStats(unreadCount = 2), disabled = true, nextSelected = true)
    ChatRow(ChatInfo.Direct(contact("erin")), listOf(item(CIDirection.DirectRcv(), "Selected chat")), selected = true)
    ErrorRow()
  }

  @Composable
  fun drafts() {
    val photoChat = ChatInfo.Direct(contact("alice", "Alice", photo))
    val image = listOf(item(CIDirection.DirectRcv(), "Sunset at the beach", MsgContent.MCImage("Sunset at the beach", landscape), file = file("sunset.jpg")))
    ChatRow(photoChat, image)
    ChatRow(photoChat, image, draft = ComposeState(message = ComposeMessage("Let me check and reply"), useLinkPreviews = false))
    ChatRow(
      ChatInfo.Direct(contact("bob")),
      listOf(item(CIDirection.DirectRcv(), "Can you send the report?")),
      draft = ComposeState(message = ComposeMessage("Here it is"), preview = ComposePreview.FilePreview("report.pdf", URI("file:///tmp/report.pdf")), useLinkPreviews = false)
    )
    ChatRow(
      ChatInfo.Direct(contact("carol")),
      listOf(item(CIDirection.DirectRcv(), "Tell me in a voice message")),
      draft = ComposeState(preview = ComposePreview.VoicePreview("voice.m4a", 12_000, true), useLinkPreviews = false)
    )
    ChatRow(
      ChatInfo.Direct(contact("dan")),
      listOf(item(CIDirection.DirectRcv(), "Any photos from the trip?")),
      draft = ComposeState(message = ComposeMessage("Look at this"), preview = ComposePreview.MediaPreview(listOf(landscape), listOf()), useLinkPreviews = false)
    )
  }
}
