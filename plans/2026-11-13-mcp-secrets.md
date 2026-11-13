# SimpleX MCP: secrets bound to hosts, put into requests by the plugin's proxy

Status: rewritten on 2026-11-13 to the user's design, which replaces the redaction of the model's requests in the earlier version of this plan. The user's answers Q2 A and Q4 A still apply. Q1, Q3 and Q5 are new. The plan waits for the user's approval before implementation.

It completes #8151 (https://github.com/simplex-chat/simplex-chat/pull/8151, "mcp server: give the agent secrets without exposing them to the model"), whose head is `cc45d339b`. Code references: #8151 at `cc45d339b` and master `8fda06295`, by file and function. Claude Code references: the 2.1.322 binary at the byte offsets given, and the official docs, quoted. Runs R1 to R3 used Claude Code 2.1.323 with `claude -p`, a scratch `HOME` and `CLAUDE_CONFIG_DIR`, a fake token, a local server that answers model requests with canned tool calls, a test plugin loaded with `--plugin-dir`, and a local proxy that terminates TLS for `api.anthropic.com` with a test CA:

- R1: the test plugin's SessionStart hook wrote `HTTPS_PROXY`, `https_proxy`, `NO_PROXY`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE` and `NODE_EXTRA_CA_CERTS` to `CLAUDE_ENV_FILE`. The model asked for a Bash command that printed these variables and ran `curl https://api.anthropic.com/probe-from-bash-main`.
- R2: as R1, from a Bash command of a subagent.
- R3: Node.js 22.23.3 `fetch` and `https.get` through the same proxy, with and without `NODE_USE_ENV_PROXY=1`.

## 1. Goal

The user's words, 2026-11-13:

> maybe complete secrets from Alain with proxy? I am assuming plugin would run proxy, right?

> I honestly do not understand why command needs to print anything at all. Keys are always passed either in URIs or in headers of HTTP requests, right? and it some rarer cases in JSON bodies, correct? Because if command prints the secret there is nothing to stop the model from printing it. My thinking was that secret is per service, and each secret is tied to a particular remote host, and cannot be used with any other host, and cannot be printed to - the substitution happens inside HTTP proxy.

The design works for Claude Code without a user setting. The plugin's SessionStart hook gives Claude's Bash commands the proxy and the plugin's certificate authority through `CLAUDE_ENV_FILE`, which Claude Code gives to plugin hooks (R1, R2, fact 1).

The secrets are values for web services, such as a GitHub token or AWS IAM keys. Each one is bound to one host or a list of hosts.

- Claude writes a placeholder in its commands, `simplex-secret-GITHUB_TOKEN`, or the variable `$GITHUB_TOKEN` that holds it.
- The plugin's proxy replaces the placeholder with the value in an HTTPS request to a bound host, in a header, the URL or the body.
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
- VALUE: the rest of the line, as in #8151.
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
- `list` returns `"secrets": [{"name": "GITHUB_TOKEN", "hosts": ["api.github.com", "github.com"], "placeholder": "simplex-secret-GITHUB_TOKEN"}]`, without values.
- Each Bash command has the variable `GITHUB_TOKEN=simplex-secret-GITHUB_TOKEN`. Tools that read a standard variable, such as `gh` with `GH_TOKEN` or the AWS CLI with `AWS_SECRET_ACCESS_KEY`, send the placeholder, and the proxy puts the value in.
- The `list` description: `secrets has the name, hosts and placeholder of each secret your owners set. Use the placeholder, or the variable named as the secret, in an HTTPS request to one of its hosts, in a header, the URL or the body: the SimpleX proxy puts the value in. The value is never shown to you, and a request to another host gets no value.`

Examples:

```
curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user
git clone https://x-access-token:simplex-secret-GITHUB_TOKEN@github.com/org/repo.git
aws s3 ls
```

Answers of the proxy to Claude's commands, as HTTP responses with status 403 and a one-line body:

```
case                                                         body
a placeholder in a request to a host not bound to it          SimpleX proxy: secret NAME is for HOSTS, not HOST.
a placeholder of a secret that doesn't exist                   SimpleX proxy: no secret NAME; list shows the secrets.
a placeholder over plain HTTP                                 SimpleX proxy: secrets are sent only over HTTPS.
an AWS request the proxy can't sign again                     SimpleX proxy: this AWS request can't be signed with secret NAME: FORM.
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

Answered on 2026-11-13: Q2 A and Q4 A.

Q1. What the plugin promises about Claude reading a value. Claude's commands run as the person's own OS user, as the SimpleX service does.
- A, recommended: the plugin variant now. Values stay in the service's private folder. Claude is never told the folder, a command sees only placeholders, and a command that avoids the proxy gets no value. A command that searches the person's files can still read the folder, as any program of that user can. The docs name two stronger setups: Claude Code's own sandbox, whose settings can deny reading the folder and send traffic to a proxy of the person's choice, still to be checked with this proxy; and a container without network that reaches the proxy only through a Unix socket, as in steward (facts 7 and 8).
- B: secrets only for Claude Code in such a sandbox or container. The plugin refuses `/secret` until the setup is in place. Every person who uses secrets sets it up first.

Q3. Where the proxy puts a value in a request to a bound host.
- A, recommended, as in the user's words: any header, `Authorization: Basic` included, the URL, and the body, with AWS requests signed again with the real key. A command can also put a value into data that the bound host stores or shows, such as an issue comment.
- B: headers and the URL only, with AWS signing. Bodies keep the placeholder, so services that take keys in the body don't work.

Q5. #8151's way for `serve` and opencode, where the agent reads the value by path and opencode redacts model requests.
- A, recommended: replaced everywhere by the proxy. `serve` runs the same proxy, the person starts opencode with the proxy variables that `serve` prints, and the opencode plugin is removed. One way for every host.
- B: kept for `serve` and opencode; the proxy is for the plugin only. Two ways, with values in the agent's shell under `serve`.

## 4. Decisions

Facts:

1. A plugin's SessionStart hook gets `CLAUDE_ENV_FILE`, and Claude Code applies the variables written there to every Bash command of the session, a subagent's included. R1: the hook's `CLAUDE_ENV_FILE` was `~/.claude/session-env/SESSION/sessionstart-hook-0.sh`, and the Bash command printed every variable the hook wrote. R2: the same for a subagent's command. Claude Code 2.1.322 sets `CLAUDE_ENV_FILE` for SessionStart, Setup, CwdChanged and FileChanged hooks (296981265), as `EVENT-hook-N.sh` (`$Mi`, 292665531), and reads these files before Bash commands (`Hps`, 292666442). The hooks docs in the binary: "write bash exports there to apply env to subsequent BashTool commands" (313216108). Claude Code refuses Claude's own writes to that folder (289572572).
2. The variables are for Bash commands: the docs of fact 1 name them so, and Claude Code's own process, with its model requests and WebFetch, keeps its environment.
3. A command's HTTPS request passes such a proxy and trusts its CA from these variables. R1 and R2: `curl` sent `CONNECT api.anthropic.com:443` to the proxy, accepted the proxy's certificate for that host, and the proxy saw `GET /probe-from-bash-main` and `GET /probe-from-bash-sub`.
4. Node.js 22.23.3 `fetch` and `https.get` use `HTTPS_PROXY` only with `NODE_USE_ENV_PROXY=1`. R3: with it, both requests passed the proxy; without it, `fetch` went straight to the host.
5. Node.js has no API that creates certificates: `crypto` offers `generateKeyPairSync`, `sign` and `X509Certificate`, which reads and checks a certificate (`checkIssued`, `checkHost`, `verify`), and `tls.rootCertificates` holds 119 root certificates (Node.js 22.23.3).
6. AWS SigV4 computes a signature from the secret access key, and the key itself is not sent. Claude Code's sandbox signs such requests again at its proxy, and refuses by default the forms it can't sign again: streaming uploads, presigned URLs and SigV4A (`sigv4` policies, 283850014).
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
17. Q3 A. In a request to a bound host over HTTPS, the proxy replaces `simplex-secret-NAME` with the value of NAME when NAME is bound to that host:
    - in every header value;
    - inside `Authorization: Basic`, which it decodes and encodes again;
    - in the path and the query;
    - in a body of up to 8 MiB without `Content-Encoding`, whose `Content-Type` is JSON, form data, text or XML; `Content-Length` is set again.

    Other bodies pass unchanged, so a placeholder there stays text.
18. A request to a bound host that carries a placeholder of another secret, of an unknown secret, or any placeholder over plain HTTP gets the 403 answers of section 2. A request through a tunnel is not read (decision 14), so a placeholder there reaches its host as text, without a value.
19. AWS: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` form one pair, as in Claude Code's sandbox (fact 6). For a request to a host of the pair with `Authorization: AWS4-HMAC-SHA256` whose credential is the key ID's placeholder or value, the proxy sets the real key ID and session token and computes the signature again over the request as it arrives. Streaming uploads, presigned URLs and SigV4A get the 403 of section 2.
20. Responses from a bound host: in headers and in text bodies, the proxy replaces each value, its URL encoding and its base64 and base64url forms with the placeholder, by #8151's `replacements`. A compressed text body is decompressed and sent without `Content-Encoding`. The body streams through a window of the longest form's length, so a value split across chunks is replaced.
21. The SessionStart hook writes these variables to `CLAUDE_ENV_FILE`, in every mode:
    - `HTTPS_PROXY`, `HTTP_PROXY`, `https_proxy`, `http_proxy`: `http://127.0.0.1:5225`;
    - `NO_PROXY`, `no_proxy`: `localhost,127.0.0.1,::1`;
    - `NODE_USE_ENV_PROXY=1` (fact 4);
    - `SSL_CERT_FILE`, `CURL_CA_BUNDLE`, `REQUESTS_CA_BUNDLE`, `GIT_SSL_CAINFO`, `AWS_CA_BUNDLE`: `ROOT/proxy-ca-bundle.pem`;
    - `NODE_EXTRA_CA_CERTS`: `ROOT/proxy-ca.pem`;
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
31. Delivery: our own pull request, stacked on #8151, branch `ep/mcp-secrets` of the evgeny-simplex fork, started at #8151's head `cc45d339b`. After #8151 merges, `git rebase --onto master cc45d339b` leaves only our commits. Alain is told of the user's design before he changes #8151 further; his commands, moderation and store remain.

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

Changes, on top of #8151:

```
file                function                  change
src/proxy.ts        new                       startProxy(port, store, ca): CONNECT tunnels, terminated TLS for bound
                                              hosts, placeholders, AWS signing, refusals, response replacement
src/certs.ts        new                       the CA and host certificates in DER (decisions 15 and 16)
src/sigv4.ts        new                       the canonical request and signature of SigV4
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
opencode/           simplex-secrets.ts        removed (Q5 A)
```

The proxy, per connection:

```
CONNECT HOST:PORT:
  no secret bound to HOST:   tunnel, nothing read
  else:                      TLS with the host certificate of HOST, then for each request inside:
    Host differs from HOST:  403
    placeholders = simplex-secret-NAME in headers, Basic credentials, path, query, text body
    a NAME unknown, or not bound to HOST:  403
    replace placeholders with values; AWS: sign again, or 403 for the forms it can't
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
  Terminated --> Injected: placeholders replaced, AWS signed again
  Injected --> Refused: AWS form that can't be signed
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
```

## 6. Compatibility

- Tools that read `HTTPS_PROXY` and one of the certificate variables work: `curl` (R1), Node.js with `NODE_USE_ENV_PROXY` (R3). `git`, Python `requests`, the AWS CLI and `gh` are checked in TESTING.
- Tools that ignore the proxy variables, Claude Code's WebFetch and MCP servers send the placeholder as text: no value, and the request fails.
- HTTP/2-only clients fail for bound hosts, as the proxy offers only `http/1.1`; other hosts are tunnelled unchanged.
- Claude Code's sandbox sets its own proxy for sandboxed commands; this plan does not cover the sandbox, and TESTING records what happens with it on.
- A computer with its own HTTPS proxy: the service's connections to bound hosts use the proxy variables that `spawnService` passes, with `NODE_USE_ENV_PROXY`.
- Older plugin data folders: the CA and `secrets.json` appear at the first start of this version.
- An older service: the hook of this version stops it (`client.ts` `ensureService`).
- Older SimpleX apps: moderation and full deletion as in #8151.
- `serve`: by Q5.

## 7. Acceptance and tests

Done when:

```
#  criterion                                                                                  checked by
1  host certificates verify against the CA, with the host in subjectAltName                   unit: certs
2  a tunnel copies bytes unchanged for a host bound to no secret                              unit: proxy
3  placeholders are replaced in headers, Basic credentials, path, query and text bodies,      unit: proxy
   for bound hosts only
4  refusals: Host differs, unknown placeholder, another host's placeholder, plain HTTP        unit: proxy
5  responses carry placeholders in place of values, also split across chunks and compressed   unit: proxy
6  SigV4 signatures equal those of the AWS test suite; streaming, presigned, SigV4A refused   unit: sigv4
7  the SessionStart hook writes the variables of decision 21 and returns watchPaths;          unit: hook
   FileChanged writes the secrets' variables again
8  every /secret message is moderated, in session groups and the Main group; hosts and        unit: sessions
   reserved names; list returns names, hosts and placeholders
9  curl through the service to a local HTTPS server bound to a secret sends the value, and    e2e
   its output shows the placeholder
10 a real session: gh, git and the AWS CLI work with secrets; Claude's answers and the        TESTING
   transcript hold no value; R1 repeated with the plugin
```

Tests:
- `test/unit/certs.test.ts`, new: "makes a CA and host certificates that X509Certificate verifies, with the host in subjectAltName".
- `test/unit/proxy.test.ts`, new, with local HTTPS servers and the test CA: "tunnels a host bound to no secret without reading it", "puts the value into headers, Basic credentials, path, query and a JSON body of a request to a bound host", "refuses a placeholder for another host, an unknown placeholder, a Host that differs from CONNECT and a placeholder over plain HTTP", "replaces values in responses, also split across chunks and gzip-compressed", "checks the bound host's real certificate".
- `test/unit/sigv4.test.ts`, new: "signs the requests of the AWS SigV4 test suite again with the real key", "refuses streaming uploads, presigned URLs and SigV4A".
- `test/unit/hook.test.ts`: "writes the proxy, certificate and secret variables to CLAUDE_ENV_FILE, and returns watchPaths". It fails on #8151's head, whose hook writes no variables.
- `test/unit/sessions.test.ts`: "moderates every message that starts with /secret, from every member and in every form, before any other handling"; "sets a secret with its hosts and refuses reserved names"; "moderates /secret in the Main group and says where to send it".
- `test/unit/messages.test.ts`: "list returns the name, hosts and placeholder of each secret, without values".
- `test/e2e/service.test.ts`: "a curl command through the service's proxy sends the value of a secret to its bound host, and prints the placeholder".
- Run `npm test --prefix packages/simplex-chat-mcp`, and the end-to-end tests as TESTING.md states, in the reduced build. No app changes, so no app test workflows.

## 8. Docs to change

- `README.md`: section Secrets: secrets with hosts, `/secret NAME HOSTS VALUE`, placeholders and variables, an example.
- `REFERENCE.md`: section Secrets rewritten: the commands, hosts and reserved names, placeholders and variables, where the proxy puts values, AWS, responses, refusals, tools that work and those that don't, the limits of the plugin variant and the two stronger setups (Q1 A). "Plugin data folder": `secrets/`, `secrets.json`, `proxy-ca.key`, `proxy-ca.pem`, `proxy-ca-bundle.pem`. "Options": `SIMPLEX_MCP_PROXY_PORT`. "Plugin security": the line of Q4 A, `The plugin and its proxy are meant for a computer or a container that one person uses.`, and the data folder readable by programs of the same user.
- `TESTING.md`: the automated tests; real checks for criterion 10, with Claude Code 2.1.323.
- `spec/api.md`: 4.2 and 4.3, `/secret` and its replies; 4.1, `list`; 4.6, `TitleRequest.proxy`; 4.8, the hook variables; a new part for the proxy, with its answers.
- `spec/architecture.md`: 8.1, the proxy in the system diagram; 8.2, `proxy.ts`, `certs.ts`, `sigv4.ts`; 8.3, the store and the CA; 8.4, the start order and the idle stop; 8.7 and 8.8, the boundaries and limits of section 5.
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

```
part                                        source lines   test lines
proxy.ts                                    260            320
certs.ts, sigv4.ts                          200            160
control.ts, hub.ts, main-group.ts, tools.ts 60             140
hook.ts, service.ts, files.ts, protocol.ts  70             100
e2e                                                        60
docs                                        200 lines of text
```

About six working days, with two review rounds, after #8151's conflicts with master are resolved.
