package chat.simplex.common.model

import kotlinx.datetime.Instant
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toJavaLocalDateTime
import kotlinx.datetime.toLocalDateTime
import java.time.format.DateTimeFormatter

actual fun dateSeparatorText(t: Instant, withYear: Boolean): String {
  val time = t.toLocalDateTime(TimeZone.currentSystemDefault()).toJavaLocalDateTime()
  val weekday = time.format(DateTimeFormatter.ofPattern("EEE"))
  val dayMonthYear = time.format(DateTimeFormatter.ofPattern(if (withYear) "d MMM yyyy" else "d MMM"))
  return "$weekday, $dayMonthYear"
}
