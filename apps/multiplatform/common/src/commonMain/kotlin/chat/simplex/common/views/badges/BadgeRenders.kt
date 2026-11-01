package chat.simplex.common.views.badges

import androidx.compose.desktop.ui.tooling.preview.Preview
import androidx.compose.runtime.*
import chat.simplex.common.model.BadgeModel
import chat.simplex.common.model.BadgeState
import chat.simplex.common.model.BadgeType
import chat.simplex.common.views.onboarding.PreviewWhatsNewView
import kotlinx.datetime.Instant

@Composable
private fun WithShownBadge(type: BadgeType, content: @Composable () -> Unit) {
  remember {
    BadgeModel.badgeState.value = BadgeState(
      badgePurchaseId = 1,
      purchaseKey = "",
      badgeType = type,
      shown = true,
      monthsLeft = 1,
      paidThrough = Instant.parse("2026-12-15T00:00:00Z"),
      willRenew = false
    )
  }
  DisposableEffect(Unit) { onDispose { BadgeModel.badgeState.value = null } }
  content()
}

@Composable
private fun WithBadgeStateOfAnotherProfile(content: @Composable () -> Unit) {
  remember { BadgeModel.userId.value = 1L }
  DisposableEffect(Unit) { onDispose { BadgeModel.userId.value = null } }
  content()
}

@Preview
@Composable
fun PreviewWhatsNewWithBadge() {
  WithShownBadge(BadgeType.Supporter) { PreviewWhatsNewView() }
}

@Preview
@Composable
fun PreviewWhatsNewBadgeStateLoading() {
  WithBadgeStateOfAnotherProfile { PreviewWhatsNewView() }
}
