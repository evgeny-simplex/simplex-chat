package chat.simplex.common.model

import android.icu.text.DateFormat
import kotlinx.datetime.Instant
import java.util.Date
import java.util.Locale

actual fun dateSeparatorText(t: Instant, withYear: Boolean): String =
  DateFormat.getInstanceForSkeleton(if (withYear) "yMMMEd" else "MMMEd", Locale.getDefault()).format(Date(t.toEpochMilliseconds()))
