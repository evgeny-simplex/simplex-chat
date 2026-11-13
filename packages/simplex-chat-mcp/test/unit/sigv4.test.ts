import {AwsRequest, resign, signature, sigV4Credential} from "../../src/sigv4"

const secretKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
const amzDate = "20150830T123600Z"

describe("SigV4", () => {
  it("gets the signatures of AWS's published examples", () => {
    const iam: AwsRequest = {
      method: "GET",
      target: "/?Action=ListUsers&Version=2010-05-08",
      headers: {"content-type": "application/x-www-form-urlencoded; charset=utf-8", host: "iam.amazonaws.com", "x-amz-date": amzDate},
      body: Buffer.alloc(0),
    }
    expect(signature(iam, {date: "20150830", region: "us-east-1", service: "iam", signedHeaders: ["content-type", "host", "x-amz-date"]}, amzDate, secretKey, true)).toBe("5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    const vanilla: AwsRequest = {method: "GET", target: "/", headers: {host: "example.amazonaws.com", "x-amz-date": amzDate}, body: Buffer.alloc(0)}
    expect(signature(vanilla, {date: "20150830", region: "us-east-1", service: "service", signedHeaders: ["host", "x-amz-date"]}, amzDate, secretKey, true)).toBe("5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
  })

  it("signs a request again with the real key, also with a session token, after checking the client's signature", () => {
    const scope = {date: "20261113", region: "eu-west-1", service: "s3", signedHeaders: ["host", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token"]}
    const date = "20261113T101500Z"
    const client: AwsRequest = {
      method: "GET",
      target: "/my%20bucket/key?list-type=2&prefix=a%2Fb",
      headers: {host: "s3.eu-west-1.amazonaws.com", "x-amz-content-sha256": "UNSIGNED-PAYLOAD", "x-amz-date": date, "x-amz-security-token": "simplex-secret-AWS_SESSION_TOKEN"},
      body: Buffer.alloc(0),
    }
    const clientSignature = signature(client, scope, date, "simplex-secret-AWS_SECRET_ACCESS_KEY", false)
    client.headers.authorization = `AWS4-HMAC-SHA256 Credential=simplex-secret-AWS_ACCESS_KEY_ID/20261113/eu-west-1/s3/aws4_request, SignedHeaders=${scope.signedHeaders.join(";")}, Signature=${clientSignature}`
    const keys = {keyId: "AKIAREAL", secretKey, sessionToken: "real-session-token"}
    const resigned = resign(client, client, "simplex-secret-AWS_SECRET_ACCESS_KEY", keys, "simplex-secret-AWS_SESSION_TOKEN")
    const expected = signature({...client, headers: {...client.headers, "x-amz-security-token": "real-session-token"}}, scope, date, secretKey, false)
    expect(resigned).toEqual({authorization: `AWS4-HMAC-SHA256 Credential=AKIAREAL/20261113/eu-west-1/s3/aws4_request, SignedHeaders=${scope.signedHeaders.join(";")}, Signature=${expected}`, sessionToken: "real-session-token"})
    expect(sigV4Credential((resigned as {authorization: string}).authorization)).toMatchObject({keyId: "AKIAREAL", region: "eu-west-1", service: "s3"})
  })

  it("refuses streaming uploads, presigned URLs, SigV4A and a signature it can't reproduce", () => {
    const base: AwsRequest = {method: "PUT", target: "/bucket/key", headers: {host: "s3.amazonaws.com", "x-amz-date": amzDate, authorization: "AWS4-HMAC-SHA256 Credential=K/20150830/us-east-1/s3/aws4_request, SignedHeaders=host;x-amz-date, Signature=" + "0".repeat(64)}, body: Buffer.from("data")}
    const keys = {keyId: "AKIAREAL", secretKey}
    const refused = (request: AwsRequest): unknown => resign(request, request, "client", keys)
    expect(refused({...base, headers: {...base.headers, "x-amz-content-sha256": "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"}})).toEqual({refused: "streaming upload"})
    expect(refused({...base, target: "/bucket/key?X-Amz-Signature=abc&X-Amz-Credential=K"})).toEqual({refused: "presigned URL"})
    expect(refused({...base, headers: {...base.headers, authorization: "AWS4-ECDSA-P256-SHA256 Credential=K/20150830/s3/aws4_request"}})).toEqual({refused: "SigV4A"})
    expect(refused(base)).toEqual({refused: "unrecognized signature"})
  })
})
