package chat.simplex.app

import android.content.ComponentCallbacks2
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.unit.IntSize
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import chat.simplex.common.platform.base64ToBitmap
import chat.simplex.common.platform.cachedBase64Bitmap
import chat.simplex.common.views.helpers.clearImageCaches
import chat.simplex.common.views.helpers.errorBitmap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class Base64BitmapTest {
  @Before
  fun clearCache() {
    clearImageCaches()
  }

  @Test
  fun testPicturesInFormatsSentByAppsAreDecoded() {
    for (format in listOf(Bitmap.CompressFormat.PNG, Bitmap.CompressFormat.JPEG, Bitmap.CompressFormat.WEBP_LOSSLESS)) {
      assertEquals(IntSize(3, 2), base64ToBitmap(base64(picture(3, 2, format))).size)
    }
    assertEquals(IntSize(1, 1), base64ToBitmap(GIF_1X1).size)
  }

  @Test
  fun testPictureInAnotherFormatIsShownAsTheErrorPicture() {
    val bmp = bmp2x2()
    assertEquals(2, BitmapFactory.decodeByteArray(bmp, 0, bmp.size).width)
    assertSame(errorBitmap, base64ToBitmap(base64(bmp)).asAndroidBitmap())
  }

  @Test
  fun testPicturesOverTheSizeLimitAreShownAsTheErrorPicture() {
    assertEquals(IntSize(4320, 1), base64ToBitmap(base64Png(4320, 1)).size)
    assertEquals(IntSize(17, 4320), base64ToBitmap(base64Png(17, 4320)).size)
    for (picture in listOf(base64Png(4321, 1), base64Png(17, 4321), base64PngHeader(0, 1))) {
      assertSame(errorBitmap, base64ToBitmap(picture).asAndroidBitmap())
    }
  }

  @Test
  fun testPictureTallerThan256TimesItsWidthIsShownAsTheErrorPicture() {
    assertEquals(IntSize(1, 256), base64ToBitmap(base64Png(1, 256)).size)
    assertEquals(IntSize(300, 1), base64ToBitmap(base64Png(300, 1)).size)
    assertSame(errorBitmap, base64ToBitmap(base64Png(1, 257)).asAndroidBitmap())
  }

  @Test
  fun testPicturesAreDecodedAtPreviewSize() {
    assertEquals(IntSize(500, 500), base64ToBitmap(base64Png(500, 500)).size)
    assertEquals(IntSize(750, 500), base64ToBitmap(base64Png(1501, 1001)).size)
    assertEquals(IntSize(1024, 1023), base64ToBitmap(base64Png(2049, 2047)).size)
    assertEquals(IntSize(540, 540), base64ToBitmap(base64Png(4320, 4320)).size)
  }

  @Test
  fun testDecodedPictureIsCached() {
    val picture = base64Png(41, 31)
    val decoded = base64ToBitmap(picture)
    assertSame(decoded, base64ToBitmap(picture))
    assertSame(decoded, cachedBase64Bitmap(picture))
  }

  @Test
  fun testPictureThatCannotBeReadIsCachedAsTheErrorPicture() {
    val picture = "data:image/png;base64,not a picture"
    assertSame(errorBitmap, base64ToBitmap(picture).asAndroidBitmap())
    assertSame(errorBitmap, cachedBase64Bitmap(picture)?.asAndroidBitmap())
  }

  @Test
  fun testPictureThatRunsOutOfMemoryIsNotCached() {
    val picture = base64OverFreeMemory()
    assertSame(errorBitmap, base64ToBitmap(picture).asAndroidBitmap())
    assertNull(cachedBase64Bitmap(picture))
  }

  @Test
  fun testCachedPicturesAreLimitedByTheirMemory() {
    val pictures = (0..16).map { base64Png(1000, 1000, mark = it) }
    val first = base64ToBitmap(pictures[0])
    val second = base64ToBitmap(pictures[1])
    assertSame(first, base64ToBitmap(pictures[0]))
    pictures.drop(2).forEach { base64ToBitmap(it) }
    assertSame(first, cachedBase64Bitmap(pictures[0]))
    assertNull(cachedBase64Bitmap(pictures[1]))
    assertNotSame(second, base64ToBitmap(pictures[1]))
  }

  @Test
  fun testClearedCacheDecodesPicturesAgain() {
    val picture = base64Png(43, 37)
    val decoded = base64ToBitmap(picture)
    assertSame(decoded, cachedBase64Bitmap(picture))
    clearImageCaches()
    assertNull(cachedBase64Bitmap(picture))
    assertNotSame(decoded, base64ToBitmap(picture))
  }

  @Test
  fun testAppHiddenFromTheUserClearsTheCache() {
    val picture = base64Png(47, 29)
    for (level in listOf(ComponentCallbacks2.TRIM_MEMORY_UI_HIDDEN, ComponentCallbacks2.TRIM_MEMORY_BACKGROUND)) {
      val decoded = base64ToBitmap(picture)
      assertSame(decoded, cachedBase64Bitmap(picture))
      trimMemory(level)
      assertNull(cachedBase64Bitmap(picture))
    }
  }

  @Test
  fun testMemoryTrimWhileTheAppIsShownKeepsTheCache() {
    val picture = base64Png(53, 31)
    val decoded = base64ToBitmap(picture)
    trimMemory(ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL)
    assertSame(decoded, cachedBase64Bitmap(picture))
  }

  private val ImageBitmap.size: IntSize get() = IntSize(width, height)

  private fun trimMemory(level: Int) {
    InstrumentationRegistry.getInstrumentation().runOnMainSync { SimplexApp.context.onTrimMemory(level) }
  }

  private fun base64OverFreeMemory(): String {
    val runtime = Runtime.getRuntime()
    runtime.gc()
    val free = runtime.maxMemory() - runtime.totalMemory() + runtime.freeMemory()
    return String(ByteArray((free * 2 / 5 / 4 * 4).toInt()).apply { fill('A'.code.toByte()) }, Charsets.ISO_8859_1)
  }
}
