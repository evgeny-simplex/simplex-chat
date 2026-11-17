package chat.simplex.app

import android.graphics.Bitmap
import android.graphics.Color
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64
import java.util.zip.CRC32

internal const val GIF_1X1 = "R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw=="

internal fun base64(data: ByteArray): String = Base64.getEncoder().encodeToString(data)

internal fun base64Png(width: Int, height: Int, mark: Int = 0): String =
  "data:image/png;base64," + base64(picture(width, height, Bitmap.CompressFormat.PNG, mark))

internal fun picture(width: Int, height: Int, format: Bitmap.CompressFormat, mark: Int = 0): ByteArray {
  val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.rgb(255, mark, 0)) }
  return ByteArrayOutputStream().use { out ->
    bitmap.compress(format, 100, out)
    out.toByteArray()
  }
}

internal fun base64PngHeader(width: Int, height: Int): String {
  val ihdr = ByteBuffer.allocate(17).put("IHDR".toByteArray()).putInt(width).putInt(height).put(byteArrayOf(8, 2, 0, 0, 0)).array()
  val crc = CRC32().apply { update(ihdr) }.value.toInt()
  val signature = picture(1, 1, Bitmap.CompressFormat.PNG).copyOf(8)
  return base64(ByteBuffer.allocate(41).put(signature).putInt(13).put(ihdr).putInt(crc).putInt(0).put("IDAT".toByteArray()).array())
}

internal fun bmp2x2(): ByteArray =
  ByteBuffer.allocate(70).order(ByteOrder.LITTLE_ENDIAN)
    .put('B'.code.toByte()).put('M'.code.toByte()).putInt(70).putInt(0).putInt(54)
    .putInt(40).putInt(2).putInt(2).putShort(1).putShort(24).putInt(0).putInt(16).putInt(0).putInt(0).putInt(0).putInt(0)
    .put(ByteArray(16) { if (it % 8 == 2 || it % 8 == 5) -1 else 0 })
    .array()
