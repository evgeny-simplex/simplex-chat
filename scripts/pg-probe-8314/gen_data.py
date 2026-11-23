import hashlib
import json
import random
from array import array
from bisect import bisect_left, bisect_right
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Callable, Iterator

NOW = datetime(2026, 11, 23, 12, 0, 0, tzinfo=timezone.utc)
DAY = 86400.0
SEED = 8314
USER_ID = 1
USER_CONTACT_ID = 1
USER_PROFILE_ID = 1
USER_LDN = "user"
CONTACT_COUNT = 500
GROUP_COUNT = 300
BIG_GROUPS = (2, 17, 33, 48, 64, 99, 128, 170, 222, 280)
BIG_GROUP_SIZE = 300
GROUP_17 = 17
CONTACT_42 = 42
NOTE_FOLDER_ID = 1
TOTAL_ITEMS = 1_000_000
GROUP_ITEMS = 900_000
NOTE_ITEMS = 500
MAX_CHAT_ITEMS = 20_000
G17_FIRST_MEMBER = 1100
OTHER_FIRST_MEMBER = 2000
FORCED_GROUP_ITEM = 98765
SENDER_1234 = 1234
MEMBER_1300 = 1300
MEMBER_1234_MID = bytes.fromhex("0b5a3f1c9d7e2a4b6c8d0e1f")
FORCED_SHARED_MSG_ID = bytes.fromhex("a1b2c3d4e5f60718293a4b5c")
MSG_ID_START = 450001
UNREAD_SHARE = 0.03
SILENT_SHARE = 0.30
HIGH_SHARE = 0.03
ORIGINAL_TS_ITEMS = 300
VIA_TO_USER = 150
VIA_TO_HOST = 50
DELIVERY_TASKS = 5000
SPARE_MESSAGES = 2000
BATCH = 1000
RECENT_DAYS = 30

FIRST_NAMES = [
    "alice", "alina", "bob", "carol", "dave", "eve", "frank", "grace", "heidi", "ivan",
    "judy", "khalid", "liam", "mallory", "natalia", "oscar", "peggy", "quinn", "ruth", "salim",
    "trent", "uma", "victor", "walter", "xavier", "yuki", "zoe", "maria", "chen", "sofia",
]
SURNAMES = ["smith", "khan", "garcia", "ivanova", "tanaka", "muller", "rossi", "kowalski", "dubois", "silva"]
GROUP_WORDS = [
    "team", "family", "friends", "italian cooking", "bali trip", "privacy", "simplex users", "news",
    "developers", "music", "books", "hiking", "chess", "quality", "gardening", "photography",
    "local events", "parents", "startup", "football",
]
WORDS = [
    "the", "a", "meeting", "tomorrow", "see", "you", "thanks", "great", "idea", "link", "photo", "call",
    "later", "today", "please", "check", "this", "update", "new", "version", "release", "works", "fine",
    "issue", "fixed", "agree", "maybe", "next", "week", "time", "place", "dinner", "coffee", "travel",
    "plan", "ok", "yes", "no", "why", "how", "where", "when", "hello", "morning", "evening", "night",
    "code", "server", "group", "message", "file", "voice", "picture", "news", "article", "read", "done",
]
EVENTS = ["memberConnected", "memberAdded", "memberLeft", "memberRole", "groupUpdated"]
THUMBNAIL = "data:image/jpg;base64," + "A" * 1200


def uniforms(item_id: int) -> list[float]:
    d = hashlib.blake2b(item_id.to_bytes(8, "little"), digest_size=64, key=b"pg-probe-8314").digest()
    return [int.from_bytes(d[k:k + 4], "little") / 4294967296.0 for k in range(0, 64, 4)]


def tagged_bytes(tag: bytes, n: int, size: int) -> bytes:
    return hashlib.blake2b(tag + n.to_bytes(8, "little"), digest_size=size).digest()


def at(offset: float) -> datetime:
    return NOW + timedelta(seconds=offset)


@dataclass
class Member:
    gmid: int
    group_id: int
    index: int
    member_id: bytes
    role: str
    category: str
    status: str
    contact_id: int | None
    profile_id: int
    ldn: str
    created: float
    invited_by_gmid: int | None = None
    invited_via_gmid: int | None = None
    removed_at: float | None = None
    pub_key: bytes | None = None
    via: bytes | None = None


@dataclass
class Group:
    group_id: int
    size: int
    ldn: str
    name: str
    created: float
    user_role: str
    user_creator: bool
    favorite: int
    unread_chat: int
    enable_ntfs: int | None
    members: list = field(default_factory=list)
    sender_ids: list = field(default_factory=list)
    sender_cum: list = field(default_factory=list)
    support_ids: list = field(default_factory=list)


@dataclass
class Contact:
    contact_id: int
    ldn: str
    name: str
    full_name: str
    short_descr: str | None
    local_alias: str
    created: float
    contact_used: int
    deleted: int
    favorite: int
    unread_chat: int
    enable_ntfs: int | None


@dataclass
class Chat:
    kind: str
    ref: int
    count: int
    start: float
    end: float
    p_sent: float
    big: bool = False
    ids: array = field(default_factory=lambda: array("I"))
    tail: int = 0
    first_unread: int = 0


@dataclass
class Table:
    name: str
    columns: list
    head_columns: list
    rows: Callable[[], Iterator[tuple]]


class World:
    def __init__(self, scale: float = 1.0):
        self.scale = scale
        self.rng = random.Random(SEED)
        self.ldns: set = set()
        self.display_names: list = []
        self.profiles: list = []
        self.next_profile = CONTACT_COUNT + 2
        self.build_contacts()
        self.build_groups()
        self.build_connections()
        self.build_chats()
        self.place_items()
        self.plan_unread()
        self.plan_messages()
        self.plan_specials()

    def new_ldn(self, base: str, created: float) -> str:
        ldn = base
        suffix = 0
        while ldn in self.ldns:
            suffix += 1
            ldn = f"{base}_{suffix}"
        self.ldns.add(ldn)
        self.display_names.append((ldn, base, suffix, created))
        return ldn

    def new_profile(self, name: str, full_name: str, created: float, short_descr=None, local_alias="") -> int:
        pid = self.next_profile
        self.next_profile += 1
        self.profiles.append((pid, name, full_name, short_descr, local_alias, created))
        return pid

    def build_contacts(self):
        r = self.rng
        self.user_created = -800 * DAY
        self.new_ldn(USER_LDN, self.user_created)
        self.profiles.append((USER_PROFILE_ID, USER_LDN, "", None, "", self.user_created))
        ids = list(range(2, CONTACT_COUNT + 2))
        others = [c for c in ids if c != CONTACT_42]
        unused = set(r.sample(others, 20))
        deleted = set(r.sample([c for c in others if c not in unused], 5))
        favorite = set(r.sample(others, 25))
        unread_chat = set(r.sample(others, 5))
        self.contacts = {}
        for i, cid in enumerate(ids):
            name = FIRST_NAMES[i] if i < len(FIRST_NAMES) else r.choice(FIRST_NAMES)
            full_name = f"{name.title()} {r.choice(SURNAMES).title()}" if r.random() < 0.5 else ""
            short_descr = "privacy enthusiast" if r.random() < 0.1 else None
            local_alias = "friend" if r.random() < 0.05 else ""
            created = -r.uniform(30, 790) * DAY
            ntfs_u = r.random()
            enable_ntfs = 1 if ntfs_u < 0.2 else (0 if ntfs_u < 0.3 else None)
            ldn = self.new_ldn(name, created)
            self.profiles.append((cid, name, full_name, short_descr, local_alias, created))
            self.contacts[cid] = Contact(
                cid, ldn, name, full_name, short_descr, local_alias, created,
                0 if cid in unused else 1, 1 if cid in deleted else 0,
                1 if cid in favorite else 0, 1 if cid in unread_chat else 0, enable_ntfs,
            )

    def build_groups(self):
        r = self.rng
        self.groups = {}
        self.members = []
        next_gmid = OTHER_FIRST_MEMBER
        contact_ids = list(self.contacts)
        for gid in range(1, GROUP_COUNT + 1):
            big = gid in BIG_GROUPS
            size = BIG_GROUP_SIZE if big else r.randint(5, 30)
            name = r.choice(GROUP_WORDS)
            created = -r.uniform(60, 760) * DAY
            role_u = r.random()
            if gid == GROUP_17:
                user_role, creator = "admin", False
            elif role_u < 0.2:
                user_role, creator = "owner", True
            elif role_u < 0.3:
                user_role, creator = "admin", False
            else:
                user_role, creator = "member", False
            ntfs_u = r.random()
            enable_ntfs = None if ntfs_u < 0.6 else (1 if ntfs_u < 0.8 else (0 if ntfs_u < 0.95 else 2))
            g = Group(
                gid, size, self.new_ldn(name, created), name, created, user_role, creator,
                1 if r.random() < 0.05 else 0, 1 if r.random() < 0.01 else 0, enable_ntfs,
            )
            self.groups[gid] = g
            used_contacts = set()
            host_gmid = None
            for pos in range(size):
                if gid == GROUP_17:
                    gmid = G17_FIRST_MEMBER + pos
                else:
                    gmid = next_gmid
                    next_gmid += 1
                member_id = tagged_bytes(b"member", gmid, 12)
                mcreated = created + r.uniform(0, 30) * DAY
                if pos == 0:
                    m = Member(
                        gmid, gid, pos, member_id, user_role, "user", "creator" if creator else "connected",
                        USER_CONTACT_ID, USER_PROFILE_ID, USER_LDN, created,
                    )
                    g.members.append(m)
                    continue
                if pos == 1 and not creator:
                    role, category, status = "owner", "host", "connected"
                else:
                    cat_u = r.random()
                    category = "pre" if cat_u < 0.6 else ("post" if cat_u < 0.95 else "invitee")
                    st_u = r.random()
                    status = (
                        "connected" if st_u < 0.82 else "complete" if st_u < 0.90 else "announced" if st_u < 0.92
                        else "introduced" if st_u < 0.93 else "intro-inv" if st_u < 0.94 else "removed" if st_u < 0.97
                        else "left" if st_u < 0.99 else "unknown"
                    )
                    ro_u = r.random()
                    role = (
                        "owner" if ro_u < 0.01 else "admin" if ro_u < 0.03 else "moderator" if ro_u < 0.05
                        else "observer" if ro_u < 0.08 else "member"
                    )
                link_p = 0.03 if big else 0.12
                contact_id = None
                if r.random() < link_p:
                    candidate = r.choice(contact_ids)
                    if candidate not in used_contacts and not self.contacts[candidate].deleted:
                        contact_id = candidate
                        used_contacts.add(candidate)
                if contact_id is not None:
                    profile_id = contact_id
                    ldn = self.contacts[contact_id].ldn
                else:
                    base = r.choice(FIRST_NAMES)
                    full = f"{base.title()} {r.choice(SURNAMES).title()}" if r.random() < 0.3 else ""
                    profile_id = self.new_profile(base, full, mcreated)
                    ldn = self.new_ldn(base, mcreated)
                m = Member(gmid, gid, pos, member_id, role, category, status, contact_id, profile_id, ldn, mcreated)
                if category == "host":
                    host_gmid = gmid
                elif category == "invitee":
                    m.invited_by_gmid = g.members[0].gmid
                elif host_gmid is not None:
                    m.invited_by_gmid = host_gmid
                if status == "removed":
                    m.removed_at = -r.uniform(0, 60) * DAY
                if r.random() < 0.3:
                    m.pub_key = tagged_bytes(b"pubkey", gmid, 44)
                g.members.append(m)
            if gid == GROUP_17:
                self.override_group_17(g)
            self.members.extend(g.members)
            self.build_senders(g)
        self.members_by_id = {m.gmid: m for m in self.members}
        self.plan_via()

    def override_group_17(self, g: Group):
        by_pos = {m.index: m for m in g.members}
        m1234 = by_pos[SENDER_1234 - G17_FIRST_MEMBER]
        m1234.member_id = MEMBER_1234_MID
        m1234.category, m1234.status, m1234.role = "pre", "connected", "member"
        for gmid in list(range(1201, 1206)) + [G17_FIRST_MEMBER + 57, G17_FIRST_MEMBER + 3, G17_FIRST_MEMBER + 5,
                                               G17_FIRST_MEMBER + 8, G17_FIRST_MEMBER + 13, G17_FIRST_MEMBER + 21]:
            m = by_pos[gmid - G17_FIRST_MEMBER]
            m.status = "connected"
            m.removed_at = None
        m1300 = by_pos[MEMBER_1300 - G17_FIRST_MEMBER]
        m1300.category, m1300.status, m1300.removed_at = "pre", "unknown", None
        for pos in range(250, 270):
            m = by_pos[pos]
            m.category = "post"
            m.invited_via_gmid = SENDER_1234

    def build_senders(self, g: Group):
        r = self.rng
        eligible = [m for m in g.members if m.category != "user" and m.status in ("connected", "complete", "removed", "left", "announced")]
        r.shuffle(eligible)
        if g.group_id == GROUP_17:
            m1234 = next(m for m in eligible if m.gmid == SENDER_1234)
            eligible.remove(m1234)
            eligible.insert(3, m1234)
        total = 0.0
        for rank, m in enumerate(eligible):
            total += 1.0 / (rank + 1) ** 1.1
            g.sender_ids.append(m.gmid)
            g.sender_cum.append(total)
        g.support_ids = [m.gmid for m in g.members if m.category != "user"]

    def plan_via(self):
        r = self.rng
        big_candidates = [m for m in self.members if m.group_id in BIG_GROUPS and m.category not in ("user", "host")]
        for m in r.sample(big_candidates, VIA_TO_USER):
            m.via = self.groups[m.group_id].members[0].member_id
        small_candidates = [
            m for m in self.members
            if m.group_id not in BIG_GROUPS and m.category not in ("user", "host") and self.host_of(m.group_id) is not None
        ]
        for m in r.sample(small_candidates, VIA_TO_HOST):
            m.via = self.host_of(m.group_id).member_id

    def host_of(self, gid: int):
        return next((m for m in self.groups[gid].members if m.category == "host"), None)

    def build_connections(self):
        self.connections = []
        self.contact_conn = {}
        self.member_conn = {}
        cid_next = 1
        for c in self.contacts.values():
            if c.deleted:
                continue
            self.connections.append((cid_next, "contact", c.contact_id, None, c.created))
            self.contact_conn[c.contact_id] = cid_next
            cid_next += 1
        for m in self.members:
            if m.category != "user" and m.status in ("connected", "complete"):
                self.connections.append((cid_next, "member", None, m.gmid, m.created))
                self.member_conn[m.gmid] = cid_next
                cid_next += 1

    def scaled(self, n: int) -> int:
        return max(1, round(n * self.scale))

    def distribute(self, n: int, total: int, hi: int) -> list[int]:
        r = self.rng
        weights = [r.lognormvariate(0, 1.4) for _ in range(n)]
        lo_s, hi_s = 0.0, total * 10.0
        for _ in range(100):
            s = (lo_s + hi_s) / 2
            if sum(min(hi, max(1, int(w * s))) for w in weights) > total:
                hi_s = s
            else:
                lo_s = s
        counts = [min(hi, max(1, int(w * lo_s))) for w in weights]
        order = sorted(range(n), key=lambda i: -weights[i])
        k = 0
        while sum(counts) < total:
            i = order[k % n]
            if counts[i] < hi:
                counts[i] += 1
            k += 1
        return counts

    def span(self, active: bool) -> tuple[float, float]:
        r = self.rng
        start = -r.uniform(60, 730) * DAY
        if active:
            end = -r.uniform(0, 1) * DAY
        else:
            u = r.random()
            end = -r.uniform(0, 2) * DAY if u < 0.7 else (-r.uniform(2, 30) * DAY if u < 0.9 else -r.uniform(30, -start / DAY) * DAY)
        return start, end

    def build_chats(self):
        r = self.rng
        hi = self.scaled(MAX_CHAT_ITEMS)
        self.chats = []
        big_other = [g for g in BIG_GROUPS if g != GROUP_17]
        big_counts = {GROUP_17: hi}
        for gid in big_other:
            big_counts[gid] = self.scaled(r.randint(8000, MAX_CHAT_ITEMS))
        small = [gid for gid in self.groups if gid not in BIG_GROUPS]
        small_total = self.scaled(GROUP_ITEMS) - sum(big_counts.values())
        small_counts = dict(zip(small, self.distribute(len(small), small_total, hi)))
        for gid in self.groups:
            count = big_counts.get(gid) or small_counts[gid]
            big = gid in BIG_GROUPS
            start, end = self.span(big)
            if big:
                start = -730 * DAY
            self.chats.append(Chat("group", gid, count, start, end, 0.01 if big else 0.05, big))
        direct_total = self.scaled(TOTAL_ITEMS - GROUP_ITEMS - NOTE_ITEMS)
        others = [c for c in self.contacts if c != CONTACT_42]
        other_counts = dict(zip(others, self.distribute(len(others), direct_total - hi, hi)))
        for cid in self.contacts:
            count = hi if cid == CONTACT_42 else other_counts[cid]
            start, end = self.span(cid == CONTACT_42)
            if cid == CONTACT_42:
                start = -730 * DAY
            self.chats.append(Chat("direct", cid, count, start, end, 0.45))
        self.chats.append(Chat("note", NOTE_FOLDER_ID, self.scaled(NOTE_ITEMS), -365 * DAY, -1 * DAY, 1.0))
        self.chat_of_group = {c.ref: i for i, c in enumerate(self.chats) if c.kind == "group"}
        self.chat_of_contact = {c.ref: i for i, c in enumerate(self.chats) if c.kind == "direct"}

    def place_items(self):
        r = self.rng
        pairs = []
        for idx, chat in enumerate(self.chats):
            if chat.count == 1:
                pairs.append((chat.end, idx))
                continue
            pairs.append((chat.end, idx))
            for _ in range(chat.count - 1):
                pairs.append((r.uniform(chat.start, chat.end), idx))
        pairs.sort()
        self.n = len(pairs)
        g17 = self.chat_of_group[GROUP_17]
        forced_rank = FORCED_GROUP_ITEM - 1 if self.n > FORCED_GROUP_ITEM else self.n // 2
        if pairs[forced_rank][1] != g17:
            j = next(
                k for d in range(1, self.n) for k in (forced_rank - d, forced_rank + d)
                if 0 <= k < self.n and pairs[k][1] == g17 and pairs[k][0] != self.chats[g17].end
            )
            other = pairs[forced_rank][1]
            pairs[forced_rank] = (pairs[forced_rank][0], g17)
            pairs[j] = (pairs[j][0], other)
        self.forced_item = forced_rank + 1
        self.item_chat = array("H", (p[1] for p in pairs))
        self.item_ts = array("d", (p[0] for p in pairs))
        for i, (_, idx) in enumerate(pairs, start=1):
            self.chats[idx].ids.append(i)
        self.sent = bytearray(self.n + 1)
        for i in range(1, self.n + 1):
            chat = self.chats[self.item_chat[i - 1]]
            if chat.kind == "note" or (i != self.forced_item and uniforms(i)[0] < chat.p_sent):
                self.sent[i] = 1
        self.chat_last_ts = [self.item_ts[c.ids[-1] - 1] for c in self.chats]

    def plan_unread(self):
        r = self.rng
        target = round(UNREAD_SHARE * self.n)
        received = [sum(1 for i in c.ids if not self.sent[i]) if c.kind != "note" else 0 for c in self.chats]
        g17 = self.chat_of_group[GROUP_17]
        c42 = self.chat_of_contact[CONTACT_42]
        fixed = {g17: min(received[g17], self.scaled(1500)), c42: min(received[c42], self.scaled(150))}
        weights = {}
        for idx, c in enumerate(self.chats):
            if c.kind == "note" or idx in fixed:
                continue
            p = 0.45 if c.kind == "group" else 0.12
            if r.random() < p:
                weights[idx] = received[idx] * (0.01 + 0.25 * r.random() ** 2)
        tails = dict(fixed)
        remaining = target - sum(fixed.values())
        open_idx = set(weights)
        while remaining > 0 and open_idx:
            total_w = sum(weights[i] for i in open_idx)
            progressed = 0
            for i in sorted(open_idx):
                share = max(1, int(remaining * weights[i] / total_w))
                room = received[i] - tails.get(i, 0)
                add = min(share, room, remaining - progressed)
                if add > 0:
                    tails[i] = tails.get(i, 0) + add
                    progressed += add
                if received[i] - tails.get(i, 0) <= 0:
                    open_idx.discard(i)
                if progressed >= remaining:
                    break
            remaining -= progressed
            if progressed == 0:
                break
        for idx, c in enumerate(self.chats):
            c.tail = tails.get(idx, 0)
            if c.tail:
                rcv = [i for i in c.ids if not self.sent[i]]
                c.first_unread = rcv[-c.tail]
            else:
                c.first_unread = self.n + 1

    def plan_messages(self):
        cutoff = -RECENT_DAYS * DAY
        self.recent_from = bisect_left(self.item_ts, cutoff) + 1
        self.msg_of = array("I", bytes(4 * (self.n - self.recent_from + 2)))
        next_msg = MSG_ID_START
        for i in range(self.recent_from, self.n + 1):
            if self.chats[self.item_chat[i - 1]].kind != "note":
                self.msg_of[i - self.recent_from] = next_msg
                next_msg += 1
        self.spare_from = next_msg
        self.msg_end = next_msg + SPARE_MESSAGES

    def message_id(self, i: int):
        if i < self.recent_from:
            return None
        return self.msg_of[i - self.recent_from] or None

    def plan_specials(self):
        r = self.rng
        forwarding = [gid for gid, g in self.groups.items() if g.user_role in ("owner", "admin")]
        self.task_items = []
        for i in range(self.n, self.recent_from - 1, -1):
            chat = self.chats[self.item_chat[i - 1]]
            if chat.kind == "group" and chat.ref in forwarding and not self.sent[i]:
                self.task_items.append(i)
            if len(self.task_items) >= DELIVERY_TASKS:
                break
        group_received = sum(1 for i in range(1, self.n + 1) if not self.sent[i] and self.chats[self.item_chat[i - 1]].kind == "group")
        self.original_p = ORIGINAL_TS_ITEMS / max(1, group_received)
        g17 = self.chats[self.chat_of_group[GROUP_17]]
        c42 = self.chats[self.chat_of_contact[CONTACT_42]]
        note = self.chats[-1]
        g17_main = [i for i in g17.ids if not self.sent[i] and i != self.forced_item and self.item(i)["scope"] is None]
        self.anchors = {
            "group17_item": self.forced_item,
            "direct42_item": c42.ids[len(c42.ids) // 2],
            "note_item": note.ids[len(note.ids) // 2],
            "group17_item_ids": spaced(g17_main, BATCH),
            "direct42_item_ids": spaced(list(c42.ids), BATCH),
            "spare_message_ids": list(range(self.spare_from, self.spare_from + min(BATCH, SPARE_MESSAGES // 2))),
            "task_message_ids": list(range(self.spare_from + SPARE_MESSAGES // 2, self.spare_from + SPARE_MESSAGES // 2 + min(BATCH, SPARE_MESSAGES // 2))),
            "new_shared_msg_ids": [tagged_bytes(b"newshared", k, 12).hex() for k in range(BATCH)],
            "member_ids_batch": spaced(sorted(m.gmid for m in self.members if m.category != "user"), BATCH),
            "new_member_index": [100000 + k for k in range(BATCH)],
            "new_member_mids": [tagged_bytes(b"newmember", k, 12).hex() for k in range(BATCH)],
            "message_456789_exists": self.recent_from <= self.n and MSG_ID_START <= 456789 < self.spare_from,
        }
        self.badge_members = r.sample(sorted(m.gmid for m in self.members if m.category != "user"), 50)
        owned = sorted(gid for gid, g in self.groups.items() if g.user_creator)
        self.link_groups = owned[:20]
        self.directory_groups = r.sample(sorted(self.groups), 100)

    def sender(self, g: Group, u: float) -> int:
        k = bisect_right(g.sender_cum, u * g.sender_cum[-1])
        return g.sender_ids[min(k, len(g.sender_ids) - 1)]

    def item(self, i: int) -> dict:
        u = uniforms(i)
        chat = self.chats[self.item_chat[i - 1]]
        ts = self.item_ts[i - 1]
        sent = self.sent[i]
        forced = i == self.forced_item
        group = self.groups[chat.ref] if chat.kind == "group" else None
        event = group is not None and not sent and not forced and u[2] < 0.02
        kind_u = u[2]
        if event:
            tag = None
        elif kind_u < 0.88 or forced:
            tag = "text"
        elif kind_u < 0.93:
            tag = "image"
        elif kind_u < 0.96:
            tag = "link"
        elif kind_u < 0.975:
            tag = "file"
        elif kind_u < 0.99:
            tag = "voice"
        elif group is not None and not sent and kind_u > 0.9998:
            tag = "report"
        else:
            tag = "video"
        sender = None
        if group is not None and not sent:
            sender = SENDER_1234 if forced else self.sender(group, u[1])
        scope = None
        scope_member = None
        if chat.big and not forced and u[8] < 0.01:
            scope = "member_support"
            scope_member = sender if sender is not None else group.support_ids[int(u[14] * len(group.support_ids))]
        unread = not sent and i >= chat.first_unread
        priority = 0
        if not sent and not event and chat.kind != "note":
            priority = -1 if u[9] < SILENT_SHARE else (1 if u[9] < SILENT_SHARE + HIGH_SHARE else 0)
        original_ts = None
        if group is not None and not sent and not event and u[10] < self.original_p:
            original_ts = ts - 3600 - u[13] * 10 * DAY
        return {
            "u": u, "chat": chat, "group": group, "ts": ts, "sent": sent, "event": event, "tag": tag,
            "sender": sender, "scope": scope, "scope_member": scope_member, "unread": unread,
            "priority": priority, "original_ts": original_ts, "forced": forced,
        }

    def text(self, u: list[float]) -> str:
        n = 2 + int(u[3] * 12)
        seed = int(u[15] * 4294967296)
        out = []
        for _ in range(n):
            seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
            out.append(WORDS[seed % len(WORDS)])
        return " ".join(out)

    def shared_msg_id(self, i: int) -> bytes:
        return FORCED_SHARED_MSG_ID if i == self.forced_item else tagged_bytes(b"shared", i, 12)

    def chat_item_rows(self, files: list) -> Iterator[tuple]:
        for i in range(1, self.n + 1):
            yield self.chat_item_row(i, files)

    def chat_item_row(self, i: int, files: list) -> tuple:
        it = self.item(i)
        u = it["u"]
        chat = it["chat"]
        group = it["group"]
        sent = it["sent"]
        ts = at(it["ts"])
        tag = it["tag"]
        direction = "snd" if sent else "rcv"
        if it["event"]:
            ev = EVENTS[int(u[3] * len(EVENTS))]
            content = json.dumps({"type": "rcvGroupEvent", "rcvGroupEvent": {"type": ev}}, separators=(",", ":"))
            text = ev
            content_tag = "rcvGroupEvent"
        else:
            text = self.text(u)
            if tag == "image":
                mc = {"type": "image", "text": "", "image": THUMBNAIL}
                text = ""
            elif tag == "video":
                mc = {"type": "video", "text": "", "image": THUMBNAIL, "duration": 12}
                text = ""
            elif tag == "link":
                text = "https://example.com/" + text.replace(" ", "-")
                mc = {"type": "link", "text": text, "preview": {"uri": text, "title": "Example", "description": "", "image": ""}}
            elif tag == "file":
                text = f"document_{i}.pdf"
                mc = {"type": "file", "text": ""}
            elif tag == "voice":
                mc = {"type": "voice", "text": "", "duration": 9}
                text = ""
            elif tag == "report":
                mc = {"type": "report", "text": text, "reason": "spam"}
            else:
                mc = {"type": "text", "text": text}
            content = json.dumps({"type": f"{direction}MsgContent", "msgContent": mc}, separators=(",", ":"))
            content_tag = f"{direction}MsgContent"
        if chat.kind == "note":
            status = "snd_new"
        elif sent:
            status = "snd_new" if it["ts"] > -3600 else ("snd_rcvd ok complete" if chat.kind == "direct" else "snd_sent complete")
        else:
            status = "rcv_new" if it["unread"] else "rcv_read"
        viewed = 1 if (not it["event"] and (sent or not it["unread"])) else 0
        shared = None if it["event"] or chat.kind == "note" else self.shared_msg_id(i)
        quoted = (None, None, None, None, None)
        if not it["event"] and chat.kind != "note" and u[7] < 0.04:
            pos = bisect_left(chat.ids, i)
            if pos > 0:
                j = chat.ids[pos - 1 - (int(u[12] * 1000) % min(pos, 5))]
                jt = self.item(j)
                if not jt["event"]:
                    quoted_member = self.members_by_id[jt["sender"]].member_id if jt["sender"] is not None else None
                    quoted = (
                        self.shared_msg_id(j), at(jt["ts"]),
                        json.dumps({"type": "text", "text": self.text(jt["u"])}, separators=(",", ":")),
                        int(jt["sent"]), quoted_member,
                    )
        deleted = 1 if u[6] < 0.005 else 0
        deleted_ts = at(it["ts"] + 3600) if deleted else None
        timed_ttl = 86400 if u[11] < 0.003 else None
        timed_delete_at = at(it["ts"] + 86400) if timed_ttl else None
        has_link = 1 if tag == "link" or (tag == "text" and u[4] < 0.02) else 0
        mention = 1 if group is not None and not sent and not it["event"] and u[5] < 0.005 else 0
        in_history = 1 if group is not None and not it["event"] else 0
        if tag in ("image", "file", "voice", "video") and not it["event"]:
            files.append((
                i, chat.ref if chat.kind == "direct" else None, chat.ref if chat.kind == "group" else None,
                NOTE_FOLDER_ID if chat.kind == "note" else None, tag, ts, sent,
            ))
        original_ts = at(it["original_ts"]) if it["original_ts"] is not None else None
        return (
            i, USER_ID,
            chat.ref if chat.kind == "direct" else None,
            chat.ref if chat.kind == "group" else None,
            it["sender"], self.message_id(i) if chat.kind != "note" else None,
            int(sent), ts, deleted, content, text, ts, ts, status, shared,
            quoted[0], quoted[1], quoted[2], quoted[3], quoted[4],
            None, timed_ttl, timed_delete_at, deleted_ts, content_tag,
            NOTE_FOLDER_ID if chat.kind == "note" else None,
            tag, in_history, mention, it["scope"], it["scope_member"], has_link, viewed,
            it["priority"], original_ts,
        )

    def message_rows(self) -> Iterator[tuple]:
        for i in range(self.recent_from, self.n + 1):
            mid = self.message_id(i)
            if mid is None:
                continue
            it = self.item(i)
            chat = it["chat"]
            ts = at(it["ts"])
            body = json.dumps({"v": "1-16", "msgId": self.shared_msg_id(i).hex(), "event": "x.msg.new", "params": {"content": {"type": "text", "text": self.text(it["u"])}}}, separators=(",", ":")).encode()
            if chat.kind == "direct":
                conn, gid, author = self.contact_conn.get(chat.ref), None, None
            elif it["sent"]:
                conn, gid, author = None, chat.ref, None
            else:
                conn, gid, author = self.member_conn.get(it["sender"]), chat.ref, it["sender"]
            yield (
                mid, int(it["sent"]), "x.grp.mem.new" if it["event"] else "x.msg.new", body, ts, ts, conn, gid,
                None if it["event"] else self.shared_msg_id(i), 1 if it["sent"] else None, author, None,
                None if it["sent"] else ts,
            )
        conn_1234 = self.member_conn[SENDER_1234]
        for k, mid in enumerate(range(self.spare_from, self.msg_end)):
            ts = at(-600 + k * 0.1)
            shared = tagged_bytes(b"spare", mid, 12)
            body = json.dumps({"v": "1-16", "msgId": shared.hex(), "event": "x.msg.new", "params": {"content": {"type": "text", "text": "spare"}}}, separators=(",", ":")).encode()
            yield (mid, 0, "x.msg.new", body, ts, ts, conn_1234, GROUP_17, shared, None, SENDER_1234, None, ts)

    def delivery_task_rows(self) -> Iterator[tuple]:
        items = self.task_items or [self.forced_item]
        for t in range(1, DELIVERY_TASKS + 1):
            i = items[(t - 1) % len(items)]
            it = self.item(i)
            mid = self.message_id(i) or self.spare_from
            u = uniforms(10_000_000 + t)
            status = "processed" if u[0] < 0.85 else ("new" if u[0] < 0.99 else "error")
            ts = at(max(it["ts"], -7 * DAY) + u[1] * 60)
            sender = it["sender"] if it["sender"] is not None else SENDER_1234
            yield (
                t, it["chat"].ref, "group", "delivery_job", 0, None, sender, mid, 0, status,
                "error" if status == "error" else None, 1 if status == "error" else 0, ts, ts,
                1 if u[2] < 0.02 else 0,
            )

    def file_rows(self, files: list) -> Iterator[tuple]:
        for file_id, (item_id, contact_id, group_id, note_id, tag, ts, sent) in enumerate(files, start=1):
            ext = {"image": "jpg", "video": "mp4", "voice": "m4a", "file": "pdf"}[tag]
            status = "snd_complete" if sent else "rcv_complete"
            yield (
                file_id, contact_id, group_id, f"{tag}_{item_id}.{ext}", None, 1000 + item_id % 5_000_000,
                16384, ts, USER_ID, item_id, ts, status, "xftp", note_id,
            )

    def tables(self) -> list[Table]:
        files: list = []
        member_cols = [
            "group_member_id", "group_id", "member_id", "member_role", "member_category", "member_status",
            "invited_by", "user_id", "local_display_name", "contact_profile_id", "contact_id", "created_at",
            "updated_at", "show_messages", "invited_by_group_member_id", "peer_chat_min_version",
            "peer_chat_max_version", "index_in_group", "member_relations_vector", "member_pub_key", "removed_at",
            "invited_via_group_member_id",
        ]

        def users():
            created = at(self.user_created)
            yield (USER_ID, USER_CONTACT_ID, USER_LDN, 1, created, created, 1, 1)

        def display_names():
            for ldn, base, suffix, created in self.display_names:
                yield (USER_ID, ldn, base, suffix, at(created), at(created))

        def profiles():
            for pid, name, full, short_descr, alias, created in sorted(self.profiles):
                yield (pid, name, full, at(created), at(created), USER_ID, alias, short_descr)

        def contacts():
            created = at(self.user_created)
            yield (USER_CONTACT_ID, USER_PROFILE_ID, USER_ID, USER_LDN, 1, created, created, None, 0, 0, created, 0, 0)
            for c in self.contacts.values():
                last = at(self.chat_last_ts[self.chat_of_contact[c.contact_id]])
                yield (
                    c.contact_id, c.contact_id, USER_ID, c.ldn, 0, at(c.created), last, c.enable_ntfs,
                    c.unread_chat, c.contact_used, last, c.deleted, c.favorite,
                )

        def group_profiles():
            for g in self.groups.values():
                descr = f"a group about {g.name}" if g.group_id % 3 == 0 else None
                yield (g.group_id, g.name, "", at(g.created), at(g.created), USER_ID, descr, None)

        def groups():
            for g in self.groups.values():
                last = at(self.chat_last_ts[self.chat_of_group[g.group_id]])
                yield (
                    g.group_id, USER_ID, g.ldn, g.group_id, at(g.created), last, g.enable_ntfs, g.unread_chat,
                    last, g.favorite, len(g.members), 0,
                )

        def members():
            for m in self.members:
                created = at(m.created)
                yield (
                    m.gmid, m.group_id, m.member_id, m.role, m.category, m.status, None, USER_ID, m.ldn,
                    m.profile_id, m.contact_id, created, created, 1, m.invited_by_gmid, 1, 16, m.index, b"",
                    m.pub_key, at(m.removed_at) if m.removed_at is not None else None, m.invited_via_gmid, m.via,
                )

        def connections():
            for conn_id, conn_type, contact_id, gmid, created in self.connections:
                ts = at(created)
                yield (
                    conn_id, tagged_bytes(b"agentconn", conn_id, 16), 0, "ready", conn_type, contact_id, gmid,
                    ts, USER_ID, ts, 1, 16, 16,
                )

        def note_folders():
            created = at(-365 * DAY)
            yield (NOTE_FOLDER_ID, USER_ID, created, created, at(self.chat_last_ts[-1]))

        def badge_proofs():
            for gmid in self.badge_members:
                ts = at(-10 * DAY)
                yield (gmid, tagged_bytes(b"proof", gmid, 64), tagged_bytes(b"pres", gmid, 32), 1, "supporter", at(300 * DAY), "{}", ts, ts)

        def contact_links():
            for k, gid in enumerate(self.link_groups, start=1):
                ts = at(self.groups[gid].created)
                yield (k, tagged_bytes(b"link", gid, 64), f"group_link_{gid}", ts, USER_ID, ts, gid, tagged_bytes(b"glid", gid, 16), "member")

        def directory_regs():
            for k, gid in enumerate(self.directory_groups, start=1):
                ts = at(self.groups[gid].created)
                contact_id = 2 + (k * 7) % CONTACT_COUNT
                yield (k, gid, k, contact_id, None, "active", 1 if k % 10 == 0 else 0, ts, ts)

        return [
            Table("users", ["user_id", "contact_id", "local_display_name", "active_user", "created_at", "updated_at", "agent_user_id", "show_ntfs"], [], users),
            Table("display_names", ["user_id", "local_display_name", "ldn_base", "ldn_suffix", "created_at", "updated_at"], [], display_names),
            Table("contact_profiles", ["contact_profile_id", "display_name", "full_name", "created_at", "updated_at", "user_id", "local_alias", "short_descr"], [], profiles),
            Table("contacts", ["contact_id", "contact_profile_id", "user_id", "local_display_name", "is_user", "created_at", "updated_at", "enable_ntfs", "unread_chat", "contact_used", "chat_ts", "deleted", "favorite"], [], contacts),
            Table("group_profiles", ["group_profile_id", "display_name", "full_name", "created_at", "updated_at", "user_id", "description", "short_descr"], [], group_profiles),
            Table("groups", ["group_id", "user_id", "local_display_name", "group_profile_id", "created_at", "updated_at", "enable_ntfs", "unread_chat", "chat_ts", "favorite", "member_index", "creating_in_progress"], [], groups),
            Table("group_members", member_cols, ["member_via"], members),
            Table("connections", ["connection_id", "agent_conn_id", "conn_level", "conn_status", "conn_type", "contact_id", "group_member_id", "created_at", "user_id", "updated_at", "peer_chat_min_version", "peer_chat_max_version", "conn_chat_version"], [], connections),
            Table("note_folders", ["note_folder_id", "user_id", "created_at", "updated_at", "chat_ts"], [], note_folders),
            Table("messages", ["message_id", "msg_sent", "chat_msg_event", "msg_body", "created_at", "updated_at", "connection_id", "group_id", "shared_msg_id", "shared_msg_id_user", "author_group_member_id", "forwarded_by_group_member_id", "broker_ts"], [], self.message_rows),
            Table("chat_items", [
                "chat_item_id", "user_id", "contact_id", "group_id", "group_member_id", "created_by_msg_id",
                "item_sent", "item_ts", "item_deleted", "item_content", "item_text", "created_at", "updated_at",
                "item_status", "shared_msg_id", "quoted_shared_msg_id", "quoted_sent_at", "quoted_content",
                "quoted_sent", "quoted_member_id", "item_edited", "timed_ttl", "timed_delete_at", "item_deleted_ts",
                "item_content_tag", "note_folder_id", "msg_content_tag", "include_in_history", "user_mention",
                "group_scope_tag", "group_scope_group_member_id", "has_link", "item_viewed",
            ], ["item_priority", "item_original_ts"], lambda: self.chat_item_rows(files)),
            Table("files", ["file_id", "contact_id", "group_id", "file_name", "file_path", "file_size", "chunk_size", "created_at", "user_id", "chat_item_id", "updated_at", "ci_file_status", "protocol", "note_folder_id"], [], lambda: self.file_rows(files)),
            Table("delivery_tasks", ["delivery_task_id", "group_id", "worker_scope", "job_scope_spec_tag", "job_scope_include_pending", "job_scope_support_gm_id", "sender_group_member_id", "message_id", "message_from_channel", "task_status", "task_err_reason", "failed", "created_at", "updated_at"], ["update_notification"], self.delivery_task_rows),
            Table("group_member_badge_proofs", ["group_member_id", "badge_proof", "badge_pres_header", "badge_key_idx", "badge_type", "badge_expiry", "badge_extra", "created_at", "updated_at"], [], badge_proofs),
            Table("user_contact_links", ["user_contact_link_id", "conn_req_contact", "local_display_name", "created_at", "user_id", "updated_at", "group_id", "group_link_id", "group_link_member_role"], [], contact_links),
            Table("sx_directory_group_regs", ["group_reg_id", "group_id", "user_group_reg_id", "contact_id", "owner_member_id", "group_reg_status", "group_promoted", "created_at", "updated_at"], [], directory_regs),
        ]


def spaced(values: list, n: int) -> list:
    if len(values) <= n:
        return list(values)
    step = len(values) / n
    return [values[int(k * step)] for k in range(n)]
