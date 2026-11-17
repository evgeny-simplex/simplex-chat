package chat.simplex.app

import androidx.compose.runtime.Composable
import androidx.compose.runtime.snapshots.Snapshot
import androidx.compose.ui.ImageComposeScene
import androidx.compose.ui.unit.Density
import androidx.compose.ui.use
import chat.simplex.common.model.*
import chat.simplex.common.platform.base64ImageDecoder
import chat.simplex.common.ui.theme.SimpleXTheme
import chat.simplex.common.views.chatlist.ChatPreviewView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.jetbrains.skia.Bitmap
import org.jetbrains.skia.Image
import java.awt.Color
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.util.Base64
import java.util.concurrent.CountDownLatch
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class Base64ImagePainterTest {
  @Test
  fun testChatListChatLinkPictureIsShownOnceDecoded() {
    val picture = base64Png(325, 175)
    val card = MsgContent.MCChat("", MsgChatLink.Contact("https://simplex.chat/contact", Profile.sampleData.copy(image = picture), business = false))
    val chat = Chat.sampleData.copy(chatItems = listOf(ChatItem.getSampleData(1, CIDirection.DirectRcv(), text = card.text).copy(content = CIContent.RcvMsgContent(card))))
    whileDecoderIsBusy { release ->
      scene(ROW_WIDTH, 150) {
        SimpleXTheme {
          ChatPreviewView(chat, true, null, null, "", disabled = false, linkMode = SimplexLinkMode.DESCRIPTION, inProgress = false, progressByTimeout = false, {})
        }
      }.use { scene ->
        assertFalse(scene.render().hasRedIn(0 until 150))
        release()
        awaitDecodedPictures()
        assertTrue(scene.renderUntil { it.hasRedIn(0 until 150) })
      }
    }
  }

  private fun <T> whileDecoderIsBusy(block: (release: () -> Unit) -> T): T {
    val busy = CountDownLatch(1)
    val released = CountDownLatch(1)
    CoroutineScope(base64ImageDecoder).launch {
      busy.countDown()
      released.await()
    }
    busy.await()
    try {
      return block { released.countDown() }
    } finally {
      released.countDown()
    }
  }

  private fun scene(width: Int = SCENE_SIZE, height: Int = SCENE_SIZE, content: @Composable () -> Unit): ImageComposeScene =
    ImageComposeScene(width = width, height = height, density = Density(1f), coroutineContext = Dispatchers.Unconfined, content = content)

  private fun Image.hasRedIn(rows: IntRange): Boolean = hasPixelIn(rows) { it.red > 204 && it.green < 51 && it.blue < 51 && it.alpha > 204 }

  private fun Image.hasPixelIn(rows: IntRange, matches: (Color) -> Boolean): Boolean {
    val bitmap = Bitmap.makeFromImage(this)
    return rows.any { y -> (0 until width).any { x -> matches(Color(bitmap.getColor(x, y), true)) } }
  }

  private fun ImageComposeScene.renderUntil(rendered: (Image) -> Boolean): Boolean {
    val deadline = System.nanoTime() + 30_000_000_000L
    while (System.nanoTime() < deadline) {
      Snapshot.sendApplyNotifications()
      if (rendered(render(System.nanoTime()))) return true
      Thread.sleep(20)
    }
    return false
  }

  private fun base64Png(width: Int, height: Int): String =
    "data:image/png;base64," + Base64.getEncoder().encodeToString(png(width, height))

  private fun png(width: Int, height: Int): ByteArray = encodeImage(width, height, "png")

  private fun encodeImage(width: Int, height: Int, format: String): ByteArray {
    val image = BufferedImage(width, height, BufferedImage.TYPE_INT_RGB)
    image.createGraphics().apply { color = Color.RED; fillRect(0, 0, width, height); dispose() }
    return ByteArrayOutputStream().use { out ->
      ImageIO.write(image, format, out)
      out.toByteArray()
    }
  }

  private companion object {
    const val SCENE_SIZE = 100
    const val ROW_WIDTH = 402
  }
}
