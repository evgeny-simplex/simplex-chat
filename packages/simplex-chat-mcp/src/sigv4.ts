import {createHash, createHmac} from "crypto"

const algorithm = "AWS4-HMAC-SHA256"
const authorizationPattern = /^AWS4-HMAC-SHA256 Credential=([^/,\s]+)\/(\d{8})\/([^/,\s]+)\/([^/,\s]+)\/aws4_request,\s*SignedHeaders=([a-z0-9;_.-]+),\s*Signature=([0-9a-f]{64})$/

export type Headers = {[name: string]: string | string[] | undefined}

export interface AwsRequest {
  method: string
  target: string
  headers: Headers
  body: Buffer
}

export interface AwsKeys {
  keyId: string
  secretKey: string
  sessionToken?: string
}

export interface Credential {
  keyId: string
  date: string
  region: string
  service: string
  signedHeaders: string[]
  signature: string
}

export type Resigned = {authorization: string; sessionToken?: string} | {refused: string}

export function sigV4Credential(authorization: string | undefined): Credential | undefined {
  const match = authorization === undefined ? null : authorizationPattern.exec(authorization.trim())
  if (match === null) return undefined
  const [, keyId, date, region, service, signed, signature] = match
  return {keyId, date, region, service, signedHeaders: signed.split(";"), signature}
}

export function refusedForm(request: AwsRequest): string | undefined {
  const query = new URL(request.target, "http://host").searchParams
  if (query.has("X-Amz-Signature") || query.has("X-Amz-Credential")) return "presigned URL"
  const authorization = headerValue(request.headers, "authorization") ?? ""
  if (authorization.startsWith("AWS4-ECDSA-P256-SHA256")) return "SigV4A"
  if ((headerValue(request.headers, "x-amz-content-sha256") ?? "").startsWith("STREAMING-")) return "streaming upload"
  return undefined
}

export function resign(client: AwsRequest, final: AwsRequest, clientSecret: string, keys: AwsKeys, clientSessionToken?: string): Resigned {
  const form = refusedForm(client)
  if (form !== undefined) return {refused: form}
  const credential = sigV4Credential(headerValue(client.headers, "authorization"))
  const amzDate = headerValue(client.headers, "x-amz-date")
  if (credential === undefined || amzDate === undefined) return {refused: "unrecognized signature"}
  const doubleEncodings = [credential.service !== "s3", credential.service === "s3"]
  const encoding = doubleEncodings.find(double => signature(client, credential, amzDate, clientSecret, double) === credential.signature)
  if (encoding === undefined) return {refused: "unrecognized signature"}
  const tokenHeader = headerValue(final.headers, "x-amz-security-token")
  const sessionToken = tokenHeader !== undefined && clientSessionToken !== undefined && tokenHeader === clientSessionToken ? keys.sessionToken : undefined
  const headers = sessionToken === undefined ? final.headers : {...withoutHeader(final.headers, "x-amz-security-token"), "x-amz-security-token": sessionToken}
  const resigned = signature({...final, headers}, credential, amzDate, keys.secretKey, encoding)
  const scope = [credential.date, credential.region, credential.service, "aws4_request"].join("/")
  return {authorization: `${algorithm} Credential=${keys.keyId}/${scope}, SignedHeaders=${credential.signedHeaders.join(";")}, Signature=${resigned}`, ...(sessionToken === undefined ? {} : {sessionToken})}
}

export function signature(request: AwsRequest, credential: Omit<Credential, "keyId" | "signature">, amzDate: string, secretKey: string, doubleEncode: boolean): string {
  const scope = [credential.date, credential.region, credential.service, "aws4_request"].join("/")
  const stringToSign = [algorithm, amzDate, scope, sha256(canonicalRequest(request, credential.signedHeaders, doubleEncode))].join("\n")
  const key = [credential.date, credential.region, credential.service, "aws4_request"].reduce<Buffer>((signing, part) => hmac(signing, part), Buffer.from(`AWS4${secretKey}`, "utf8"))
  return hmac(key, stringToSign).toString("hex")
}

export function canonicalRequest({method, target, headers, body}: AwsRequest, signedHeaders: string[], doubleEncode: boolean): string {
  const [path, query = ""] = splitTarget(target)
  const canonicalHeaders = signedHeaders.map(name => `${name}:${headerValues(headers, name).map(value => value.trim().replace(/\s+/g, " ")).join(",")}\n`).join("")
  const payloadHash = headerValue(headers, "x-amz-content-sha256") ?? sha256(body)
  return [method.toUpperCase(), canonicalUri(path, doubleEncode), canonicalQuery(query), canonicalHeaders, signedHeaders.join(";"), payloadHash].join("\n")
}

function canonicalUri(path: string, doubleEncode: boolean): string {
  if (path === "") return "/"
  return doubleEncode ? path.split("/").map(uriEncode).join("/") : path
}

function canonicalQuery(query: string): string {
  if (query === "") return ""
  return query
    .split("&")
    .filter(pair => pair !== "")
    .map(pair => {
      const i = pair.indexOf("=")
      const [name, value] = i < 0 ? [pair, ""] : [pair.slice(0, i), pair.slice(i + 1)]
      return [uriEncode(decoded(name)), uriEncode(decoded(value))]
    })
    .sort(([a, x], [b, y]) => (a < b ? -1 : a > b ? 1 : x < y ? -1 : x > y ? 1 : 0))
    .map(([name, value]) => `${name}=${value}`)
    .join("&")
}

function splitTarget(target: string): [string, string] {
  const i = target.indexOf("?")
  return i < 0 ? [target, ""] : [target.slice(0, i), target.slice(i + 1)]
}

function decoded(text: string): string {
  try {
    return decodeURIComponent(text)
  } catch {
    return text
  }
}

function uriEncode(text: string): string {
  return encodeURIComponent(text).replace(/[!'()*]/g, c => `%${c.charCodeAt(0).toString(16).toUpperCase()}`)
}

function headerValues(headers: Headers, name: string): string[] {
  const entry = Object.entries(headers).find(([key]) => key.toLowerCase() === name)?.[1]
  return entry === undefined ? [] : Array.isArray(entry) ? entry : [entry]
}

export function headerValue(headers: Headers, name: string): string | undefined {
  return headerValues(headers, name)[0]
}

function withoutHeader(headers: Headers, name: string): Headers {
  return Object.fromEntries(Object.entries(headers).filter(([key]) => key.toLowerCase() !== name))
}

function sha256(data: string | Buffer): string {
  return createHash("sha256").update(data).digest("hex")
}

function hmac(key: Buffer, data: string): Buffer {
  return createHmac("sha256", key).update(data, "utf8").digest()
}
