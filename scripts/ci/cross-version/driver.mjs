import { execFileSync, spawn } from 'node:child_process'
import { appendFileSync, mkdirSync, openSync, writeFileSync } from 'node:fs'
import { setTimeout as sleep } from 'node:timers/promises'

const [bin, work, router, ...selected] = process.argv.slice(2)
const deliveryWait = 30000
const workers = Number(process.env.CONCURRENCY ?? 4)
const createdVersion = { '5.5.0': 1, '5.6.1': 2, '5.7.0': 3 }
const migrating = ['7.0.4', '7.1.0', 'F']
const expectedAfter = 'delivered, ratchets P 3, R 3'

const stage = (poster, reader, n, expected) => ({ poster, reader, n, expected })
const cell = (id, creator, poster, reader, expected) => ({ id, creator, stages: [stage(poster, reader, 3, expected)] })

const allCases = [
  cell('A1', '5.6.1', '7.0.4', '7.0.4', 'delivered'),
  cell('A2', '5.6.1', '7.1.0', '7.0.4', 'lost'),
  cell('A3', '5.6.1', '7.0.4', '7.1.0', 'lost'),
  cell('A4', '5.6.1', 'F', '7.0.4', 'delivered'),
  cell('A5', '5.6.1', '7.0.4', 'F', 'delivered'),
  cell('A6', '5.6.1', '7.1.0', 'F', 'delivered'),
  cell('A7', '5.6.1', 'F', '7.1.0', 'delivered'),
  cell('A8', '5.6.1', 'F', 'F', 'delivered'),
  cell('B4', '5.5.0', 'F', '7.0.4', 'delivered'),
  cell('B5', '5.5.0', '7.0.4', 'F', 'delivered'),
  cell('B8', '5.5.0', 'F', 'F', 'delivered'),
  cell('C2', '5.7.0', '7.1.0', '7.0.4', 'delivered'),
  cell('C3', '5.7.0', '7.0.4', '7.1.0', 'delivered'),
  {
    id: 'D1',
    creator: '5.6.1',
    stages: [stage('7.0.4', '7.0.4', 3, 'delivered'), stage('F', '7.0.4', 3, 'delivered'), stage('F', 'F', 3, 'delivered')]
  },
  { id: 'D2', creator: '5.6.1', stages: [stage('7.1.0', '7.0.4', 2, 'lost'), stage('F', '7.0.4', 2, 'delivered')] },
  { id: 'E', creator: '5.6.1', host: '7.0.4', stages: [stage('F', '7.0.4', 3, 'delivered')] }
]
const cases = allCases.filter(c => selected.length === 0 || selected.includes(c.id))

class App {
  constructor(ctx, name, v, port) {
    Object.assign(this, { ctx, name, v, port, db: `${ctx.dir}/${name}`, log: `${ctx.dir}/${name}.log`, pending: new Map(), corrId: 0 })
  }

  static async start(ctx, name, v, port) {
    const app = new App(ctx, name, v, port)
    const args = ['-d', app.db, '-p', String(port), '-s', router, ...(migrating.includes(v) ? ['-y'] : [])]
    app.write(`start ${v}: ${args.join(' ')}`)
    const out = openSync(app.log, 'a')
    app.proc = spawn(`${bin}/${v}/simplex-chat`, args, { stdio: ['pipe', out, out] })
    app.running = true
    app.exited = new Promise(resolve => app.proc.on('exit', resolve).on('error', resolve)).then(() => (app.running = false))
    app.proc.stdin.on('error', () => {}).end(`${name}\n`)
    for (const t = Date.now(); !(await app.connect()); await sleep(500)) {
      if (!app.running || Date.now() - t > 120000) {
        app.proc.kill('SIGKILL')
        throw new Error(`${name} ${v} did not start, see ${app.log}`)
      }
    }
    return app
  }

  connect() {
    return new Promise(resolve => {
      const ws = new WebSocket(`ws://127.0.0.1:${this.port}`)
      ws.onopen = () => resolve((this.ws = ws))
      ws.onerror = () => resolve(null)
      ws.onmessage = ({ data }) => this.receive(data)
    })
  }

  receive(data) {
    this.write(`< ${data.slice(0, 4000)}`)
    const { corrId, resp } = JSON.parse(data)
    this.pending.get(corrId)?.(resp)
    this.pending.delete(corrId)
    const kind = data.match(/"type":"(rcvDecryptionError|rcvIntegrityError)"/)?.[1] ?? (/rror|atchetSync/.test(resp.type) ? resp.type : null)
    if (kind) this.ctx.error(`${this.name} ${this.v}, ${this.ctx.phase}: ${kind} ${detail(kind, resp, data)}`)
  }

  cmd(cmd) {
    const corrId = String(++this.corrId)
    this.write(`> ${cmd}`)
    this.ws.send(JSON.stringify({ corrId, cmd }))
    return new Promise((resolve, reject) => {
      this.pending.set(corrId, resolve)
      setTimeout(() => reject(new Error(`${this.name} ${this.v}: no response to ${cmd}`)), 60000).unref()
    })
  }

  sql(query) {
    const args = ['-cmd', '.timeout 5000', '-json', `${this.db}_chat.db`, `ATTACH '${this.db}_agent.db' AS a; ${query}`]
    const out = execFileSync('sqlite3', args, { encoding: 'utf8' })
    return out.trim() ? JSON.parse(out) : []
  }

  async stop() {
    this.ws?.close()
    this.proc.kill('SIGINT')
    if (!(await Promise.race([this.exited.then(() => true), sleep(20000, false)]))) {
      this.proc.kill('SIGKILL')
      await this.exited
    }
    this.write(`stopped ${this.v}`)
  }

  write(line) {
    appendFileSync(this.log, `${new Date().toISOString()} ${line}\n`)
  }
}

const omitted = /^(user|connectionEntity_?|contact|groupInfo|member|connection)$/
const detail = (kind, resp, data) =>
  kind.startsWith('rcv')
    ? (data.match(/"itemText":"([^"]*)"/)?.[1] ?? '')
    : JSON.stringify(resp.chatError ?? resp.errorMessage ?? resp.ratchetSyncProgress?.ratchetSyncStatus ?? resp, (k, v) => (omitted.test(k) ? undefined : v)).slice(0, 300)

const conns = `FROM connections c LEFT JOIN contacts ct ON ct.contact_id = c.contact_id
  LEFT JOIN group_members m ON m.group_member_id = c.group_member_id
  LEFT JOIN a.connections ac ON ac.conn_id = c.agent_conn_id LEFT JOIN a.ratchets r ON r.conn_id = c.agent_conn_id`
const peer = (name, group) => `WHERE ${group ? 'm' : 'ct'}.local_display_name = '${name}'`
const ready = (app, name, group) => app.sql(`SELECT count(*) AS n ${conns} ${peer(name, group)} AND c.conn_status = 'ready'`)[0].n > 0
const state = (app, name, group) =>
  app.sql(`SELECT json_extract(CAST(r.ratchet_state AS TEXT), '$.rcVersion') AS rc, ac.smp_agent_version AS av,
    ac.ratchet_sync_state AS sync, c.conn_status AS status, c.peer_chat_min_version || '-' || c.peer_chat_max_version AS chat
    ${conns} ${peer(name, group)} ORDER BY c.connection_id DESC LIMIT 1`)[0] ?? {}
const quoted = texts => texts.map(t => `'${t}'`).join(',')
const received = (app, texts) => app.sql(`SELECT count(*) AS n FROM chat_items WHERE item_sent = 0 AND item_text IN (${quoted(texts)})`)[0].n
const sentStatus = (app, texts) =>
  app
    .sql(`SELECT item_status AS s, count(*) AS n FROM chat_items WHERE item_sent = 1 AND item_text IN (${quoted(texts)}) GROUP BY item_status`)
    .map(({ s, n }) => `${s} ×${n}`)
    .join(', ')

async function until(check, what, ms = 120000) {
  for (const t = Date.now(); !check(); await sleep(1000)) {
    if (Date.now() - t > ms) throw new Error(`timed out: ${what}`)
  }
}

async function link(a, b) {
  const { connReqInvitation } = await a.cmd('/c')
  if (!connReqInvitation) throw new Error(`${a.name} ${a.v}: no invitation link`)
  await b.cmd(`/c ${connReqInvitation}`)
  await until(() => ready(a, b.name) && ready(b, a.name), `${a.name}-${b.name} connection`)
}

async function makeGroup(h, p, r) {
  await link(h, p)
  await link(h, r)
  await h.cmd('/g g')
  for (const m of [p, r]) {
    await h.cmd(`/a g ${m.name}`)
    await until(() => m.sql("SELECT count(*) AS n FROM groups WHERE local_display_name = 'g'")[0].n > 0, `${m.name} group invitation`)
    await m.cmd('/j g')
    await until(() => ready(m, h.name, true), `${m.name} joining the group`)
  }
  await until(() => ready(p, r.name, true) && ready(r, p.name, true), 'p-r member connection')
}

async function deliver(from, to, texts, group) {
  for (const t of texts) await from.cmd(group ? `#g ${t}` : `@${to.name} ${t}`)
  let n = 0
  for (const t = Date.now(); (n = received(to, texts)) < texts.length && Date.now() - t < deliveryWait; ) await sleep(1000)
  return { from: from.name, sent: texts.length, received: n, status: sentStatus(from, texts) }
}

async function runCase(c, slot) {
  const ctx = { dir: `${work}/${c.id}`, phase: 'creation', errors: new Map() }
  ctx.error = e => ctx.errors.set(e, (ctx.errors.get(e) ?? 0) + 1)
  mkdirSync(ctx.dir, { recursive: true })
  const group = Boolean(c.host)
  const apps = {}
  const ports = { p: 0, r: 1, h: 2 }
  const start = (name, v) => App.start(ctx, name, v, 15000 + 4 * slot + ports[name])
  const states = () => ({ p: state(apps.p, 'r', group), r: state(apps.r, 'p', group) })
  const res = { id: c.id, creator: c.creator, host: c.host, stages: [] }
  try {
    for (const name of group ? ['p', 'r', 'h'] : ['p', 'r']) apps[name] = await start(name, c.creator)
    await apps.r.cmd('/set receipts all off')
    await (group ? makeGroup(apps.h, apps.p, apps.r) : link(apps.p, apps.r))
    res.exchange = [await deliver(apps.r, apps.p, ['c1'], group), await deliver(apps.p, apps.r, ['c2'], group)]
    if (res.exchange.some(d => d.received < d.sent)) throw new Error(`${c.creator} apps did not exchange messages`)
    await sleep(3000)
    res.created = states()
    for (const [i, s] of c.stages.entries()) {
      ctx.phase = `stage ${i + 1}`
      const changed = [['p', s.poster], ['r', s.reader], ['h', c.host]].filter(([n, v]) => apps[n] && apps[n].v !== v)
      for (const [n] of changed) await apps[n].stop()
      for (const [n, v] of changed) apps[n] = await start(n, v)
      const texts = Array.from({ length: s.n }, (_, j) => `s${i + 1}-${j + 1}`)
      res.stages.push({ ...s, ...(await deliver(apps.p, apps.r, texts, group)), state: states() })
    }
    ctx.phase = 'migration'
    res.migration = [await deliver(apps.r, apps.p, ['m1'], group), await deliver(apps.p, apps.r, ['m2', 'm3'], group)]
    res.migration.push(await deliver(apps.r, apps.p, ['m4', 'm5'], group))
    res.after = states()
  } catch (e) {
    res.error = e.message
  } finally {
    for (const app of Object.values(apps)) await app.stop()
  }
  res.errors = [...ctx.errors].map(([e, n]) => (n > 1 ? `${e} (×${n})` : e))
  return judge(c, res)
}

const current = s => Number(String(s?.rc ?? '').match(/\d+/)?.[0])
const outcome = ds => (ds.every(d => d.received === d.sent) ? 'delivered' : ds.every(d => d.received === 0) ? 'lost' : 'partly delivered')

function judge(c, res) {
  for (const s of res.stages) s.actual = outcome([s])
  res.actualAfter = res.after ? `${outcome(res.migration)}, ratchets P ${current(res.after.p)}, R ${current(res.after.r)}` : '-'
  res.createdAsExpected = Boolean(res.created) && [res.created.p, res.created.r].every(s => current(s) === createdVersion[c.creator])
  res.matches = !res.error && res.createdAsExpected && res.stages.every(s => s.actual === s.expected) && res.actualAfter === expectedAfter
  return res
}

const timeline = (r, k) =>
  [['created', r.created], ...r.stages.map((s, i) => [`stage ${i + 1}`, s.state]), ['after migration', r.after]]
    .filter(([, st]) => st)
    .map(([n, st]) => `${n}: P ${st.p[k] ?? '-'}, R ${st.r[k] ?? '-'}`)
    .join('<br>')

function row(r) {
  const c = allCases.find(x => x.id === r.id)
  const sent = [...r.stages.map(s => `${s.sent} → ${s.received} (${s.status})`), ...(r.migration ?? []).map(d => `${d.from}: ${d.sent} → ${d.received}`)]
  return [
    r.id,
    r.creator,
    c.stages.map(s => `${s.poster} → ${s.reader}`).join('<br>') + (c.host ? `<br>host ${c.host}` : ''),
    c.stages.map(s => s.expected).join('<br>'),
    r.stages.map(s => s.actual).join('<br>') || '-',
    expectedAfter,
    r.actualAfter,
    sent.join('<br>'),
    timeline(r, 'rc'),
    timeline(r, 'av'),
    [...r.errors, ...(r.error ? [`harness: ${r.error}`] : [])].join('<br>') || '-',
    r.error ? 'harness error' : r.matches ? 'yes' : 'no'
  ]
    .map(v => String(v).replaceAll('|', '\\|'))
    .join(' | ')
}

mkdirSync(work, { recursive: true })
const queue = [...cases]
const results = []
await Promise.all(
  Array.from({ length: workers }, async (_, slot) => {
    for (let c; (c = queue.shift()); ) {
      console.log(`${c.id}: started`)
      const r = await runCase(c, slot)
      console.log(`${c.id}: ${r.error ? `harness error: ${r.error}` : r.matches ? 'as expected' : 'unexpected'}`)
      results.push(r)
    }
  })
)
results.sort((a, b) => allCases.findIndex(c => c.id === a.id) - allCases.findIndex(c => c.id === b.id))
writeFileSync(`${work}/results.json`, JSON.stringify(results, null, 2))
const header = ['Case', 'Created by', 'Poster → reader', 'Expected before migration', 'Actual before migration', 'Expected after migration']
header.push('Actual after migration', 'Sent → received', 'Ratchet versions', 'Agent versions', 'Errors', 'As expected')
const table = [`| ${header.join(' | ')} |`, `|${header.map(() => '---').join('|')}|`, ...results.map(r => `| ${row(r)} |`)].join('\n')
console.log(`${table}\n\n${JSON.stringify(results, null, 2)}`)
if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, `## Cross-version test\n\n${table}\n`)
process.exit(results.every(r => r.matches) ? 0 : 1)
