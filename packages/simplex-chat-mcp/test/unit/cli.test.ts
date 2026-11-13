import {resolve} from "path"
import {helpText, parseCommand} from "../../src/cli"
import {ExitError} from "../../src/log"

describe("plugin commands", () => {
  it("parses each command", () => {
    expect(parseCommand(["session"])).toEqual({command: "session"})
    expect(parseCommand(["service"])).toEqual({command: "service"})
    expect(parseCommand(["hook", "session-start"])).toEqual({command: "hook session-start"})
    expect(parseCommand(["link"])).toEqual({command: "link"})
    expect(parseCommand(["reset-owners"])).toEqual({command: "reset-owners"})
    expect(parseCommand(["--help"])).toEqual({command: "help"})
  })

  it("parses the hooks that register adds for an agent, with its data folder as an absolute path", () => {
    expect(parseCommand(["hook", "agent-session-start", "/home/alice/.simplex-mcp/agent"])).toEqual({command: "hook agent-session-start", data: "/home/alice/.simplex-mcp/agent"})
    expect(parseCommand(["hook", "agent-secrets-changed", "agent"])).toEqual({command: "hook agent-secrets-changed", data: resolve("agent")})
  })

  it("refuses other commands and extra arguments", () => {
    const usage = new ExitError("Usage: simplex-mcp serve NAME [options] or simplex-mcp register NAME [options]. Run simplex-mcp --help.", 2)
    for (const args of [[], ["hook"], ["link", "x"], ["session", "--port", "1"], ["constructor"], ["__proto__"], ["toString"], ["hook", "agent-session-start"], ["hook", "agent-secrets-changed", "/a", "/b"], ["hook", "session-start", "/a"]]) {
      expect(() => parseCommand(args)).toThrow(usage)
    }
  })

  it("documents the commands, the install and the data folder", () => {
    for (const text of ["simplex-mcp session", "simplex-mcp service", "simplex-mcp hook session-start", "simplex-mcp hook agent-session-start DATA", "simplex-mcp hook agent-secrets-changed DATA", "simplex-mcp link", "simplex-mcp reset-owners", "/plugin install simplex@simplex-chat", "SIMPLEX_MCP_HOME"]) {
      expect(helpText).toContain(text)
    }
  })
})
