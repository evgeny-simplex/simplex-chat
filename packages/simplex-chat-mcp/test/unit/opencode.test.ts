import {mkdtempSync, rmSync, writeFileSync} from "fs"
import {tmpdir} from "os"
import {join} from "path"
import plugin, {shellVariables} from "../../opencode/simplex-secrets"
import {SecretRecord, Secrets} from "../../src/files"
import {proxyFiles, proxyVariables} from "../../src/secrets"

const record: SecretRecord = {hosts: ["api.github.com"], mode: "value", setBy: "Alice", setById: 3, setAt: "2026-11-13T10:00:00.000Z"}
let folder: string

beforeEach(() => {
  folder = mkdtempSync(join(tmpdir(), "simplex-mcp-opencode-"))
  writeFileSync(join(folder, "proxy-env.json"), JSON.stringify(proxyVariables(proxyFiles(folder, 5226), [])))
})

afterEach(() => rmSync(folder, {recursive: true, force: true}))

describe("shell variables", () => {
  it("are the proxy, its certificates and a placeholder for each secret of the agent", () => {
    const secrets = new Secrets(folder)
    secrets.set("GITHUB_TOKEN", "ghp_real_token_value", record)
    secrets.set("AWS_ACCESS_KEY_ID", "AKIAREALKEYID123", {...record, hosts: ["*.amazonaws.com"], mode: "aws"})
    expect(shellVariables(folder)).toEqual(proxyVariables(proxyFiles(folder, 5226), ["AWS_ACCESS_KEY_ID", "GITHUB_TOKEN"]))
    expect(shellVariables(folder)).toMatchObject({HTTPS_PROXY: "http://127.0.0.1:5226", GITHUB_TOKEN: "simplex-secret-GITHUB_TOKEN", AWS_ACCESS_KEY_ID: "simplex-secret-AWS_ACCESS_KEY_ID"})
  })

  it("are none without secrets, and none for a folder without files", () => {
    expect(shellVariables(folder)).toEqual({})
    expect(shellVariables(join(folder, "missing"))).toEqual({})
  })
})

describe("plugin", () => {
  it("is a server plugin with an id that adds the variables to the shell environment of opencode", async () => {
    expect(plugin.id).toBe("simplex-secrets")
    const output = {env: {PATH: "/usr/bin"}}
    await (await plugin.server())["shell.env"]({}, output)
    expect(output.env).toEqual({PATH: "/usr/bin"})
  })
})
