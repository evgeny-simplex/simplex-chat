# SimpleX MCP: secrets bound to hosts, put into requests by the plugin's proxy

Status: rewritten on 2026-11-13 to the user's design, which replaces the redaction of the model's requests in the earlier version of this plan. Answered by the user on 2026-11-13: Q2 A, Q3 A, Q4 A, Q5 A, with opencode support as part of this work, and Q6 A on the plans page, the plugin's own proxy. Q1 is open. Implemented on `ep/mcp-secrets` without the docs that depend on Q1; section 12 lists where the implementation differs from this plan.

It completes #8151 (https://github.com/simplex-chat/simplex-chat/pull/8151, "mcp server: give the agent secrets without exposing them to the model"), whose head is `cc45d339b`. Code references: #8151 at `cc45d339b` and master `8fda06295`, by file and function. Claude Code references: the 2.1.322 binary at the byte offsets given, and the official docs, quoted. Runs R1 to R3 used Claude Code 2.1.323 with `claude -p`, a scratch `HOME` and `CLAUDE_CONFIG_DIR`, a fake token, a local server that answers model requests with canned tool calls, a test plugin loaded with `--plugin-dir`, and a local proxy that terminates TLS for `api.anthropic.com` with a test CA:

- R1: the test plugin's SessionStart hook wrote `HTTPS_PROXY`, `https_proxy`, `NO_PROXY`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS` to `CLAUDE_ENV_FILE`. The model asked for a Bash command that printed these variables and ran `curl https://api.anthropic.com/probe-from-bash-main`.
- R2: as R1, from a Bash command of a subagent.
- R3: Node.js 22.23.3 `fetch` and `https.get` through the same proxy, with and without `NODE_USE_ENV_PROXY=1`.
- R4: `npm install -g --prefix DIR opencode-ai@1.19.5` into a scratch folder, then `opencode models` and `opencode run --model opencode/deepseek-v4.1-flash-free "Reply with the single word OK."` with a scratch `HOME`.

## 1. Goal

The user's words, 2026-11-13:

> maybe complete secrets from Alain with proxy? I am assuming plugin would run proxy, right?

> I honestly do not understand why command needs to print anything at all. Keys are always passed either in URIs or in headers of HTTP requests, right? and it some rarer cases in JSON bodies, correct? Because if command prints the secret there is nothing to stop the model from printing it. My thinking was that secret is per service, and each secret is tied to a particular remote host, and cannot be used with any other host, and cannot be printed to - the substitution happens inside HTTP proxy.

The design works for Claude Code without a user setting. The plugin's SessionStart hook gives Claude's Bash commands the proxy and the plugin's certificate authority through `CLAUDE_ENV_FILE`, which Claude Code gives to plugin hooks (R1, R2, fact 1).

The secrets are values for web services, such as a GitHub token or AWS IAM keys. Each one is bound to one host or a list of hosts.

- Claude writes a placeholder in its commands, `simplex-secret-GITHUB_TOKEN`, or the variable `$GITHUB_TOKEN` that holds it.
- The plugin's proxy uses the secret in an HTTPS request to a bound host, by the secret's mode:
  - `value`: the proxy replaces the placeholder with the value, in a header, the URL or the body. This serves bearer tokens, API keys in URLs, keys in JSON bodies and Basic auth.
  - `aws`: AWS requests carry no secret key, only the access key ID and a signature that the client computes with the key. The client signs with the placeholder, and the proxy computes the signature again with the real key.
  - `gcp`: a Google service-account key signs a JWT, which Google exchanges for an access token. The proxy does both and puts the access token where the client sent the placeholder as a bearer token.
- A request to any other host gets no value.
- The value never exists in the shell, in a file Claude is told about, in command output or in a model request. The model's requests need no change.

```mermaid
flowchart LR
  CL[Claude] -->|command with the placeholder| SH[Bash commands]
  SH -->|HTTPS through the proxy| PX[proxy in the SimpleX service]
  PX -->|value put in, bound host only| WS[web service such as api.github.com]
  WS -->|response, value replaced by the placeholder| PX
  PX --> SH
  SH -->|output without the value| CC[Claude Code]
  CC -->|model request, unchanged| AN[Anthropic API]
```

Outcome:
- Admins and owners of a session's group set a secret with its hosts there (Q2 A).
- In every session on the computer, Claude's HTTPS commands pass the proxy, which puts in the values for bound hosts.
- The plugin is for a computer or a container that one person uses (Q4 A).

## 2. What users see

Commands in a session's group, for its admins and owners:

```
command                        reply, a new message without a quote
/secret NAME HOSTS VALUE       Secret NAME is set for HOSTS, in all sessions on this computer. /'unsecret NAME'
/unsecret NAME                 Secret NAME is removed.
/secrets                       NAME  HOSTS  set by Alice  2026-11-13 10:05 UTC, one line per secret, or No secrets.
```

- HOSTS: one or more host names separated by commas, without spaces, such as `api.github.com,github.com`. `*.amazonaws.com` stands for every subdomain of `amazonaws.com`. A host may have a port, such as `git.example.com:8443`.
- VALUE: the rest of the line, as in #8151, without control characters.
- The mode follows from the secret:
  - `aws`: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` with the same hosts form one AWS pair, as in Claude Code's sandbox (fact 6). The reply adds ` It signs AWS requests with AWS_ACCESS_KEY_ID.` once both keys are set.
  - `gcp`: a VALUE that is the JSON of a Google service-account key, `"type": "service_account"`, on one line. The reply adds ` Claude uses $NAME as a Google access token.`
  - `value`: every other secret.
- NAME: as in #8151. Names that Claude's commands need for themselves are refused: `PATH`, `HOME`, `SHELL`, `USER`, `PWD`, `TERM`, `LANG`, `TMPDIR`, the proxy and certificate variables of decision 21, and names starting with `CLAUDE_`, `SIMPLEX_`, `LC_` or `NODE_`. The reply: `NAME is reserved; choose another name.`
- A message without hosts gets the usage text: `Usage: /secret NAME HOSTS VALUE on one line. NAME: capital letters, digits and _, starting with a letter, up to 64 characters. HOSTS: host names separated by commas, such as api.github.com,github.com. VALUE: 8 characters or more.`

Every message that starts with `/secret`, in any letter case and form, is moderated at once, for every sender, before anything else is done with it. The apps show it as `moderated by Claude`. Such a message is never a prompt to Claude.

```
message starting with /secret                  reply, a new message
in a session group, from an admin or owner     the replies above, or the usage text
in a session group, from another member        Only admins and owners of this group can send / commands.
in the Main group                              Send /secret in the group of a session; the secret is set for all sessions on this computer.
```

What Claude sees:
- `list` returns `"secrets": [{"name": "GITHUB_TOKEN", "hosts": ["api.github.com", "github.com"], "mode": "value", "placeholder": "simplex-secret-GITHUB_TOKEN"}]`, without values.
- Each Bash command has the variable `GITHUB_TOKEN=simplex-secret-GITHUB_TOKEN`. Tools that read a standard variable, such as `gh` with `GH_TOKEN` or the AWS CLI with `AWS_SECRET_ACCESS_KEY`, send the placeholder, and the proxy puts the value in.
- The `list` description: `secrets has the name, hosts, mode and placeholder of each secret your owners set. Use the placeholder, or the variable named as the secret, in an HTTPS request to one of its hosts: the SimpleX proxy puts the value in. Mode value: in a header, the URL or the body. Mode aws: the AWS CLI and SDKs read the variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, and the proxy signs. Mode gcp: send the placeholder as a bearer token, and the proxy puts in a Google access token. The value is never shown to you, and a request to another host gets no value.`

Examples:

```
service        secret and hosts                                       Claude's command                                       mode
GitHub API     GITHUB_TOKEN api.github.com,github.com                 curl -H "Authorization: Bearer $GITHUB_TOKEN"         value
                                                                      https://api.github.com/user
git            GITHUB_TOKEN, as above                                 git clone https://x-access-token:                      value, inside
                                                                      simplex-secret-GITHUB_TOKEN@github.com/org/repo.git    Basic auth
OpenAI         OPENAI_API_KEY api.openai.com                          curl -H "Authorization: Bearer $OPENAI_API_KEY" ...   value
Stripe         STRIPE_KEY api.stripe.com                              curl -u "$STRIPE_KEY:" https://api.stripe.com/v1/...  value, inside
                                                                                                                             Basic auth
a key in a     MAPS_KEY maps.googleapis.com                           curl "https://maps.googleapis.com/...?key=$MAPS_KEY"  value, URL-
URL                                                                                                                          encoded
AWS            AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY            aws s3 ls                                              aws
               *.amazonaws.com
Google Cloud   GCP_KEY *.googleapis.com, the service-account JSON     gcloud storage ls --access-token-file=<(echo $GCP_KEY) gcp
```

Answers of the proxy to Claude's commands, as HTTP responses with status 403 and a one-line body:

```
case                                                         body
a placeholder in a request to a host not bound to it          SimpleX proxy: secret NAME is for HOSTS, not HOST.
a placeholder of a secret that doesn't exist                   SimpleX proxy: no secret NAME; list shows the secrets.
a placeholder over plain HTTP                                 SimpleX proxy: secrets are sent only over HTTPS.
an AWS request the proxy can't sign again                     SimpleX proxy: this AWS request can't be signed with secret NAME: FORM.
an aws or gcp secret's placeholder outside the place of its   SimpleX proxy: secret NAME is used only to sign requests.
  mode, such as in a body
Google refused the service-account key                        SimpleX proxy: Google refused secret NAME: ERROR.
```

FORM is `streaming upload`, `presigned URL` or `SigV4A`.

A command that doesn't use the proxy, such as one that ignores proxy variables, sends the placeholder as text: the service gets no value, and the request fails. While the SimpleX service is stopped, HTTPS commands fail with a connection error to `127.0.0.1:5225`; the session's MCP server starts the service again within 30 seconds (`session.ts` `ServiceLink.reconnect`).

```mermaid
sequenceDiagram
  participant O as admin's app
  participant S as SimpleX service
  participant CC as Claude Code
  participant B as Bash command
  participant G as api.github.com
  O->>S: /secret GITHUB_TOKEN api.github.com,github.com VALUE
  S->>O: the message moderated
  S->>O: Secret GITHUB_TOKEN is set for api.github.com, github.com, in all sessions on this computer.
  CC->>B: curl -H Authorization Bearer GITHUB_TOKEN variable
  B->>S: CONNECT api.github.com 443
  S->>B: TLS with a certificate of the plugin's CA
  B->>S: GET /user with the placeholder
  S->>G: GET /user with the value
  G-->>S: response
  S-->>B: response, the value replaced by the placeholder
  B-->>CC: output without the value
```

Before and after:

```
moment                          #8151                                        this item
/secret in a session group      Secrets are off: the server runs without      moderated, then set for its hosts
                                --secrets-folder.
the agent uses a secret         "$(cat FOLDER/NAME)": the value in the        the placeholder: the value only in the
                                command's process and its output              request to a bound host
model requests                  values redacted by an opencode plugin         unchanged: they hold no values
```

## 3. Questions for the user

Answered on 2026-11-13: Q2 A, Q3 A, Q4 A, Q5 A and Q6 A. The user's note on Q5: "we need to install opencode and make it work with it with some model - you will guide me. Opencode has lots of users, it's good to add support as part of this work." Q1 is open.

Q1. What the plugin promises about Claude reading a value. Claude's commands run as the person's own OS user, as the SimpleX service does.
- A, recommended: the plugin variant now. Values stay in the service's private folder. Claude is never told the folder, a command sees only placeholders, and a command that avoids the proxy gets no value. A command that searches the person's files can still read the folder, as any program of that user can. The docs name two stronger setups: Claude Code's own sandbox, whose settings can deny reading the folder and send traffic to a proxy of the person's choice, still to be checked with this proxy; and a container without network that reaches the proxy only through a Unix socket, as in steward (facts 7 and 8).
- B: secrets only for Claude Code in such a sandbox or container. The plugin refuses `/secret` until the setup is in place. Every person who uses secrets sets it up first.

Q3. Which uses of a secret the first version covers (section 5, "Modes").
- A, chosen: the modes `value`, `aws` and `gcp`. `value` puts values into headers, `Authorization: Basic`, the URL and the body, as in the user's words. A command can also put a `value` secret into data that the bound host stores or shows, such as an issue comment.
- B: `value` and `aws` now, `gcp` later. Google Cloud keys don't work until then; about 90 source lines less now.
- C: `value` in headers and the URL only, with `aws`. Bodies keep the placeholder, so services that take keys in a body don't work.

Q5. #8151's way for `serve` and opencode, where the agent reads the value by path and opencode redacts model requests.
- A, chosen: replaced everywhere by the proxy. `serve` runs the same proxy, and the opencode plugin gives opencode's shell commands the proxy variables (decision 35). One way for every host.
- B: kept for `serve` and opencode; the proxy is for the plugin only. Two ways, with values in the agent's shell under `serve`.

## 4. Decisions

Facts:

1. A plugin's SessionStart hook gets `CLAUDE_ENV_FILE`, and Claude Code applies the variables written there to every Bash command of the session, a subagent's included. R1: the hook's `CLAUDE_ENV_FILE` was `~/.claude/session-env/SESSION/sessionstart-hook-0.sh`, and the Bash command printed every variable the hook wrote. R2: the same for a subagent's command. Claude Code 2.1.322 sets `CLAUDE_ENV_FILE` for SessionStart, Setup, CwdChanged and FileChanged hooks (296981265), as `EVENT-hook-N.sh` (`$Mi`, 292665531), and reads these files before Bash commands (`Hps`, 292666442). The hooks docs in the binary: "write bash exports there to apply env to subsequent BashTool commands" (313216108). Claude Code refuses Claude's own writes to that folder (289572572).
2. The variables are for Bash commands: the docs of fact 1 name them so, and Claude Code's own process, with its model requests and WebFetch, keeps its environment.
3. A command's HTTPS request passes such a proxy and trusts its CA from these variables. R1 and R2: `curl` sent `CONNECT api.anthropic.com:443` to the proxy, accepted the proxy's certificate for that host, and the proxy saw `GET /probe-from-bash-main` and `GET /probe-from-bash-sub`.
4. Node.js 22.23.3 `fetch` and `https.get` use `HTTPS_PROXY` only with `NODE_USE_ENV_PROXY=1`. R3: with it, both requests passed the proxy; without it, `fetch` went straight to the host.
5. Node.js has no API that creates certificates: `crypto` offers `generateKeyPairSync`, `sign` and `X509Certificate`, which reads and checks a certificate (`checkIssued`, `checkHost`, `verify`), and `tls.rootCertificates` holds 119 root certificates (Node.js 22.23.3).
6. How services take credentials:
   - AWS (IAM, "AWS Signature Version 4 for API requests"): "You don't use your secret access key to sign API requests. Instead, you use the SigV4 signing process", which derives "a key that is scoped to a single AWS service, in a single AWS region, on a particular day" and adds "this signature to the request as an Authorization header". The secret key never travels, so a substituted placeholder can't serve AWS. Claude Code's sandbox signs such requests again at its proxy, and refuses by default the forms it can't sign again: streaming uploads, presigned URLs and SigV4A (`sigv4` policies, 283850014).
   - Google service accounts (Google Identity, "Using OAuth 2.0 for Server to Server Applications"): a JWT with `iss`, `scope`, `aud` `https://oauth2.googleapis.com/token`, `exp` and `iat`, signed `RS256` with the account's private key, is posted to `https://oauth2.googleapis.com/token` with `grant_type` `urn:ietf:params:oauth:grant-type:jwt-bearer`; the access token lasts `expires_in`, 3600 s in the example, and is sent as `Authorization: Bearer`. `gcloud --access-token-file` reads "a file path to read the access token" (gcloud reference).
   - GitHub (REST API, "Authenticating to the REST API"): "you can use `Authorization: Bearer` or `Authorization: token` to pass a token". `git` over HTTPS sends a token as the password of Basic auth.
   - Stripe (API reference, "Authentication"): "Provide your API key as the basic auth username value. You don't need to provide a password", or `Authorization: Bearer`.
   - OpenAI (its OpenAPI document, `components.securitySchemes.ApiKeyAuth`): `type: http`, `scheme: bearer`.
7. Claude Code 2.1.322 has the same idea inside its sandbox, set in the person's settings: `sandbox.credentials.envVars` and `files` with `mode: "mask"` show sandboxed commands a sentinel, and "the host proxy swaps sentinel→real on egress to `injectHosts`" (283841991, 283837753, 283841003). AWS pairs are signed again (`awsPairs`, 283848979). TLS termination is marked `[EXPERIMENTAL]` (`network.tlsTerminate`, 283832764). These three are "Only honored from user, managed/policy, or CLI (`--settings`) settings". File masking "degrades to `deny`" on macOS and Windows (283848011). The sandbox can send its traffic to "your own HTTP proxy" (`network.httpProxyPort`, 283832396) and deny reading paths (`filesystem.denyRead`).
8. In steward, agent containers run with `--network none`; their way out is a model gateway and an egress proxy, each on a Unix socket per session (`/code/steward/10a-agents-via-steward.patch`, "Agent containers run without network").
9. The plugin's data folder has mode 0700 (`files.ts` `createDataFolder`), which stops other users but not programs of the same user. `send` refuses its files (`tools.ts` `isRefused`).
10. #8151 adds `/secret`, `/unsecret` and `/secrets`, moderation and full deletion (`control.ts` `onMessage`, `ownerCommand`, `setSecret`), the store (`files.ts` `Secrets`), `list` with the folder and names (`tools.ts` `listChats`), and the opencode plugin (`opencode/simplex-secrets.ts`). In the plugin, a session's `Control` and `AgentTools` get no `Secrets` (`hub.ts` `Session` constructor).
11. A SessionStart hook's output may name `watchPaths`, and a FileChanged hook then runs when such a file changes (285552299), with `CLAUDE_ENV_FILE` (fact 1).
12. #8151 is a draft by brenzi-agent, its merge state `dirty` against master (GitHub API, 2026-11-13). `serve` uses port 5226, and REFERENCE.md uses 5227 for a second `serve` agent.

Choices:

13. The proxy runs in the SimpleX service on `127.0.0.1`, port `SIMPLEX_MCP_PROXY_PORT` or 5225 (fact 12). It is an HTTP/1.1 forward proxy. It starts before the hub opens.
14. A `CONNECT` to a host that no secret names is a tunnel: the proxy copies bytes both ways and reads nothing. A `CONNECT` to a bound host is terminated with a certificate of the plugin's CA; the proxy reads the requests inside and sends them to the host over its own TLS connection, which checks the host's real certificate. A request inside it whose `Host` differs from the `CONNECT` host is refused.
15. The CA: an ECDSA P-256 key and a certificate valid for 10 years, made at the service's first start. `ROOT/proxy-ca.key`, mode 0600, never named to Claude. `ROOT/proxy-ca.pem` and `ROOT/proxy-ca-bundle.pem`, which holds the system's root certificates and the CA. The system's file is the first of `/etc/ssl/certs/ca-certificates.crt`, `/etc/pki/tls/certs/ca-bundle.crt` and `/etc/ssl/cert.pem` that exists, else `tls.rootCertificates`. Only Claude's Bash commands trust the CA, through their variables; the system's trust store is unchanged.
16. Host certificates are made on demand, one per host, valid for 7 days, with the host in `subjectAltName`, from one ECDSA P-256 key of the service, and kept in memory. The proxy offers only `http/1.1` by ALPN. `src/certs.ts` writes the DER of the certificates with Node.js `crypto` and checks them with `X509Certificate` in tests, so the package gets no new dependency (fact 5).
17. Q3 A, mode `value`. In a request to a bound host over HTTPS, the proxy replaces `simplex-secret-NAME` with the value of NAME when NAME is bound to that host, encoded for its place:
    - in every header value, as it is;
    - inside `Authorization: Basic`, which it decodes, fills in and encodes again;
    - in the path and the query, percent-encoded;
    - in a body of up to 8 MiB without `Content-Encoding`: JSON escaped inside a JSON string, form-encoded in form data, as it is in other text and XML escaped in XML; `Content-Length` is set again.

    Other bodies pass unchanged, so a placeholder there stays text.
18. A request to a bound host that carries a placeholder of another secret, of an unknown secret, or any placeholder over plain HTTP gets the 403 answers of section 2. A request through a tunnel is not read (decision 14), so a placeholder there reaches its host as text, without a value.
19. Mode `aws`: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` with the same hosts form one pair, as in Claude Code's sandbox (fact 6). The client signs with the placeholders, which the hook exports under these standard names, so the AWS CLI and SDKs need no change.
    - The proxy acts on a request to a host of the pair whose `Authorization: AWS4-HMAC-SHA256` credential is the key ID's placeholder. It keeps the date, region and service of the client's credential scope, and the list of signed headers.
    - It sets the real key ID, replaces the session token's placeholder in `X-Amz-Security-Token`, and computes the signature again over the request as it arrives. The payload hash is `X-Amz-Content-Sha256` when present, `UNSIGNED-PAYLOAD` included, else the SHA-256 of the body, read up to 8 MiB.
    - Streaming uploads (`STREAMING-*` payload hashes), presigned URLs and SigV4A get the 403 of section 2, as Claude Code's sandbox refuses them by default: "per-chunk signatures chain off the seed signature, so re-signing would require rewriting the body" (283850014). TESTING records which AWS CLI uploads use streaming and fail.
    - A request without the placeholder, such as `--no-sign-request`, passes unchanged.
20. Responses from a bound host: in headers and in text bodies, the proxy replaces each value, its URL encoding and its base64 and base64url forms with the placeholder, by #8151's `replacements`. A compressed text body is decompressed and sent without `Content-Encoding`. The body streams through a window of the longest form's length, so a value split across chunks is replaced.
21. The SessionStart hook writes these variables to `CLAUDE_ENV_FILE`, in every mode:
    - `HTTPS_PROXY`, `HTTP_PROXY`, `https_proxy`, `http_proxy`: `http://127.0.0.1:5225`;
    - `NO_PROXY`, `no_proxy`: `localhost,127.0.0.1,::1`;
    - `NODE_USE_ENV_PROXY=1` (fact 4);
    - `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO`, `AWS_CA_BUNDLE`: `ROOT/proxy-ca-bundle.pem`;
    - `NODE_EXTRA_CA_CERTS`: `ROOT/proxy-ca.pem`;
    - `CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE`: `ROOT/proxy-ca-bundle.pem`, for `gcloud`, checked in TESTING;
    - each secret's name, with its placeholder as the value.

    It returns `watchPaths` with `ROOT/secrets.json`. A FileChanged hook writes the secrets' variables again when that file changes, so a secret set during a session gets its variable (fact 11).
22. Values are stored in `ROOT/secrets/NAME`, mode 0600, and the index `ROOT/secrets.json` holds `{hosts, setBy, setById, setAt}` per name, by #8151's `Secrets` with hosts added. `list` and the proxy never return a value. Q5 A removes #8151's separate folder and `--secrets-folder`.
23. The proxy reads the index and the values at each request to a bound host. A secret removed during a session stops at once.
24. Q2 A. A session's `Control` gets `Secrets`; the commands work in session groups for admins and owners, one set per computer. `Session.onMessage` passes every message that starts with `/secret` to `Control.onMessage` before it checks the sender or parses a command; `Control` moderates it, then answers a member who is not an admin or owner with `Only admins and owners of this group can send / commands.` No such message is a prompt.
25. `MainGroup.onMessage` moderates every message that starts with `/secret` and posts the reply of section 2. The Main group gets full deletion at its creation and at `MainGroup.load`, as #8151 does for session groups.
26. The service keeps running while a Claude Code process whose hook wrote the variables runs: the hook sends `POST /title` with `proxy: true` and the PID, and `scheduleStop` waits while that PID runs.
27. When port 5225 is taken, the service logs `Port 5225 is in use; secrets are not put into requests.` and runs without the proxy. Commands then fail to connect to the proxy, and no value is sent.
28. The proxy logs refusals with their reason, the secret's name and the host. It logs no value, header or body.
29. Q4 A. The docs state that the plugin and its proxy are meant for a computer or a container that one person uses.
30. Q1 A. The docs name the limit of the plugin variant and the two stronger setups of fact 7 and fact 8.
31. Mode `gcp`, for a value that is a service-account key (fact 6). On a request to a bound host whose `Authorization` is `Bearer simplex-secret-NAME`, the proxy puts in an access token of its own:
    - It signs a JWT with `RS256`, `iss` the key's `client_email`, `scope` `https://www.googleapis.com/auth/cloud-platform`, `aud` the key's `token_uri`, and `exp` one hour after `iat`.
    - It posts the JWT to `token_uri` with `grant_type` `urn:ietf:params:oauth:grant-type:jwt-bearer`, and keeps the access token in memory until 5 minutes before `expires_in` ends.
    - A refusal from Google gets the 403 of section 2, with Google's `error_description`.
    - The access token never reaches Claude: responses of bound hosts get it replaced by the placeholder, as values are (decision 20).
    - Clients that sign with a key file themselves, such as client libraries with `GOOGLE_APPLICATION_CREDENTIALS`, get no key and fail.
32. The secrets of modes `aws` and `gcp` are used only to sign or authenticate: their placeholders are replaced only in `Authorization` and `X-Amz-Security-Token`. A placeholder of such a secret anywhere else gets the 403 of section 2, so the secret key can't be written into a request body.
33. Later modes, not in this item, each its own decision of the user:
    - OAuth token exchanges, such as client credentials posted to a token endpoint: the client secret works in mode `value`, but the access token in the response reaches the command, as the proxy doesn't know it. A mode would replace the returned tokens with placeholders it keeps.
    - Keys that sign a JWT for another service, such as a GitHub App's private key, by the pattern of `gcp`.
    - HMAC signatures of other services, such as Azure Shared Key and OAuth 1.0a, by the pattern of `aws`.
    - TLS client certificates, which the proxy could present to a bound host.
34. Delivery: our own pull request, stacked on #8151, branch `ep/mcp-secrets` of the evgeny-simplex fork, started at #8151's head `cc45d339b`. After #8151 merges, `git rebase --onto master cc45d339b` leaves only our commits. Alain is told of the user's design before he changes #8151 further; his commands, moderation and store remain.
35. Q5 A, `serve`: the agent's HTTP server on `127.0.0.1:PORT` (5226 by default) also serves as the proxy: `CONNECT` and requests in absolute form are proxy requests, and `/mcp` keeps its token. The store and the CA are in the agent's data folder. `--secrets-folder` and #8151's separate folder are removed.
36. Q5 A, opencode: opencode 1.19.5 calls the plugin hook `shell.env` with `{cwd, sessionID, callID}` before each shell command and adds the returned variables to the command's environment (`ShellTool.shellEnv`, `{...process.env, ...k.env}`, offset 125356956 of the `opencode-linux-x64-baseline` binary; the same for `!` commands and terminals, 125536886, 125789515). `opencode/simplex-secrets.ts` becomes a `shell.env` hook that returns the variables of decision 21 for the agent's port, read from `DATA/proxy-env.json`, which `serve` writes. Its redaction of model requests is removed.
37. `register NAME --host opencode` runs `opencode mcp add simplex-NAME --url http://127.0.0.1:PORT/mcp --header Authorization=...` (R4: `opencode mcp add` takes `--url` and `--header`) and writes the plugin to `~/.config/opencode/plugins/simplex-NAME.ts`, with the agent's data folder in it. `register` without `--host` adds the agent to Claude Code as now.

## 5. Design

How Claude's commands reach the proxy:

```
option                                   set by          cost
E. CLAUDE_ENV_FILE from the plugin's     the plugin      variables only in Bash commands; a command can unset them
   SessionStart hook (chosen)                            and then gets no value
S. HTTPS_PROXY in the settings env       the person      every program Claude Code starts, and Claude Code's own
                                                         traffic, pass the proxy
N. Claude Code's sandbox credentials     the person,     one entry per secret in the person's settings; file
                                         per secret      masking on Linux only; TLS termination experimental
C. a container with network none         the person      container setup; the strongest
```

Where the proxy runs:

```
option                                   cost
V. in the service (chosen)               one process; the secrets store and the commands are at hand
X. its own process                       its own spawn, lock and version check, and a channel to the service
```

Which requests the proxy reads:

```
option                                   cost
B. only those to bound hosts (chosen)    other hosts keep their own certificates; a placeholder sent there is text
A. every request                         every HTTPS connection of Claude's commands is decrypted by the service;
                                         HTTP/2-only and certificate-pinning clients break for every host
```

Modes, one per secret (Q3):

```
mode    services and schemes                        what the proxy does                       cost
value   bearer tokens: GitHub, OpenAI, Slack;       replaces the placeholder with the value,  the base: about 120 source lines
        API keys in URLs; keys in JSON or form      encoded for its place (decision 17)       of proxy.ts
        bodies; Basic auth: git, Stripe
aws     AWS SigV4: every AWS service with IAM       computes the signature again with the     sigv4.ts, about 110 lines, tested
        keys or temporary credentials               real key over the client's request        with AWS's published examples;
                                                    (decision 19)                             streaming uploads, presigned
                                                                                              URLs and SigV4A refused
gcp     Google service accounts: every Google       signs a JWT, gets an access token from    gcp.ts, about 90 lines; one HTTPS
        Cloud API                                   Google, caches it for its hour, puts it   request to Google an hour; clients
                                                    in Authorization (decision 31)            that sign with a key file fail
```

Plain substitution can't serve `aws` or `gcp`: there the client needs the secret itself to compute a signature, so the proxy has to sign in its place (fact 6).

Changes, on top of #8151:

```
file                function                  change
src/proxy.ts        new                       startProxy(port, store, ca): CONNECT tunnels, terminated TLS for bound
                                              hosts, placeholders, refusals, response replacement
src/certs.ts        new                       the CA and host certificates in DER (decisions 15 and 16)
src/sigv4.ts        new                       mode aws: the canonical request and signature of SigV4
src/gcp.ts          new                       mode gcp: the JWT, the token request and its cache
src/redaction.ts    new                       #8151's replacements and redacted, for responses
src/files.ts        Secrets                   + hosts; values in ROOT/secrets/; the index with hosts
                    proxyFiles                new: paths of the CA, the key and the bundle
src/control.ts      ownerRequest, setSecret   /secret NAME HOSTS VALUE; reserved names; the replies of section 2
                    secretsText               hosts in each line
                    isSecretMessage           new: #8151's test of onMessage, exported
                    ownerCommand              a session member's /secret: commandsApproversOnly, moved from hub.ts
src/hub.ts          Session constructor       Control options secrets; agent secrets
                    Session.onMessage         /secret messages to Control first (decision 24)
src/main-group.ts   MainGroup.onMessage       /secret moderated and answered
                    createMainGroup, load     fullDelete
src/tools.ts        listOutput, listChats     secrets as name, hosts and placeholder
                    listDescription           the text of section 2
src/service.ts      Service.start             the proxy before the hub; port in use logged
                    onTitle, scheduleStop     PIDs with proxy true keep the service running
src/hook.ts         sessionStart              the variables of decision 21; watchPaths; POST /title with proxy
                    secretsChanged            new: the FileChanged hook
src/protocol.ts     TitleRequest              + proxy?: boolean
hooks/hooks.json    FileChanged               new entry: hook secrets-changed
src/cli.ts          main                      hook secrets-changed
src/serve.ts        startAgent                the proxy on the agent's HTTP server; DATA/proxy-env.json (decision 35)
src/http.ts         startHttp                 CONNECT and absolute-form requests to the proxy
src/register.ts     register                  --host opencode (decision 37)
opencode/           simplex-secrets.ts        the shell.env hook in place of the redaction (decision 36)
```

The proxy, per connection:

```
CONNECT HOST:PORT:
  no secret bound to HOST:   tunnel, nothing read
  else:                      TLS with the host certificate of HOST, then for each request inside:
    Host differs from HOST:  403
    placeholders = simplex-secret-NAME in headers, Basic credentials, path, query, text body
    a NAME unknown, or not bound to HOST:  403
    value: replace placeholders with values, encoded for their places
    aws: sign again with the real key, or 403 for the forms it can't
    gcp: Authorization: Bearer with the cached or a new access token
    an aws or gcp placeholder elsewhere: 403
    send to HOST over TLS, checking HOST's certificate
    stream the response back, values replaced by placeholders
plain HTTP request:
  a placeholder in it:       403
  else:                      forwarded
```

```mermaid
stateDiagram-v2
  [*] --> Connect
  Connect --> Tunnel: host bound to no secret
  Connect --> Terminated: host bound to a secret
  Tunnel --> [*]
  Terminated --> Refused: Host differs, placeholder unknown or bound elsewhere
  Terminated --> Injected: value replaced, AWS signed again, or Google token put in
  Injected --> Refused: AWS form that can't be signed, or Google refused the key
  Injected --> Streamed: host answers
  Streamed --> Terminated: next request on the connection
  Streamed --> [*]
  Refused --> [*]
```

Components:

```mermaid
flowchart LR
  AD[admin or owner] -->|/secret NAME HOSTS VALUE| CT[Control]
  CT --> ST[(ROOT/secrets and secrets.json)]
  HK[SessionStart and FileChanged hooks] -->|variables| EF[CLAUDE_ENV_FILE]
  EF --> BC[Bash commands]
  BC -->|CONNECT| PX[proxy]
  ST --> PX
  CA[(proxy CA)] --> PX
  PX -->|bound hosts, values put in| WS[web services]
  PX -->|other hosts, tunnel| OT[other hosts]
  ST --> LS[list: names, hosts, placeholders]
```

What the plugin variant keeps from Claude, and what it does not:

```
kept from Claude
  values in commands, variables, output and model requests: only placeholders
  values in responses of bound hosts: replaced by placeholders
  a value for a host the secret is not bound to
not kept from Claude
  the files of the data folder, which every program of the person's user can read (Q1)
  a value that a request puts into data the bound host stores or shows (Q3)
  a value printed by a command that reads the data folder
  a token that a bound host returns, such as from an OAuth token endpoint (decision 33)
```

## 6. Compatibility

- Tools that read `HTTPS_PROXY` and one of the certificate variables work: `curl` (R1), Node.js with `NODE_USE_ENV_PROXY` (R3). `git`, Python `requests`, `gh`, the AWS CLI and `gcloud` with `--access-token-file` are checked in TESTING.
- AWS uploads that the CLI or an SDK sends as streaming, presigned URLs and multi-region SigV4A fail (decision 19).
- Google client libraries that read a key file from `GOOGLE_APPLICATION_CREDENTIALS` fail; tools that take an access token work (decision 31).
- Tools that ignore the proxy variables, Claude Code's WebFetch and MCP servers send the placeholder as text: no value, and the request fails.
- HTTP/2-only clients fail for bound hosts, as the proxy offers only `http/1.1`; other hosts are tunnelled unchanged.
- Claude Code's sandbox sets its own proxy for sandboxed commands; this plan does not cover the sandbox, and TESTING records what happens with it on.
- A computer with its own HTTPS proxy: the service's connections to bound hosts use the proxy variables that `spawnService` passes, with `NODE_USE_ENV_PROXY`.
- Older plugin data folders: the CA and `secrets.json` appear at the first start of this version.
- An older service: the hook of this version stops it (`client.ts` `ensureService`).
- Older SimpleX apps: moderation and full deletion as in #8151.
- `serve` and opencode: the same proxy (decisions 35 to 37). An agent started with `--secrets-folder` exits with the usage error of an unknown option.

## 7. Acceptance and tests

Done when:

```
#  criterion                                                                                  checked by
1  host certificates verify against the CA, with the host in subjectAltName                   unit: certs
2  a tunnel copies bytes unchanged for a host bound to no secret                              unit: proxy
3  mode value: placeholders are replaced in headers, Basic credentials, path, query and text  unit: proxy
   bodies, encoded for each place, for bound hosts only
4  refusals: Host differs, unknown placeholder, another host's placeholder, plain HTTP, an    unit: proxy
   aws or gcp placeholder outside Authorization
5  responses carry placeholders in place of values and Google tokens, also split across      unit: proxy
   chunks and compressed
6  mode aws: signatures equal those of AWS's published examples; the session token is put    unit: sigv4
   in; streaming, presigned and SigV4A refused
11 mode gcp: the JWT verifies with the key's public key; the token is requested once an       unit: gcp
   hour and put in Authorization; Google's refusal reaches the command
7  the SessionStart hook writes the variables of decision 21 and returns watchPaths;          unit: hook
   FileChanged writes the secrets' variables again
8  every /secret message is moderated, in session groups and the Main group; hosts and        unit: sessions
   reserved names; list returns names, hosts and placeholders
9  curl through the service to a local HTTPS server bound to a secret sends the value, and    e2e
   its output shows the placeholder
10 a real session: gh, git, the AWS CLI and gcloud work with secrets; Claude's answers and    TESTING
   the transcript hold no value; R1 repeated with the plugin
```

Tests:
- `test/unit/certs.test.ts`, new: "makes a CA and host certificates that X509Certificate verifies, with the host in subjectAltName".
- `test/unit/proxy.test.ts`, new, with local HTTPS servers and the test CA: "tunnels a host bound to no secret without reading it", "puts the value into headers, Basic credentials, path, query, a JSON body and a form body of a request to a bound host, encoded for each place", "refuses a placeholder for another host, an unknown placeholder, a Host that differs from CONNECT, a placeholder over plain HTTP and an aws or gcp placeholder outside Authorization", "replaces values in responses, also split across chunks and gzip-compressed", "checks the bound host's real certificate".
- `test/unit/sigv4.test.ts`, new: "signs AWS's published example requests again with the real key and gets their signatures", "puts the session token in and signs it", "refuses streaming uploads, presigned URLs and SigV4A", "passes a request without the placeholder unchanged".
- `test/unit/gcp.test.ts`, new, with a local token endpoint: "signs a JWT that verifies with the key's public key, with the claims of decision 31", "requests a token once while it is valid, and again before it ends", "answers 403 with Google's error_description".
- `test/unit/hook.test.ts`: "writes the proxy, certificate and secret variables to CLAUDE_ENV_FILE, and returns watchPaths". It fails on #8151's head, whose hook writes no variables.
- `test/unit/sessions.test.ts`: "moderates every message that starts with /secret, from every member and in every form, before any other handling"; "sets a secret with its hosts and refuses reserved names"; "moderates /secret in the Main group and says where to send it".
- `test/unit/messages.test.ts`: "list returns the name, hosts and placeholder of each secret, without values".
- `test/e2e/service.test.ts`: "a curl command through the service's proxy sends the value of a secret to its bound host, and prints the placeholder".
- Run `npm test --prefix packages/simplex-chat-mcp`, and the end-to-end tests as TESTING.md states, in the reduced build. No app changes, so no app test workflows.

## 8. Docs to change

- `README.md`: section Secrets: secrets with hosts, `/secret NAME HOSTS VALUE`, placeholders and variables, an example.
- `REFERENCE.md`: section Secrets rewritten: the commands, hosts and reserved names, placeholders and variables, the modes `value`, `aws` and `gcp` with examples for GitHub, git, OpenAI, Stripe, AWS and Google Cloud, responses, refusals, tools that work and those that don't, the limits of the plugin variant and the two stronger setups (Q1 A). "Plugin data folder": `secrets/`, `secrets.json`, `proxy-ca.key`, `proxy-ca.pem`, `proxy-ca-bundle.pem`. "Options": `SIMPLEX_MCP_PROXY_PORT`. "Plugin security": the line of Q4 A, `The plugin and its proxy are meant for a computer or a container that one person uses.`, and the data folder readable by programs of the same user.
- `TESTING.md`: the automated tests; real checks for criterion 10, with Claude Code 2.1.323.
- `spec/api.md`: 4.2 and 4.3, `/secret` and its replies; 4.1, `list`; 4.6, `TitleRequest.proxy`; 4.8, the hook variables; a new part for the proxy, with its answers.
- `spec/architecture.md`: 8.1, the proxy in the system diagram; 8.2, `proxy.ts`, `certs.ts`, `sigv4.ts`, `gcp.ts`; 8.3, the store and the CA; 8.4, the start order and the idle stop; 8.7 and 8.8, the boundaries and limits of section 5.
- `spec/flows.md`: flow 32 in a session group; a new flow, a command with a secret through the proxy.
- `ROADMAP.md`: unchanged, as it has no line for secrets.

## 9. Conflict areas with the other items

```
file                where                                   items
src/hub.ts          Session.onMessage                       mcp-reactions, mcp-threads, mcp-decisions, mcp-flat-sessions
                    createSessionGroup (#8151 fullDelete)   mcp-flat-sessions, mcp-threads, mcp-decisions
src/main-group.ts   onMessage, createMainGroup, load        mcp-session-list, mcp-flat-sessions, mcp-threads
src/control.ts      onMessage, ownerCommand                 mcp-allow-tool, mcp-decisions, mcp-threads
src/service.ts      Service.start, scheduleStop, runService mcp-activity, mcp-live-answers, mcp-session-usage, mcp-session-list
src/hook.ts         sessionStart                            mcp-context-summary
hooks/hooks.json    new FileChanged entry                   mcp-activity (tool hooks)
src/protocol.ts     TitleRequest                            mcp-session-list (SessionRequest), mcp-threads, mcp-decisions (AttachLine)
src/tools.ts        listOutput, listDescription             mcp-threads, mcp-decisions
REFERENCE.md, spec  Secrets, 4.x, 8.x, flows                every item; mcp-spec-names for the spec anchors
```

## 10. Estimate

Hours of agent work:

```
part                                                  source lines   test lines   hours
proxy.ts: tunnels, TLS, mode value, refusals,         260            320          2
  responses
certs.ts                                              90             50           0.5
sigv4.ts: mode aws                                    110            110          1
gcp.ts: mode gcp                                      90             80           0.5
control.ts, hub.ts, main-group.ts, tools.ts           60             140          1
hook.ts, service.ts, files.ts, protocol.ts            70             100          1
serve, http.ts, register.ts, the opencode plugin      80             80           1
e2e and the real checks of criterion 10                              60           1
docs                                                  250 lines of text           1
two review rounds                                                                 2
```

About 11 hours, after #8151's conflicts with master are resolved, which takes about half an hour more.

## 11. opencode setup

What the agent did here, without the user (R4):
- `npm install -g --prefix DIR opencode-ai` installed opencode 1.19.5 without a prompt or `sudo`. The default prefix of this machine is `/usr`, which needs `sudo`, so the user's step uses `~/.local`, whose `bin` is on `PATH`.
- opencode lists free models of its own provider without any key, such as `opencode/deepseek-v4.1-flash-free`. `opencode run` with that model answered `OK`.
- This machine has no model provider key in its environment, so the free model is the one to test with. Other providers are added in opencode with `/connect`.

The user's steps, after the implementation is published:

1. `npm install -g --prefix ~/.local opencode-ai`
2. `npx -y @simplex-chat/mcp serve my-agent`, in its own terminal; scan the QR code with the SimpleX app.
3. `npx -y @simplex-chat/mcp register my-agent --host opencode`
4. `opencode --model opencode/deepseek-v4.1-flash-free`

Then send `/secret GITHUB_TOKEN api.github.com <token>` in the agent control chat, and ask opencode: `Show my GitHub login with the GITHUB_TOKEN secret.`

Before the publication, the agent gives the commands of steps 2 and 3 for the branch's build.

## 12. Implementation

Where the code differs from sections 2 to 7:

```
#   plan                                         code                                          reason
D1  values in ROOT/secrets/NAME (decision 22)    ROOT/_secrets/NAME                            agent folders of serve can be named
                                                                                               secrets; names with _ can't collide
D2  src/redaction.ts with #8151's replacements   secrets.ts valueForms, proxy.ts Scrubber      one module of the proxy
D3  variables in every session (decision 21)     only while secrets exist; FileChanged         a session without secrets keeps its
                                                 writes them when the first one is set         network unchanged
D4  aws note: It signs AWS requests with         It signs AWS requests, with                   each aws secret gets it; copy for
    AWS_ACCESS_KEY_ID. once both keys are set    AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY   approval
                                                 set for the same hosts.
D5  gcp note: Claude uses $NAME as a Google      It is a Google service-account key: $NAME     copy for approval
    access token.                                stands for its access token.
D6  list description: ... a request to another   ... a request to another host contains the    a tunnel sends the placeholder as
    host gets no value.                          placeholder, not the value.                   text (decision 18)
D7  hosts as written                             each host has a dot                           a value with spaces lost its first
                                                                                               word to HOSTS; NO_PROXY keeps
                                                                                               localhost off the proxy
D8  reserved names of section 2                  also LOGNAME, ALL_PROXY, SSL_CERT_DIR and     the variables of decision 21
                                                 CLOUDSDK_
D9  the refusals of section 2                    also: the Host differs, a chunked body over   checks of decisions 14 and 17
                                                 8 MiB, a gcp value that is no key, aws
                                                 without both keys, unrecognized signature
D10 list: secrets always                         absent while there are none                   tools of a session without secrets
                                                                                               are unchanged
D11 opencode header Authorization=TOKEN          Authorization=Bearer {file:DATA/token}        the token stays out of the command
    (decision 37)                                                                              and of opencode.jsonc, as for Claude
                                                                                               Code; opencode refuses to start
                                                                                               while that file is missing
D12 the hook makes secrets.json for watchPaths   no file made                                  Claude Code's chokidar watches a
                                                                                               missing path through its folder
D13 e2e: curl through the service's proxy        unit tests with local HTTPS servers, the      a bound host needs a certificate
                                                 serve scenario of e2e, and a curl run to      that the system trusts
                                                 httpbin.org through the build
D14 the hooks' port: SIMPLEX_MCP_PROXY_PORT      proxyPort of GET /status, written after       the service may run without the
    or 5225 (decisions 13, 21)                   /title, only while the service runs the       proxy, or on the port of its own
                                                 proxy                                         environment
```

Added: the unit tests run with `HOME` in a temporary folder, the `globalSetup` of the project `unit` in `jest.config.js`, and the hook tests pass their own `SIMPLEX_MCP_HOME`; a test of `files.test.ts` fails when the default data root is outside that folder. New spec text names functions and links files, without line numbers, for #8176.

Open:

- O1. Tunnels connect directly, and the proxy's own HTTPS requests use the person's proxy only with `NODE_USE_ENV_PROXY=1` in the service's environment. Behind a person's own HTTPS proxy, commands that had used it lose their way out while secrets exist. A fix chains `CONNECT` to the proxy of the service's environment: about 40 lines and a test.
- O2. An agent of `serve` in Claude Code gets no variables, as no hook of `serve` runs there; the agent names the proxy in its commands. A fix: `register` adds a SessionStart hook, or `list` returns the proxy's URL.
- O3. The FileChanged matcher `secrets.json` also makes Claude Code watch `secrets.json` of the session's folder (`ne`, 295488859), and a change there writes the variables again.
- O4. The docs of Q1: the limits of the plugin variant and the stronger setups.
- O5. README.md "## Secrets" still has #8151's text: `--secrets-folder`, `/secret` without hosts, `$(cat …)`. The text the user approves replaces it before the branch ships.
