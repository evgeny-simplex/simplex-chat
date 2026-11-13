import * as childProcess from "child_process"
import {existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync} from "fs"
import {homedir, tmpdir} from "os"
import {join} from "path"
import {createDataFolder, serverToken, writeServerFile} from "../../src/files"
import {ExitError} from "../../src/log"
import {RunResult, cmdArgument, projectRoot, register, registryEntry} from "../../src/register"

let dir: string
let home: string

beforeEach(() => {
  dir = join(mkdtempSync(join(tmpdir(), "simplex-mcp-register-")), "agent")
  home = join(dir, "..", "home")
  createDataFolder(dir)
})

afterEach(() => {
  jest.restoreAllMocks()
  rmSync(join(dir, ".."), {recursive: true, force: true})
})

const ok: RunResult = {missing: false, status: 0, stderr: ""}

function recorder(results: RunResult[]): {calls: string[][]; run: (command: string, args: string[]) => RunResult} {
  const calls: string[][] = []
  return {calls, run: (command, args) => (calls.push([command, ...args]), results[calls.length - 1] ?? ok)}
}

describe("register", () => {
  const platform = Object.getOwnPropertyDescriptor(process, "platform")!
  const onPlatform = (value: NodeJS.Platform): void => {
    Object.defineProperty(process, "platform", {...platform, value})
  }

  afterEach(() => Object.defineProperty(process, "platform", platform))

  it("builds the entry with the timeout from server.json and a helper that prints the headers file", () => {
    onPlatform("linux")
    expect(registryEntry(5226, "/home/alice/.simplex-mcp/agent", 23)).toEqual({
      type: "http",
      url: "http://127.0.0.1:5226/mcp",
      headersHelper: "cat /home/alice/.simplex-mcp/agent/headers.json",
      timeout: 169_800_000,
    })
    expect(registryEntry(5227, "/tmp/my agent's", 1)).toMatchObject({headersHelper: "cat '/tmp/my agent'\\''s/headers.json'", timeout: 25 * 3_600_000 + 600_000})
    onPlatform("win32")
    const data = "C:\\Users\\Ana Lu\\agent"
    expect(registryEntry(5226, data, 23).headersHelper).toBe(`type "${join(data, "headers.json")}"`)
  })

  it("removes the entry before adding it, with no token in the command", () => {
    writeServerFile(dir, {name: "agent", port: 5227, expireHours: 2})
    const token = serverToken(dir, false)
    const {calls, run} = recorder([{missing: false, status: 1, stderr: "not found"}, ok])
    expect(register({name: "agent", data: dir, scope: "user", host: "claude"}, run, undefined, {HOME: home})).toBe(
      `Added to Claude Code: scope user, server simplex-agent, hooks in ${join(home, ".claude", "settings.json")}.`,
    )
    const entry = JSON.stringify({type: "http", url: "http://127.0.0.1:5227/mcp", headersHelper: `cat ${join(dir, "headers.json")}`, timeout: 26 * 3_600_000 + 600_000})
    expect(calls).toEqual([
      ["claude", "mcp", "remove", "--scope", "user", "simplex-agent"],
      ["claude", "mcp", "add-json", "--scope", "user", "simplex-agent", entry],
    ])
    expect(calls.flat().join(" ")).not.toContain(token)
  })

  it("reports an agent that was never started", () => {
    const {run} = recorder([])
    expect(() => register({name: "agent", data: dir, scope: "user", host: "claude"}, run)).toThrow(
      new ExitError('Agent "agent" was never started. Start it with: npx -y @simplex-chat/mcp serve agent', 1),
    )
    expect(() => register({name: "agent", data: dir, scope: "user", host: "opencode"}, run)).toThrow(
      new ExitError('Agent "agent" was never started. Start it with: npx -y @simplex-chat/mcp serve agent', 1),
    )
  })

  it("prints the entry when claude is missing", () => {
    writeServerFile(dir, {name: "agent", port: 5226, expireHours: 23})
    const entry = JSON.stringify(registryEntry(5226, dir, 23))
    const missing = {missing: true, status: null, stderr: ""}
    const project = join(dir, "..", "project")
    expect(() => register({name: "agent", data: dir, scope: "user", host: "claude"}, recorder([missing]).run, undefined, {HOME: home})).toThrow(
      new ExitError(`Add this entry under "mcpServers" in ~/.claude.json: {"simplex-agent": ${entry}}`, 1),
    )
    expect(() => register({name: "agent", data: dir, scope: "local", host: "claude"}, recorder([missing]).run, () => project, {HOME: home})).toThrow(
      new ExitError(`Add this entry under "projects" > "${project}" > "mcpServers" in ~/.claude.json: {"simplex-agent": ${entry}}`, 1),
    )
  })

  it("reports a failed add", () => {
    writeServerFile(dir, {name: "agent", port: 5226, expireHours: 23})
    expect(() => register({name: "agent", data: dir, scope: "user", host: "claude"}, recorder([ok, {missing: false, status: 1, stderr: "bad scope\n"}]).run, undefined, {HOME: home})).toThrow(
      new ExitError("claude mcp add-json failed: bad scope", 1),
    )
  })

  describe("hooks", () => {
    const cli = join(__dirname, "..", "..", "src", "cli.js")
    const settingsOf = (file: string): unknown => JSON.parse(readFileSync(file, "utf8"))
    const agentHooks = (data: string, folder = data) => ({
      SessionStart: {hooks: [{type: "command", command: `node ${cli} hook agent-session-start ${folder}`}]},
      FileChanged: {matcher: "secrets.json", hooks: [{type: "command", command: `node ${cli} hook agent-secrets-changed ${folder}`}]},
    })

    beforeEach(() => writeServerFile(dir, {name: "agent", port: 5226, expireHours: 23}))

    it("runs in a temporary home without CLAUDE_CONFIG_DIR, so that no test writes the settings of this computer's Claude Code", () => {
      expect(process.env.CLAUDE_CONFIG_DIR).toBeUndefined()
      expect(homedir().startsWith(join(tmpdir(), "simplex-mcp-home-"))).toBe(true)
    })

    it("adds the agent's SessionStart and FileChanged hooks to the user's settings after the hooks there, and replaces only its own at a new register", () => {
      const file = join(home, ".claude", "settings.json")
      const other = agentHooks(join(dir, "..", "other"))
      const own = agentHooks(dir)
      const echo = {hooks: [{type: "command", command: "echo hi"}]}
      const envrc = {matcher: ".envrc", hooks: [{type: "command", command: "direnv export bash"}]}
      const older = {hooks: [{type: "command", command: `node /old/dist/cli.js hook agent-session-start ${dir}`}, {type: "command", command: "date"}]}
      mkdirSync(join(home, ".claude"), {recursive: true})
      writeFileSync(file, JSON.stringify({model: "opus", hooks: {SessionStart: [echo, other.SessionStart, older], FileChanged: [envrc, other.FileChanged], Stop: [echo]}}))
      register({name: "agent", data: dir, scope: "user", host: "claude"}, () => ok, undefined, {HOME: home})
      const expected = {
        model: "opus",
        hooks: {
          SessionStart: [echo, other.SessionStart, {hooks: [{type: "command", command: "date"}]}, own.SessionStart],
          FileChanged: [envrc, other.FileChanged, own.FileChanged],
          Stop: [echo],
        },
      }
      expect(readFileSync(file, "utf8")).toBe(`${JSON.stringify(expected, null, 2)}\n`)
      register({name: "agent", data: dir, scope: "user", host: "claude"}, () => ok, undefined, {HOME: home})
      expect(settingsOf(file)).toEqual(expected)
    })

    it("writes the settings of CLAUDE_CONFIG_DIR, or the project's local settings for --scope local, creating the folder", () => {
      const config = join(dir, "..", "config")
      const project = join(dir, "..", "project")
      const own = agentHooks(dir)
      const hooks = {SessionStart: [own.SessionStart], FileChanged: [own.FileChanged]}
      expect(register({name: "agent", data: dir, scope: "user", host: "claude"}, () => ok, undefined, {HOME: home, CLAUDE_CONFIG_DIR: config})).toBe(
        `Added to Claude Code: scope user, server simplex-agent, hooks in ${join(config, "settings.json")}.`,
      )
      expect(settingsOf(join(config, "settings.json"))).toEqual({hooks})
      register({name: "agent", data: dir, scope: "local", host: "claude"}, () => ok, () => project, {HOME: home})
      expect(settingsOf(join(project, ".claude", "settings.local.json"))).toEqual({hooks})
      expect(existsSync(join(home, ".claude"))).toBe(false)
    })

    it("quotes the data folder for the shell of the hooks: bash, or Git Bash and PowerShell on Windows", () => {
      const spaced = join(dir, "..", "my agent's")
      createDataFolder(spaced)
      writeServerFile(spaced, {name: "agent", port: 5226, expireHours: 23})
      const file = join(home, ".claude", "settings.json")
      register({name: "agent", data: spaced, scope: "user", host: "claude"}, () => ok, undefined, {HOME: home})
      const quoted = agentHooks(spaced, `'${spaced.replace(/'/g, "'\\''")}'`)
      expect(settingsOf(file)).toEqual({hooks: {SessionStart: [quoted.SessionStart], FileChanged: [quoted.FileChanged]}})
      onPlatform("win32")
      register({name: "agent", data: spaced, scope: "user", host: "claude"}, () => ok, undefined, {HOME: home})
      const windows = agentHooks(spaced, `"${spaced}"`)
      expect(settingsOf(file)).toEqual({hooks: {SessionStart: [quoted.SessionStart, windows.SessionStart], FileChanged: [quoted.FileChanged, windows.FileChanged]}})
    })

    it("refuses settings that are not a JSON object before it changes the Claude Code entry", () => {
      const file = join(home, ".claude", "settings.json")
      mkdirSync(join(home, ".claude"), {recursive: true})
      for (const text of ['{"model": "opus",', "[]", "null"]) {
        writeFileSync(file, text)
        const {calls, run} = recorder([])
        expect(() => register({name: "agent", data: dir, scope: "user", host: "claude"}, run, undefined, {HOME: home})).toThrow(
          new ExitError(`${file} is not a JSON object. Correct it, then run register again.`, 1),
        )
        expect(calls).toEqual([])
        expect(readFileSync(file, "utf8")).toBe(text)
      }
    })
  })

  describe("to opencode", () => {
    beforeEach(() => writeServerFile(dir, {name: "agent", port: 5227, expireHours: 2}))

    it("adds the server with the token file in its header from the home folder, and the plugin with the agent's data folder", () => {
      const token = serverToken(dir, false)
      const calls: [string, string[], string | undefined][] = []
      const message = register({name: "agent", data: dir, scope: "user", host: "opencode"}, (command, args, cwd) => (calls.push([command, args, cwd]), ok), undefined, {HOME: home})
      const plugin = join(home, ".config", "opencode", "plugins", "simplex-agent.ts")
      expect(message).toBe(`Added to opencode: server simplex-agent, plugin ${plugin}.`)
      expect(calls).toEqual([["opencode", ["mcp", "add", "simplex-agent", "--url", "http://127.0.0.1:5227/mcp", "--header", `Authorization=Bearer {file:${join(dir, "token")}}`], home]])
      expect(calls.flat(2).join(" ")).not.toContain(token)
      const source = readFileSync(join(__dirname, "..", "..", "opencode", "simplex-secrets.ts"), "utf8")
      expect(readFileSync(plugin, "utf8")).toBe(source.replace('const data = "__SIMPLEX_MCP_DATA__"', `const data = ${JSON.stringify(dir)}`))
      register({name: "agent", data: dir, scope: "user", host: "opencode"}, () => ok, undefined, {HOME: home, XDG_CONFIG_HOME: join(home, "xdg")})
      expect(existsSync(join(home, "xdg", "opencode", "plugins", "simplex-agent.ts"))).toBe(true)
    })

    it("reports opencode missing and a failed add, and writes no plugin then", () => {
      expect(() => register({name: "agent", data: dir, scope: "user", host: "opencode"}, () => ({missing: true, status: null, stderr: ""}), undefined, {HOME: home})).toThrow(
        new ExitError("opencode is not installed. Install it with: npm install -g --prefix ~/.local opencode-ai", 1),
      )
      expect(() => register({name: "agent", data: dir, scope: "user", host: "opencode"}, () => ({missing: false, status: 1, stderr: "bad url\n"}), undefined, {HOME: home})).toThrow(
        new ExitError("opencode mcp add failed: bad url", 1),
      )
      expect(existsSync(join(home, ".config"))).toBe(false)
    })
  })

  describe("when claude can't be spawned", () => {
    const spawnClaude = (shellStatus: number): jest.SpyInstance =>
      jest.spyOn(childProcess, "spawnSync").mockImplementation(((_command: string, args: unknown) =>
        Array.isArray(args) ? {error: Object.assign(new Error("spawnSync claude ENOENT"), {code: "ENOENT"}), status: null, stderr: ""} : {status: shellStatus, stderr: ""}) as never)
    const manualEntry = (): ExitError => new ExitError(`Add this entry under "mcpServers" in ~/.claude.json: {"simplex-agent": ${JSON.stringify(registryEntry(5226, dir, 23))}}`, 1)

    beforeEach(() => writeServerFile(dir, {name: "agent", port: 5226, expireHours: 23}))

    it("runs it through cmd.exe on Windows, with the arguments quoted for cmd.exe", () => {
      onPlatform("win32")
      const spawn = spawnClaude(0)
      expect(register({name: "agent", data: dir, scope: "user", host: "claude"}, undefined, undefined, {HOME: home})).toBe(
        `Added to Claude Code: scope user, server simplex-agent, hooks in ${join(home, ".claude", "settings.json")}.`,
      )
      const words = (args: string[]): string => ["claude", ...args.map(cmdArgument)].join(" ")
      expect(spawn.mock.calls).toEqual([
        ["claude", ["mcp", "remove", "--scope", "user", "simplex-agent"], {encoding: "utf8"}],
        [words(["mcp", "remove", "--scope", "user", "simplex-agent"]), {encoding: "utf8", shell: true}],
        ["claude", ["mcp", "add-json", "--scope", "user", "simplex-agent", JSON.stringify(registryEntry(5226, dir, 23))], {encoding: "utf8"}],
        [words(["mcp", "add-json", "--scope", "user", "simplex-agent", JSON.stringify(registryEntry(5226, dir, 23))]), {encoding: "utf8", shell: true}],
      ])
    })

    it("prints the entry on Windows when cmd.exe does not find it either", () => {
      onPlatform("win32")
      const spawn = spawnClaude(9009)
      expect(() => register({name: "agent", data: dir, scope: "user", host: "claude"}, undefined, undefined, {HOME: home})).toThrow(manualEntry())
      expect(spawn).toHaveBeenCalledTimes(2)
    })

    it("prints the entry on other platforms without a shell", () => {
      onPlatform("linux")
      const spawn = spawnClaude(0)
      expect(() => register({name: "agent", data: dir, scope: "user", host: "claude"}, undefined, undefined, {HOME: home})).toThrow(manualEntry())
      expect(spawn).toHaveBeenCalledTimes(1)
    })
  })

  it("quotes an argument for cmd.exe and for the npm command shim it runs", () => {
    expect(cmdArgument("mcp")).toBe('^^^"mcp^^^"')
    expect(cmdArgument('{"a":"b c"}')).toBe('^^^"{\\^^^"a\\^^^":\\^^^"b^^^ c\\^^^"}^^^"')
    expect(cmdArgument('a\\"b')).toBe('^^^"a\\\\\\^^^"b^^^"')
    expect(cmdArgument("C:\\dir\\")).toBe('^^^"C:\\dir\\\\^^^"')
    expect(cmdArgument("100% & more")).toBe('^^^"100^^^%^^^ ^^^&^^^ more^^^"')
  })
})

describe("project root", () => {
  function folder(...parts: string[]): string {
    const path = join(dir, "..", ...parts)
    mkdirSync(path, {recursive: true})
    return path
  }

  it("keys a repository folder, a worktree, a submodule and a plain folder as Claude Code does", () => {
    const repo = folder("repo")
    const worktreeGit = folder("repo", ".git", "worktrees", "feature")
    writeFileSync(join(worktreeGit, "commondir"), "../..\n")
    writeFileSync(join(folder("feature"), ".git"), `gitdir: ${worktreeGit}\n`)
    folder("repo", ".git", "modules", "sub")
    writeFileSync(join(folder("repo", "sub"), ".git"), "gitdir: ../.git/modules/sub\n")
    expect(projectRoot(folder("repo", "src", "lib"))).toBe(repo)
    expect(projectRoot(folder("feature", "src"))).toBe(repo)
    expect(projectRoot(folder("repo", "sub", "src"))).toBe(join(repo, "sub"))
    expect(projectRoot(folder("plain", "a"))).toBe(folder("plain", "a"))
  })
})
