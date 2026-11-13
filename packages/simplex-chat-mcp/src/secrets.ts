import {join} from "path"
import {SecretEntry, SecretMode} from "./files"
import {serviceAccountKey} from "./gcp"

// spec: spec/architecture.md#secrets-awsnames
export const awsNames = {keyId: "AWS_ACCESS_KEY_ID", secretKey: "AWS_SECRET_ACCESS_KEY", sessionToken: "AWS_SESSION_TOKEN"}
// spec: spec/architecture.md#secrets-awsnames
export const placeholderPattern = /simplex-secret-([A-Z][A-Z0-9_]{0,63})/g
// spec: spec/architecture.md#secrets-awsnames
export const minValueLength = 8

// spec: spec/architecture.md#secrets-hostpattern
const hostPattern = /^(\*\.)?[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+(?::\d{1,5})?$/
// spec: spec/architecture.md#secrets-hostpattern
const reservedNames = new Set(["PATH", "HOME", "SHELL", "USER", "LOGNAME", "PWD", "TERM", "LANG", "TMPDIR", "NO_PROXY", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "SSL_CERT_FILE", "SSL_CERT_DIR", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE", "GIT_SSL_CAINFO", "AWS_CA_BUNDLE"])
// spec: spec/architecture.md#secrets-hostpattern
const reservedPrefixes = ["CLAUDE_", "SIMPLEX_", "LC_", "NODE_", "CLOUDSDK_"]
const encodings: BufferEncoding[] = ["base64", "base64url"]

export interface ProxyFiles {
  url: string
  caCert: string
  caBundle: string
}

// spec: spec/architecture.md#secrets-placeholder
export function placeholder(name: string): string {
  return `simplex-secret-${name}`
}

// spec: spec/architecture.md#secrets-placeholder
export function proxyFiles(dir: string, port: number): ProxyFiles {
  return {url: `http://127.0.0.1:${port}`, caCert: join(dir, "proxy-ca.pem"), caBundle: join(dir, "proxy-ca-bundle.pem")}
}

// spec: spec/architecture.md#secrets-reservedname
export function reservedName(name: string): boolean {
  return reservedNames.has(name) || reservedPrefixes.some(prefix => name.startsWith(prefix))
}

// spec: spec/architecture.md#secrets-reservedname
export function secretMode(name: string, value: string): SecretMode {
  if (Object.values(awsNames).includes(name)) return "aws"
  return serviceAccountKey(value) === undefined ? "value" : "gcp"
}

// spec: spec/architecture.md#secrets-reservedname
export function parseHosts(text: string): string[] | undefined {
  const hosts = text.toLowerCase().split(",")
  return hosts.every(host => hostPattern.test(host) && validPort(host)) ? [...new Set(hosts)] : undefined
}

// spec: spec/architecture.md#secrets-boundto
export function boundTo(hosts: string[], host: string, port: number): boolean {
  const name = host.toLowerCase().replace(/\.$/, "")
  return hosts.some(pattern => {
    const [patternHost, patternPort = "443"] = pattern.split(":")
    if (Number(patternPort) !== port) return false
    return patternHost.startsWith("*.") ? name.endsWith(patternHost.slice(1)) && name.length > patternHost.length - 1 : name === patternHost
  })
}

// spec: spec/architecture.md#secrets-boundto
export function boundEntries(entries: SecretEntry[], host: string, port: number): SecretEntry[] {
  return entries.filter(entry => boundTo(entry.hosts, host, port))
}

// spec: spec/architecture.md#secrets-proxyvariables
export function proxyVariables({url, caCert, caBundle}: ProxyFiles, names: string[]): {[name: string]: string} {
  return {
    HTTPS_PROXY: url,
    HTTP_PROXY: url,
    https_proxy: url,
    http_proxy: url,
    NO_PROXY: "localhost,127.0.0.1,::1",
    no_proxy: "localhost,127.0.0.1,::1",
    NODE_USE_ENV_PROXY: "1",
    SSL_CERT_FILE: caBundle,
    CURL_CA_BUNDLE: caBundle,
    REQUESTS_CA_BUNDLE: caBundle,
    GIT_SSL_CAINFO: caBundle,
    AWS_CA_BUNDLE: caBundle,
    CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE: caBundle,
    NODE_EXTRA_CA_CERTS: caCert,
    ...Object.fromEntries(names.map(name => [name, placeholder(name)])),
  }
}

// spec: spec/architecture.md#secrets-proxyvariables
export function shellExports(variables: {[name: string]: string}): string {
  return Object.entries(variables)
    .map(([name, value]) => `export ${name}='${value.replace(/'/g, `'\\''`)}'\n`)
    .join("")
}

// spec: spec/architecture.md#secrets-valueforms
export function valueForms(value: string): string[] {
  const bytes = Buffer.from(value)
  const base64 = [0, 1, 2].flatMap(leading => {
    const padded = Buffer.concat([Buffer.alloc(leading), bytes])
    return encodings.map(encoding => padded.toString(encoding).slice(Math.ceil((leading * 4) / 3), Math.floor((padded.length * 4) / 3)))
  })
  return [...new Set([value, encodeURIComponent(value), ...base64])].filter(form => form.length >= minValueLength)
}

function validPort(host: string): boolean {
  const port = host.split(":")[1]
  return port === undefined || (Number(port) >= 1 && Number(port) <= 65535)
}
