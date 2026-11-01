package chat.simplex.common.views.chatlist

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.ui.theme.*
import chat.simplex.common.model.PendingContactConnection
import chat.simplex.common.model.getTimestampText
import chat.simplex.common.views.helpers.*
import chat.simplex.res.*

@Composable
fun ContactConnectionView(contactConnection: PendingContactConnection) {
  Row {
    Box(Modifier.size(72.dp * fontSizeSqrtMultiplier), contentAlignment = Alignment.Center) {
      ProfileImage(size = 54.dp * fontSizeSqrtMultiplier, null, if (contactConnection.initiated) MR.images.ic_add_link else MR.images.ic_link)
    }
    Column(
      modifier = Modifier
        .padding(start = 8.dp)
        .weight(1F)
    ) {
      Row {
        Text(
          contactConnection.displayName,
          Modifier.weight(1f),
          maxLines = 1,
          overflow = TextOverflow.Ellipsis,
          style = MaterialTheme.typography.h3,
          fontWeight = FontWeight.Bold,
          color = MaterialTheme.colors.secondary
        )
        Spacer(Modifier.width(8.sp.toDp()))
        val ts = getTimestampText(contactConnection.updatedAt)
        ChatListTimestampView(ts)
      }
      Row(Modifier.heightIn(min = 46.sp.toDp())) {
        Text(
          contactConnection.description,
          Modifier.padding(top = 3.sp.toDp()).weight(1f),
          maxLines = 2,
          style = TextStyle(
            fontFamily = Inter,
            fontSize = 15.sp,
            color = if (isInDarkTheme()) MessagePreviewDark else MessagePreviewLight,
            lineHeight = 21.sp
          )
        )
        Spacer(Modifier.width(8.sp.toDp()))
        Box(Modifier.widthIn(min = 34.sp.toDp()), contentAlignment = Alignment.TopEnd) {
          Box(
            Modifier.offset(y = 28.sp.toDp()),
            contentAlignment = Alignment.Center
          ) {
            IncognitoIcon(contactConnection.incognito)
          }
        }
      }
    }
  }
}
