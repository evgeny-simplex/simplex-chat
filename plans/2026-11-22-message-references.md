# Message references: links to messages across chats

## Problem

A person or an agent can point to a message only inside its chat, by a quote, or by forwarding a copy. From a short line in one chat, such as a list of open questions, the reader cannot open another chat at the message the line is about. A reader who is not in a public channel cannot be sent to one of its posts. Agents cannot produce or follow such a pointer.

## Acceptance

| # | After the change | Before |
|---|---|---|
| A1 | at "Copy link" in the menu of a message in a contact, group or channel chat, the app puts its message link on the clipboard | the menu offers Copy of the text only |
| A2 | `[label](link)` and a bare link in a message are shown as a tappable label | global forms: a channel link; local forms: plain text |
| A3 | at a tap, the app opens the chat at the message for a reader who has it, runs the connection flow of a public chat for a reader who is not in it, and shows an alert otherwise | global forms: the connection flow; local forms: plain text |
| A4 | a link opened from a web page or another app is handled as in A3 | global forms: the connection flow; local forms: "Error: URL is invalid" (iOS), a connection error (Android, desktop) |
| A5 | local links are replaced by their labels in a forward to another chat, and global links are kept where SimpleX links are allowed; all links are kept when the forward is to the same chat or to notes | the text is forwarded unchanged |
| A6 | where SimpleX links are prohibited for the sender, a global message link is refused as a SimpleX link, and local message links are sent | global forms: refused as SimpleX links |
| A7 | apps of earlier versions open a global message link as its chat and show local links as text | — |
| A8 | the plugin's `link` returns the link of a message; `open` returns the message of a link, or the public chat to connect to | — |

## Options

| Option | Cost |
|---|---|
| A. URI in the message text, parsed by the core's markdown | parser, one `Format` constructor, three commands, app rendering; protocol and database unchanged; copy, paste and links from web pages are supported |
| B. Side map in `MsgContainer`, as `mentions` (Protocol.hs:697), with markers in the text | fields in `XMsgNew` and `XMsgUpdate`, a database table, a compose API for apps and bots; the links are lost at copy and paste; earlier apps show the markers |
| C. A message content type with one link and a preview, as `MCChat` (Protocol.hs:752) | protocol type, card UI, one link per message; the text of a private chat is copied into the preview for a new audience |

A is chosen: it is the cheapest, and the only option with copy, paste and links from web pages.

## Format

Message IDs are 12 random bytes in base64, 16 bytes in all (Store/Messages.hs:241-260, Store/Shared.hs:641-642, 660-661); history welcome messages have 24 random bytes (Internal.hs:1444). Every member stores a group message with the author's member ID and the same message ID, relayed messages included (Subscriber.hs:4066-4071). The keys of a p2p group are the member's own (`GKGroup`, Types.hs:493-495), and a message of a group is found by the author's member ID and the message ID (Store/Messages.hs:3092-3109). A public chat served by relays is identified by `publicGroupId`, the hash of its root key, which is the entity ID of its short link (Types.hs:910-916; Commands.hs:2795-2797, 4688-4695).

Schemes (Q1): `simplex:` is the scheme of URIs in the SimpleX network: connection links, SimpleX names (simplexmq SimplexName.hs:113), files (simplexmq FileTransfer/Description.hs:283) and message links. `simplexchat:` is the scheme of app-specific deep links, such as badge links (plans/2026-09-24-badge-buy-in-browser.md:43). The comments that state another rule (ContentView.swift:506, ChatListView.kt:816) are changed to these roles.

| Kind | Chats | A reader who is not in the chat | Forms |
|---|---|---|---|
| global | public chats served by relays: channels now, public groups later | can connect | the chat's short link in its https form on its server host or in its `simplex:` form, or `simplex:/name` with the chat's SimpleX name; each with `m`, and `a` for a message of a member |
| local `g` | p2p groups and business chats | cannot connect | `simplex:/m#g/<msg-id>?a=<author>` |
| local `d` | contacts | cannot connect | `simplex:/m#d/<msg-id>` |

```
msg-link     = global-link | local-link
global-link  = short link of a group (CCTChannel or CCTGroup), https or simplex: form, with m and a added to its query
             | "simplex:/name#" public-name "?" query
local-link   = "simplex:/m#" kind "/" msg-id [ "?" query ]
kind         = "g"   p2p group or business chat
             | "d"   contact
public-name  = the domain of SimplexNameInfo with NTPublicGroup (simplexmq SimplexName.hs:110-132)
msg-id       = SharedMsgId bytes, base64url without padding
query        = query string, values percent-encoded, unknown names ignored
  m          = msg-id                                           global links: required
  a          = author MemberId, base64url without padding       kind g: required; global links: absent for messages sent as the chat
  h, p, c    = the server parameters of a short link, as now
```

Examples:

```
https://smp18.simplex.im/c#3tR8_b50RNZQtPkDs0Z3IxdfsszHxdyZYWQ4KHOyifg?m=Z21RRHdMR1NzSmlyNDBYeA
simplex:/c#3tR8_b50RNZQtPkDs0Z3IxdfsszHxdyZYWQ4KHOyifg?h=smp18.simplex.im&m=Z21RRHdMR1NzSmlyNDBYeA
simplex:/name#privacy.simplex?m=Z21RRHdMR1NzSmlyNDBYeA
simplex:/m#g/Z21RRHdMR1NzSmlyNDBYeA?a=UWRoR05KMk16UG1hSGRpag
simplex:/m#d/Z21RRHdMR1NzSmlyNDBYeA
```

- A public group served by relays has a short link of type `g`, with the same parameters: `https://<host>/g#<key>?m=…&a=…`. The connect plan handles links of types `c` and `g` alike (Commands.hs:4652-4653); today a relay link of another type than a channel gets `GLPUpdateRequired` (Commands.hs:4685, 4715-4717), and forward attribution already maps type `g` to `GTGroup` (Internal.hs:281-284). The global form needs no change for public groups.
- A global link is produced for a chat with a `PublicGroupProfile` (Types.hs:910-916). A short link of a group with `m`, also of a p2p group with a group link, is parsed as a global link and resolved by the same connect plan.
- The short-link parser reads only `h`, `p` and `c` of the query (simplexmq Agent/Protocol.hs:1779-1786), so `m` and `a` are reserved there for message links, and earlier cores parse a global message link as the chat's link. Apps of earlier versions show it and open it as the chat, in messages and from outside: SMP servers serve the paths `/c` and `/g` in their app association files and link pages (simplexmq apps/common/Web/static/.well-known/apple-app-site-association, apps/smp-server/SMPWeb.hs:23-24), and iOS opens `*.simplex.im` links in the app (SimpleX (iOS).entitlements:12).
- The query of the fragment is kept in the app URI built by the link page of SMP servers (simplexmq apps/common/Web/static/media/contact.js:23-33), so the app receives a message link opened in a browser with `m`.
- The name form uses the URI prefix that the SimpleX name parser accepts (simplexmq SimplexName.hs:113) and the names that connect accepts (Types.hs:1915-1920). Earlier cores show it as text, as their markdown parses no `simplex:/name` URI (Markdown.hs:506-518), and it is refused by their connect, as the domain parser consumes the word up to a space and fails at `?` (simplexmq SimplexName.hs:101-108, 120-124).
- `simplex:/m#…` is refused as a connection link: `m` is neither a short-link type letter (simplexmq Agent/Protocol.hs:1775-1778, 1809-1815) nor a full-link mode (Agent/Protocol.hs:1308). Earlier cores show it as text; opened from outside, earlier apps show "Error: URL is invalid" (ContentView.swift:476-486) or a connection error (ChatListView.kt:808-812).
- The fields of a global link are those of `ForwardLink` (Protocol.hs:710-717) without `displayName`, and with the link or the SimpleX name in place of `publicGroupId`. The author is set by the rule of `chatItemMember` (Messages.hs:374-380), as in forwards (Commands.hs:1158).
- The message part of kind `g` and of global links is the identity of `MsgRef` in quotes (Protocol.hs:236-242).
- A `simplex:/m#` link of an unknown kind is parsed as `MLUnknown` with its text, so no format change is required for a later kind.

Types, Types.hs:

```haskell
data MsgLink
  = MLPublicGroup
      { publicChat :: ContactNameOrLink, -- Types.hs:1891: a CCTChannel or CCTGroup link, or an NTPublicGroup name, by the parser
        memberId :: Maybe MemberId,
        msgId :: SharedMsgId
      }
  | MLGroup
      { memberId :: MemberId,
        msgId :: SharedMsgId
      }
  | MLDirect {msgId :: SharedMsgId}
  | MLUnknown {linkText :: Text}

data MsgLinkType = MLTPublicGroup | MLTGroup | MLTDirect | MLTUnknown

instance StrEncoding MsgLink    -- the forms above; the link of CTLink keeps its https or simplex: scheme (SLSServer, SLSSimplex)
-- JSON: the link string, by strToJSON and strParseJSON
```

The link of an item, Messages.hs:

```haskell
itemMsgLink :: ChatInfo c -> ChatItem c d -> Either String MsgLink
itemMsgLink cInfo ci@ChatItem {meta = CIMeta {itemSharedMsgId}} = case (cInfo, itemSharedMsgId) of
  (DirectChat _, Just msgId) -> Right $ MLDirect msgId
  (GroupChat g@GroupInfo {groupProfile = GroupProfile {publicGroup}} _, Just msgId) -> case publicGroup of
    Just PublicGroupProfile {groupLink} -> Right $ MLPublicGroup (CTLink groupLink) (memberId' <$> chatItemMember g ci) msgId
    Nothing -> maybe (Left "message has no author") (Right . (`MLGroup` msgId) . memberId') $ chatItemMember g ci
  _ -> Left "message has no link"
```

`groupLink` is stored in its https form on the server host (Commands.hs:4902-4903), so "Copy link" of a message in a public chat gives the https form (Q3).

## Privacy

| Kind | Readers who open it | What any other reader learns |
|---|---|---|
| global | members of the public chat; others connect to it by the link or the name | the chat, the message's ID and the author's member ID, all public in the chat |
| `g` | members who have the message | two random IDs; links with the same `a` refer to one author in one group |
| `d` | the two parties | one random ID |

- Access to a message is not given by its link: only a reader who has the message can open it.
- The core resolves a link from the local database and sends no request. For a public chat that the reader is not in, its link data is then fetched from its server by the connection flow, as for its link; `m` and `a` are not sent.
- When a link in its https form is opened in a browser, the server's link page is requested; the fragment, with `m` and `a`, is not sent to the server (simplexmq apps/common/Web/static/link.html:150).
- The label is text of the writer and is visible to every reader. The apps do not fill it from the referenced message (Q4).
- The core searches only the user given by the app: the user of the chat where the link is tapped, or the active user for a link opened from outside the app. Other profiles, hidden ones included, are not searched.
- The oldest matching item is opened. A copy planted by a peer who read the link is created later than the original in the reader's database.

## Resolution

```mermaid
flowchart TD
  L[message link] --> K{kind}
  K -->|global| C1[connect plan of the link or name, local search only]
  C1 -->|GLPKnown or GLPOwnLink| C2[item by author and message ID]
  C1 -->|not resolved locally, or another plan| J[join: the link or name]
  C2 -->|found| I[item]
  C2 -->|absent| CH[chat without the item]
  K -->|g| G1[oldest item by author member ID and message ID]
  G1 -->|found| I
  G1 -->|absent| G2[group with a member of that member ID]
  G2 -->|found| CH
  G2 -->|absent| N[not found]
  K -->|d| D1[oldest contact item by message ID]
  D1 -->|found| I
  D1 -->|absent| N
  K -->|other| U[unknown link]
```

```haskell
-- Controller.hs
data MsgLinkPlan
  = MLPItem {chatItem :: AChatItem}
  | MLPChat {chatInfo :: AChatInfo}
  | MLPJoin {connTarget :: AConnectTarget} -- Types.hs:1898-1899, JSON as a string
  | MLPNotFound
  | MLPUnknownLink

-- Internal.hs
msgLinkPlan :: User -> MsgLink -> CM MsgLinkPlan
```

```
msgLinkPlan user link:
  MLPublicGroup target author msgId:
    connectPlan user (ACTarget SCMContact (CTShortContact target)) PRMNever Nothing Nothing
      CPGroupLink (GLPKnown g ..) or CPGroupLink (GLPOwnLink g):
        publicItemId g author msgId
          Just itemId -> MLPItem (item of g and itemId)
          Nothing     -> MLPChat g
      CENotResolvedLocally, or another plan -> MLPJoin target
  MLGroup author msgId:
    getGroupItemIdByAuthor author msgId
      Just (gId, itemId) -> MLPItem (item of gId and itemId)
      Nothing -> getGroupIdByMemberId author
        Just gId -> MLPChat (group gId)
        Nothing  -> MLPNotFound
  MLDirect msgId:
    getDirectItemIdByMsgId msgId
      Just (ctId, itemId) -> MLPItem (item of ctId and itemId)
      Nothing             -> MLPNotFound
  MLUnknown _ -> MLPUnknownLink
item of chat and itemId = getAChatItem (Store/Messages.hs:3376-3393), with the scope of getGroupChatScopeForItem_ (Store/Messages.hs:1510)
```

- With `PRMNever`, the connect plan is limited to the local search (Controller.hs:728-732): a public chat is found by its link (Commands.hs:4718-4722) or by its verified name (Store/Groups.hs:1116-1134); otherwise the plan is refused with `CENotResolvedLocally` (Commands.hs:4674-4676).
- `publicItemId` is the item lookup of `forwardLinkCIFF` (Internal.hs:285-292) moved into one function, used by both.
- `getGroupItemIdByAuthor`, Store/Messages.hs: the join of `getGroupMemberCIBySharedMsgId` (Store/Messages.hs:3092-3109) without the group, `WHERE m.user_id = ? AND m.member_id = ? AND i.shared_msg_id = ?`, `ORDER BY i.chat_item_id ASC LIMIT 1`. Own items, stored with `group_member_id` NULL, are matched by the own membership row.
- `getDirectItemIdByMsgId`, Store/Messages.hs: `WHERE user_id = ? AND contact_id IS NOT NULL AND shared_msg_id = ?`, `ORDER BY chat_item_id ASC LIMIT 1`. The user's entries of `idx_chat_items_direct_shared_msg_id` (chat_schema.sql:1031-1035) are scanned; the time on a database with 1 million contact items is measured before review.
- A deleted or moderated item is returned as an item. For an item removed by deletion or by the chat's time to live, the plan is `MLPChat` for a group or a public chat, and `MLPNotFound` for a contact.
- No database row is written by resolution.

A reader who is not in the public chat:

```mermaid
sequenceDiagram
  actor U as Reader
  participant A as App
  participant C as Core
  participant S as SMP server of the link
  participant R as Chat relays
  U->>A: tap a global message link
  A->>C: /_msg link plan, local
  C-->>A: MLPJoin with the link or name
  A->>C: planAndConnect, as for the chat's link (v1)
  C->>S: link data of the chat, after the name is resolved for the name form
  C-->>A: GLPOk with the chat's profile
  U->>A: Join
  A->>C: connect to the prepared group
  C->>R: join through the relays
  R-->>C: the last 100 messages, with History on (Internal.hs:1424, Subscriber.hs:977-983)
  A->>A: open the chat at its last messages (v1)
  Note over A,C: later: /_msg link plan again at each new item of the chat, until MLPItem
  A->>A: open the chat at the message (later)
  Note over C,R: later: a request to the relays for history up to the message
```

## Markdown

Markdown.hs:

```haskell
data Format
  = ...
  | MessageLink {showText :: Maybe Text, linkType :: MsgLinkType, msgLink :: MsgLink}
```

| Form | Result |
|---|---|
| `[label](link)` | `MessageLink (Just label)` |
| `<link>` | `MessageLink Nothing` |
| bare link | `MessageLink Nothing` |
| a short link without `m` | `SimplexLink`, as now |
| a known form with an invalid field | text, or the chat's link, as now |

- `linkType` is set by the parser from `msgLink`, as `linkType` of `SimplexLink` (Markdown.hs:546-567).
- `linkMD` and `hyperLinkFormat` (Markdown.hs:461-467, 506-518) try `MsgLink` before `AConnectionLink`.
- `sowLinkP` (Markdown.hs:450-456): the label is any text up to `]` without `[` or a line break. The punctuation rule of web hyperlinks (Markdown.hs:453-454) is not applied. A label with a link in its own markdown (`isLink`) is refused: the label is left as text and the link is parsed bare, as for spoofed web links (MarkdownTests.hs:344-348).
- A bare link is parsed whole first, then without its trailing punctuation (`linkEndLength`, Markdown.hs:519-532), so a final `-` of an ID is kept.
- `markdownText` returns the source text, as for `SimplexLink` (Markdown.hs:978).
- `MessageLink` is included in `isLink`, so `hasLink` is set for the item (Internal.hs:3159-3167). `MessageLink` with `MLPublicGroup` is included in `isSimplexLink` (Markdown.hs:315-318), so the group preference is applied at send (Commands.hs:5076), edit (Commands.hs:854) and receive (Subscriber.hs:2260, 2336, 2357), and in member profiles (Internal.hs:1376-1385), as earlier cores apply it to the chat's link.

## Core API

| Command | Syntax | Response |
|---|---|---|
| `APIGetChatItemLink {chatRef, chatItemId}` | `/_get item link <chatRef> <chatItemId>` | `CRChatItemLink {user, msgLink}` |
| `ShowChatItemLink {chatName, msg}` | `/item link <chatName> <text>`, as `/item info` (Commands.hs:3567-3570, 7109) | the same |
| `APIMsgLinkPlan {userId, msgLink}` | `/_msg link plan <userId> <msgLink>` | `CRMsgLinkPlan {user, msgLinkPlan}` |

- `APIGetChatItemLink`: `getAChatItem`, then `itemMsgLink`; `Left` is returned as a command error. Notes and items without a message ID, such as group events, are refused.
- CLI views, View.hs: the link is printed for `CRChatItemLink`; for `CRMsgLinkPlan`, the chat and the item line, or `message link: not in your chats`, `message link: the message is not in CHAT`, `message link: connect with TARGET`, `message link: unknown link type`.
- Bots API: `APIGetChatItemLink` and `APIMsgLinkPlan` in the category "Message commands" (bots/src/API/Docs/Commands.hs:95-111), the types `MsgLink` (string), `MsgLinkType`, `MsgLinkPlan` and `Format.MessageLink`; bots/api/*.md and the TypeScript and Python types are generated again.

## Forwards

```mermaid
flowchart TD
  F[content of a forwarded item] --> S{destination}
  S -->|the source chat| K[all links kept]
  S -->|notes| K
  S -->|another chat| P[each link]
  P -->|global, SimpleX links allowed in the destination| KC[kept]
  P -->|global, SimpleX links prohibited for the user| R
  P -->|local, unknown kind| R[replaced by its label, or by the default text without a label]
```

- In each destination branch of `APIForwardChatItems` (Commands.hs:1109-1130), the result of `prepareForward` (Commands.hs:1134-1257) is mapped by `forwardedLinks keep`, after the mention names (Commands.hs:1161-1166) and the owner signature (Commands.hs:1186-1190) are set: the content of each `ComposedMessageReq` (Commands.hs:5391) is changed, and its texts are computed again by `msgContentTexts` (Internal.hs:368-369).
- `keep` is `const True` when `toChat == fromChat` and in the notes branch. In the group branch, after `getGroupInfoKeys` (Commands.hs:1122), it is `const False` where SimpleX links are prohibited for the user (`groupFeatureMemberAllowed SGFSimplexLinks`, as in Internal.hs:431), and `isGlobalLink` otherwise. In the contact branch, it is `isGlobalLink`. A forward is thus never refused for its message links.
- `forwardedLinks :: (MsgLink -> Bool) -> MsgContent -> MsgContent`, Messages.hs, beside `parsedMsgContent` (Messages.hs:633-637): the content is parsed by `parsedMsgContent`, each replaced segment is changed to its label or to the default text (Q2), and `text` is set to the concatenation of `markdownText` of the segments, as in `updatedMentionNames` (Internal.hs:294-301).
- A new message, as opposed to a forward, is sent as written.

## Apps

```mermaid
sequenceDiagram
  actor U as User
  participant A as App
  participant C as Core
  U->>A: tap a message link, or open one from outside
  A->>C: /_msg link plan userId link
  C-->>A: CRMsgLinkPlan
  alt item
    A->>A: open the chat around the item, or scroll in the open chat
  else chat
    A->>A: open the chat, then the alert of Q5
  else join
    A->>A: planAndConnect with the link or name
  else not found
    A->>A: alert "This message is not in your chats."
  else unknown link
    A->>A: alert "Update the app to open this link."
  end
```

| Part | iOS | Android and desktop |
|---|---|---|
| `Format` and `MsgLinkType` | SimpleXChat/ChatTypes.swift:6008-6027 | ChatModel.kt:5382-5412 |
| commands and `MsgLinkPlan` | Shared/Model/AppAPITypes.swift, Shared/Model/SimpleXAPI.swift | model/SimpleXAPI.kt |
| rendering and tap | MsgContentView.swift:300-313, 653-665: an attribute key for message links | TextItemView.kt:401-416, 489-504: the annotation `MESSAGE_LINK` |
| open at the item | `ItemsModel.loadOpenChatNoWait(chatId, itemId)` (ChatModel.swift:143-157), as the forward header (FramedItemView.swift:117-123) | `openChat(null, rhId, chatType, apiId, itemId)` (ChatListNavLinkView.kt:212-236), as FramedItemView.kt:362-370 |
| link from outside | `connectViaUrl_` (ContentView.swift:463-488): a URL that the core parses as a message link goes to the plan before the path switch, for the paths `/m`, `/c`, `/g` and `/name` | `connectIfOpenedViaUri` (ChatListView.kt:800-814): the same check before `planAndConnect` |
| Copy link | the item menu (ChatView.swift:2447-2507) | `MsgContentItemDropdownMenu` (ChatItemView.kt:394-451) |
| link pasted in search | `strConnectTarget` (NewChatView.swift:860-872), then the plan | `strConnectTarget` (NewChatView.kt:834), then the plan |

- The label is `showText`, or the generic label of Q4. At long-press, the app opens the item menu, as now (ChatItemView.kt:129).
- The decision from `MsgLinkPlan` to an action is one pure function in each app, tested on recorded core responses.
- For an item in a member support scope, the app opens its group in stage 1 and its support chat in stage 3.
- `simplex:` is registered on iOS (SimpleX--iOS--Info.plist:40-43), Android (AndroidManifest.xml:75) and desktop (plans/2026-09-28-desktop-deep-links.md, section "`simplex:` connection links"); https links on preset servers open the app on iOS (SimpleX (iOS).entitlements:12) and Android (AndroidManifest.xml:86-112).
- `minRemoteCtrlVersion` and `minRemoteHostVersion` (Remote.hs:77-82) are set to the release version, as for block markdown (plans/2026-10-13-block-markdown.md:691), because an earlier desktop cannot decode the new `Format`.
- A `messageLink` case is added to the website renderer (website/src/js/simplex-lib.jsc:234-294): the label is rendered as a link; the href of a global link in a short-link form is `platformSimplexUri` of the link (simplex-lib.jsc:307-329), which keeps `m` and `a`, and the other forms are used as they are.
- Message links are described in spec/client/navigation.md of both apps.

## Plugin

| Tool | Input | Output |
|---|---|---|
| `link` | `item`, and `chat`: `@N` or `#N`; without `chat` in the plugin, the item of the session's group | `{link}` |
| `open` | `link` | `status`: `found` with `message`; `chat` with the chat fields; `join` with `target`, the link or name for `connect`; `none`; `update` |

- No action is created by either tool; both only read, as `receive`.
- After `connect` to the public chat of a `join`, `open` of the same link returns `found` once the message is received with the chat's history.
- `open` returns `none` for a chat that the session does not own (spec/api.md:686), so chats of other sessions are kept hidden. A message of the session's group is returned with `item` and without `chat`, as the channel's prompts (spec/api.md:1036).
- `connect` with a global message link connects to its chat, as earlier cores parse it. `connect` with a `simplex:/m#` link returns `TARGET is a message link; open returns its message.` in place of `Not a SimpleX link or name: TARGET` (spec/api.md:132).
- One sentence is added to the instructions (tools.ts:495-506): `A message link references one message: link returns the link of a message, which you write as [label](link); open returns the message of a link, or the public chat to connect to.`
- The Message object (messages.ts:23-35) is unchanged: with a link in every message, each message would be 35 to 120 characters longer, for up to 100 messages per result.

Agents can use such links under three conditions, each stated by the design:

1. Every link is taken from a `link` result or from a received text.
2. The agent writes it as `[label](link)`.
3. The agent follows it with `open`.

| Evidence | Source |
|---|---|
| agents already write Markdown, and `[text](url)` in their posts is parsed by the core | Claude's text is posted to the session group (spec/api.md:911); Markdown.hs:450-456 |
| opaque `simplex:/` links are copied by agents between results and calls | `connect` takes them (tools.ts:284) |
| an ID cannot be produced from memory, as it is random | Store/Shared.hs:660-661 |
| a damaged link is parsed as text, as the chat's link, or resolved as `none` | the parser and the plan above |
| a global message link given to `connect` connects to its chat; a local link gets the error above | Agent/Protocol.hs:1779-1786 |

## Stages

```mermaid
flowchart LR
  S1["Stage 1 PR, v1: core, CLI, bots API, iOS, Android, desktop, website"] --> R["release of the npm packages simplex-chat and @simplex-chat/types (packages/simplex-chat-mcp/package.json:31-33)"]
  R --> S2["Stage 2 PR: plugin link and open, the board link of Q6"]
  S1 --> S3["Stage 3: the message after a join, history up to it, notes, support scopes, previews"]
```

| Stage | Content |
|---|---|
| 1, v1 | every form of the Format section, parsed and encoded; Copy link; resolution; for a public chat that the reader is not in, the connection flow as for its link, which opens the chat at its last messages; forwards; group preference; app rendering, tap, links from outside, search paste; remote versions; website case; the comments of the scheme roles |
| 2 | plugin `link` and `open`, the `simplex:/m#` error of `connect`, instructions; the board link of Q6 |
| 3 | after a join from a message link, the plan is run again at each new item of the chat, and the app opens the chat at the message; a request to the relays for history up to a message; the forward header of `CIFFGroupLink` opens the original message by the same flow (FramedItemView.swift:120-121); kind `n` for notes, by local IDs, replaced by its label in every message sent outside notes; the support chat at the item; a preview of the referenced message at long-press |

No v1 format is changed in stage 3, or when public groups are served by relays: every form is defined in v1, the global form is keyed by the chat's link or name of either group type, unknown parameters are ignored, and a new kind of `simplex:/m#` is parsed as `MLUnknown` by v1 cores.

## Tests

Each test fails on master, except the compatibility test, which pins how earlier cores parse a global message link.

| File | Test |
|---|---|
| tests/MarkdownTests.hs | `[Should I merge?](simplex:/m#g/…?a=…)` gives `MessageLink (Just "Should I merge?") MLTGroup …` |
| | the https, `simplex:` and name forms of a global message link give `MessageLink … MLTPublicGroup …`, for links of types `c` and `g`; the same short link without `m` gives `SimplexLink` |
| | compatibility: `strDecode` of a global message link as `AConnectionLink` gives the chat's link |
| | `see simplex:/m#d/ID.` gives text, a bare link and `.`; a final `-` of an ID is kept |
| | `simplex:/m#x/…` gives `MLUnknown` |
| | `[https://example.com](simplex:/m#d/…)` gives the label as text and a bare link |
| | `strDecode . strEncode` returns each `MsgLink` variant in each form |
| tests/ChatTests/Groups.hs | `/item link #team hi` by alice; the link is sent in `#club`; cath, a member of `#team`, gets the item from `/_msg link plan`; dan gets `not in your chats` |
| | a channel post: a subscriber gets the item by the https form; a non-subscriber gets `join` with the link, connects with it, and then gets the item |
| | after `/_delete item … internal` by cath, the plan is the chat |
| | `#club` with SimpleX links off: a global message link is refused, and a local group message link is sent |
| tests/ChatTests/Names.hs | a channel with a verified name, as in `testConnectByChannelName`: a subscriber gets the item by the name form; a non-subscriber gets `join` with the name |
| tests/ChatTests/Direct.hs | alice's message to bob, its link sent to bob in a group: bob gets the item, cath gets `not in your chats` |
| tests/ChatTests/Forward.hs | a local group link forwarded to a contact is replaced by its label; it is kept in forwards to the same group and to notes; a global link is kept, and replaced by its label in a group with SimpleX links off |
| app tests on recorded core responses | `Format.messageLink` is decoded; each `MsgLinkPlan` variant gives its action |
| plugin unit and e2e tests | `link` of a sent message, then `open` of the link in the same session; `open` for a chat of another session returns `none`; `connect` with a `simplex:/m#` link returns its error |

## Questions

| ID | Question | Recommendation |
|---|---|---|
| Q1 | `simplex:` for every message link: links of public chats served by relays (channels now, public groups later) in the chat's own connection forms (https on its link's server host, `simplex:` link, `simplex:/name`) with `m` and `a`; local links of groups, business chats and contacts as `simplex:/m#…`, changed in forwards by Q2. `simplexchat:` stays the scheme of app-specific deep links, such as badge links. | decided by you |
| Q2 | In forwards to another chat, local links are replaced by their labels, and global links are kept where SimpleX links are allowed; a link without a label is replaced by `message`. | yes |
| Q3 | "Copy link" of a message in a public chat gives the https form on its link's server host. The name form, for a chat with a verified name, is written by hand in v1. | yes: the https form opens in browsers and in apps of earlier versions |
| Q4 | A link without a label is shown as "message" with a link icon; Copy link copies the link without text of the message. | yes |
| Q5 | When the chat is known and the message is gone, the app opens the chat and shows an alert: the message is deleted or not received yet. | yes |
| Q6 | The session's message on the board in the Main group links "waiting for you" to the oldest pending card of the session. | yes, in stage 2 |
