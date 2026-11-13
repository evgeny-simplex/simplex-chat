import {KeyObject} from "crypto"
import {existsSync, readFileSync} from "fs"
import {IncomingHttpHeaders, IncomingMessage, OutgoingHttpHeaders, Server, ServerResponse, createServer, request as httpRequest} from "http"
import {Agent as HttpsAgent, RequestOptions as HttpsRequestOptions, request as httpsRequest} from "https"
import {BlockList, Socket, connect, isIP} from "net"
import {join} from "path"
import {Duplex, Transform, TransformCallback, pipeline} from "stream"
import {SecureContext, TLSSocket, createSecureContext, rootCertificates} from "tls"
import {createBrotliDecompress, createGunzip, createInflate} from "zlib"
import {Issued, caFromPem, createCa, hostCertificate, newKey} from "./certs"
import {SecretEntry, Secrets, writePrivateFile} from "./files"
import {GcpError, GcpTokens, serviceAccountKey} from "./gcp"
import {log} from "./log"
import {awsNames, boundEntries, placeholder, placeholderPattern, valueForms} from "./secrets"
import {AwsRequest, Headers, headerValue, resign, sigV4Credential} from "./sigv4"

// spec: spec/api.md#secrets-proxy
const maxBody = 8 * 1_048_576
const certRenewMs = 6 * 86_400_000
const caName = "SimpleX MCP local CA"
const systemBundles = ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt", "/etc/ssl/cert.pem"]
const hopHeaders = new Set(["connection", "keep-alive", "proxy-authorization", "proxy-authenticate", "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "expect"])
// spec: spec/api.md#secrets-proxy
const textType = /^(text\/|application\/(json|x-www-form-urlencoded|xml|javascript|graphql)\b|[^;]*\+(json|xml)\b)/i
const decoders = {gzip: createGunzip, "x-gzip": createGunzip, deflate: createInflate, br: createBrotliDecompress}
const loopbackHosts = new Set(["localhost", "127.0.0.1", "::1"])

export interface ProxyOptions {
  secrets: Secrets
  ca: Issued
  upstream?: Upstream
  gcp?: GcpTokens
  connectTo?: (host: string, port: number) => {host: string; port: number}
  upstreamCa?: string
}

export interface Upstream {
  https?: UpstreamProxy
  http?: UpstreamProxy
  noProxy: string[]
}

export interface UpstreamProxy {
  host: string
  port: number
  tls: boolean
  authorization?: string
}

interface Target {
  host: string
  port: number
}

interface Outgoing {
  target: string
  headers: Headers
  body: Buffer
}

class Refusal extends Error {}

// spec: spec/architecture.md#proxy-secretsproxy
export class SecretsProxy {
  private readonly contexts = new Map<string, {context: SecureContext; at: number}>()
  private readonly leafKey: KeyObject = newKey()
  private readonly inner: Server
  private readonly targets = new WeakMap<Socket, Target>()
  private readonly sockets = new Set<Socket>()
  private readonly issued = new Map<string, string>()
  private readonly gcp: GcpTokens
  private readonly agent = new TargetAgent(target => this.open(target))

  constructor(private readonly options: ProxyOptions) {
    this.gcp = options.gcp ?? new GcpTokens((url, form) => this.postForm(url, form))
    this.inner = createServer((req, res) => {
      const target = this.targets.get(req.socket)
      if (target === undefined) res.destroy()
      else this.forward(req, res, target).catch(error => this.fail(res, error, target.host))
    })
  }

  // spec: spec/architecture.md#proxy-attach
  attach(server: Server): void {
    server.on("connect", (req: IncomingMessage, socket: Socket, head: Buffer) => this.connect(req, socket, head))
  }

  // spec: spec/architecture.md#proxy-attach
  close(): void {
    this.agent.destroy()
    for (const socket of this.sockets) socket.destroy()
  }

  // spec: spec/architecture.md#proxy-connect
  connect(req: IncomingMessage, client: Socket, head: Buffer): void {
    this.track(client)
    client.on("error", () => client.destroy())
    const target = parseTarget(req.url)
    if (target === undefined) return void client.end("HTTP/1.1 400 Bad Request\r\n\r\n")
    if (boundEntries(this.options.secrets.entries(), target.host, target.port).length === 0) return this.tunnel(client, head, target)
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
    if (head.length > 0) client.unshift(head)
    const tls = new TLSSocket(client, {isServer: true, secureContext: this.context(target.host), ALPNProtocols: ["http/1.1"]})
    tls.on("error", () => tls.destroy())
    this.targets.set(tls, target)
    this.inner.emit("connection", tls)
  }

  // spec: spec/architecture.md#proxy-request
  request(req: IncomingMessage, res: ServerResponse): void {
    let url: URL
    try {
      url = new URL(req.url ?? "")
    } catch {
      return plain(res, 400, "SimpleX proxy: a request in absolute form expected.")
    }
    if (url.protocol !== "http:") return plain(res, 400, "SimpleX proxy: HTTPS requests are sent with CONNECT.")
    const used = [url.pathname + url.search, ...Object.values(req.headers).flat()].some(text => text !== undefined && new RegExp(placeholderPattern.source).test(text))
    if (used) return this.refuse(res, url.hostname, "secrets are sent only over HTTPS.")
    const host = bareHost(url.hostname)
    const port = Number(url.port || 80)
    const via = this.proxyFor({host, port}, this.options.upstream?.http)
    const headers = forwardedHeaders(req.headers)
    const onResponse = (response: IncomingMessage): void => {
      res.writeHead(response.statusCode ?? 502, forwardedHeaders(response.headers))
      pipeline(response, res, () => undefined)
    }
    const upstream =
      via === undefined
        ? httpRequest({host, port, method: req.method, path: url.pathname + url.search, headers, agent: false}, onResponse)
        : (via.tls ? httpsRequest : httpRequest)({host: via.host, port: via.port, method: req.method, path: url.href, headers: {...headers, ...proxyAuthorization(via)}, agent: false}, onResponse)
    upstream.on("error", () => plain(res, 502, `SimpleX proxy: ${url.hostname} can't be reached.`))
    pipeline(req, upstream, () => undefined)
  }

  // spec: spec/architecture.md#proxy-connect
  private tunnel(client: Socket, head: Buffer, target: Target): void {
    this.open(target).then(
      upstream => {
        upstream.on("error", () => client.destroy())
        client.on("close", () => upstream.destroy())
        if (client.destroyed) return void upstream.destroy()
        client.write("HTTP/1.1 200 Connection Established\r\n\r\n")
        if (head.length > 0) upstream.write(head)
        upstream.pipe(client)
        client.pipe(upstream)
      },
      () => client.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"),
    )
  }

  // spec: spec/architecture.md#proxy-open
  private async open(target: Target): Promise<Socket> {
    const via = this.proxyFor(target, this.options.upstream?.https)
    if (via !== undefined) return this.chained(via, target)
    const {host, port} = this.options.connectTo?.(target.host, target.port) ?? target
    const socket = this.track(connect(port, host))
    await new Promise<void>((resolve, reject) => {
      socket.once("connect", () => {
        socket.off("error", reject)
        resolve()
      })
      socket.once("error", reject)
    })
    return socket
  }

  // spec: spec/architecture.md#proxy-open
  private chained(via: UpstreamProxy, {host, port}: Target): Promise<Socket> {
    const authority = `${isIP(host) === 6 ? `[${host}]` : host}:${port}`
    return new Promise((resolve, reject) => {
      const request = (via.tls ? httpsRequest : httpRequest)({host: via.host, port: via.port, method: "CONNECT", path: authority, headers: {host: authority, ...proxyAuthorization(via)}, agent: false})
      request.once("socket", socket => this.track(socket as Socket))
      request.once("connect", (response: IncomingMessage, socket: Socket, head: Buffer) => {
        if (response.statusCode !== 200) {
          socket.destroy()
          return reject(new Error(`the proxy ${via.host}:${via.port} answered ${response.statusCode}`))
        }
        if (head.length > 0) socket.unshift(head)
        resolve(socket)
      })
      request.once("error", reject)
      request.end()
    })
  }

  // spec: spec/architecture.md#proxy-open
  private proxyFor(target: Target, via: UpstreamProxy | undefined): UpstreamProxy | undefined {
    return via === undefined || bypassed(this.options.upstream?.noProxy ?? [], target.host, target.port) ? undefined : via
  }

  // spec: spec/architecture.md#proxy-open
  private targetOptions({host, port}: Target): HttpsRequestOptions {
    return {agent: this.agent, host, port, servername: host, ...(this.options.upstreamCa === undefined ? {} : {ca: this.options.upstreamCa})}
  }

  // spec: spec/architecture.md#proxy-forward
  private async forward(req: IncomingMessage, res: ServerResponse, target: Target): Promise<void> {
    if (!sameHost(req.headers.host, target)) return this.refuse(res, target.host, `the request's Host differs from ${target.host}.`)
    const entries = this.options.secrets.entries()
    const streamed = Number(req.headers["content-length"] ?? 0) > maxBody
    const body = streamed ? Buffer.alloc(0) : await readBody(req)
    const outgoing = await this.withSecrets({target: req.url ?? "/", headers: {...req.headers}, body}, req.method ?? "GET", target, entries, streamed)
    const headers: OutgoingHttpHeaders = forwardedHeaders(outgoing.headers)
    if (!streamed) headers["content-length"] = String(outgoing.body.length)
    const upstream = httpsRequest({...this.targetOptions(target), method: req.method, path: outgoing.target, headers}, response => this.respond(response, res, target, entries))
    upstream.on("error", () => plain(res, 502, `SimpleX proxy: ${target.host} can't be reached.`))
    if (streamed) pipeline(req, upstream, () => undefined)
    else upstream.end(outgoing.body)
  }

  // spec: spec/architecture.md#proxy-open
  private postForm(url: string, form: {[name: string]: string}): Promise<{status: number; body: unknown}> {
    const {hostname, port, pathname, search} = new URL(url)
    const body = new URLSearchParams(form).toString()
    return new Promise((resolve, reject) => {
      const request = httpsRequest({...this.targetOptions({host: bareHost(hostname), port: Number(port || 443)}), method: "POST", path: pathname + search, headers: {"content-type": "application/x-www-form-urlencoded", "content-length": Buffer.byteLength(body)}}, response => {
        readBody(response).then(data => resolve({status: response.statusCode ?? 0, body: jsonOf(data)}), reject)
      })
      request.on("error", reject)
      request.end(body)
    })
  }

  // spec: spec/architecture.md#proxy-forward
  private async withSecrets(request: Outgoing, method: string, target: Target, entries: SecretEntry[], streamed: boolean): Promise<Outgoing> {
    const textBody = !streamed && request.body.length > 0 && headerValue(request.headers, "content-encoding") === undefined && textType.test(headerValue(request.headers, "content-type") ?? "text/plain")
    const bodyText = textBody ? request.body.toString("latin1") : ""
    const authorization = headerValue(request.headers, "authorization")
    const basic = /^Basic (.+)$/i.exec(authorization ?? "")?.[1]
    const basicText = basic === undefined ? "" : Buffer.from(basic, "base64").toString("latin1")
    const places = [request.target, ...Object.values(request.headers).flat(), basicText, bodyText].filter((text): text is string => text !== undefined)
    const names = [...new Set(places.flatMap(text => [...text.matchAll(placeholderPattern)].map(([, name]) => name)))]
    if (names.length === 0) return request
    const bound = boundEntries(entries, target.host, target.port)
    for (const name of names) {
      const entry = entries.find(e => e.name === name)
      if (entry === undefined) throw new Refusal(`no secret ${name}; list shows the secrets.`)
      if (!bound.includes(entry)) throw new Refusal(`secret ${name} is for ${entry.hosts.join(", ")}, not ${target.host}.`)
    }
    const values = names.filter(name => bound.find(e => e.name === name)?.mode === "value")
    const signing = names.filter(name => !values.includes(name))
    const value = (name: string): string => this.options.secrets.value(name)
    let headers: Headers = Object.fromEntries(Object.entries(request.headers).map(([key, header]) => [key, header === undefined ? undefined : Array.isArray(header) ? header.map(text => replaceIn(text, values, value, raw)) : replaceIn(header, values, value, raw)]))
    if (basic !== undefined && values.some(name => basicText.includes(placeholder(name)))) headers = {...headers, authorization: `Basic ${Buffer.from(replaceIn(basicText, values, value, raw), "latin1").toString("base64")}`}
    const contentType = headerValue(request.headers, "content-type") ?? ""
    const body = textBody ? Buffer.from(replaceIn(bodyText, values, value, bodyEncoder(contentType)), "latin1") : request.body
    let outgoing: Outgoing = {target: replaceIn(request.target, values, value, encodeURIComponent), headers, body}
    if (signing.length === 0) return outgoing
    const gcpNames = signing.filter(name => bound.find(e => e.name === name)?.mode === "gcp")
    for (const name of gcpNames) {
      if (headerValue(request.headers, "authorization") !== `Bearer ${placeholder(name)}` || places.filter(text => text.includes(placeholder(name))).length !== 1) throw new Refusal(`secret ${name} is used only to sign requests.`)
      const key = serviceAccountKey(value(name))
      if (key === undefined) throw new Refusal(`secret ${name} is not a Google service-account key.`)
      const token = await this.gcp.token(key).catch(error => {
        throw new Refusal(`Google refused secret ${name}: ${error instanceof GcpError ? error.message : String(error)}`)
      })
      this.issued.set(name, token)
      outgoing = {...outgoing, headers: {...outgoing.headers, authorization: `Bearer ${token}`}}
    }
    if (signing.some(name => bound.find(e => e.name === name)?.mode === "aws")) outgoing = this.signedForAws(request, outgoing, method, places, bound)
    return outgoing
  }

  // spec: spec/architecture.md#proxy-forward
  private signedForAws(original: Outgoing, outgoing: Outgoing, method: string, places: string[], bound: SecretEntry[]): Outgoing {
    const named = (name: string): boolean => bound.some(entry => entry.name === name)
    if (!named(awsNames.keyId) || !named(awsNames.secretKey)) throw new Refusal(`secrets ${awsNames.keyId} and ${awsNames.secretKey} are needed to sign this request.`)
    const authorization = headerValue(original.headers, "authorization")
    const keyId = sigV4Credential(authorization)?.keyId
    const tokenHeader = headerValue(original.headers, "x-amz-security-token")
    const allowed = (text: string, name: string): boolean => (name === awsNames.keyId && text === authorization && keyId === placeholder(name)) || (name === awsNames.sessionToken && text === tokenHeader && tokenHeader === placeholder(name))
    for (const name of Object.values(awsNames)) {
      if (places.some(text => text.includes(placeholder(name)) && !allowed(text, name))) throw new Refusal(`secret ${name} is used only to sign requests.`)
    }
    if (keyId !== placeholder(awsNames.keyId)) throw new Refusal(`secret ${awsNames.keyId} is used only to sign requests.`)
    const sessionToken = named(awsNames.sessionToken) ? this.options.secrets.value(awsNames.sessionToken) : undefined
    const keys = {keyId: this.options.secrets.value(awsNames.keyId), secretKey: this.options.secrets.value(awsNames.secretKey), sessionToken}
    const client: AwsRequest = {method, target: original.target, headers: original.headers, body: original.body}
    const final: AwsRequest = {method, target: outgoing.target, headers: outgoing.headers, body: outgoing.body}
    const resigned = resign(client, final, placeholder(awsNames.secretKey), keys, placeholder(awsNames.sessionToken))
    if ("refused" in resigned) throw new Refusal(`this AWS request can't be signed with secret ${awsNames.secretKey}: ${resigned.refused}.`)
    return {...outgoing, headers: {...outgoing.headers, authorization: resigned.authorization, ...(resigned.sessionToken === undefined ? {} : {"x-amz-security-token": resigned.sessionToken})}}
  }

  // spec: spec/architecture.md#proxy-respond
  private respond(response: IncomingMessage, res: ServerResponse, target: Target, entries: SecretEntry[]): void {
    const forms = this.forms(boundEntries(entries, target.host, target.port))
    const headers = forwardedHeaders(response.headers)
    const scrub = (text: string): string => forms.reduce((result, [form, mark]) => result.replaceAll(form, mark), text)
    const scrubbed: OutgoingHttpHeaders = Object.fromEntries(Object.entries(headers).map(([name, header]) => [name, typeof header === "string" ? scrub(header) : Array.isArray(header) ? header.map(scrub) : header]))
    const encoding = (response.headers["content-encoding"] ?? "identity").toLowerCase()
    const decoder = encoding === "identity" ? undefined : decoders[encoding as keyof typeof decoders]
    const text = textType.test(response.headers["content-type"] ?? "")
    if (forms.length === 0 || !text || (encoding !== "identity" && decoder === undefined)) {
      res.writeHead(response.statusCode ?? 502, scrubbed)
      return void pipeline(response, res, () => undefined)
    }
    delete scrubbed["content-length"]
    delete scrubbed["content-encoding"]
    res.writeHead(response.statusCode ?? 502, scrubbed)
    const scrubber = new Scrubber(forms)
    if (decoder === undefined) pipeline(response, scrubber, res, () => undefined)
    else pipeline(response, decoder(), scrubber, res, () => undefined)
  }

  // spec: spec/architecture.md#proxy-respond
  private forms(bound: SecretEntry[]): [string, string][] {
    const marked = bound.flatMap(({name, mode}) => {
      const values = mode === "gcp" ? [this.issued.get(name)].filter((token): token is string => token !== undefined) : [this.options.secrets.value(name)]
      return values.flatMap(value => valueForms(value).map((form): [string, string] => [form, placeholder(name)]))
    })
    return marked.sort(([a], [b]) => b.length - a.length)
  }

  // spec: spec/architecture.md#proxy-context
  private context(host: string): SecureContext {
    const cached = this.contexts.get(host)
    if (cached !== undefined && Date.now() - cached.at < certRenewMs) return cached.context
    const cert = hostCertificate(host, this.options.ca, this.leafKey)
    const context = createSecureContext({key: this.leafKey.export({type: "pkcs8", format: "pem"}), cert: cert.toString()})
    this.contexts.set(host, {context, at: Date.now()})
    return context
  }

  // spec: spec/api.md#secrets-proxy
  private refuse(res: ServerResponse, host: string, reason: string): void {
    log(`SimpleX proxy: refused a request to ${host}: ${reason}`)
    plain(res, 403, `SimpleX proxy: ${reason}`)
  }

  // spec: spec/api.md#secrets-proxy
  private fail(res: ServerResponse, error: unknown, host: string): void {
    if (error instanceof Refusal) return this.refuse(res, host, error.message)
    log(`SimpleX proxy: a request to ${host} failed: ${error instanceof Error ? error.message : String(error)}`)
    plain(res, 502, `SimpleX proxy: the request to ${host} failed.`)
  }

  private track(socket: Socket): Socket {
    this.sockets.add(socket)
    socket.on("close", () => this.sockets.delete(socket))
    return socket
  }
}

// spec: spec/architecture.md#proxy-open
class TargetAgent extends HttpsAgent {
  constructor(private readonly open: (target: Target) => Promise<Socket>) {
    super({keepAlive: true})
  }

  createConnection(options: HttpsRequestOptions, oncreate?: (error: Error | null, socket: Duplex) => void): undefined {
    this.open({host: String(options.host), port: Number(options.port)}).then(
      socket => oncreate?.(null, super.createConnection({...options, socket} as HttpsRequestOptions) as Duplex),
      error => oncreate?.(error, undefined as unknown as Duplex),
    )
    return undefined
  }
}

// spec: spec/architecture.md#proxy-upstreamproxies
export function upstreamProxies(env: NodeJS.ProcessEnv, ownPort: number): Upstream {
  const https = upstreamProxy(env.https_proxy || env.HTTPS_PROXY, ownPort)
  const http = upstreamProxy(env.http_proxy || env.HTTP_PROXY, ownPort)
  const noProxy = (env.no_proxy || env.NO_PROXY || "").split(/[\s,]+/).filter(entry => entry !== "")
  return {...(https === undefined ? {} : {https}), ...(http === undefined ? {} : {http}), noProxy}
}

// spec: spec/architecture.md#proxy-upstreamproxies
function upstreamProxy(text: string | undefined, ownPort: number): UpstreamProxy | undefined {
  const given = text?.trim()
  if (!given) return undefined
  try {
    const url = new URL(given.includes("://") ? given : `http://${given}`)
    const tls = url.protocol === "https:"
    const host = bareHost(url.hostname)
    const port = Number(url.port || (tls ? 443 : 80))
    if ((!tls && url.protocol !== "http:") || (loopbackHosts.has(host) && port === ownPort)) return undefined
    const authorization = url.username === "" ? undefined : `Basic ${Buffer.from(`${decodeURIComponent(url.username)}:${decodeURIComponent(url.password)}`).toString("base64")}`
    return {host, port, tls, ...(authorization === undefined ? {} : {authorization})}
  } catch {
    return undefined
  }
}

// spec: spec/architecture.md#proxy-upstreamproxies
export function bypassed(noProxy: string[], host: string, port: number): boolean {
  return noProxy.some(entry => {
    if (entry === "*") return true
    const match = /^\[(.+)\](?::(\d+))?$/.exec(entry) ?? /^([^:]+):(\d+)$/.exec(entry)
    const name = (match?.[1] ?? entry).toLowerCase()
    if (match?.[2] !== undefined && Number(match[2]) !== port) return false
    if (name.includes("/")) return inSubnet(host, name)
    const domain = name.replace(/^\*?\./, "")
    return host === domain || host.endsWith(`.${domain}`)
  })
}

// spec: spec/architecture.md#proxy-upstreamproxies
function inSubnet(host: string, subnet: string): boolean {
  const [address, bits] = subnet.split("/")
  const family = isIP(address)
  if (family === 0 || family !== isIP(host)) return false
  const type = family === 6 ? "ipv6" : "ipv4"
  try {
    const list = new BlockList()
    list.addSubnet(address, Number(bits), type)
    return list.check(host, type)
  } catch {
    return false
  }
}

function proxyAuthorization({authorization}: UpstreamProxy): {"proxy-authorization"?: string} {
  return authorization === undefined ? {} : {"proxy-authorization": authorization}
}

function bareHost(hostname: string): string {
  return hostname.replace(/^\[(.*)\]$/, "$1")
}

function jsonOf(data: Buffer): unknown {
  try {
    return JSON.parse(data.toString("utf8"))
  } catch {
    return undefined
  }
}

// spec: spec/architecture.md#proxy-respond
export class Scrubber extends Transform {
  private carry = ""
  private readonly pattern: RegExp
  private readonly marks: Map<string, string>
  private readonly keep: number

  constructor(forms: [string, string][]) {
    super()
    const latin = forms.map(([form, mark]): [string, string] => [Buffer.from(form, "utf8").toString("latin1"), mark])
    this.marks = new Map(latin)
    this.pattern = new RegExp(latin.map(([form]) => form.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|"), "g")
    this.keep = Math.max(...latin.map(([form]) => form.length)) - 1
  }

  _transform(chunk: Buffer, _encoding: BufferEncoding, done: TransformCallback): void {
    const text = this.carry + chunk.toString("latin1")
    const limit = text.length - this.keep
    let out = ""
    let at = 0
    this.pattern.lastIndex = 0
    for (let match = this.pattern.exec(text); match !== null && match.index < limit; match = this.pattern.exec(text)) {
      out += text.slice(at, match.index) + this.marks.get(match[0])
      at = match.index + match[0].length
    }
    const safe = Math.max(at, limit)
    this.carry = text.slice(safe)
    done(null, Buffer.from(out + text.slice(at, safe), "latin1"))
  }

  _flush(done: TransformCallback): void {
    done(null, Buffer.from(this.carry.replace(this.pattern, form => this.marks.get(form)!), "latin1"))
  }
}

// spec: spec/architecture.md#proxy-startproxy
export function startProxy(port: number, options: ProxyOptions): Promise<{server: Server; proxy: SecretsProxy}> {
  const proxy = new SecretsProxy(options)
  const server = createServer((req, res) => (isProxyRequest(req) ? proxy.request(req, res) : plain(res, 400, "SimpleX proxy: proxy requests only.")))
  proxy.attach(server)
  return new Promise((resolve, reject) => {
    server.once("error", reject)
    server.listen(port, "127.0.0.1", () => {
      server.off("error", reject)
      resolve({server, proxy})
    })
  })
}

// spec: spec/architecture.md#proxy-startproxy
export function isProxyRequest(req: IncomingMessage): boolean {
  return /^https?:\/\//i.test(req.url ?? "")
}

// spec: spec/architecture.md#proxy-proxyca
export function proxyCa(dir: string): Issued {
  const keyFile = join(dir, "proxy-ca.key")
  const certFile = join(dir, "proxy-ca.pem")
  const ca = existsSync(keyFile) && existsSync(certFile) ? caFromPem(readFileSync(keyFile, "utf8"), readFileSync(certFile, "utf8")) : newCa(keyFile, certFile)
  writePrivateFile(join(dir, "proxy-ca-bundle.pem"), `${systemCertificates()}\n${ca.cert.toString()}`)
  return ca
}

// spec: spec/architecture.md#proxy-proxyca
function newCa(keyFile: string, certFile: string): Issued {
  const ca = createCa(caName)
  writePrivateFile(keyFile, ca.key.export({type: "pkcs8", format: "pem"}) as string)
  writePrivateFile(certFile, ca.cert.toString())
  return ca
}

// spec: spec/architecture.md#proxy-proxyca
function systemCertificates(): string {
  const file = systemBundles.find(path => existsSync(path))
  return file === undefined ? rootCertificates.join("\n") : readFileSync(file, "utf8")
}

// spec: spec/api.md#secrets-proxy
function replaceIn(text: string, names: string[], value: (name: string) => string, encode: (value: string) => string): string {
  return names.reduce((result, name) => result.replaceAll(placeholder(name), () => Buffer.from(encode(value(name)), "utf8").toString("latin1")), text)
}

function raw(value: string): string {
  return value
}

// spec: spec/api.md#secrets-proxy
function bodyEncoder(contentType: string): (value: string) => string {
  if (/json/i.test(contentType)) return value => JSON.stringify(value).slice(1, -1)
  if (/x-www-form-urlencoded/i.test(contentType)) return encodeURIComponent
  if (/xml/i.test(contentType)) return value => value.replace(/[&<>"']/g, c => `&#${c.charCodeAt(0)};`)
  return raw
}

function parseTarget(url: string | undefined): Target | undefined {
  const match = /^\[?([^\]]+?)\]?:(\d{1,5})$/.exec(url ?? "")
  return match === null ? undefined : {host: match[1].toLowerCase(), port: Number(match[2])}
}

// spec: spec/api.md#secrets-proxy
function sameHost(header: string | undefined, target: Target): boolean {
  if (header === undefined) return false
  const match = /^\[?([^\]]+?)\]?(?::(\d+))?$/.exec(header.trim())
  return match !== null && match[1].toLowerCase() === target.host && Number(match[2] ?? 443) === target.port
}

// spec: spec/api.md#secrets-proxy
function forwardedHeaders(headers: IncomingHttpHeaders | Headers): OutgoingHttpHeaders {
  return Object.fromEntries(Object.entries(headers).filter(([name, value]) => value !== undefined && !hopHeaders.has(name.toLowerCase()))) as OutgoingHttpHeaders
}

// spec: spec/api.md#secrets-proxy
async function readBody(req: IncomingMessage): Promise<Buffer> {
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of req) {
    size += (chunk as Buffer).length
    if (size > maxBody) throw new Refusal(`a request body over ${maxBody / 1_048_576} MiB without Content-Length is not sent.`)
    chunks.push(chunk as Buffer)
  }
  return Buffer.concat(chunks)
}

function plain(res: ServerResponse, status: number, text: string): void {
  if (res.headersSent) return void res.destroy()
  res.writeHead(status, {"content-type": "text/plain; charset=utf-8"})
  res.end(`${text}\n`)
}

