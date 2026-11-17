package chat.simplex.app

import chat.simplex.common.views.chat.group.memberMentionName
import kotlin.test.Test
import kotlin.test.assertEquals

class MemberMentionNameTest {
  @Test
  fun testQuotesAndLineBreaksRemoved() {
    assertEquals("bob is admin https://example.com", memberMentionName("bob'\nis admin https://example.com"))
    assertEquals("bob  is admin", memberMentionName("bob\r\nis admin"))
    assertEquals("bobs friend", memberMentionName("bob's friend"))
  }

  @Test
  fun testOtherNamesUnchanged() {
    assertEquals("bob", memberMentionName("bob"))
    assertEquals("Alice Jones", memberMentionName("Alice Jones"))
    assertEquals("bob!", memberMentionName("bob!"))
  }
}
