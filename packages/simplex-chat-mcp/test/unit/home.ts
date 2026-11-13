import {mkdtempSync, rmSync} from "fs"
import {tmpdir} from "os"
import {join} from "path"

export default function temporaryHome(): void {
  const home = mkdtempSync(join(tmpdir(), "simplex-mcp-home-"))
  process.env.HOME = home
  process.env.USERPROFILE = home
  delete process.env.SIMPLEX_MCP_HOME
  delete process.env.CLAUDE_CONFIG_DIR
  process.on("exit", () => rmSync(home, {recursive: true, force: true}))
}
