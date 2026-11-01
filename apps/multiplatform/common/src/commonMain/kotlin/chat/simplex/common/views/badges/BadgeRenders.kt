package chat.simplex.common.views.badges

import androidx.compose.desktop.ui.tooling.preview.Preview
import androidx.compose.runtime.*
import chat.simplex.common.model.BadgeModel
import chat.simplex.common.model.BadgeState
import chat.simplex.common.model.BadgeType
import chat.simplex.common.ui.theme.SimpleXTheme
import chat.simplex.common.views.helpers.ModalManager
import chat.simplex.common.views.helpers.ModalView
import chat.simplex.common.views.onboarding.PreviewWhatsNewView
import chat.simplex.common.views.usersettings.PreviewSettingsLayout
import kotlinx.datetime.Instant

@Composable
private fun WithShownBadge(type: BadgeType, content: @Composable (BadgeState) -> Unit) {
  val state = remember {
    BadgeState(
      badgePurchaseId = 1,
      purchaseKey = "",
      badgeType = type,
      shown = true,
      monthsLeft = 1,
      paidThrough = Instant.parse("2026-12-15T00:00:00Z"),
      willRenew = false
    ).also { BadgeModel.badgeState.value = it }
  }
  DisposableEffect(Unit) { onDispose { BadgeModel.badgeState.value = null } }
  content(state)
}

@Preview
@Composable
fun PreviewYourSupporterBadge() {
  SimpleXTheme {
    WithShownBadge(BadgeType.Supporter) { state ->
      ModalView(close = {}, cardScreen = true) { BadgesYourBadgeView(state, ModalManager.start) }
    }
  }
}

@Preview
@Composable
fun PreviewYourLegendBadge() {
  SimpleXTheme {
    WithShownBadge(BadgeType.Legend) { state ->
      ModalView(close = {}, cardScreen = true) { BadgesYourBadgeView(state, ModalManager.start) }
    }
  }
}

@Preview
@Composable
fun PreviewSettingsSupporterBadge() {
  WithShownBadge(BadgeType.Supporter) { PreviewSettingsLayout() }
}

@Preview
@Composable
fun PreviewSettingsLegendBadge() {
  WithShownBadge(BadgeType.Legend) { PreviewSettingsLayout() }
}

@Preview
@Composable
fun PreviewWhatsNewWithBadge() {
  WithShownBadge(BadgeType.Supporter) { PreviewWhatsNewView() }
}
