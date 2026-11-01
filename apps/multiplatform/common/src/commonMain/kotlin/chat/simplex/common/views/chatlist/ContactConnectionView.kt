package chat.simplex.common.views.chatlist

import androidx.compose.foundation.layout.*
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import chat.simplex.common.model.PendingContactConnection
import chat.simplex.common.model.getTimestampText
import chat.simplex.common.views.helpers.*
import chat.simplex.res.*

@Composable
fun ContactConnectionView(contactConnection: PendingContactConnection) {
  ChatRowLayout(
    avatar = {
      Box(Modifier.size(72.dp * fontSizeSqrtMultiplier), contentAlignment = Alignment.Center) {
        ProfileImage(size = 54.dp * fontSizeSqrtMultiplier, null, if (contactConnection.initiated) MR.images.ic_add_link else MR.images.ic_link)
      }
    },
    title = {
      Text(
        contactConnection.displayName,
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        style = MaterialTheme.typography.h3,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colors.secondary
      )
    },
    timestamp = getTimestampText(contactConnection.updatedAt),
    unread = {},
    status = { IncognitoIcon(contactConnection.incognito) }
  ) {
    Text(
      contactConnection.description,
      maxLines = 2,
      overflow = TextOverflow.Ellipsis,
      style = chatPreviewTextStyle()
    )
  }
}
