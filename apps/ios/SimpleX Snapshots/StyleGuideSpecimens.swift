import SwiftUI
import UIKit
@testable import SimpleX
@testable import SimpleXChat

struct StyleGuideType_Previews: PreviewProvider {
    static var previews: some View {
        SpecimenTypeScale()
    }
}

struct StyleGuideTypeRoles_Previews: PreviewProvider {
    static var previews: some View {
        SpecimenTypeRoles()
    }
}

struct StyleGuideSpacing_Previews: PreviewProvider {
    static var previews: some View {
        SpecimenSpacing()
    }
}

struct StyleGuideRadii_Previews: PreviewProvider {
    static var previews: some View {
        SpecimenRadii()
    }
}

struct StyleGuideIcons_Previews: PreviewProvider {
    static var previews: some View {
        SpecimenIcons()
    }
}

struct StyleGuideColours_Previews: PreviewProvider {
    static var previews: some View {
        SpecimenColours()
    }
}

private struct SpecimenTypeScale: View {
    var body: some View {
        SpecimenSheet(title: "Type scale · iOS · Dynamic Type text styles") {
            Group {
                SpecimenTypeRow(token: "type.display", styleName: "largeTitle", style: .largeTitle, uiStyle: .largeTitle, weight: .bold, sample: "Settings", note: "screen titles: navigation bar 92, in content 36")
                SpecimenTypeRow(token: "type.title1", styleName: "title", style: .title, uiStyle: .title1, sample: "Alice Smith", note: "sheet titles (bold), call name, keypad · 16")
                SpecimenTypeRow(token: "type.title2", styleName: "title2", style: .title2, uiStyle: .title2, sample: "Alice Smith", note: "profile full name, content section titles · 15")
                SpecimenTypeRow(token: "type.title3", styleName: "title3", style: .title3, uiStyle: .title3, weight: .bold, sample: "Alice", note: "chat row title (bold), onboarding subtitle (medium) · 18")
                SpecimenTypeRow(token: "type.headline", styleName: "headline", style: .headline, uiStyle: .headline, sample: "Toolbar title", note: "toolbar title, card names, primary button (proposed) · 58")
                SpecimenTypeRow(token: "type.body", styleName: "body", style: .body, uiStyle: .body, sample: "Message text", note: "messages, rows, paragraphs · 146")
            }
            Group {
                SpecimenTypeRow(token: "type.callout", styleName: "callout", style: .callout, uiStyle: .callout, sample: "Important footer", note: "important footers (U99), date separator (medium) · 21 + 17")
                SpecimenTypeRow(token: "type.subheadline", styleName: "subheadline", style: .subheadline, uiStyle: .subheadline, sample: "Quote text  12:45", note: "quotes, descriptions, chat row date (top-aligned, U1) · 30")
                SpecimenTypeRow(token: "type.footnote", styleName: "footnote", style: .footnote, uiStyle: .footnote, sample: "Fine print", note: "fine print, link card description · 28")
                SpecimenTypeRow(token: "type.caption", styleName: "caption", style: .caption, uiStyle: .caption1, sample: "12:45  edited", note: "meta, events (light), bubble sender · 75")
                SpecimenTypeRow(token: "type.caption2", styleName: "caption2", style: .caption2, uiStyle: .caption2, sample: "12  status", note: "meta status glyphs, badges above xxxLarge · 4")
                SpecimenLabel(text: "system styles: section headers 172 sites (footnote, upper case), footers 89")
                SpecimenWeights()
            }
        }
    }
}

private struct SpecimenTypeRoles: View {
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        let base = UIFont.preferredFont(forTextStyle: .body).pointSize
        SpecimenSheet(title: "Type roles · iOS") {
            Group {
                SpecimenBlock(label: "primary button label: fixed 17 semibold now (24 sites); .headline proposed, equal at Large") {
                    SpecimenNowProposed {
                        Button {} label: { Text(verbatim: "Continue") }
                            .buttonStyle(OnboardingButtonStyle())
                    } proposed: {
                        Button {} label: { Text(verbatim: "Continue").font(.headline) }
                            .buttonStyle(OnboardingButtonStyle())
                    }
                }
                SpecimenBlock(label: "type.emoji 48 / 36: typed emoji fixed now; sent emoji and proposed relative to .largeTitle (Q3 B)") {
                    SpecimenNowProposed {
                        Text(verbatim: "👍").font(Font(largeEmojiUIFont as CTFont))
                    } proposed: {
                        Text(verbatim: "👍").font(largeEmojiFont)
                    }
                }
                SpecimenBlock(label: "type.chat.sender: bubbles .caption; terminal 13.5 × 17/16 scaled with .body") {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(verbatim: "alice").font(.caption).foregroundColor(theme.colors.secondary)
                        Text(verbatim: "alice").font(.system(size: terminalNameSize)).foregroundColor(theme.colors.secondary)
                        SpecimenLabel(text: "terminal \(specimenPoints(terminalNameSize)) pt")
                    }
                }
                SpecimenBlock(label: "type.numeral 54 bold, fixed in the ring · type.keypad .title") {
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        Text(verbatim: "73%").font(.system(size: 54, weight: .bold)).foregroundColor(theme.colors.primary)
                        Text(verbatim: "1 2 3").font(.title).foregroundColor(theme.colors.secondary)
                    }
                }
            }
            Group {
                SpecimenBlock(label: "type.markdown.heading.chat: bold × 1.25^(3 − level) of the message size") {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        ForEach([1.5625, 1.25, 1] as [CGFloat], id: \.self) { f in
                            Text(verbatim: "Heading").font(.system(size: base * f, weight: .bold))
                        }
                    }
                }
                SpecimenBlock(label: "type.markdown.heading.document: bold × 1.5 / 1.3 / 1.15 / 1") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach([1.5, 1.3, 1.15, 1] as [CGFloat], id: \.self) { f in
                            Text(verbatim: "Heading \(specimenPoints(base * f)) pt").font(.system(size: base * f, weight: .bold))
                        }
                    }
                }
                SpecimenBlock(label: "type.markdown.code: monospaced × 0.875") {
                    Text(verbatim: "let x = 14").font(.system(size: base * 0.875, design: .monospaced))
                }
                SpecimenBlock(label: "content section titles (Q4 C): regular for data labels, bold for prose headings") {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(verbatim: "Delivery").font(.title2)
                        Text(verbatim: "How to use it").font(.title2).bold()
                    }
                }
                SpecimenBlock(label: "type.footer: system footer; important footers .callout (U99)") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "System footer text under a section.").font(.footnote).foregroundColor(theme.colors.secondary)
                        Text(verbatim: "Important footer text under a section.").font(.callout).foregroundColor(theme.colors.secondary)
                    }
                }
            }
        }
    }
}

private struct SpecimenSpacing: View {
    var body: some View {
        SpecimenSheet(title: "Spacing · iOS · pt") {
            SpecimenLabel(text: "relation tokens, the gap drawn at its size")
            VStack(alignment: .leading, spacing: 5) {
                Group {
                    SpecimenGapRow(token: "space.part", value: "2", gaps: [2], relation: "parts of one element")
                    SpecimenGapRow(token: "space.iconText", value: "4", gaps: [4], relation: "an icon and its text")
                    SpecimenGapRow(token: "space.controlParts", value: "6", gaps: [6], relation: "header icon and title")
                    SpecimenGapRow(token: "space.group", value: "8", gaps: [8], relation: "items of one group")
                    SpecimenGapRow(token: "space.content", value: "12", gaps: [12], relation: "inset in a container")
                    SpecimenGapRow(token: "space.chatText", value: "12", gaps: [12], relation: "chat text padding")
                    SpecimenGapRow(token: "space.cardText", value: "16", gaps: [16], relation: "banner text inset")
                }
                Group {
                    SpecimenGapRow(token: "space.edge", value: "16", gaps: [16], relation: "screen and row edge")
                    SpecimenGapRow(token: "space.block", value: "20, 24", gaps: [20, 24], relation: "between blocks")
                    SpecimenGapRow(token: "space.indent", value: "24", gaps: [24], relation: "indented rows")
                    SpecimenGapRow(token: "space.double", value: "32", gaps: [32], relation: "2 × 16 margins")
                    SpecimenGapRow(token: "space.pageEnd", value: "40", gaps: [40], relation: "above a button")
                    SpecimenGapRow(token: "space.scrollEnd", value: "48", gaps: [48], relation: "page bottom")
                }
            }
            SpecimenLabel(text: "space.section: system list spacing · 809 sites use SwiftUI defaults (space.system)")
            SpecimenLabel(text: "steps in use now: sites mapped to each step (inventory of master)")
            SpecimenHistogram(steps: [
                SpecimenStep(step: 0, sites: 105),
                SpecimenStep(step: 2, sites: 64),
                SpecimenStep(step: 4, sites: 119),
                SpecimenStep(step: 6, sites: 57),
                SpecimenStep(step: 8, sites: 111),
                SpecimenStep(step: 10, sites: 54),
                SpecimenStep(step: 12, sites: 84),
                SpecimenStep(step: 16, sites: 62),
                SpecimenStep(step: 20, sites: 35),
                SpecimenStep(step: 24, sites: 16),
                SpecimenStep(step: 32, sites: 10),
                SpecimenStep(step: 40, sites: 1),
                SpecimenStep(step: 48, sites: 9)
            ])
            SpecimenLabel(text: "off-scale values kept until a toggle render: 3, 13, 14, 15, 17, 18 · 15 sites")
            SpecimenLabel(text: "seen together: the Notifications label sits left of settingsRow labels (U92); guide at 36")
            SpecimenNowProposed {
                SpecimenSettingsRows(proposed: false)
            } proposed: {
                SpecimenSettingsRows(proposed: true)
            }
        }
    }
}

private struct SpecimenRadii: View {
    @EnvironmentObject var theme: AppTheme
    @AppStorage(DEFAULT_CHAT_ITEM_ROUNDNESS) private var roundness = defaultChatItemRoundness
    @AppStorage(DEFAULT_PROFILE_IMAGE_CORNER_RADIUS) private var avatarRadius = defaultProfileImageCorner

    var body: some View {
        let r = CGFloat(roundness)
        let textItem = ChatItem.getSample(1, .directRcv, previewDate, "hello")
        SpecimenSheet(title: "Corner radii · iOS · roundness r = \(String(format: "%.2f", roundness))") {
            SpecimenLabel(text: "chat content, scaled by r")
            HStack(alignment: .top, spacing: 8) {
                SpecimenTile(token: "radius.bubble", value: "21.6 × r, quadratic") {
                    fill
                        .modifier(ChatTailPadding())
                        .frame(width: 73, height: 44)
                        .modifier(ChatItemClipped(textItem, tailVisible: true))
                        .padding(.leading, 9)
                }
                SpecimenShapeTile(token: "radius.item", value: "18 × r = \(specimenPoints(18 * r))", radius: 18 * r)
                SpecimenShapeTile(token: "radius.block", value: "12 × r = \(specimenPoints(12 * r))", radius: 12 * r)
                SpecimenShapeTile(token: "radius.inner", value: "8 × r = \(specimenPoints(8 * r))", radius: 8 * r)
            }
            SpecimenLabel(text: "fixed")
            HStack(alignment: .top, spacing: 8) {
                SpecimenTile(token: "radius.bar", value: "2 on a 4 bar") {
                    RoundedRectangle(cornerRadius: 2).fill(tileColour).frame(width: 4, height: 44)
                }
                SpecimenTile(token: "radius.avatar", value: "R \(specimenPoints(avatarRadius)) % of the side") {
                    clipProfileImage(Image(uiImage: specimenImage(UIColor(tileColour))), size: 44, radius: avatarRadius)
                }
                SpecimenShapeTile(token: "radius.tile", value: "22.5 % of the side", radius: 44 * 0.225, width: 44)
                SpecimenShapeTile(token: "radius.pill", value: "half the height", radius: 14, height: 28)
            }
            HStack(alignment: .top, spacing: 8) {
                SpecimenShapeTile(token: "radius.card", value: "16", radius: 16)
                SpecimenShapeTile(token: "radius.card.large", value: "18", radius: 18)
                SpecimenShapeTile(token: "radius.card.hero", value: "24", radius: 24)
                SpecimenShapeTile(token: "radius.media", value: "12", radius: 12)
            }
            HStack(alignment: .top, spacing: 8) {
                SpecimenShapeTile(token: "radius.field", value: "10", radius: 10)
                SpecimenShapeTile(token: "radius.compose", value: "20 on 41 high", radius: 20, height: 41)
                SpecimenShapeTile(token: "radius.sheet", value: "user picker 10; system", radius: 10)
                SpecimenShapeTile(token: "list thumbnail", value: "8 fixed (U7)", radius: 8, width: 38, height: 38)
            }
            SpecimenLabel(text: "changes: now → proposed")
            HStack(alignment: .top, spacing: 8) {
                SpecimenTile(token: "deleted item", value: "now 8 × r") {
                    fill.frame(width: 82, height: 44).modifier(ChatItemClipped(ChatItem.getDeletedContentSample(), tailVisible: false))
                }
                SpecimenTile(token: "deleted item", value: "proposed bubble, no tail (U33)") {
                    fill.frame(width: 82, height: 44).modifier(ChatItemClipped(textItem, tailVisible: false))
                }
                SpecimenShapeTile(token: "connect banner", value: "now 18", radius: 18)
                SpecimenShapeTile(token: "connect banner", value: "proposed 16 (Q11)", radius: 16)
            }
        }
    }

    private var tileColour: Color { theme.colors.primary.opacity(0.28) }

    private var fill: some View { Rectangle().fill(tileColour) }
}

private struct SpecimenIcons: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dynamicTypeSize) private var userFont

    var body: some View {
        let sizes = specimenIconSizes[userFont] ?? specimenIconSizes[.large]!
        let headerIcon = 14 * UIFont.preferredFont(forTextStyle: .caption1).pointSize / 12
        SpecimenSheet(title: "Icons · iOS · SF Symbols, weight from the text") {
            Group {
                SpecimenLabel(text: "icon.inline · the text style of the line")
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    (Text(Image(systemName: "checkmark")) + Text(verbatim: " 12:45")).font(.caption)
                    (Text(Image(systemName: "bell.slash")) + Text(verbatim: " Muted")).font(.subheadline)
                    (Text(Image(systemName: "lock")) + Text(verbatim: " Encrypted")).font(.body)
                }
                .foregroundColor(theme.colors.secondary)
                SpecimenLabel(text: "icon.row · settingsRow: the symbol in a 24 × 24 slot, text at 36; guide at 36")
                SpecimenSettingsRows(proposed: true)
                SpecimenLabel(text: "icon.bubble · fixed 30, 14 and 16 now; DynamicSizes columns proposed (Q3 B): \(specimenPoints(sizes.file)), \(specimenPoints(headerIcon)), \(specimenPoints(sizes.context))")
                SpecimenNowProposed {
                    bubbleIcons(file: 30, header: 14, context: 16)
                } proposed: {
                    bubbleIcons(file: sizes.file, header: headerIcon, context: sizes.context)
                }
            }
            Group {
                SpecimenLabel(text: "icon.close multiply · icon.failure xmark in a checkmark slot · icon.clear xmark.circle.fill")
                HStack(spacing: 18) {
                    Image(systemName: "multiply")
                    Image(systemName: "xmark")
                    Image(systemName: "xmark.circle.fill")
                }
                .font(.body)
                .foregroundColor(theme.colors.secondary)
                SpecimenLabel(text: "'Cancel file' is drawn with xmark now; multiply proposed")
                SpecimenNowProposed {
                    menuItem("xmark")
                } proposed: {
                    menuItem("multiply")
                }
                SpecimenLabel(text: "icon.fill · 'photo.on.rectangle.fill' is not a symbol, so the button is empty now")
                SpecimenNowProposed {
                    Image(systemName: "photo.on.rectangle.fill").font(.body).foregroundColor(theme.colors.primary).frame(height: 24)
                } proposed: {
                    Image(systemName: "photo.fill.on.rectangle.fill").font(.body).foregroundColor(theme.colors.primary).frame(height: 24)
                }
            }
        }
    }

    private func bubbleIcons(file: CGFloat, header: CGFloat, context: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "doc.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: file, height: file)
                    .foregroundColor(Color(uiColor: .tertiaryLabel))
                Text(verbatim: "report.pdf").font(.body)
            }
            HStack(spacing: 6) {
                Image(systemName: "flag")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: header, height: header)
                    .foregroundColor(theme.colors.secondary)
                Text(verbatim: "archived report").font(.caption).italic().foregroundColor(theme.colors.secondary)
            }
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: context, height: context)
                    .foregroundColor(theme.colors.secondary)
                Text(verbatim: "Reply").font(.body)
            }
        }
    }

    private func menuItem(_ icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(verbatim: "Cancel file")
        }
        .font(.body)
        .foregroundColor(.red)
    }
}

private struct SpecimenColours: View {
    @EnvironmentObject var theme: AppTheme

    var body: some View {
        let c = theme.colors
        let a = theme.appColors
        SpecimenSheet(title: "Colour roles · iOS · \(c.isLight ? "LIGHT" : "DARK") theme") {
            Group {
                SpecimenColourRow(token: "colour.accent", source: "theme primary", colours: [UIColor(c.primary)])
                SpecimenColourRow(token: "colour.accent.badge", source: "theme primaryVariant (= primary here; #1298A5 in SIMPLEX)", colours: [UIColor(c.primaryVariant)])
                SpecimenSwatchRow(token: "colour.onAccent", source: "white on primary", values: "") {
                    Text(verbatim: "12").font(.caption).foregroundColor(.white).frame(width: 30, height: 22).background(Capsule().fill(c.primary))
                }
                SpecimenColourRow(token: "colour.text", source: "theme onBackground", colours: [UIColor(c.onBackground)])
                SpecimenColourRow(token: "colour.text.secondary", source: "theme secondary; system secondaryLabel at 61 sites (Q16)", colours: [UIColor(c.secondary), .secondaryLabel])
                SpecimenSwatchRow(token: "Q16 headers", source: "theme secondary, then system secondaryLabel", values: "") {
                    Text(verbatim: "CHATS").font(.footnote).foregroundColor(c.secondary)
                    Text(verbatim: "CHATS").font(.footnote).foregroundColor(Color(uiColor: .secondaryLabel))
                }
                SpecimenColourRow(token: "colour.icon.faded", source: "UIColor.tertiaryLabel", colours: [.tertiaryLabel])
            }
            Group {
                SpecimenColourRow(token: "colour.background", source: "theme background", colours: [UIColor(c.background)])
                SpecimenColourRow(token: "colour.canvas", source: "background.asGroupedBackground", colours: [UIColor(c.background.asGroupedBackground(theme.base.mode))])
                SpecimenColourRow(token: "colour.card", source: "secondarySystemGroupedBackground, tertiarySystemFill", colours: [.secondarySystemGroupedBackground, .tertiarySystemFill])
                SpecimenColourRow(token: "colour.surface", source: "theme surface (menus)", colours: [UIColor(c.surface)])
                SpecimenColourRow(token: "colour.bubble", source: "sent, sent quote, received, received quote", colours: [UIColor(a.sentMessage), UIColor(a.sentQuote), UIColor(a.receivedMessage), UIColor(a.receivedQuote)])
            }
            Group {
                SpecimenColourRow(token: "colour.destructive", source: "system red", colours: [.systemRed])
                SpecimenColourRow(token: "colour.warning", source: "system orange", colours: [.systemOrange])
                SpecimenColourRow(token: "colour.caution", source: "system yellow", colours: [.systemYellow])
                SpecimenColourRow(token: "colour.success", source: "system green", colours: [.systemGreen])
                SpecimenColourRow(token: "colour.incognito", source: "system indigo", colours: [.systemIndigo])
                SpecimenColourRow(token: "colour.selection", source: "accent at 0.1", colours: [UIColor(c.primary.opacity(0.1))])
                SpecimenColourRow(token: "colour.scrim", source: "black 0.121 light, 0.29 dark", colours: [UIColor.black.withAlphaComponent(c.isLight ? 0.121 : 0.29)])
                SpecimenSwatchRow(token: "colour.overlay.media", source: "black 0.35 disc, white glyph, on a received quote fill", values: "") {
                    ZStack {
                        Rectangle().fill(a.receivedQuote)
                        Circle().fill(Color.black.opacity(0.35)).frame(width: 20, height: 20)
                        Image(systemName: "play.fill").font(.system(size: 9)).foregroundColor(.white)
                    }
                    .frame(width: 30, height: 22)
                }
            }
        }
    }
}

private struct SpecimenSheet<Content: View>: View {
    @EnvironmentObject var theme: AppTheme
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.system(size: 15, weight: .semibold))
            content()
        }
        .foregroundColor(theme.colors.onBackground)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.background)
    }
}

private struct SpecimenLabel: View {
    @EnvironmentObject var theme: AppTheme
    var text: String
    var strong = false

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 10))
            .foregroundColor(strong ? theme.colors.onBackground : theme.colors.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SpecimenBlock<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SpecimenLabel(text: label)
            content()
        }
    }
}

private struct SpecimenNowProposed<Now: View, Proposed: View>: View {
    @ViewBuilder var now: () -> Now
    @ViewBuilder var proposed: () -> Proposed

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                SpecimenLabel(text: "now")
                now()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                SpecimenLabel(text: "proposed")
                proposed()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SpecimenTypeRow: View {
    var token: String
    var styleName: String
    var style: Font.TextStyle
    var uiStyle: UIFont.TextStyle
    var weight: Font.Weight? = nil
    var sample: String
    var note: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                SpecimenLabel(text: token, strong: true)
                SpecimenLabel(text: ".\(styleName) · \(specimenPoints(UIFont.preferredFont(forTextStyle: uiStyle).pointSize)) pt")
            }
            .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: sample).font(.system(style)).fontWeight(weight)
                SpecimenLabel(text: note)
            }
        }
    }
}

private struct SpecimenWeights: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SpecimenLabel(text: "weights at .body: light (events), regular, medium (text buttons), semibold (headline), bold (titles)")
            HStack(spacing: 10) {
                ForEach([Font.Weight.light, .regular, .medium, .semibold, .bold], id: \.self) { w in
                    Text(verbatim: "Chat").font(.body).fontWeight(w)
                }
            }
        }
    }
}

private struct SpecimenGapRow: View {
    @EnvironmentObject var theme: AppTheme
    var token: String
    var value: String
    var gaps: [CGFloat]
    var relation: String

    var body: some View {
        HStack(spacing: 0) {
            SpecimenLabel(text: "\(token) · \(value)", strong: true)
                .frame(width: 116, alignment: .leading)
            ForEach(gaps.indices, id: \.self) { i in
                HStack(spacing: 0) {
                    block
                    Rectangle().fill(theme.colors.primary.opacity(0.35)).frame(width: gaps[i], height: 14)
                    block
                }
                .padding(.trailing, 8)
            }
            SpecimenLabel(text: relation)
        }
    }

    private var block: some View {
        Rectangle().fill(theme.colors.secondary.opacity(0.45)).frame(width: 14, height: 14)
    }
}

private struct SpecimenStep: Hashable {
    var step: Int
    var sites: Int
}

private struct SpecimenHistogram: View {
    @EnvironmentObject var theme: AppTheme
    var steps: [SpecimenStep]

    var body: some View {
        let top = CGFloat(steps.map { $0.sites }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(steps, id: \.step) { s in
                VStack(spacing: 2) {
                    SpecimenLabel(text: "\(s.sites)")
                    Rectangle()
                        .fill(theme.colors.primary.opacity(0.6))
                        .frame(width: 14, height: max(1, 90 * CGFloat(s.sites) / top))
                    SpecimenLabel(text: "\(s.step)", strong: true)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SpecimenSettingsRows: View {
    @EnvironmentObject var theme: AppTheme
    var proposed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if proposed {
                settingsRow("bolt", color: theme.colors.secondary) { Text(verbatim: "Notifications") }
            } else {
                HStack {
                    Image(systemName: "bolt")
                        .padding(.trailing, 9)
                        .foregroundColor(theme.colors.secondary)
                    Text(verbatim: "Notifications")
                }
            }
            settingsRow("internaldrive", color: theme.colors.secondary) { Text(verbatim: "Database") }
        }
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(theme.colors.primary.opacity(0.6))
                .frame(width: 1)
                .padding(.leading, 36)
        }
    }
}

private struct SpecimenTile<Sample: View>: View {
    var token: String
    var value: String
    @ViewBuilder var sample: () -> Sample

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            sample().frame(width: 82, height: 44, alignment: .leading)
            SpecimenLabel(text: token, strong: true)
            SpecimenLabel(text: value)
        }
        .frame(width: 82, alignment: .leading)
    }
}

private struct SpecimenShapeTile: View {
    @EnvironmentObject var theme: AppTheme
    var token: String
    var value: String
    var radius: CGFloat
    var width: CGFloat = 82
    var height: CGFloat = 44

    var body: some View {
        SpecimenTile(token: token, value: value) {
            RoundedRectangle(cornerRadius: radius)
                .fill(theme.colors.primary.opacity(0.28))
                .frame(width: width, height: height)
        }
    }
}

private struct SpecimenSwatchRow<Swatches: View>: View {
    var token: String
    var source: String
    var values: String
    @ViewBuilder var swatches: () -> Swatches

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(spacing: 4) { swatches() }
                .frame(width: 132, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                SpecimenLabel(text: "\(token) · \(source)", strong: true)
                if !values.isEmpty {
                    SpecimenLabel(text: values)
                }
            }
        }
    }
}

private struct SpecimenColourRow: View {
    @EnvironmentObject var theme: AppTheme
    var token: String
    var source: String
    var colours: [UIColor]

    var body: some View {
        let trait = UITraitCollection(userInterfaceStyle: theme.colors.isLight ? .light : .dark)
        SpecimenSwatchRow(token: token, source: source, values: colours.map { specimenHex($0.resolvedColor(with: trait)) }.joined(separator: "  ")) {
            ForEach(colours.indices, id: \.self) { i in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: colours[i]))
                    .frame(width: 28, height: 20)
                    .padding(1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(theme.colors.onBackground.opacity(0.12)))
            }
        }
    }
}

private let specimenIconSizes: [DynamicTypeSize: (file: CGFloat, context: CGFloat)] = [
    .xSmall: (26, 13.2),
    .small: (27, 14.1),
    .medium: (28, 15.1),
    .large: (30, 16),
    .xLarge: (34, 17.9),
    .xxLarge: (38, 19.8),
    .xxxLarge: (42, 21.6),
    .accessibility1: (52, 26.4),
    .accessibility2: (61, 31.1),
    .accessibility3: (74, 37.6),
    .accessibility4: (87, 44.2),
    .accessibility5: (99, 49.9)
]

private func specimenPoints(_ v: CGFloat) -> String {
    v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v)
}

private func specimenHex(_ c: UIColor) -> String {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getRed(&r, green: &g, blue: &b, alpha: &a)
    func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
    let rgb = String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    return a < 1 ? rgb + String(format: " a%.2f", a) : rgb
}

private func specimenImage(_ color: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
        color.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    }
}
