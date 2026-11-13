import {generateKeyPairSync, verify} from "crypto"
import {GcpError, GcpTokens, PostForm, assertion, serviceAccountKey} from "../../src/gcp"

const {privateKey, publicKey} = generateKeyPairSync("rsa", {modulusLength: 2048})
const key = {client_email: "agent@project.iam.gserviceaccount.com", private_key: privateKey.export({type: "pkcs8", format: "pem"}) as string, token_uri: "https://oauth2.googleapis.com/token", private_key_id: "kid-1"}
const keyJson = JSON.stringify({type: "service_account", project_id: "project", ...key})

function decodePart(part: string): {[name: string]: unknown} {
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8"))
}

describe("Google service-account tokens", () => {
  it("reads a service-account key and nothing else", () => {
    expect(serviceAccountKey(keyJson)).toMatchObject(key)
    expect(serviceAccountKey(JSON.stringify({type: "authorized_user"}))).toBeUndefined()
    expect(serviceAccountKey("ghp_token_value")).toBeUndefined()
  })

  it("signs a JWT that verifies with the key's public key, with the claims Google requires", () => {
    const jwt = assertion(key, Date.UTC(2026, 10, 13, 10, 0, 0))
    const [header, claims, signature] = jwt.split(".")
    expect(decodePart(header)).toEqual({alg: "RS256", typ: "JWT", kid: "kid-1"})
    expect(decodePart(claims)).toEqual({iss: key.client_email, scope: "https://www.googleapis.com/auth/cloud-platform", aud: key.token_uri, iat: 1_794_564_000, exp: 1_794_567_600})
    expect(verify("RSA-SHA256", Buffer.from(`${header}.${claims}`), publicKey, Buffer.from(signature, "base64url"))).toBe(true)
  })

  it("requests a token once while it is valid, again 5 minutes before it ends, and reports Google's refusal", async () => {
    let now = 1_000_000
    const posts: {url: string; form: {[name: string]: string}}[] = []
    let reply = {status: 200, body: {access_token: "ya29.first", expires_in: 3600} as unknown}
    const postForm: PostForm = async (url, form) => {
      posts.push({url, form})
      return reply
    }
    const tokens = new GcpTokens(postForm, () => now)
    expect(await Promise.all([tokens.token(key), tokens.token(key)])).toEqual(["ya29.first", "ya29.first"])
    expect(posts).toHaveLength(1)
    expect(posts[0].url).toBe(key.token_uri)
    expect(posts[0].form.grant_type).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer")
    now += 54 * 60_000
    expect(await tokens.token(key)).toBe("ya29.first")
    now += 2 * 60_000
    reply = {status: 200, body: {access_token: "ya29.second", expires_in: 3600}}
    expect(await tokens.token(key)).toBe("ya29.second")
    expect(posts).toHaveLength(2)
    now += 3600_000
    reply = {status: 400, body: {error: "invalid_grant", error_description: "Invalid JWT Signature."}}
    await expect(tokens.token(key)).rejects.toEqual(new GcpError("Invalid JWT Signature."))
    reply = {status: 200, body: {access_token: "ya29.third", expires_in: 3600}}
    expect(await tokens.token(key)).toBe("ya29.third")
  })
})
