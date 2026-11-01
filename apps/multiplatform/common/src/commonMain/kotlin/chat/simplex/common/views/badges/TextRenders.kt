package chat.simplex.common.views.badges

import androidx.compose.desktop.ui.tooling.preview.Preview
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import chat.simplex.common.model.*
import chat.simplex.common.ui.theme.SimpleXTheme
import chat.simplex.common.views.helpers.*
import chat.simplex.res.*
import kotlinx.datetime.Clock
import kotlinx.datetime.Instant

@Composable
private fun AlertRender(show: AlertManager.() -> Unit) {
  val alertManager = remember { AlertManager().apply(show) }
  SimpleXTheme {
    Box(Modifier.fillMaxWidth().height(874.dp)) { alertManager.showInView() }
  }
}

@Composable
private fun YourBadgeRender(status: BadgeSubscriptionState?, paidDays: Int, subscribed: Boolean = true) {
  LaunchedEffect(Unit) { BadgeStore.load() }
  val paidThrough = Instant.fromEpochMilliseconds(Clock.System.now().toEpochMilliseconds() + paidDays * 86_400_000L)
  val state = BadgeState(
    badgePurchaseId = 1,
    purchaseKey = "",
    badgeType = BadgeType.Supporter,
    shown = true,
    monthsLeft = 1,
    paidThrough = paidThrough,
    willRenew = subscribed,
    subscription = if (subscribed) BadgeSubscription(planMonths = 1, status = status) else null
  )
  SimpleXTheme {
    Box(Modifier.fillMaxWidth().height(874.dp)) { BadgesYourBadgeView(state, ModalManager.start) }
  }
}

@Preview
@Composable
fun PreviewTextAlertLinkNotSupported() {
  AlertRender { showAlertMsg(title = generalGetString(MR.strings.app_link_not_supported)) }
}

@Preview
@Composable
fun PreviewTextAlertSignMessages() {
  AlertRender {
    showAlertDialog(
      title = generalGetString(MR.strings.sign_messages_question),
      text = generalGetString(MR.strings.sign_messages_alert_desc),
      confirmText = generalGetString(MR.strings.sign_messages_enable)
    )
  }
}

@Preview
@Composable
fun PreviewTextAlertSignatureMissing() {
  AlertRender { showAlertMsg(title = generalGetString(MR.strings.signature_missing_alert_title), text = generalGetString(MR.strings.signature_missing_alert_desc)) }
}

@Preview
@Composable
fun PreviewTextAlertUnsupportedVersion() {
  AlertRender { showAlertMsg(title = generalGetString(MR.strings.badges_error_title), text = generalGetString(MR.strings.badges_error_unsupported_version)) }
}

@Preview
@Composable
fun PreviewTextAlertReceiptUsed() {
  AlertRender { showAlertMsg(title = generalGetString(MR.strings.badges_purchase_error), text = generalGetString(MR.strings.badges_error_receipt_used)) }
}

@Preview
@Composable
fun PreviewTextAlertTestPurchase() {
  AlertRender { showAlertMsg(title = generalGetString(MR.strings.badges_purchase_error), text = generalGetString(MR.strings.badges_error_test_purchase)) }
}

@Preview
@Composable
fun PreviewTextAlertAlreadyOwned() {
  AlertRender { showAlertMsg(title = generalGetString(MR.strings.badges_purchase_error), text = generalGetString(MR.strings.badges_error_already_owned)) }
}

@Preview
@Composable
fun PreviewTextAlertStorePurchaseOpen() {
  AlertRender { showAlertMsg(title = generalGetString(MR.strings.badges_error_title), text = generalGetString(MR.strings.badges_error_store_purchase_open)) }
}

@Preview
@Composable
fun PreviewTextAlertAlreadyActive() {
  AlertRender { showAlertMsg(title = generalGetString(MR.strings.badges_error_title), text = generalGetString(MR.strings.badges_error_already_active)) }
}

@Preview
@Composable
fun PreviewTextYourBadgePaymentProblem() {
  YourBadgeRender(BadgeSubscriptionState.BillingRetry, 20)
}

@Preview
@Composable
fun PreviewTextYourBadgeRenewing() {
  YourBadgeRender(BadgeSubscriptionState.Renewing, -1)
}

@Preview
@Composable
fun PreviewTextYourBadgeRenews() {
  YourBadgeRender(BadgeSubscriptionState.Renewing, 20)
}

@Preview
@Composable
fun PreviewTextYourBadgeEnded() {
  YourBadgeRender(BadgeSubscriptionState.Ended, -1)
}

@Preview
@Composable
fun PreviewTextYourBadgePrepaid() {
  YourBadgeRender(null, 40, subscribed = false)
}
