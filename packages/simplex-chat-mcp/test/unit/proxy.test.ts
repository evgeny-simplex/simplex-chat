import {generateKeyPairSync} from "crypto"
import {once} from "events"
import {mkdtempSync, rmSync} from "fs"
import {IncomingMessage, Server, createServer as createHttpServer, request as httpRequest} from "http"
import {createServer as createHttpsServer, request as httpsRequest} from "https"
import {AddressInfo, Socket, createServer as createTcpServer} from "net"
import {tmpdir} from "os"
import {join} from "path"
import {connect as tlsConnect, createSecureContext} from "tls"
import {gzipSync} from "zlib"
import {Issued, createCa, hostCertificate, newKey} from "../../src/certs"
import {SecretRecord, Secrets} from "../../src/files"
import {GcpTokens} from "../../src/gcp"
import {Scrubber, SecretsProxy, startProxy} from "../../src/proxy"
import {signature} from "../../src/sigv4"

const token = "ghp_RealToken+/=1234"
const record = (hosts: string[], mode: SecretRecord["mode"] = "value"): SecretRecord => ({hosts, mode, setBy: "Alice", setById: 3, setAt: "2026-11-13T10:00:00.000Z"})

interface Received {
  method: string
  url: string
  headers: IncomingMessage["headers"]
  body: string
}

interface Reply {
  status: number
  headers: IncomingMessage["headers"]
  body: string
}

let dir: string
let secrets: Secrets
let proxyCa: Issued
let upstreamCa: Issued
let upstream: Server
let proxyServer: Server
let proxy: SecretsProxy
let received: Received[]
let gcpPosts: number
let lines: string[]

beforeAll(async () => {
  proxyCa = createCa("proxy test CA")
  upstreamCa = createCa("upstream test CA")
  const key = newKey()
  upstream = createHttpsServer({SNICallback: (host, done) => done(null, createSecureContext({key: key.export({type: "pkcs8", format: "pem"}), cert: hostCertificate(host, upstreamCa, key).toString()}))}, (req, res) => {
    const chunks: Buffer[] = []
    req.on("data", chunk => chunks.push(chunk))
    req.on("end", () => {
      const body = Buffer.concat(chunks).toString("utf8")
      received.push({method: req.method ?? "", url: req.url ?? "", headers: req.headers, body})
      if (req.url === "/echo") {
        res.writeHead(200, {"content-type": "application/json", "x-echo": String(req.headers.authorization ?? "")})
        res.end(JSON.stringify({authorization: req.headers.authorization, body}))
      } else if (req.url === "/gzip") {
        res.writeHead(200, {"content-type": "text/plain", "content-encoding": "gzip"})
        res.end(gzipSync(`token ${token} end`))
      } else if (req.url === "/split") {
        res.writeHead(200, {"content-type": "text/plain"})
        res.write(`start ${token.slice(0, 7)}`)
        setTimeout(() => res.end(`${token.slice(7)} end`), 20)
      } else {
        res.writeHead(200, {"content-type": "text/plain"})
        res.end("ok")
      }
    })
  })
  upstream.listen(0, "127.0.0.1")
  await once(upstream, "listening")
})

beforeEach(async () => {
  received = []
  gcpPosts = 0
  lines = []
  jest.spyOn(process.stdout, "write").mockImplementation(text => (lines.push(String(text).trimEnd()), true))
  dir = mkdtempSync(join(tmpdir(), "simplex-mcp-proxy-"))
  secrets = new Secrets(dir)
  secrets.set("GITHUB_TOKEN", token, record(["api.test.example"]))
  secrets.set("OTHER_TOKEN", "other-token-value", record(["other.example"]))
  const upstreamPort = (upstream.address() as AddressInfo).port
  const gcp = new GcpTokens(async () => {
    gcpPosts++
    return {status: 200, body: {access_token: "ya29.minted-token", expires_in: 3600}}
  })
  const started = await startProxy(0, {secrets, ca: proxyCa, gcp, connectTo: () => ({host: "127.0.0.1", port: upstreamPort}), upstreamCa: upstreamCa.cert.toString()})
  proxyServer = started.server
  proxy = started.proxy
})

afterEach(async () => {
  proxy.close()
  proxyServer.closeAllConnections()
  await new Promise(resolve => proxyServer.close(resolve))
  rmSync(dir, {recursive: true, force: true})
  jest.restoreAllMocks()
})

afterAll(() => upstream.close())

function proxyPort(): number {
  return (proxyServer.address() as AddressInfo).port
}

async function through(host: string, path: string, options: {method?: string; headers?: {[name: string]: string}; body?: string} = {}): Promise<Reply> {
  const connect = httpRequest({host: "127.0.0.1", port: proxyPort(), method: "CONNECT", path: `${host}:443`})
  connect.end()
  const [response, socket] = (await once(connect, "connect")) as [IncomingMessage, Socket]
  if (response.statusCode !== 200) return {status: response.statusCode ?? 0, headers: response.headers, body: ""}
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      {host, servername: host, path, method: options.method ?? "GET", headers: {host, ...options.headers}, createConnection: () => tlsConnect({socket, servername: host, ca: proxyCa.cert.toString()})},
      res => {
        const chunks: Buffer[] = []
        res.on("data", chunk => chunks.push(chunk))
        res.on("end", () => resolve({status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(chunks).toString("utf8")}))
      },
    )
    req.on("error", reject)
    req.end(options.body)
  })
}

describe("secrets proxy, mode value", () => {
  it("puts the value into headers, Basic credentials, path, query, a JSON body and a form body, encoded for each place", async () => {
    const basic = Buffer.from("x-access-token:simplex-secret-GITHUB_TOKEN").toString("base64")
    expect((await through("api.test.example", "/repos/simplex-secret-GITHUB_TOKEN?key=simplex-secret-GITHUB_TOKEN", {headers: {authorization: `Basic ${basic}`, "x-api-key": "simplex-secret-GITHUB_TOKEN"}})).status).toBe(200)
    expect(received[0].url).toBe(`/repos/${encodeURIComponent(token)}?key=${encodeURIComponent(token)}`)
    expect(Buffer.from(String(received[0].headers.authorization).slice(6), "base64").toString()).toBe(`x-access-token:${token}`)
    expect(received[0].headers["x-api-key"]).toBe(token)
    await through("api.test.example", "/json", {method: "POST", headers: {"content-type": "application/json"}, body: JSON.stringify({token: "simplex-secret-GITHUB_TOKEN"})})
    expect(JSON.parse(received[1].body)).toEqual({token})
    await through("api.test.example", "/form", {method: "POST", headers: {"content-type": "application/x-www-form-urlencoded"}, body: "client_secret=simplex-secret-GITHUB_TOKEN&a=b"})
    expect(new URLSearchParams(received[2].body).get("client_secret")).toBe(token)
  })

  it("replaces the value with the placeholder in responses, also split across chunks and gzip-compressed", async () => {
    const echo = await through("api.test.example", "/echo", {headers: {authorization: "Bearer simplex-secret-GITHUB_TOKEN"}})
    expect(received[0].headers.authorization).toBe(`Bearer ${token}`)
    expect(JSON.parse(echo.body)).toEqual({authorization: "Bearer simplex-secret-GITHUB_TOKEN", body: ""})
    expect(echo.headers["x-echo"]).toBe("Bearer simplex-secret-GITHUB_TOKEN")
    expect((await through("api.test.example", "/split")).body).toBe("start simplex-secret-GITHUB_TOKEN end")
    const gzip = await through("api.test.example", "/gzip")
    expect([gzip.body, gzip.headers["content-encoding"]]).toEqual(["token simplex-secret-GITHUB_TOKEN end", undefined])
  })

  it("refuses a placeholder for another host, an unknown placeholder and a Host that differs, and sends nothing", async () => {
    expect(await through("api.test.example", "/x", {headers: {authorization: "Bearer simplex-secret-OTHER_TOKEN"}})).toMatchObject({status: 403, body: "SimpleX proxy: secret OTHER_TOKEN is for other.example, not api.test.example.\n"})
    expect(await through("api.test.example", "/x?k=simplex-secret-MISSING")).toMatchObject({status: 403, body: "SimpleX proxy: no secret MISSING; list shows the secrets.\n"})
    expect(await through("api.test.example", "/x", {headers: {host: "other.example"}})).toMatchObject({status: 403, body: "SimpleX proxy: the request's Host differs from api.test.example.\n"})
    expect(received).toEqual([])
    expect(lines).toEqual([
      "SimpleX proxy: refused a request to api.test.example: secret OTHER_TOKEN is for other.example, not api.test.example.",
      "SimpleX proxy: refused a request to api.test.example: no secret MISSING; list shows the secrets.",
      "SimpleX proxy: refused a request to api.test.example: the request's Host differs from api.test.example.",
    ])
  })

  it("forwards plain HTTP, refuses a placeholder in it, and refuses HTTPS without CONNECT", async () => {
    const plainServer = createHttpServer((req, res) => res.end(`plain ${req.url} ${req.headers.authorization}`))
    plainServer.listen(0, "127.0.0.1")
    await once(plainServer, "listening")
    const viaProxy = (target: string, headers: {[name: string]: string} = {}): Promise<Reply> =>
      new Promise(resolve => {
        const req = httpRequest({host: "127.0.0.1", port: proxyPort(), path: target, headers}, res => {
          const chunks: Buffer[] = []
          res.on("data", chunk => chunks.push(chunk))
          res.on("end", () => resolve({status: res.statusCode ?? 0, headers: res.headers, body: Buffer.concat(chunks).toString()}))
        })
        req.end()
      })
    const plainUrl = `http://127.0.0.1:${(plainServer.address() as AddressInfo).port}`
    expect(await viaProxy(`${plainUrl}/x`, {authorization: "Bearer public"})).toMatchObject({status: 200, body: "plain /x Bearer public"})
    expect(await viaProxy(`${plainUrl}/x`, {authorization: "Bearer simplex-secret-GITHUB_TOKEN"})).toMatchObject({status: 403, body: "SimpleX proxy: secrets are sent only over HTTPS.\n"})
    expect(await viaProxy("http://api.test.example/x?k=simplex-secret-GITHUB_TOKEN")).toMatchObject({status: 403, body: "SimpleX proxy: secrets are sent only over HTTPS.\n"})
    expect(await viaProxy("https://api.test.example/x")).toMatchObject({status: 400, body: "SimpleX proxy: HTTPS requests are sent with CONNECT.\n"})
    plainServer.close()
  })

  it("tunnels a host bound to no secret without reading it", async () => {
    const echo = createTcpServer(socket => socket.pipe(socket))
    echo.listen(0, "127.0.0.1")
    await once(echo, "listening")
    const connect = httpRequest({host: "127.0.0.1", port: proxyPort(), method: "CONNECT", path: `127.0.0.1:${(echo.address() as AddressInfo).port}`})
    connect.end()
    const [response, socket] = (await once(connect, "connect")) as [IncomingMessage, Socket]
    expect(response.statusCode).toBe(200)
    socket.write("simplex-secret-GITHUB_TOKEN bytes")
    const [data] = await once(socket, "data")
    expect(String(data)).toBe("simplex-secret-GITHUB_TOKEN bytes")
    socket.destroy()
    echo.close()
  })

  it("checks the bound host's real certificate", async () => {
    const other = createCa("unknown CA")
    const key = newKey()
    const served: string[] = []
    const fake = createHttpsServer({key: key.export({type: "pkcs8", format: "pem"}), cert: hostCertificate("api.test.example", other, key).toString()}, (req, res) => {
      served.push(String(req.headers.authorization))
      res.end()
    })
    fake.listen(0, "127.0.0.1")
    await once(fake, "listening")
    proxy.close()
    await new Promise(resolve => proxyServer.close(resolve))
    const started = await startProxy(0, {secrets, ca: proxyCa, connectTo: () => ({host: "127.0.0.1", port: (fake.address() as AddressInfo).port}), upstreamCa: upstreamCa.cert.toString()})
    proxyServer = started.server
    proxy = started.proxy
    expect(await through("api.test.example", "/x", {headers: {authorization: "Bearer simplex-secret-GITHUB_TOKEN"}})).toMatchObject({status: 502, body: "SimpleX proxy: api.test.example can't be reached.\n"})
    expect(served).toEqual([])
    fake.close()
  })
})

describe("secrets proxy, modes aws and gcp", () => {
  it("signs an AWS request again with the real key and session token", async () => {
    const hosts = ["s3.test.example"]
    secrets.set("AWS_ACCESS_KEY_ID", "AKIAREALKEYID123", record(hosts, "aws"))
    secrets.set("AWS_SECRET_ACCESS_KEY", "real/secret+access/key0000000000000000", record(hosts, "aws"))
    secrets.set("AWS_SESSION_TOKEN", "real-session-token-value", record(hosts, "aws"))
    const scope = {date: "20261113", region: "us-east-1", service: "s3", signedHeaders: ["host", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token"]}
    const headers = {host: "s3.test.example", "x-amz-content-sha256": "UNSIGNED-PAYLOAD", "x-amz-date": "20261113T101500Z", "x-amz-security-token": "simplex-secret-AWS_SESSION_TOKEN"}
    const client = {method: "GET", target: "/bucket/key", headers, body: Buffer.alloc(0)}
    const signed = signature(client, scope, headers["x-amz-date"], "simplex-secret-AWS_SECRET_ACCESS_KEY", false)
    const authorization = `AWS4-HMAC-SHA256 Credential=simplex-secret-AWS_ACCESS_KEY_ID/20261113/us-east-1/s3/aws4_request, SignedHeaders=${scope.signedHeaders.join(";")}, Signature=${signed}`
    expect((await through("s3.test.example", "/bucket/key", {headers: {...headers, authorization}})).status).toBe(200)
    const sent = received[0]
    expect(sent.headers["x-amz-security-token"]).toBe("real-session-token-value")
    const expected = signature({...client, headers: {...headers, "x-amz-security-token": "real-session-token-value"}}, scope, headers["x-amz-date"], "real/secret+access/key0000000000000000", false)
    expect(sent.headers.authorization).toBe(`AWS4-HMAC-SHA256 Credential=AKIAREALKEYID123/20261113/us-east-1/s3/aws4_request, SignedHeaders=${scope.signedHeaders.join(";")}, Signature=${expected}`)
    expect(await through("s3.test.example", "/bucket/key", {headers: {...headers, authorization, "x-amz-content-sha256": "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"}})).toMatchObject({status: 403, body: "SimpleX proxy: this AWS request can't be signed with secret AWS_SECRET_ACCESS_KEY: streaming upload.\n"})
    expect(await through("s3.test.example", "/bucket/key", {method: "PUT", headers: {"content-type": "text/plain"}, body: "simplex-secret-AWS_SECRET_ACCESS_KEY"})).toMatchObject({status: 403, body: "SimpleX proxy: secret AWS_SECRET_ACCESS_KEY is used only to sign requests.\n"})
  })

  it("puts in a Google access token for a service-account key, and refuses its placeholder elsewhere", async () => {
    const {privateKey} = generateKeyPairSync("rsa", {modulusLength: 2048})
    const key = JSON.stringify({type: "service_account", client_email: "agent@p.iam.gserviceaccount.com", private_key: privateKey.export({type: "pkcs8", format: "pem"}), token_uri: "https://oauth2.googleapis.com/token"})
    secrets.set("GCP_KEY", key, record(["storage.test.example"], "gcp"))
    const echo = await through("storage.test.example", "/echo", {headers: {authorization: "Bearer simplex-secret-GCP_KEY"}})
    expect(received[0].headers.authorization).toBe("Bearer ya29.minted-token")
    expect(JSON.parse(echo.body).authorization).toBe("Bearer simplex-secret-GCP_KEY")
    await through("storage.test.example", "/x", {headers: {authorization: "Bearer simplex-secret-GCP_KEY"}})
    expect(gcpPosts).toBe(1)
    expect(await through("storage.test.example", "/x?k=simplex-secret-GCP_KEY", {headers: {authorization: "Bearer simplex-secret-GCP_KEY"}})).toMatchObject({status: 403, body: "SimpleX proxy: secret GCP_KEY is used only to sign requests.\n"})
  })
})

describe("scrubber", () => {
  it("replaces forms split at every position of a stream", async () => {
    const text = `a ${token} b ${token}`
    for (let cut = 1; cut < text.length; cut++) {
      const scrubber = new Scrubber([[token, "simplex-secret-GITHUB_TOKEN"]])
      const out: Buffer[] = []
      scrubber.on("data", chunk => out.push(chunk))
      scrubber.write(Buffer.from(text.slice(0, cut)))
      scrubber.end(Buffer.from(text.slice(cut)))
      await once(scrubber, "end")
      expect(Buffer.concat(out).toString()).toBe("a simplex-secret-GITHUB_TOKEN b simplex-secret-GITHUB_TOKEN")
    }
  })
})
