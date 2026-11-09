package chat.simplex.app

import chat.simplex.common.platform.dataDir
import chat.simplex.common.platform.tmpDir
import kotlin.test.Test
import kotlin.test.assertEquals

class TmpDirLocationTest {
  @Test
  fun tmpDirIsInsideDataDir() {
    assertEquals(dataDir.toPath(), tmpDir.toPath().parent, "tmpDir $tmpDir must be a folder inside dataDir $dataDir")
  }
}
