package chat.simplex.app

import android.graphics.Bitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.unit.IntSize
import androidx.test.ext.junit.runners.AndroidJUnit4
import chat.simplex.common.platform.base64BitmapSize
import chat.simplex.common.platform.base64ToBitmap
import chat.simplex.common.platform.byteCount
import chat.simplex.common.views.helpers.errorBitmap
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class Base64BitmapSizeTest {
  @Test
  fun testPictureSizeIsReadFromItsHeaderAlone() {
    val png = picture(1501, 1001, Bitmap.CompressFormat.PNG)
    val header = png.copyOf(String(png, Charsets.ISO_8859_1).indexOf("IDAT") + 4)
    assertEquals(IntSize(750, 500), base64BitmapSize(base64(header)))
  }

  @Test
  fun testPicturesAtTheSizeLimitAreSizedAtPreviewSize() {
    assertEquals(IntSize(540, 540), base64BitmapSize(base64PngHeader(4320, 4320)))
    assertEquals(IntSize(1080, 255), base64BitmapSize(base64PngHeader(4320, 1023)))
    assertEquals(IntSize(4320, 17), base64BitmapSize(base64PngHeader(4320, 17)))
    assertEquals(IntSize(1024, 1023), base64BitmapSize(base64PngHeader(2049, 2047)))
  }

  @Test
  fun testPicturesOutsideTheLimitsHaveNoSize() {
    val pictures = listOf(base64PngHeader(4321, 1), base64PngHeader(17, 4321), base64PngHeader(1, 257), base64PngHeader(0, 1), base64(bmp2x2()), "not a picture")
    for (picture in pictures) {
      assertNull(base64BitmapSize(picture))
    }
  }

  @Test
  fun testDecodedPicturesAreCountedByTheirBitmapMemory() {
    for (bitmap in listOf(base64ToBitmap(base64Png(53, 29)), errorBitmap.asImageBitmap())) {
      val pixels = bitmap.asAndroidBitmap()
      assertEquals(pixels.rowBytes.toLong() * pixels.height, bitmap.byteCount())
    }
  }
}
