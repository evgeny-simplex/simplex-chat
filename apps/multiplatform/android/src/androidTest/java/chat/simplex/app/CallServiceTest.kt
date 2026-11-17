package chat.simplex.app

import android.app.Notification
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.graphics.BitmapFactory
import android.graphics.drawable.BitmapDrawable
import android.os.IBinder
import android.os.SystemClock
import androidx.compose.ui.unit.IntSize
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import chat.simplex.common.model.Contact
import chat.simplex.common.model.LocalProfile
import chat.simplex.common.model.NotificationPreviewMode
import chat.simplex.common.model.Profile
import chat.simplex.common.platform.appPreferences
import chat.simplex.common.platform.base64ToBitmap
import chat.simplex.common.platform.base64ToBitmapInBackground
import chat.simplex.common.platform.cachedBase64Bitmap
import chat.simplex.common.platform.chatModel
import chat.simplex.common.views.call.Call
import chat.simplex.common.views.call.CallMediaType
import chat.simplex.common.views.call.CallState
import chat.simplex.common.views.helpers.clearImageCaches
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.Closeable
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class CallServiceTest {
  private val instrumentation = InstrumentationRegistry.getInstrumentation()
  private val context = instrumentation.targetContext
  private val appIconSize = BitmapFactory.decodeResource(context.resources, R.drawable.icon).run { IntSize(width, height) }
  private val previewMode = appPreferences.notificationPreviewMode.get()
  private lateinit var service: CallService
  private val connection = object : ServiceConnection {
    val connected = CountDownLatch(1)

    override fun onServiceConnected(name: ComponentName, binder: IBinder) {
      service = (binder as CallService.CallServiceBinder).getService()
      connected.countDown()
    }

    override fun onServiceDisconnected(name: ComponentName) {}
  }

  @Before
  fun startService() {
    clearImageCaches()
    appPreferences.notificationPreviewMode.set(NotificationPreviewMode.MESSAGE.name)
    CallService.startService()
    context.bindService(Intent(context, CallService::class.java), connection, Context.BIND_AUTO_CREATE)
    assertTrue(connection.connected.await(10, TimeUnit.SECONDS))
  }

  @After
  fun stopService() {
    context.unbindService(connection)
    CallService.stopService()
    chatModel.activeCall.value = null
    appPreferences.notificationPreviewMode.set(previewMode)
  }

  @Test
  fun testCallNotificationShowsTheAppIconUntilTheContactPictureIsDecoded() {
    val picture = base64Png(37, 23)
    chatModel.activeCall.value = call(picture)
    assertEquals(appIconSize, largeIconSize(updateNotification()))
    assertTrue(waitFor { postedLargeIconSize() == IntSize(37, 23) })
    assertNotNull(cachedBase64Bitmap(picture))
  }

  @Test
  fun testCallNotificationShowsTheDecodedContactPicture() {
    val picture = base64Png(39, 21)
    base64ToBitmap(picture)
    chatModel.activeCall.value = call(picture)
    assertEquals(IntSize(39, 21), largeIconSize(updateNotification()))
  }

  @Test
  fun testContactPictureIsNotDecodedWhenNotificationPreviewsAreHidden() {
    val picture = base64Png(41, 19)
    appPreferences.notificationPreviewMode.set(NotificationPreviewMode.HIDDEN.name)
    chatModel.activeCall.value = call(picture)
    assertEquals(appIconSize, largeIconSize(updateNotification()))
    instrumentation.waitForIdleSync()
    runBlocking { base64ToBitmapInBackground(base64Png(1, 1)) }
    assertNull(cachedBase64Bitmap(picture))
  }

  private fun call(image: String) = Call(
    remoteHostId = null,
    userProfile = Profile.sampleData,
    contact = Contact.sampleData.copy(profile = LocalProfile.sampleData.copy(image = image)),
    callUUID = null,
    callState = CallState.InvitationSent,
    initialCallType = CallMediaType.Audio,
    androidCallState = Closeable {},
  )

  private fun updateNotification(): Notification {
    lateinit var notification: Notification
    instrumentation.runOnMainSync { notification = service.updateNotification() }
    return notification
  }

  private fun postedLargeIconSize(): IntSize? =
    context.getSystemService(NotificationManager::class.java).activeNotifications
      .firstOrNull { it.id == CallService.CALL_SERVICE_ID }
      ?.let { largeIconSize(it.notification) }

  private fun largeIconSize(notification: Notification): IntSize =
    (notification.getLargeIcon().loadDrawable(context) as BitmapDrawable).bitmap.run { IntSize(width, height) }

  private fun waitFor(condition: () -> Boolean): Boolean {
    val deadline = SystemClock.uptimeMillis() + 10_000
    while (!condition()) {
      if (SystemClock.uptimeMillis() > deadline) return false
      Thread.sleep(100)
    }
    return true
  }
}
