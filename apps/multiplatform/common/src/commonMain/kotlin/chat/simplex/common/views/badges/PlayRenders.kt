package chat.simplex.common.views.badges

import androidx.compose.desktop.ui.tooling.preview.Preview
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import chat.simplex.common.platform.androidPlayStoreCountry
import chat.simplex.common.ui.theme.SimpleXTheme
import chat.simplex.common.views.helpers.ModalManager

@Composable
private fun PlayRender(content: @Composable () -> Unit) {
  androidPlayStoreCountry.value = "US"
  SimpleXTheme {
    Box(Modifier.fillMaxWidth().height(874.dp)) { content() }
  }
}

@Preview
@Composable
fun PreviewCheckPlaySupport() {
  PlayRender { BadgesSupportSimplexView(ModalManager.start, 0) }
}

@Preview
@Composable
fun PreviewCheckPlayChoose() {
  PlayRender { BadgesChooseBadgeView(ModalManager.start, 0) }
}

@Preview
@Composable
fun PreviewCheckPlayHowLong() {
  PlayRender { BadgesHowLongView(BadgeLevel.Supporter, ModalManager.start, 0) }
}

@Preview
@Composable
fun PreviewCheckPlayCheckOrder() {
  PlayRender { BadgesCheckOrderView(BadgeLevel.Supporter, BadgePeriod.Monthly, ModalManager.start, 0) }
}
