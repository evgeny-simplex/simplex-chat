package chat.simplex.app

import LocalCardScreen
import SectionItemView
import SectionTextFooter
import SectionView
import TextIconSpaced
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.Icon
import androidx.compose.material.IconButton
import androidx.compose.material.MaterialTheme
import androidx.compose.material.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import chat.simplex.common.model.CIDirection
import chat.simplex.common.model.ChatController.appPrefs
import chat.simplex.common.model.ChatItem
import chat.simplex.common.ui.theme.*
import chat.simplex.common.views.chat.item.clipChatItem
import chat.simplex.common.views.chatlist.UnreadBadge
import chat.simplex.common.views.helpers.*
import chat.simplex.common.views.usersettings.SettingsActionItem
import chat.simplex.res.*
import dev.icerock.moko.resources.compose.painterResource

@Composable
fun StyleGuideTypeScale() {
  SpecimenSheet("Type scale · Android, desktop · sp at font 100%") {
    val t = MaterialTheme.typography
    val body = t.body1
    TypeRow("type.display", "33.5 Bold · h1", "Settings", t.h1, note = "screen titles · 138 sites, unchanged")
    TypeRow("type.title1", "24 · h2", "Chat help", t.h2, note = "section headings, full names · 11 sites")
    TypeRow(
      "type.title2", "20 · new style", "Delete contact?", t.subtitle1.copy(fontFamily = Inter, letterSpacing = 0.sp, fontSize = 20.sp),
      alt = t.subtitle1.copy(fontSize = 20.sp), note = "alert titles now: platform font, 0.15 sp tracking · 439 sites"
    )
    TypeRow(
      "type.title3", "18.5 · h3", "Alice", t.h3.copy(fontWeight = FontWeight.Bold),
      alt = t.caption, altTag = "kept 18", note = "chat names; SimpleButton labels kept at 18 (tolerance 0.8)"
    )
    TypeRow("type.headline", "16 SemiBold", "Toolbar title", body.copy(fontWeight = FontWeight.SemiBold), note = "toolbar titles, card names · 9 sites")
    TypeRow(
      "type.body", "16 · body1", "Reply  Forward  Copy", body,
      alt = t.subtitle1, note = "menu items now: platform font, 0.15 sp tracking · 98 sites"
    )
    TypeRow("type.callout", "15", "Chat preview text", body.copy(fontSize = 15.sp), note = "previews, quotes, filter tags · 26 sites")
    TypeRow("type.subheadline", "14 · body2", "Section footer text", t.body2, note = "footers, descriptions · 80 sites")
    TypeRow("type.footnote", "13", "12:45  Yesterday", body.copy(fontSize = 13.sp), note = "chat row date, tab titles · 10 sites")
    TypeRow(
      "type.caption", "12", "search  call  video", body.copy(fontSize = 12.sp),
      alt = t.subtitle2.copy(fontWeight = FontWeight.Normal, fontSize = 12.sp), note = "info action labels now: platform font · 13 sites"
    )
    Row {
      TokenColumn("type.caption2", "10")
      Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        TaggedRow("proposed") {
          InterBadge("12")
          InterBadge("3")
        }
        TaggedRow("now") {
          UnreadBadge("12", MaterialTheme.colors.primaryVariant)
          UnreadBadge("3", MaterialTheme.colors.primaryVariant)
        }
        SpecimenLabel("unread badge digits now: platform font · 7 sites")
      }
    }
  }
}

@Composable
fun StyleGuideTypeRoles() {
  SpecimenSheet("Type roles · Android, desktop · sp at font 100%") {
    val t = MaterialTheme.typography
    val body = t.body1
    RoleBlock("chat banner: full name 17.5 (h4) under an 18.5 name now; 14 (body2) proposed") {
      NowProposed(
        now = { BannerNames(t.h4) },
        proposed = { BannerNames(t.body2) }
      )
    }
    RoleBlock("SimpleX name 14 with 'verify' 16 now; 'verify' 14 proposed") {
      NowProposed(
        now = { SimplexNameRow(body) },
        proposed = { SimplexNameRow(t.body2) }
      )
    }
    RoleBlock("type.keypad · 30: platform font now; Inter proposed") {
      val digits = TextStyle(fontWeight = FontWeight.Normal, fontSize = 30.sp, letterSpacing = (-0.5).sp)
      NowProposed(
        now = { Text("1 2 3", style = digits, color = MaterialTheme.colors.secondary) },
        proposed = { Text("1 2 3", style = digits.copy(fontFamily = Inter), color = MaterialTheme.colors.secondary) }
      )
    }
    RoleBlock("type.markdown.heading.document · now h1 16, h2 22, h3 17.5, h4 16, h5 20 (h4, h5 platform font); proposed 16 × 1.5 / 1.3 / 1.15 / 1 Bold") {
      NowProposed(
        now = {
          DocumentHeadings(
            listOf(
              body,
              t.h3.copy(fontSize = 22.sp, fontWeight = FontWeight.Bold),
              t.h4.copy(fontWeight = FontWeight.Bold),
              t.h5.copy(fontSize = 16.sp, fontWeight = FontWeight.Bold),
              t.h6.copy(fontWeight = FontWeight.Bold)
            )
          )
        },
        proposed = {
          DocumentHeadings(listOf(1.5f, 1.3f, 1.15f, 1f, 1f).map { body.copy(fontSize = 16.sp * it, fontWeight = FontWeight.Bold) })
        }
      )
    }
    RoleBlock("type.markdown.heading.chat · Bold × 1.25^(3 − level), floor 1 · unchanged") {
      Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.Bottom) {
        listOf(25.sp, 20.sp, 16.sp).forEachIndexed { i, size ->
          Text("Heading ${i + 1}", style = body.copy(fontSize = size, fontWeight = FontWeight.Bold))
        }
      }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
      RoleBlock("type.emoji · 48 / 36") {
        Row(verticalAlignment = Alignment.Bottom) {
          Text("👍", style = TextStyle(fontFamily = EmojiFont, fontSize = 48.sp))
          Text("👍👍👍👍", style = TextStyle(fontFamily = EmojiFont, fontSize = 36.sp))
        }
      }
      RoleBlock("type.numeral · 50 Bold") {
        Text("73%", style = t.h1.copy(fontSize = 50.sp), color = MaterialTheme.colors.primary)
      }
    }
    Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
      RoleBlock("type.chat.sender · 13.5") {
        Text("alice", style = body.copy(fontSize = 13.5.sp, fontWeight = FontWeight.Medium), color = MaterialTheme.colors.secondary)
      }
      RoleBlock("type.markdown.code · mono × 0.875") {
        Text("let x = 14", style = body.copy(fontFamily = FontFamily.Monospace, fontSize = 14.sp))
      }
    }
    RoleBlock("type.sectionHeader · 14 Medium on cards, 12 elsewhere · type.footer · 14, line 18") {
      Row(horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.Bottom) {
        Text("Chats", color = MaterialTheme.colors.secondary, style = t.body2, fontSize = 14.sp, fontWeight = FontWeight.Medium)
        Text("Chats", color = MaterialTheme.colors.secondary, style = t.body2, fontSize = 12.sp)
        Text("Footer text that wraps\nonto a second line.", color = MaterialTheme.colors.secondary, lineHeight = 18.sp, fontSize = 14.sp)
      }
    }
    RoleBlock("weights at 16: Light (events), Normal, Medium (text buttons), SemiBold (headline), Bold (titles)") {
      Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        listOf(FontWeight.Light, FontWeight.Normal, FontWeight.Medium, FontWeight.SemiBold, FontWeight.Bold).forEach {
          Text("Chat", style = body.copy(fontWeight = it))
        }
      }
    }
  }
}

@Composable
fun StyleGuideSpacing() {
  SpecimenSheet("Spacing · Android, desktop · dp (sp in chat rows)") {
    SpecimenLabel("relation tokens, the gap drawn at its size")
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
      GapRow("space.part", "2", 2.dp, "parts of one element, chip padding")
      GapRow("space.iconText", "4", 4.dp, "an icon and its text, meta parts")
      GapRow("space.controlParts", "6", 6.dp, "header icon and title")
      GapRow("space.group", "8", 8.dp, "items of one group, avatar to text")
      GapRow("space.content", "10", 10.dp, "inset in a container (DEFAULT_PADDING_HALF)")
      GapRow("space.chatText", "12", 12.dp, "chat text padding")
      GapRow("space.cardText", "16", 16.dp, "chat-list banner text inset")
      GapRow("space.edge", "20", 20.dp, "screen and row edge (DEFAULT_PADDING)")
      GapRow("space.block", "24", 24.dp, "between blocks of a page")
      GapRow("space.indent", "24", 24.dp, "indented detail rows")
      GapRow("space.section", "30", 30.dp, "between sections on card screens")
      GapRow("space.double", "32", 32.dp, "user picker sections")
      GapRow("space.pageEnd", "40", 40.dp, "page bottom above a primary button")
      GapRow("space.scrollEnd", "48", 48.dp, "bottom spacer of a scrolling page")
    }
    SpecimenLabel("named insets: card edge 18 (CARD_PADDING), headers at 30, onboarding sides 25, rows 15 vertical, min height 50")
    SpecimenLabel("steps in use now: sites mapped to each step (inventory of master)")
    StepHistogram(
      listOf(0 to 19, 2 to 40, 4 to 134, 6 to 27, 8 to 128, 10 to 162, 12 to 56, 16 to 36, 20 to 249, 24 to 25, 30 to 17, 32 to 1, 40 to 17, 48 to 2)
    )
    SpecimenLabel("off-scale values kept until a toggle render: 3, 5, 7, 14, 15, 27, 41 · 61 sites")
  }
}

@Composable
fun StyleGuideSpacingCards() {
  SpecimenSheet("Card screen edges · Android, desktop · Q6") {
    SpecimenLabel("guides at 18 (card edge), 30 (header text), 36 (row content)")
    SpecimenLabel("now: title and footer at 20")
    CardScreen(proposed = false)
    SpecimenLabel("proposed (Q6 A): title at 18, footer at 30")
    CardScreen(proposed = true)
  }
}

@Composable
fun StyleGuideRadii() {
  val r = appPrefs.chatItemRoundness.get()
  SpecimenSheet("Corner radii · Android, desktop · r = ${"%.2f".format(r)}") {
    SpecimenLabel("chat content, scaled by r")
    TileGrid {
      Tile("radius.bubble", "21.6 × r, quadratic") {
        Box(Modifier.size(TILE_W, TILE_H).clipChatItem(ChatItem.getSampleData(dir = CIDirection.DirectRcv()), tailVisible = true).background(tileFill()))
      }
      ShapeTile("radius.item", "18 × r = ${dp1(18 * r)}", RoundedCornerShape(18.dp * r))
      ShapeTile("radius.block", "12 × r = ${dp1(12 * r)}", RoundedCornerShape(12.dp * r))
      ShapeTile("radius.inner", "8 × r = ${dp1(8 * r)}", RoundedCornerShape(8.dp * r))
    }
    SpecimenLabel("fixed")
    TileGrid {
      Tile("radius.bar", "2 on a 4 bar") {
        Box(Modifier.size(4.dp, TILE_H).clip(RoundedCornerShape(2.dp)).background(tileFill()))
      }
      Tile("radius.avatar", "R 22.5 % of the side") {
        Box(ProfileIconModifier(TILE_H, padding = false).background(tileFill()))
      }
      Tile("radius.tile", "22 % (Int percent)") {
        Box(Modifier.size(TILE_H).clip(RoundedCornerShape(22)).background(tileFill()))
      }
      ShapeTile("radius.pill", "half the height", CircleShape, height = 28.dp)
      ShapeTile("radius.card", "16", RoundedCornerShape(16.dp))
      ShapeTile("radius.card.large", "18", RoundedCornerShape(18.dp))
      ShapeTile("radius.card.hero", "24", RoundedCornerShape(24.dp))
      ShapeTile("radius.media", "12", RoundedCornerShape(12.dp))
      ShapeTile("radius.field", "10", RoundedCornerShape(10.dp))
      ShapeTile("radius.small", "8", RoundedCornerShape(8.dp))
      ShapeTile("radius.editor", "14; 16 flush with a card", RoundedCornerShape(14.dp))
      ShapeTile("radius.press", "4 (Material small)", RoundedCornerShape(4.dp))
      ShapeTile("radius.dialog", "25", RoundedCornerShape(25.dp))
      ShapeTile("radius.sheet", "18 top", RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp))
    }
    SpecimenLabel("changes: now → proposed")
    TileGrid {
      ShapeTile("group invitation", "now 18 fixed", RoundedCornerShape(18.dp))
      ShapeTile("group invitation", "proposed 18 × r", RoundedCornerShape(18.dp * r))
      ShapeTile("notification cards", "now 35", RoundedCornerShape(35.dp))
      ShapeTile("notification cards", "proposed 18", RoundedCornerShape(18.dp))
      ShapeTile("terminal deleted card", "now 18 fixed", RoundedCornerShape(18.dp))
      ShapeTile("terminal deleted card", "proposed 18 × r", RoundedCornerShape(18.dp * r))
      ShapeTile("connect banner", "now 18", RoundedCornerShape(18.dp))
      ShapeTile("connect banner", "proposed 16 (Q11)", RoundedCornerShape(16.dp))
    }
  }
}

@Composable
fun StyleGuideIcons() {
  SpecimenSheet("Icons · Android, desktop · Material Symbols Rounded 400, 22 dp") {
    SpecimenLabel("icon.row · 22 dp painter + TextIconSpaced: 20 flat, 16 on card screens")
    SettingsActionItem(painterResource(MR.images.ic_lock), "SimpleX Lock")
    CompositionLocalProvider(LocalCardScreen provides true) {
      SettingsActionItem(painterResource(MR.images.ic_light_mode), "Appearance (card screen)")
    }
    SpecimenLabel("24 px files beside 22 px now: the label moves 2 dp when the filled state is on")
    NowProposed(
      now = {
        Column {
          SettingsActionItem(painterResource(MR.images.ic_flag), "Flag")
          SettingsActionItem(painterResource(MR.images.ic_flag_filled), "Flagged")
        }
      },
      proposed = {
        Column {
          SettingsActionItem(painterResource(MR.images.ic_flag), "Flag")
          SizedIconRow(painterResource(MR.images.ic_flag_filled), "Flagged", 22.dp)
        }
      }
    )
    SpecimenLabel("icon.weight · 400 everywhere (Q13): search, call, add member, phone")
    NowProposed(
      now = {
        GlyphRow(listOf(MR.images.ic_search_500, MR.images.ic_call_500, MR.images.ic_person_add_500, MR.images.ic_smartphone_300).map { painterResource(it) })
      },
      proposed = {
        GlyphRow(listOf(MR.images.ic_search, MR.images.ic_call, MR.images.ic_person_add, MR.images.ic_smartphone).map { painterResource(it) })
      }
    )
    SpecimenLabel("icon.toolbar · 22 dp in a 48 dp button: More is a 24 dp ImageVector now")
    NowProposed(
      now = {
        Row {
          IconButton({}) { Icon(MoreVertFilled, null, tint = MaterialTheme.colors.primary) }
          IconButton({}) { Icon(painterResource(MR.images.ic_search), null, tint = MaterialTheme.colors.primary) }
        }
      },
      proposed = {
        Row {
          IconButton({}) { Icon(painterResource(MR.images.ic_more_vert), null, tint = MaterialTheme.colors.primary) }
          IconButton({}) { Icon(painterResource(MR.images.ic_search), null, tint = MaterialTheme.colors.primary) }
        }
      }
    )
    SpecimenLabel("icon.fill · outline = action, filled = on or state; a filled Edit among outline actions now")
    NowProposed(
      now = { GlyphRow(listOf(MR.images.ic_reply, MR.images.ic_edit_filled, MR.images.ic_star, MR.images.ic_star_filled).map { painterResource(it) }) },
      proposed = { GlyphRow(listOf(MR.images.ic_reply, MR.images.ic_edit, MR.images.ic_star, MR.images.ic_star_filled).map { painterResource(it) }) }
    )
    SpecimenLabel("icon.close, icon.failure, icon.clear · ic_close; icon.inline · sp of the line beside text")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
      Icon(painterResource(MR.images.ic_close), null, tint = MaterialTheme.colors.secondary)
      Spacer(Modifier.width(12.dp))
      Text("12:45", fontSize = 12.sp, color = MaterialTheme.colors.secondary)
      Icon(painterResource(MR.images.ic_check), null, Modifier.size(with(LocalDensity.current) { 12.sp.toDp() }), tint = MaterialTheme.colors.secondary)
    }
  }
}

@Composable
fun StyleGuideColours() {
  SpecimenSheet("Colour roles · Android, desktop · ${if (isInDarkTheme()) "DARK" else "LIGHT"} theme") {
    val c = MaterialTheme.colors
    val a = MaterialTheme.appColors
    val dark = isInDarkTheme()
    ColourRow("colour.accent", "colors.primary", listOf(c.primary))
    ColourRow("colour.accent.badge", "colors.primaryVariant (= primary here; #1298A5 in SIMPLEX)", listOf(c.primaryVariant))
    SwatchRow("colour.onAccent", "white on primaryVariant; onPrimary on primary (3 sites)", "white  ${hex(c.onPrimary)}") {
      OnFill("12", Color.White, c.primaryVariant)
      OnFill("12", c.onPrimary, c.primary)
    }
    ColourRow("colour.text", "colors.onBackground", listOf(c.onBackground))
    ColourRow("colour.text.secondary", "colors.secondary", listOf(c.secondary))
    ColourRow("colour.text.preview", if (dark) "MessagePreviewDark" else "MessagePreviewLight", listOf(if (dark) MessagePreviewDark else MessagePreviewLight))
    ColourRow("colour.icon.faded", if (dark) "FileDark" else "FileLight", listOf(if (dark) FileDark else FileLight))
    ColourRow("colour.background", "colors.background", listOf(c.background))
    ColourRow("colour.canvas", "canvasColorForCurrentTheme()", listOf(canvasColorForCurrentTheme()))
    ColourRow("colour.card", "sectionCardColor(); secondaryVariant", listOf(sectionCardColor(), c.secondaryVariant))
    ColourRow("colour.surface", "colors.surface (menus)", listOf(c.surface))
    ColourRow("colour.bubble", "sent, sent quote, received, received quote", listOf(a.sentMessage, a.sentQuote, a.receivedMessage, a.receivedQuote))
    ColourRow("colour.destructive", "Color.Red = colors.error", listOf(Color.Red, c.error))
    ColourRow("colour.warning", "WarningOrange", listOf(WarningOrange))
    ColourRow("colour.caution", "WarningYellow", listOf(WarningYellow))
    ColourRow("colour.success", "SimplexGreen", listOf(SimplexGreen))
    ColourRow("colour.incognito", "Indigo", listOf(Indigo))
    ColourRow("colour.bar", "background + 3 % onBackground at the bars alpha", listOf(c.background.mixWith(c.onBackground, 0.97f).copy(alpha = appPrefs.inAppBarsAlpha.get())))
    ColourRow("colour.selection", "primary at 0.1", listOf(c.primary.copy(alpha = 0.1f)))
    SwatchRow("colour.overlay.media", "black 0.35 disc, white glyph, on a received quote fill", "") {
      Box(Modifier.size(30.dp, 22.dp).background(a.receivedQuote), contentAlignment = Alignment.Center) {
        Box(Modifier.size(20.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.35f)), contentAlignment = Alignment.Center) {
          Icon(painterResource(MR.images.ic_play_arrow_filled), null, Modifier.size(14.dp), tint = Color.White)
        }
      }
    }
  }
}

private val TILE_W = 82.dp
private val TILE_H = 56.dp

@Composable
private fun SpecimenSheet(title: String, content: @Composable ColumnScope.() -> Unit) {
  SimpleXTheme {
    Column(
      Modifier.fillMaxWidth().background(MaterialTheme.colors.background).padding(horizontal = 14.dp, vertical = 12.dp),
      verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
      Text(title, style = MaterialTheme.typography.body1.copy(fontWeight = FontWeight.SemiBold))
      content()
    }
  }
}

@Composable
private fun SpecimenLabel(text: String, color: Color = MaterialTheme.colors.secondary) {
  Text(text, color = color, style = TextStyle(fontFamily = Inter, fontSize = 10.sp, lineHeight = 13.sp))
}

@Composable
private fun TokenColumn(token: String, value: String) {
  Column(Modifier.width(96.dp).padding(end = 6.dp)) {
    SpecimenLabel(token, MaterialTheme.colors.onBackground)
    SpecimenLabel(value)
  }
}

@Composable
private fun TaggedRow(tag: String, content: @Composable RowScope.() -> Unit) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Row(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically, content = content)
    SpecimenLabel(tag)
  }
}

@Composable
private fun TypeRow(token: String, value: String, sample: String, style: TextStyle, alt: TextStyle? = null, altTag: String = "now", note: String) {
  Row {
    TokenColumn(token, value)
    Column(Modifier.weight(1f)) {
      TaggedRow(if (alt == null) "" else "proposed") { Text(sample, style = style, maxLines = 1) }
      if (alt != null) {
        TaggedRow(altTag) { Text(sample, style = alt, maxLines = 1) }
      }
      SpecimenLabel(note)
    }
  }
}

@Composable
private fun InterBadge(text: String) {
  Text(
    text,
    color = Color.White,
    fontSize = 10.sp,
    style = TextStyle(fontFamily = Inter, textAlign = TextAlign.Center),
    modifier = Modifier
      .background(MaterialTheme.colors.primaryVariant, shape = CircleShape)
      .badgeLayout()
      .padding(horizontal = 2.sp.toDp())
      .padding(vertical = 1.sp.toDp())
  )
}

@Composable
private fun RoleBlock(label: String, content: @Composable () -> Unit) {
  Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
    SpecimenLabel(label)
    content()
  }
}

@Composable
private fun NowProposed(now: @Composable () -> Unit, proposed: @Composable () -> Unit) {
  Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
    Column(Modifier.weight(1f)) {
      SpecimenLabel("now")
      now()
    }
    Column(Modifier.weight(1f)) {
      SpecimenLabel("proposed")
      proposed()
    }
  }
}

@Composable
private fun BannerNames(fullName: TextStyle) {
  Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
    Text("Alice", style = MaterialTheme.typography.h3)
    Text("Alice Smith", style = fullName)
  }
}

@Composable
private fun SimplexNameRow(verify: TextStyle) {
  Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
    Text("alice.simplex", style = MaterialTheme.typography.body2, color = MaterialTheme.colors.secondary)
    Text("verify", style = verify, color = MaterialTheme.colors.primary)
  }
}

@Composable
private fun DocumentHeadings(styles: List<TextStyle>) {
  Column {
    styles.forEachIndexed { i, style -> Text("Heading ${i + 1}", style = style, maxLines = 1) }
  }
}

@Composable
private fun GapRow(token: String, value: String, gap: Dp, relation: String) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Column(Modifier.width(108.dp)) {
      SpecimenLabel("$token · $value", MaterialTheme.colors.onBackground)
    }
    GapBlock()
    Box(Modifier.size(gap, 14.dp).background(MaterialTheme.colors.primary.copy(alpha = 0.35f)))
    GapBlock()
    Spacer(Modifier.width(8.dp))
    SpecimenLabel(relation)
  }
}

@Composable
private fun GapBlock() {
  Box(Modifier.size(14.dp).background(MaterialTheme.colors.secondary.copy(alpha = 0.45f)))
}

@Composable
private fun StepHistogram(steps: List<Pair<Int, Int>>) {
  val max = steps.maxOf { it.second }
  Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.Bottom) {
    steps.forEach { (step, sites) ->
      Column(horizontalAlignment = Alignment.CenterHorizontally) {
        SpecimenLabel("$sites")
        Box(Modifier.size(14.dp, (90f * sites / max).coerceAtLeast(1f).dp).background(MaterialTheme.colors.primary.copy(alpha = 0.6f)))
        SpecimenLabel("$step", MaterialTheme.colors.onBackground)
      }
    }
  }
}

@Composable
private fun CardScreen(proposed: Boolean) {
  val guide = MaterialTheme.colors.primary.copy(alpha = 0.5f)
  CompositionLocalProvider(LocalCardScreen provides true) {
    Column(
      Modifier
        .fillMaxWidth()
        .background(canvasColorForCurrentTheme())
        .drawWithContent {
          drawContent()
          listOf(18.dp, 30.dp, 36.dp).forEach {
            val x = it.toPx()
            drawLine(guide, Offset(x, 0f), Offset(x, size.height), strokeWidth = 1f)
          }
        }
    ) {
      if (proposed) {
        Box(Modifier.padding(horizontal = CARD_EDGE)) { AppBarTitle("Privacy", withPadding = false, bottomPadding = 12.dp) }
      } else {
        AppBarTitle("Privacy", bottomPadding = 12.dp)
      }
      SectionView("Chats") {
        SettingsActionItem(painterResource(MR.images.ic_lock), "SimpleX Lock")
        SettingsActionItem(painterResource(MR.images.ic_light_mode), "Appearance")
      }
      if (proposed) {
        Text(
          FOOTER,
          Modifier.padding(start = 30.dp, end = DEFAULT_PADDING, top = DEFAULT_PADDING_HALF).fillMaxWidth(0.9F),
          color = MaterialTheme.colors.secondary,
          lineHeight = 18.sp,
          fontSize = 14.sp
        )
      } else {
        SectionTextFooter(FOOTER)
      }
      Spacer(Modifier.height(12.dp))
    }
  }
}

private val CARD_EDGE = 18.dp
private const val FOOTER = "The footer text explains the section above."

@Composable
private fun TileGrid(content: @Composable () -> Unit) {
  Layout(content) { measurables, constraints ->
    val gap = 8.dp.roundToPx()
    val placeables = measurables.map { it.measure(constraints.copy(minWidth = 0, minHeight = 0)) }
    var x = 0
    var y = 0
    var rowHeight = 0
    val positions = placeables.map { p ->
      if (x > 0 && x + p.width > constraints.maxWidth) {
        x = 0
        y += rowHeight + gap
        rowHeight = 0
      }
      val pos = x to y
      x += p.width + gap
      rowHeight = maxOf(rowHeight, p.height)
      pos
    }
    layout(constraints.maxWidth, y + rowHeight) {
      placeables.forEachIndexed { i, p -> p.place(positions[i].first, positions[i].second) }
    }
  }
}

@Composable
private fun tileFill(): Color = MaterialTheme.colors.primary.copy(alpha = 0.28f)

@Composable
private fun Tile(token: String, value: String, shape: @Composable () -> Unit) {
  Column(Modifier.width(TILE_W), verticalArrangement = Arrangement.spacedBy(3.dp)) {
    Box(Modifier.size(TILE_W, TILE_H), contentAlignment = Alignment.CenterStart) { shape() }
    SpecimenLabel(token, MaterialTheme.colors.onBackground)
    SpecimenLabel(value)
  }
}

@Composable
private fun ShapeTile(token: String, value: String, shape: Shape, height: Dp = TILE_H) {
  Tile(token, value) {
    Box(Modifier.size(TILE_W, height).clip(shape).background(tileFill()))
  }
}

private fun dp1(v: Float): String = "%.1f".format(v)

@Composable
private fun SizedIconRow(icon: Painter, text: String, size: Dp) {
  SectionItemView {
    Icon(icon, text, Modifier.size(size), tint = MaterialTheme.colors.secondary)
    TextIconSpaced()
    Text(text)
  }
}

@Composable
private fun GlyphRow(icons: List<Painter>) {
  Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
    icons.forEach { Icon(it, null, tint = MaterialTheme.colors.primary) }
  }
}

@Composable
private fun ColourRow(token: String, source: String, colours: List<Color>) {
  SwatchRow(token, source, colours.joinToString("  ") { hex(it) }) {
    colours.forEach {
      Box(
        Modifier
          .size(30.dp, 22.dp)
          .clip(RoundedCornerShape(5.dp))
          .background(MaterialTheme.colors.onBackground.copy(alpha = 0.12f))
          .padding(1.dp)
          .clip(RoundedCornerShape(4.dp))
          .background(it)
      )
    }
  }
}

@Composable
private fun SwatchRow(token: String, source: String, values: String, swatches: @Composable RowScope.() -> Unit) {
  Row(verticalAlignment = Alignment.CenterVertically) {
    Row(Modifier.width(132.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), content = swatches)
    Column(Modifier.weight(1f)) {
      SpecimenLabel("$token · $source", MaterialTheme.colors.onBackground)
      if (values.isNotEmpty()) SpecimenLabel(values)
    }
  }
}

@Composable
private fun OnFill(text: String, content: Color, fill: Color) {
  Box(Modifier.size(30.dp, 22.dp).clip(RoundedCornerShape(11.dp)).background(fill), contentAlignment = Alignment.Center) {
    Text(text, color = content, fontSize = 12.sp)
  }
}

private fun hex(c: Color): String = "#" + Integer.toHexString(c.toArgb()).padStart(8, '0').uppercase()
