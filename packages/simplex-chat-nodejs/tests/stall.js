const {spawn, execFile} = require("child_process")
const fs = require("fs")
const path = require("path")
const libs = require("../dist/libs")

const pkgDir = path.resolve(__dirname, "..")
const addon = path.join(pkgDir, "build", "Release", "simplex.node")
const tmp = path.join(pkgDir, "tests", "stall-tmp")
const samplesDir = path.join(pkgDir, "tests", "stall-samples")
const budgetMs = Number(process.env.STALL_BUDGET_MS || 35 * 60000)
const J = JSON.stringify

const mark = `const t0 = Date.now(), mark = (s) => process.stderr.write("MARK " + s + " " + (Date.now() - t0) + "\\n");`

function idleScript(lib, db) {
  return `${mark}
    const simplex = require(${J(addon)});
    simplex.load(${J(lib)}); mark("load");
    simplex.chat_migrate_init(${J(db)}, "key", "yesUp")
      .then(([ctrl]) => { mark("init"); return simplex.chat_recv_msg_wait(ctrl, 1) })
      .then((res) => { mark("recv"); console.log("received " + JSON.stringify(res)) });`
}

function workersScript(lib, db) {
  return `${mark}
    const {Worker} = require("worker_threads");
    const simplex = require(${J(addon)});
    try { simplex.load(${J(addon)}) } catch (e) { console.log(JSON.stringify(e.message.endsWith("does not export hs_init_with_rtsopts"))) }
    mark("failed-load");
    const load = ${J(`require(${J(addon)}).load(${J(lib)})`)};
    const workers = Array.from({length: 4}, () => new Worker(load, {eval: true}));
    Promise.all(workers.map((w, i) => new Promise((resolve, reject) => w.on("exit", (c) => { mark("worker-exit-" + i); resolve(c) }).on("error", reject))))
      .then(async (codes) => {
        simplex.load(${J(lib)}); mark("main-load");
        const [ctrl] = await simplex.chat_migrate_init(${J(db)}, "key", "yesUp"); mark("init");
        await simplex.chat_send_cmd(ctrl, "/_stop"); mark("stop");
        const closed = await simplex.chat_close_store(ctrl) === ""; mark("close");
        console.log(JSON.stringify({codes, closed}));
      });`
}

function closeScript(lib, dir) {
  return `${mark}
    const simplex = require(${J(addon)});
    simplex.load(${J(lib)}); mark("load");
    (async () => {
      for (let i = 0; i < 10; i++) {
        const [ctrl] = await simplex.chat_migrate_init(${J(path.join(dir, "simplex"))}, "key", "yesUp"); mark(i + "-init");
        await simplex.chat_send_cmd(ctrl, "/v");
        await simplex.chat_send_cmd(ctrl, "/_stop"); mark(i + "-stop");
        const res = await simplex.chat_close_store(ctrl); mark(i + "-close");
        if (res !== "") throw new Error("close failed: " + res);
      }
    })();`
}

function sample(pid, file) {
  return new Promise((resolve) => {
    execFile("sudo", ["sample", String(pid), "3", "-file", file], {timeout: 60000}, (error, stdout, stderr) =>
      resolve(error ? "sample failed: " + error.message + " " + stderr : "sampled to " + file))
  })
}

function runChild(name, script, limitMs, round) {
  return new Promise((resolve) => {
    const start = Date.now()
    const child = spawn(process.execPath, ["-e", script], {cwd: pkgDir})
    let stderr = "", stdout = "", stalled = false
    child.stderr.on("data", (d) => { stderr += d })
    child.stdout.on("data", (d) => { stdout += d })
    const stallTimer = setTimeout(async () => {
      stalled = true
      const file = path.join(samplesDir, `${name}-${round}-${child.pid}.txt`)
      console.log(`STALL ${name} round ${round} pid ${child.pid} after ${Date.now() - start} ms; marks:\n${stderr}`)
      console.log(await sample(child.pid, file))
    }, limitMs)
    const killTimer = setTimeout(() => child.kill("SIGKILL"), limitMs + 90000)
    child.on("exit", (code, signal) => {
      clearTimeout(stallTimer)
      clearTimeout(killTimer)
      const ms = Date.now() - start
      if (stalled || code !== 0) console.log(`END ${name} round ${round} code ${code} signal ${signal} after ${ms} ms stalled ${stalled}; stdout ${J(stdout.trim())}; marks:\n${stderr}`)
      resolve({ms, stalled, failed: code !== 0})
    })
  })
}

;(async () => {
  const lib = libs.libPath(await libs.resolveLibsDir("sqlite"))
  fs.rmSync(tmp, {recursive: true, force: true})
  fs.mkdirSync(tmp, {recursive: true})
  fs.mkdirSync(samplesDir, {recursive: true})
  const template = path.join(tmp, "template")
  await runChild("template", `const simplex = require(${J(addon)}); simplex.load(${J(lib)});
    simplex.chat_migrate_init(${J(template)}, "key", "yesUp").then(([ctrl]) => simplex.chat_send_cmd(ctrl, "/_stop").then(() => simplex.chat_close_store(ctrl)));`, 60000, 0)
  const stats = {}
  const record = (name, r) => {
    const s = stats[name] || (stats[name] = {runs: 0, stalls: 0, failures: 0, max: 0, total: 0})
    s.runs++
    s.total += r.ms
    s.max = Math.max(s.max, r.ms)
    if (r.stalled) s.stalls++
    if (r.failed) s.failures++
  }
  const deadline = Date.now() + budgetMs
  for (let round = 1; Date.now() < deadline; round++) {
    const dir = path.join(tmp, "r" + round)
    fs.mkdirSync(dir)
    for (const suffix of ["_chat.db", "_agent.db"]) fs.copyFileSync(template + suffix, path.join(dir, "idle" + suffix))
    record("idle", await runChild("idle", idleScript(lib, path.join(dir, "idle")), 15000, round))
    record("workers", await runChild("workers", workersScript(lib, path.join(dir, "workers")), 20000, round))
    record("close", await runChild("close", closeScript(lib, dir), 60000, round))
    fs.rmSync(dir, {recursive: true, force: true})
    if (round % 20 === 0) console.log(`ROUND ${round} ${J(stats)}`)
  }
  console.log(`SUMMARY ${J(stats)}`)
})()
