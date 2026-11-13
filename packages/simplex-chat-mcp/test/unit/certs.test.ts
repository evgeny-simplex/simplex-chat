import {createPublicKey} from "crypto"
import {once} from "events"
import {isIP} from "net"
import {connect, createServer} from "tls"
import {createCa, hostCertificate, newKey} from "../../src/certs"

describe("certificates", () => {
  it("makes a CA and host certificates that X509Certificate verifies, with the host in subjectAltName", () => {
    const ca = createCa("SimpleX MCP test CA")
    expect(ca.cert.ca).toBe(true)
    expect(ca.cert.verify(createPublicKey(ca.key))).toBe(true)
    const key = newKey()
    for (const host of ["api.github.com", "127.0.0.1", "::1"]) {
      const cert = hostCertificate(host, ca, key)
      expect(cert.ca).toBe(false)
      expect(cert.checkIssued(ca.cert)).toBe(true)
      expect(cert.verify(ca.cert.publicKey)).toBe(true)
      expect(isIP(host) === 0 ? cert.checkHost(host) : cert.checkIP(host)).toBe(host)
      expect(cert.subjectAltName).toBe({"api.github.com": "DNS:api.github.com", "127.0.0.1": "IP Address:127.0.0.1", "::1": "IP Address:0:0:0:0:0:0:0:1"}[host])
      expect(new Date(cert.validTo).getTime() - Date.now()).toBeLessThanOrEqual(7 * 86_400_000)
    }
  })

  it("encodes every random serial number as DER", () => {
    const ca = createCa("SimpleX MCP test CA")
    const key = newKey()
    const serials = new Set(Array.from({length: 2000}, () => hostCertificate("api.github.com", ca, key).serialNumber))
    expect(serials.size).toBe(2000)
  })

  it("serves TLS that a client trusting only the CA accepts for the host", async () => {
    const ca = createCa("SimpleX MCP test CA")
    const key = newKey()
    const server = createServer({key: key.export({type: "pkcs8", format: "pem"}), cert: hostCertificate("api.github.com", ca, key).toString()}, socket => socket.end("ok"))
    server.listen(0, "127.0.0.1")
    await once(server, "listening")
    const {port} = server.address() as {port: number}
    const socket = connect({port, host: "127.0.0.1", servername: "api.github.com", ca: ca.cert.toString()})
    const [data] = await once(socket, "data")
    expect(String(data)).toBe("ok")
    expect(socket.authorized).toBe(true)
    socket.destroy()
    server.close()
  })
})
