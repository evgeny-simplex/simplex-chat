import {sign} from "crypto"

const scope = "https://www.googleapis.com/auth/cloud-platform"
const grantType = "urn:ietf:params:oauth:grant-type:jwt-bearer"
const lifetimeSeconds = 3600
const renewBeforeMs = 5 * 60_000

export interface ServiceAccountKey {
  client_email: string
  private_key: string
  token_uri: string
  private_key_id?: string
}

export type PostForm = (url: string, form: {[name: string]: string}) => Promise<{status: number; body: unknown}>

export class GcpError extends Error {}

export function serviceAccountKey(value: string): ServiceAccountKey | undefined {
  try {
    const key = JSON.parse(value)
    const valid = key?.type === "service_account" && [key.client_email, key.private_key, key.token_uri].every(field => typeof field === "string")
    return valid ? key : undefined
  } catch {
    return undefined
  }
}

export function assertion(key: ServiceAccountKey, now: number): string {
  const iat = Math.floor(now / 1000)
  const header = {alg: "RS256", typ: "JWT", ...(key.private_key_id === undefined ? {} : {kid: key.private_key_id})}
  const claims = {iss: key.client_email, scope, aud: key.token_uri, iat, exp: iat + lifetimeSeconds}
  const signed = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`
  return `${signed}.${sign("RSA-SHA256", Buffer.from(signed), key.private_key).toString("base64url")}`
}

export class GcpTokens {
  private readonly tokens = new Map<string, Promise<{token: string; renewAt: number}>>()

  constructor(
    private readonly postForm: PostForm = fetchForm,
    private readonly now: () => number = Date.now,
  ) {}

  async token(key: ServiceAccountKey): Promise<string> {
    const id = `${key.client_email} ${key.private_key_id ?? ""} ${key.token_uri}`
    const cached = this.tokens.get(id)
    const entry = await cached?.catch(() => undefined)
    if (entry !== undefined && entry.renewAt > this.now()) return entry.token
    if (this.tokens.get(id) === cached) {
      const request = this.request(key)
      this.tokens.set(id, request)
      request.catch(() => this.tokens.get(id) === request && this.tokens.delete(id))
    }
    return (await this.tokens.get(id)!).token
  }

  private async request(key: ServiceAccountKey): Promise<{token: string; renewAt: number}> {
    const started = this.now()
    const {status, body} = await this.postForm(key.token_uri, {grant_type: grantType, assertion: assertion(key, started)})
    const reply = (body ?? {}) as {access_token?: unknown; expires_in?: unknown; error?: unknown; error_description?: unknown}
    if (status !== 200 || typeof reply.access_token !== "string") throw new GcpError(String(reply.error_description ?? reply.error ?? `HTTP ${status}`))
    const seconds = typeof reply.expires_in === "number" ? reply.expires_in : lifetimeSeconds
    return {token: reply.access_token, renewAt: started + seconds * 1000 - renewBeforeMs}
  }
}

async function fetchForm(url: string, form: {[name: string]: string}): Promise<{status: number; body: unknown}> {
  const response = await fetch(url, {method: "POST", headers: {"content-type": "application/x-www-form-urlencoded"}, body: new URLSearchParams(form).toString()})
  return {status: response.status, body: await response.json().catch(() => undefined)}
}

function base64url(text: string): string {
  return Buffer.from(text, "utf8").toString("base64url")
}
