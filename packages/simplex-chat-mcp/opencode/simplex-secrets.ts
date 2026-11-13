import {existsSync, readFileSync} from "fs"
import {join} from "path"

type Variables = {[name: string]: string}

const data = "__SIMPLEX_MCP_DATA__"
const secretName = /^[A-Z][A-Z0-9_]{0,63}$/

export default {
  id: "simplex-secrets",
  server: async () => ({
    "shell.env": async (_input: object, output: {env: Variables}): Promise<void> => {
      Object.assign(output.env, shellVariables(data))
    },
  }),
}

export function shellVariables(folder: string): Variables {
  const index = join(folder, "secrets.json")
  const names = existsSync(index) ? Object.keys(JSON.parse(readFileSync(index, "utf8"))).filter(name => secretName.test(name)) : []
  if (names.length === 0) return {}
  const proxy: Variables = JSON.parse(readFileSync(join(folder, "proxy-env.json"), "utf8"))
  return {...proxy, ...Object.fromEntries(names.map(name => [name, `simplex-secret-${name}`]))}
}
