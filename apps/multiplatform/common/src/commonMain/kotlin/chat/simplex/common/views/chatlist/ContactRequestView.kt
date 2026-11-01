package chat.simplex.common.views.chatlist

import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import dev.icerock.moko.resources.compose.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.simplex.common.model.ChatInfo
import chat.simplex.common.model.getTimestampText
import chat.simplex.common.views.helpers.*
import chat.simplex.res.*

@Composable
fun ContactRequestView(contactRequest: ChatInfo.ContactRequest) {
  ChatRowLayout(
    avatar = { ChatInfoImage(contactRequest, size = 72.dp * fontSizeSqrtMultiplier) },
    title = {
      NameWithBadge(
        contactRequest.chatViewName,
        contactRequest.nameBadge,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        style = MaterialTheme.typography.h3,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colors.primary,
      )
    },
    timestamp = getTimestampText(contactRequest.contactRequest.updatedAt),
    unread = {},
    status = { RailIcon(MR.images.ic_person_add_filled, MaterialTheme.colors.primary, stringResource(MR.strings.contact_wants_to_connect_with_you)) }
  ) {
    Text(
      stringResource(MR.strings.contact_wants_to_connect_with_you),
      maxLines = 2,
      overflow = TextOverflow.Ellipsis,
      style = chatPreviewTextStyle()
    )
  }
}
