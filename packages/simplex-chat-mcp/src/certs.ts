import {KeyObject, X509Certificate, createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign} from "crypto"
import {isIP} from "net"

const oid = {
  ecdsaWithSha256: "1.2.840.10045.4.3.2",
  commonName: "2.5.4.3",
  basicConstraints: "2.5.29.19",
  keyUsage: "2.5.29.15",
  subjectAltName: "2.5.29.17",
  extKeyUsage: "2.5.29.37",
  serverAuth: "1.3.6.1.5.5.7.3.1",
  subjectKeyIdentifier: "2.5.29.14",
  authorityKeyIdentifier: "2.5.29.35",
}
const day = 86_400_000
const caYears = 10
const hostDays = 7

export interface Issued {
  key: KeyObject
  cert: X509Certificate
}

// spec: spec/architecture.md#certs-createca
export function createCa(name: string, now = Date.now()): Issued {
  const {privateKey, publicKey} = generateKeyPairSync("ec", {namedCurve: "P-256"})
  const subject = distinguishedName(name)
  const keyId = keyIdentifier(publicKey)
  const extensions = [
    extension(oid.basicConstraints, sequence(boolean(true)), true),
    extension(oid.keyUsage, bitString(Buffer.from([0x06]), 1), true),
    extension(oid.subjectKeyIdentifier, octetString(keyId)),
  ]
  const notAfter = new Date(now)
  notAfter.setUTCFullYear(notAfter.getUTCFullYear() + caYears)
  return {key: privateKey, cert: issue({subject, issuer: subject, publicKey, signer: privateKey, from: now - day, until: notAfter.getTime(), extensions})}
}

// spec: spec/architecture.md#certs-createca
export function hostCertificate(host: string, ca: Issued, key: KeyObject, now = Date.now()): X509Certificate {
  const ip = isIP(host)
  const altName = ip === 0 ? context(2, Buffer.from(host, "ascii"), false) : context(7, ipBytes(host, ip), false)
  const extensions = [
    extension(oid.basicConstraints, sequence(), true),
    extension(oid.keyUsage, bitString(Buffer.from([0x80]), 7), true),
    extension(oid.extKeyUsage, sequence(objectId(oid.serverAuth))),
    extension(oid.subjectAltName, sequence(altName)),
    extension(oid.authorityKeyIdentifier, sequence(context(0, keyIdentifier(createPublicKey(ca.key)), false))),
  ]
  return issue({subject: distinguishedName(host), issuer: rawSubject(ca.cert), publicKey: createPublicKey(key), signer: ca.key, from: now - day, until: now + hostDays * day, extensions})
}

export function caFromPem(keyPem: string, certPem: string): Issued {
  return {key: createPrivateKey(keyPem), cert: new X509Certificate(certPem)}
}

export function newKey(): KeyObject {
  return generateKeyPairSync("ec", {namedCurve: "P-256"}).privateKey
}

interface Template {
  subject: Buffer
  issuer: Buffer
  publicKey: KeyObject
  signer: KeyObject
  from: number
  until: number
  extensions: Buffer[]
}

function issue({subject, issuer, publicKey, signer, from, until, extensions}: Template): X509Certificate {
  const algorithm = sequence(objectId(oid.ecdsaWithSha256))
  const serial = randomBytes(16)
  const tbs = sequence(
    context(0, integer(Buffer.from([2])), true),
    integer(serial),
    algorithm,
    issuer,
    sequence(time(from), time(until)),
    subject,
    publicKey.export({type: "spki", format: "der"}),
    context(3, sequence(...extensions), true),
  )
  const signature = sign("sha256", tbs, {key: signer, dsaEncoding: "der"})
  const der = sequence(tbs, algorithm, bitString(signature, 0))
  return new X509Certificate(der)
}

function rawSubject(cert: X509Certificate): Buffer {
  const tbs = children(children(cert.raw)[0])
  return tbs[5]
}

function children(der: Buffer): Buffer[] {
  const {start, end} = contents(der, 0)
  const items: Buffer[] = []
  for (let offset = start; offset < end; ) {
    const item = contents(der, offset)
    items.push(der.subarray(offset, item.end))
    offset = item.end
  }
  return items
}

function contents(der: Buffer, offset: number): {start: number; end: number} {
  const first = der[offset + 1]
  if (first < 0x80) return {start: offset + 2, end: offset + 2 + first}
  const bytes = first & 0x7f
  const length = der.subarray(offset + 2, offset + 2 + bytes).reduce((sum, byte) => sum * 256 + byte, 0)
  return {start: offset + 2 + bytes, end: offset + 2 + bytes + length}
}

function keyIdentifier(publicKey: KeyObject): Buffer {
  return createHash("sha1").update(publicKey.export({type: "spki", format: "der"})).digest()
}

function distinguishedName(commonName: string): Buffer {
  return sequence(set(sequence(objectId(oid.commonName), tlv(0x0c, Buffer.from(commonName, "utf8")))))
}

function extension(id: string, value: Buffer, critical = false): Buffer {
  return sequence(objectId(id), ...(critical ? [boolean(true)] : []), octetString(value))
}

function time(at: number): Buffer {
  const text = new Date(at).toISOString().replace(/[-:T]/g, "").slice(0, 14)
  return at < Date.UTC(2050, 0, 1) ? tlv(0x17, Buffer.from(`${text.slice(2)}Z`, "ascii")) : tlv(0x18, Buffer.from(`${text}Z`, "ascii"))
}

function ipBytes(host: string, version: number): Buffer {
  if (version === 4) return Buffer.from(host.split(".").map(Number))
  const [head, tail = ""] = host.split("::")
  const groups = (part: string): string[] => (part === "" ? [] : part.split(":"))
  const missing = 8 - groups(head).length - groups(tail).length
  const all = host.includes("::") ? [...groups(head), ...Array<string>(missing).fill("0"), ...groups(tail)] : groups(head)
  return Buffer.concat(all.map(group => Buffer.from([parseInt(group, 16) >> 8, parseInt(group, 16) & 0xff])))
}

function objectId(id: string): Buffer {
  const [first, second, ...rest] = id.split(".").map(Number)
  const body = [40 * first + second, ...rest].flatMap(n => {
    const bytes = [n & 0x7f]
    for (let left = Math.floor(n / 128); left > 0; left = Math.floor(left / 128)) bytes.unshift((left & 0x7f) | 0x80)
    return bytes
  })
  return tlv(0x06, Buffer.from(body))
}

function integer(bytes: Buffer): Buffer {
  const start = bytes.findIndex((byte, i) => byte !== 0 || i === bytes.length - 1)
  const minimal = bytes.subarray(start)
  return tlv(0x02, minimal[0] & 0x80 ? Buffer.concat([Buffer.from([0]), minimal]) : minimal)
}

function boolean(value: boolean): Buffer {
  return tlv(0x01, Buffer.from([value ? 0xff : 0]))
}

function bitString(bytes: Buffer, unused: number): Buffer {
  return tlv(0x03, Buffer.concat([Buffer.from([unused]), bytes]))
}

function octetString(bytes: Buffer): Buffer {
  return tlv(0x04, bytes)
}

function sequence(...items: Buffer[]): Buffer {
  return tlv(0x30, Buffer.concat(items))
}

function set(...items: Buffer[]): Buffer {
  return tlv(0x31, Buffer.concat(items))
}

function context(tag: number, body: Buffer, constructed: boolean): Buffer {
  return tlv((constructed ? 0xa0 : 0x80) | tag, body)
}

function tlv(tag: number, body: Buffer): Buffer {
  const length = body.length
  if (length < 0x80) return Buffer.concat([Buffer.from([tag, length]), body])
  const bytes: number[] = []
  for (let left = length; left > 0; left = Math.floor(left / 256)) bytes.unshift(left & 0xff)
  return Buffer.concat([Buffer.from([tag, 0x80 | bytes.length, ...bytes]), body])
}
