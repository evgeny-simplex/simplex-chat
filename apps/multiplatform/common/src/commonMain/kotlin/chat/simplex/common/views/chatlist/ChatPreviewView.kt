package chat.simplex.common.views.chatlist

import SectionItemView
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import dev.icerock.moko.resources.compose.painterResource
import dev.icerock.moko.resources.compose.stringResource
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.desktop.ui.tooling.preview.Preview
import androidx.compose.foundation.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.*
import androidx.compose.ui.unit.*
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.helpers.*
import chat.simplex.common.model.*
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.model.GroupInfo
import chat.simplex.common.platform.*
import chat.simplex.common.views.call.RcvCallInvitation
import chat.simplex.common.views.chat.*
import chat.simplex.common.views.newchat.planAndConnect
import chat.simplex.common.views.chat.item.*
import chat.simplex.res.*
import dev.icerock.moko.resources.ImageResource

// Spec: spec/client/chat-list.md#ChatPreviewView
@Composable
fun ChatPreviewView(
  chat: Chat,
  showChatPreviews: Boolean,
  chatModelDraft: ComposeState?,
  chatModelDraftChatId: ChatId?,
  currentUserProfileDisplayName: String?,
  disabled: Boolean,
  linkMode: SimplexLinkMode,
  inProgress: Boolean,
  progressByTimeout: Boolean,
  defaultClickAction: () -> Unit,
  callInvitation: RcvCallInvitation? = null,
  callInProgress: Boolean = false
) {
  val cInfo = chat.chatInfo
  val deleting by remember(disabled, chat.id) { mutableStateOf(chatModel.deletedChats.value.contains(chat.remoteHostId to chat.chatInfo.id)) }
  val draft = if (chatModelDraftChatId == chat.id) chatModelDraft else null

  @Composable
  fun inactiveIcon() {
    Icon(
      painterResource(MR.images.ic_cancel_filled),
      stringResource(MR.strings.icon_descr_group_inactive),
      Modifier.size(18.sp.toDp()).background(MaterialTheme.colors.background, CircleShape),
      tint = MaterialTheme.colors.secondary
    )
  }

  @Composable
  fun chatPreviewImageOverlayIcon() {
    when (cInfo) {
      is ChatInfo.Direct ->
        if (!cInfo.contact.active) {
          inactiveIcon()
        }
      is ChatInfo.Group ->
        when (cInfo.groupInfo.membership.memberStatus) {
          GroupMemberStatus.MemRejected -> inactiveIcon()
          GroupMemberStatus.MemLeft -> inactiveIcon()
          GroupMemberStatus.MemRemoved -> inactiveIcon()
          GroupMemberStatus.MemGroupDeleted -> inactiveIcon()
          else -> {}
      }
      else -> {}
    }
  }

  @Composable
  fun chatPreviewTitleText(color: Color = Color.Unspecified) {
    Text(
      cInfo.chatViewName,
      maxLines = 1,
      overflow = TextOverflow.Ellipsis,
      style = MaterialTheme.typography.h3,
      fontWeight = FontWeight.Bold,
      color = color
    )
  }

  @Composable
  fun VerifiedIcon() {
    Icon(painterResource(MR.images.ic_verified_user), null, Modifier.size(19.sp.toDp()).padding(end = 3.sp.toDp(), top = 1.sp.toDp()), tint = MaterialTheme.colors.secondary)
  }

  fun draftAttachmentText(draft: ComposeState): AnnotatedString? =
    when (draft.preview) {
      is ComposePreview.FilePreview -> AnnotatedString(draft.preview.fileName + " ")
      is ComposePreview.VoicePreview -> AnnotatedString(durationText(draft.preview.durationMs / 1000) + " ")
      else -> null
    }

  fun draftGlyph(draft: ComposeState): ImageResource =
    when (draft.preview) {
      is ComposePreview.FilePreview -> MR.images.ic_draft_filled
      is ComposePreview.MediaPreview -> MR.images.ic_image
      is ComposePreview.VoicePreview -> MR.images.ic_play_arrow_filled
      else -> MR.images.ic_edit_note
    }

  fun contentGlyph(mc: MsgContent?): ImageResource? =
    when (mc) {
      is MsgContent.MCLink -> MR.images.ic_link
      is MsgContent.MCImage -> MR.images.ic_image
      is MsgContent.MCVideo -> MR.images.ic_videocam
      is MsgContent.MCVoice -> MR.images.ic_play_arrow_filled
      is MsgContent.MCFile -> MR.images.ic_draft_filled
      is MsgContent.MCChat -> mc.chatLink.iconRes
      else -> null
    }

  @Composable
  fun chatPreviewTitle() {
    when (cInfo) {
      is ChatInfo.Direct -> {
        Row(verticalAlignment = Alignment.CenterVertically) {
          if (cInfo.contact.verified) {
            VerifiedIcon()
          }
          val color = if (deleting)
            MaterialTheme.colors.secondary
          else if ((cInfo.contact.nextAcceptContactRequest && cInfo.contact.groupDirectInv?.memberRemoved != true) || cInfo.contact.sendMsgToConnect) {
            MaterialTheme.colors.primary
          } else if (!cInfo.contact.sndReady) {
            MaterialTheme.colors.secondary
          } else {
            Color.Unspecified
          }
          NameWithBadge(
            cInfo.chatViewName,
            cInfo.nameBadge,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.h3,
            fontWeight = FontWeight.Bold,
            color = color
          )
        }
      }
      is ChatInfo.Group -> {
        val color = if (deleting) {
          MaterialTheme.colors.secondary
        } else {
          when (cInfo.groupInfo.membership.memberStatus) {
            GroupMemberStatus.MemInvited -> if (chat.chatInfo.incognito) Indigo else MaterialTheme.colors.primary
            GroupMemberStatus.MemAccepted, GroupMemberStatus.MemRejected -> MaterialTheme.colors.secondary
            else -> if (cInfo.groupInfo.nextConnectPrepared) MaterialTheme.colors.primary else Color.Unspecified
          }
        }
        chatPreviewTitleText(color = color)
      }
      else -> chatPreviewTitleText()
    }
  }

  @Composable
  fun chatPreviewInfoText(): Pair<String, Color>? {
    return when (cInfo) {
      is ChatInfo.Direct ->
        if (cInfo.contact.isContactCard) {
          stringResource(MR.strings.contact_tap_to_connect) to MaterialTheme.colors.primary
        } else if (cInfo.contact.isBot && cInfo.contact.nextConnectPrepared) {
          stringResource(MR.strings.open_to_use_bot) to Color.Unspecified
        } else if (cInfo.contact.sendMsgToConnect) {
          stringResource(MR.strings.open_to_connect) to Color.Unspecified
        } else if (cInfo.contact.nextAcceptContactRequest) {
          stringResource(MR.strings.open_to_accept) to Color.Unspecified
        } else if (!cInfo.contact.sndReady && cInfo.contact.activeConn != null && cInfo.contact.active) {
          if ((cInfo.contact.preparedContact?.uiConnLinkType == ConnectionMode.Con && !cInfo.contact.isBot) || cInfo.contact.contactGroupMemberId != null) {
            stringResource(MR.strings.contact_should_accept) to Color.Unspecified
          } else {
            stringResource(MR.strings.contact_connection_pending) to Color.Unspecified
          }
        } else {
          null
        }

      is ChatInfo.Group ->
        if (cInfo.groupInfo.nextConnectPrepared) {
          stringResource(
            if (cInfo.groupInfo.businessChat?.chatType == BusinessChatType.Business) MR.strings.open_to_connect
            else MR.strings.group_preview_open_to_join
          ) to Color.Unspecified
        } else {
          when (cInfo.groupInfo.membership.memberStatus) {
            GroupMemberStatus.MemRejected -> stringResource(MR.strings.group_preview_rejected) to Color.Unspecified
            GroupMemberStatus.MemInvited -> groupInvitationPreviewText(currentUserProfileDisplayName, cInfo.groupInfo) to Color.Unspecified
            GroupMemberStatus.MemAccepted -> stringResource(MR.strings.group_connection_pending) to Color.Unspecified
            GroupMemberStatus.MemPendingReview, GroupMemberStatus.MemPendingApproval ->
              stringResource(MR.strings.reviewed_by_admins) to MaterialTheme.colors.secondary
            else -> null
          }
        }

      else -> null
    }
  }

  @Composable
  fun chatPreviewText() {
    val previewText = chatPreviewInfoText()
    val ci = chat.chatItems.lastOrNull()
    if (draft != null) {
      MarkdownText(
        draft.message.text,
        formattedText = null,
        toggleSecrets = false,
        linkMode = linkMode,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        style = chatPreviewTextStyle(),
        modifier = Modifier.fillMaxWidth(),
        prefix = draftAttachmentText(draft)
      )
    } else if (ci?.content?.hasMsgContent != true && previewText != null) {
      Text(previewText.first, color = previewText.second, maxLines = 2, overflow = TextOverflow.Ellipsis, style = chatPreviewTextStyle())
    } else if (ci != null && showChatPreviews) {
      val (text: CharSequence, inlineTextContent) = when {
        ci.meta.itemDeleted != null -> markedDeletedText(ci, chat.chatInfo) to null
        ci.content.msgContent is MsgContent.MCChat -> {
          val chatLink = (ci.content.msgContent as MsgContent.MCChat).chatLink
          val descr = chatLink.shortDescription?.let { "\n$it" } ?: ""
          (chatLink.displayName + descr) to null
        }
        else -> ci.text(chat.chatInfo.isChannel) to null
      }
      val formattedText: List<FormattedText>? = when {
        ci.meta.itemDeleted != null -> null
        ci.content.msgContent is MsgContent.MCChat -> null
        else -> ci.formattedText
      }
      val prefix = when (ci.content.msgContent) {
        is MsgContent.MCReport ->
          buildAnnotatedString {
            withStyle(SpanStyle(color = Color.Red, fontStyle = FontStyle.Italic)) {
              append(itemPrefixText(ci))
            }
          }

        else -> null
      }

      MarkdownText(
        text,
        formattedText,
        if (formattedText == null) null else ci.markdownBlocks,
        sender = when {
          cInfo is ChatInfo.Group && !ci.chatDir.sent && !ci.meta.showGroupAsSender -> ci.memberDisplayName
          else -> null
        },
        mentions = ci.mentions,
        userMemberId = when {
          cInfo is ChatInfo.Group -> cInfo.groupInfo.membership.memberId
          else -> null
        },
        toggleSecrets = false,
        linkMode = linkMode,
        senderBold = true,
        maxLines = 2,
        overflow = TextOverflow.Ellipsis,
        style = chatPreviewTextStyle(),
        inlineContent = inlineTextContent,
        modifier = Modifier.fillMaxWidth(),
        prefix = prefix
      )
    }
  }

  @Composable
  fun chatItemContentPreview(chat: Chat, ci: ChatItem?) {
    val mc = ci?.content?.msgContent
    val provider by remember(chat.id, ci?.id, ci?.file?.fileStatus) {
      mutableStateOf({ providerForGallery(chat.chatItems, ci?.id ?: 0) {} })
    }
    val uriHandler = LocalUriHandler.current
    // Media in the chat list has no menu, so a menu opened from it must close at once, or the media stays revealed.
    val noMenu = remember { mutableStateOf(false) }
    LaunchedEffect(noMenu.value) { noMenu.value = false }
    when (mc) {
      is MsgContent.MCLink -> SmallContentPreview {
        val image = remember(mc.preview.image) { base64ToBitmap(mc.preview.image) }
        val blurred = remember { mutableStateOf(appPrefs.privacyMediaBlurRadius.get() > 0) }
        IconButton(
          { openBrowserAlert(mc.preview.uri, uriHandler) },
          Modifier.desktopPointerHoverIconHand(),
        ) {
          Image(image, null, Modifier.desktopModifyBlurredState(blurred, noMenu).privacyBlur(fullSize = false, image, blurred, chatViewScrollState.collectAsState()), contentScale = ContentScale.Crop)
        }
        Box(Modifier.align(Alignment.TopEnd).size(15.sp.toDp()).background(Color.Black.copy(0.25f), CircleShape), contentAlignment = Alignment.Center) {
          Icon(painterResource(MR.images.ic_arrow_outward), null, Modifier.size(13.sp.toDp()), tint = Color.White)
        }
      }
      is MsgContent.MCImage -> SmallContentPreview {
        CIImageView(image = mc.image, file = ci.file, provider, noMenu, smallView = true) {
          val user = chatModel.currentUser.value ?: return@CIImageView
          withBGApi { chatModel.controller.receiveFile(chat.remoteHostId, user, it) }
        }
      }
      is MsgContent.MCVideo -> SmallContentPreview {
        CIVideoView(image = mc.image, mc.duration, file = ci.file, provider, noMenu, smallView = true) {
          val user = chatModel.currentUser.value ?: return@CIVideoView
          withBGApi { chatModel.controller.receiveFile(chat.remoteHostId, user, it) }
        }
      }
      is MsgContent.MCVoice -> SmallContentPreviewVoice() {
        CIVoiceView(mc.duration, ci.file, ci.meta.itemEdited, ci.chatDir.sent, hasText = false, ci, cInfo.timedMessagesTTL, showViaProxy = false, showTimestamp = true, smallView = true, longClick = {}) {
          val user = chatModel.currentUser.value ?: return@CIVoiceView
          withBGApi { chatModel.controller.receiveFile(chat.remoteHostId, user, it) }
        }
      }
      is MsgContent.MCFile -> SmallContentPreviewFile {
        CIFileView(ci.file, ci.meta, cInfo.timedMessagesTTL, showViaProxy = false, showTimestamp = true, showMenu = remember { mutableStateOf(false) }, smallView = true) {
          val user = chatModel.currentUser.value ?: return@CIFileView
          withBGApi { chatModel.controller.receiveFile(chat.remoteHostId, user, it) }
        }
      }
      is MsgContent.MCChat -> SmallContentPreview(borderColor = if (mc.chatLink.image != null) MaterialTheme.colors.onSurface.copy(alpha = 0.12f) else Color.Transparent) {
        Box(
          Modifier.fillMaxSize().clickable { withBGApi { planAndConnect(chat.remoteHostId, mc.chatLink.connLinkStr, linkOwnerSig = mc.ownerSig, close = null) } },
          contentAlignment = Alignment.Center
        ) {
          val image = mc.chatLink.image
          if (image != null) {
            Image(base64ToBitmap(image), null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
          } else {
            Icon(painterResource(mc.chatLink.iconRes), null, Modifier.size(44.sp.toDp()), tint = if (isInDarkTheme()) FileDark else FileLight)
          }
        }
      }
      else -> {}
    }
  }

  @Composable
  fun progressView() {
    CircularProgressIndicator(
      Modifier.size(15.sp.toDp()),
      color = MaterialTheme.colors.secondary,
      strokeWidth = 1.5.dp
    )
  }

  val showNtfsIcon = !chat.chatInfo.ntfsEnabled(false) && (chat.chatInfo is ChatInfo.Direct || chat.chatInfo is ChatInfo.Group)

  @Composable
  fun unreadMark() {
    val n = chat.chatStats.unreadCount
    val ntfsMode = chat.chatInfo.chatSettings?.enableNtfs
    if (n > 0 || chat.chatStats.unreadChat) {
      UnreadBadge(
        text = if (n > 0) unreadCountStr(n) else "",
        backgroundColor = if (disabled || showNtfsIcon) MaterialTheme.colors.secondary else MaterialTheme.colors.primaryVariant,
        yOffset = 3.dp
      )
    } else if (showNtfsIcon && ntfsMode != null) {
      Icon(
        painterResource(ntfsMode.iconFilled),
        contentDescription = generalGetString(MR.strings.notifications),
        tint = MaterialTheme.colors.secondary,
        modifier = Modifier
          .padding(start = 2.sp.toDp())
          .size(18.sp.toDp())
          .offset(x = 2.5.sp.toDp(), y = 2.sp.toDp())
      )
    } else if (chat.chatInfo.chatSettings?.favorite == true) {
      Icon(
        painterResource(MR.images.ic_star_filled),
        contentDescription = generalGetString(MR.strings.favorite_chat),
        tint = MaterialTheme.colors.secondary,
        modifier = Modifier
          .size(20.sp.toDp())
          .offset(x = 2.5.sp.toDp())
      )
    }
  }

  @Composable
  fun mentionMark() {
    val mentionColor = when {
      disabled -> MaterialTheme.colors.secondary
      cInfo is ChatInfo.Group -> {
        val enableNtfs = cInfo.groupInfo.chatSettings.enableNtfs
        if (enableNtfs == MsgFilter.All || enableNtfs == MsgFilter.Mentions) MaterialTheme.colors.primaryVariant else MaterialTheme.colors.secondary
      }

      else -> if (showNtfsIcon) MaterialTheme.colors.secondary else MaterialTheme.colors.primaryVariant
    }
    Box(modifier = Modifier.size(15.sp.toDp()).background(mentionColor, shape = CircleShape), contentAlignment = Alignment.Center) {
      Icon(
        painterResource(MR.images.ic_alternate_email),
        contentDescription = generalGetString(MR.strings.notifications),
        tint = Color.White,
        modifier = Modifier.size(9.sp.toDp())
      )
    }
  }

  @Composable
  fun chatStatusImage() {
    val itemStatus = chat.chatItems.lastOrNull()?.meta?.itemStatus
    val requestMark = when {
      cInfo is ChatInfo.Direct && cInfo.contact.nextAcceptContactRequest && cInfo.contact.groupDirectInv?.memberRemoved != true ->
        Triple(MR.images.ic_person_add_filled, MaterialTheme.colors.primary, stringResource(MR.strings.contact_wants_to_connect_with_you))
      cInfo is ChatInfo.Group && cInfo.groupInfo.membership.memberStatus == GroupMemberStatus.MemInvited ->
        Triple(MR.images.ic_group_filled, if (cInfo.incognito) Indigo else MaterialTheme.colors.primary, stringResource(MR.strings.group_preview_you_are_invited))
      else -> null
    }
    if (progressByTimeout || deleting) {
      progressView()
    } else if (callInvitation != null) {
      RailIcon(MR.images.ic_ring_volume, MaterialTheme.colors.primary, callInvitation.callTitle)
    } else if (callInProgress) {
      RailIcon(MR.images.ic_phone_in_talk_filled, DarkGreen, stringResource(MR.strings.icon_descr_call_progress))
    } else if (itemStatus is CIStatus.CISSndError || itemStatus is CIStatus.SndErrorAuth) {
      RailIcon(MR.images.ic_error_filled, MaterialTheme.colors.error, stringResource(MR.strings.message_delivery_error_title))
    } else if (itemStatus is CIStatus.SndWarning) {
      RailIcon(MR.images.ic_warning_filled, WarningOrange, stringResource(MR.strings.message_delivery_warning_title))
    } else if (requestMark != null) {
      RailIcon(requestMark.first, requestMark.second, requestMark.third)
    } else if (chat.chatStats.unreadMentions > 0) {
      mentionMark()
    } else if (draft != null) {
      RailIcon(MR.images.ic_edit_note, MaterialTheme.colors.primary, stringResource(MR.strings.privacy_message_draft))
    } else if (chat.chatStats.reportsCount > 0) {
      FlagIcon(color = MaterialTheme.colors.error)
    } else if (chat.supportUnreadCount > 0) {
      FlagIcon(color = MaterialTheme.colors.primary)
    } else if (chat.chatInfo.groupInfo_?.membership?.memberPending == true) {
      FlagIcon(color = MaterialTheme.colors.secondary)
    } else {
      IncognitoIcon(chat.chatInfo.incognito)
    }
  }

  ChatRowLayout(
    avatar = {
      Box(contentAlignment = Alignment.BottomEnd) {
        ChatInfoImage(cInfo, size = 72.dp * fontSizeSqrtMultiplier)
        Box(Modifier.padding(end = 6.sp.toDp(), bottom = 6.sp.toDp())) {
          chatPreviewImageOverlayIcon()
        }
      }
    },
    title = { chatPreviewTitle() },
    timestamp = getTimestampText(chat.chatItems.lastOrNull()?.meta?.itemTs ?: chat.chatInfo.chatTs),
    unread = { unreadMark() },
    status = { chatStatusImage() }
  ) {
    val activeVoicePreview: MutableState<(ActiveVoicePreview)?> = remember(chat.id) { mutableStateOf(null) }
    val chat = activeVoicePreview.value?.chat ?: chat
    val ci = activeVoicePreview.value?.ci ?: chat.chatItems.lastOrNull()
    val mc = ci?.content?.msgContent
    val deleted = ci?.isDeletedContent == true || ci?.meta?.itemDeleted != null
    val showContentPreview = showChatPreviews || activeVoicePreview.value != null
    if (ci != null && showContentPreview) {
      when {
        draft != null -> GlyphContentPreview(if (contentGlyph(mc) != null) draftGlyph(draft) else null, MaterialTheme.colors.primary)
        deleted -> GlyphContentPreview(contentGlyph(mc), MaterialTheme.colors.secondary)
        else -> key(ci.id) { chatItemContentPreview(chat, ci) }
      }
    }
    if (mc !is MsgContent.MCVoice || !showContentPreview || mc.text.isNotEmpty() || draft != null || deleted) {
      Box(Modifier.offset(x = if (mc is MsgContent.MCFile && !deleted && draft == null) -15.sp.toDp() else 0.dp)) {
        chatPreviewText()
      }
    }
    LaunchedEffect(AudioPlayer.currentlyPlaying.value, activeVoicePreview.value) {
      val playing = AudioPlayer.currentlyPlaying.value
      when {
        playing == null -> activeVoicePreview.value = null
        activeVoicePreview.value == null -> if (mc is MsgContent.MCVoice && playing.fileSource.filePath == ci.file?.fileSource?.filePath) {
          activeVoicePreview.value = ActiveVoicePreview(chat, ci, mc)
        }

        else -> if (playing.fileSource.filePath != ci?.file?.fileSource?.filePath) {
          activeVoicePreview.value = null
        }
      }
    }
    LaunchedEffect(chatModel.deletedChats.value) {
      val voicePreview = activeVoicePreview.value
      // Stop voice when deleting the chat
      if (chatModel.deletedChats.value.contains(chatModel.remoteHostId() to chat.id) && voicePreview?.ci != null) {
        AudioPlayer.stop(voicePreview.ci)
      }
    }
  }
}

@Composable
fun ChatRowLayout(
  avatar: @Composable () -> Unit,
  title: @Composable () -> Unit,
  timestamp: String?,
  unread: @Composable () -> Unit,
  status: @Composable () -> Unit,
  body: @Composable RowScope.() -> Unit
) {
  Row {
    avatar()
    Spacer(Modifier.width(8.dp))
    Column(Modifier.weight(1f)) {
      Row {
        Box(Modifier.weight(1f)) {
          title()
        }
        if (timestamp != null) {
          Spacer(Modifier.width(8.sp.toDp()))
          ChatListTimestampView(timestamp)
        }
      }
      Row(Modifier.heightIn(min = 46.sp.toDp()).fillMaxWidth()) {
        Row(Modifier.padding(top = 3.sp.toDp()).weight(1f)) {
          body()
        }

        Spacer(Modifier.width(8.sp.toDp()))

        Box(Modifier.widthIn(min = 34.sp.toDp()), contentAlignment = Alignment.TopEnd) {
          unread()
          Box(
            Modifier.offset(y = 28.sp.toDp()).size(21.sp.toDp()),
            contentAlignment = Alignment.Center
          ) {
            status()
          }
        }
      }
    }
  }
}

@Composable
fun chatPreviewTextStyle(): TextStyle =
  TextStyle(
    fontFamily = Inter,
    fontSize = 15.sp,
    color = if (isInDarkTheme()) MessagePreviewDark else MessagePreviewLight,
    lineHeight = 21.sp
  )

@Composable
private fun GlyphContentPreview(glyph: ImageResource?, color: Color) {
  if (glyph != null) {
    SmallContentPreview {
      Icon(painterResource(glyph), null, Modifier.align(Alignment.Center).size(18.sp.toDp()), tint = color)
    }
  }
}

@Composable
fun RailIcon(icon: ImageResource, color: Color, contentDescription: String) {
  Icon(painterResource(icon), contentDescription, Modifier.size(21.sp.toDp()), tint = color)
}

private val DarkGreen = Color(0, 128, 0)

@Composable
private fun SmallContentPreview(borderColor: Color = MaterialTheme.colors.onSurface.copy(alpha = 0.12f), content: @Composable BoxScope.() -> Unit) {
  Box(Modifier.padding(top = 2.sp.toDp(), end = 8.sp.toDp()).size(36.sp.toDp()).border(0.5.dp, borderColor, RoundedCornerShape(22)).clip(RoundedCornerShape(22))) {
    content()
  }
}

@Composable
private fun SmallContentPreviewVoice(content: @Composable () -> Unit) {
  Box(Modifier.padding(top = 2.sp.toDp(), end = 8.sp.toDp()).height(voiceMessageSizeBasedOnSquareSize(36f).sp.toDp())) {
    content()
  }
}

@Composable
private fun SmallContentPreviewFile(content: @Composable () -> Unit) {
  Box(Modifier.padding(top = 3.sp.toDp(), end = 8.sp.toDp()).offset(x = -8.sp.toDp(), y = -4.sp.toDp()).height(41.sp.toDp())) {
    content()
  }
}

@Composable
fun IncognitoIcon(incognito: Boolean) {
  if (incognito) {
    Icon(
      painterResource(MR.images.ic_theater_comedy),
      contentDescription = null,
      tint = MaterialTheme.colors.secondary,
      modifier = Modifier
        .size(21.sp.toDp())
        .offset(x = 1.sp.toDp())
    )
  }
}

@Composable
fun FlagIcon(color: Color) {
  Icon(
    painterResource(MR.images.ic_flag),
    contentDescription = null,
    tint = color,
    modifier = Modifier
      .size(21.sp.toDp())
      .offset(x = 2.sp.toDp())
  )
}

@Composable
private fun groupInvitationPreviewText(currentUserProfileDisplayName: String?, groupInfo: GroupInfo): String {
  return if (groupInfo.membership.memberIncognito)
    String.format(stringResource(MR.strings.group_preview_join_as), groupInfo.membership.memberProfile.displayName)
  else
    stringResource(MR.strings.group_preview_you_are_invited)
}

@Composable
fun UnreadBadge(
  text: String,
  backgroundColor: Color,
  yOffset: Dp? = null
) {
  Text(
    text,
    color = Color.White,
    fontSize = 10.sp,
    style = TextStyle(textAlign = TextAlign.Center),
    modifier = Modifier
      .offset(y = yOffset ?: 0.dp)
      .background(backgroundColor, shape = CircleShape)
      .badgeLayout()
      .padding(horizontal = 2.sp.toDp())
      .padding(vertical = 1.sp.toDp())
  )
}

@Composable
fun unreadCountStr(n: Int): String {
  return if (n < 1000) "$n" else "${n / 1000}" + stringResource(MR.strings.thousand_abbreviation)
}

@Composable fun ChatListTimestampView(ts: String) {
  Box(contentAlignment = Alignment.BottomStart) {
    // This should be the same font style as in title to make date located on the same line as title
    Text(
      " ",
      style = MaterialTheme.typography.h3,
      fontWeight = FontWeight.Bold,
    )
    Text(
      ts,
      Modifier.padding(bottom = 5.sp.toDp()).offset(x = if (appPlatform.isDesktop) 1.5.sp.toDp() else 0.dp),
      color = MaterialTheme.colors.secondary,
      style = MaterialTheme.typography.body2.copy(fontSize = 13.sp),
    )
  }
}

private data class ActiveVoicePreview(
  val chat: Chat,
  val ci: ChatItem,
  val mc: MsgContent.MCVoice
)

@Preview/*(
  uiMode = Configuration.UI_MODE_NIGHT_YES,
  showBackground = true,
  name = "Dark Mode"
)*/
@Composable
fun PreviewChatPreviewView() {
  SimpleXTheme {
    ChatPreviewView(Chat.sampleData.copy(chatItems = Chat.sampleData.chatItems.map(::previewDated)), true, null, null, "", disabled = false, linkMode = SimplexLinkMode.DESCRIPTION, inProgress = false, progressByTimeout = false, {})
  }
}
