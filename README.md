# Dip Sandbox

A Docker Compose / [Dip](https://github.com/bibendi/dip) configuration for running Claude Code in a Docker container with restricted network access.

All traffic goes through a proxy container. The `claude` CLI is installed in a sandbox container, can only access hosts from the allowlist and sees no real Claude credentials.

The setup follows the [Agent containment best practices](https://support.claude.com/en/articles/17316076-agent-containment-best-practices-getting-started-private-beta): deny egress by default, and keep the model credential in a proxy outside the sandbox.

## Disclaimer

This setup a reference implementation that uses Ruby, Claude and MacOS as examples. Core ideas and techniques work for any stack / platform.

## Installation

First, clone the repo:

```sh
git clone https://github.com/palkan/dip-sandbox ~/code/dip-sandbox
```

Then, create a token (assuming you want to use your Claude subscription, not API) and store it in the keychain:

```sh
claude setup-token

# The command prints a token that starts with `sk-ant-oat01-`.

# Store the token in the Keychain

security add-generic-password -a "$USER" -s claude-sandbox-token -w "st-ant-<...>"
```

Now, choose one of the options below to use it.

## Run with Dip

### In a shared home setup

_The original battle-tested setup_.

The article [Reusable development containers with Docker Compose and Dip](https://evilmartians.com/chronicles/reusable-development-containers-with-docker-compose-and-dip) keeps one `~/dip.yml` for all projects. The services live in `~/.dip`. To add the sandbox to that setup:

1. Copy this folder into `~/.dip`:

   ```sh
   cp -r ~/code/dip-sandbox ~/.dip/sandbox
   ```

2. In `~/.dip/sandbox/compose.yml`, delete the `ruby` service and its volumes (`bundle`, `history`, `claude`). Your home setup already has a `ruby` service. Keep `proxy`, `ruby-sandbox`, and the `sandbox` network.

3. Add the file to `compose.files` in `~/dip.yml`:

   ```yaml
   compose:
     files:
       # ...your files...
       - ./.dip/sandbox/compose.yml
   ```

4. Add the commands to `interaction` in `~/dip.yml`:

   ```yaml
   'ruby:sandbox':
     description: Open a Ruby terminal with network through the proxy only (start the proxy first)
     service: ruby-sandbox
     command: bash
   'claude:sandbox':
     description: Run Claude Code in the sandbox (start the proxy first)
     service: ruby-sandbox
     command: claude
   ```

Now, you can go to any project's directory and run the sandboxed Claude from it as follows:

```sh
cd my/project/directory

CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s claude-sandbox-token -w) dip up -d proxy

dip claude:sandbox
```

### Standalone

If you want to use this setup indepdently (not as your `$HOME` setup), provide the `DIP_FILE` env variable, so `dip` can find the configuration:

```sh
cd my/project/directory

export DIP_FILE=~/dev/dip-sandbox/dip.yml

CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s claude-sandbox-token -w) dip up -d proxy

dip claude:sandbox
```

## Run with Docker Compose

Run these commands from your project directory. The services mount the current directory (`$PWD`) at the same path.

1. Start the proxy:

   ```sh
   CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s claude-sandbox-token -w) \
     docker compose -f ~/dev/dip-sandbox/compose.yml up -d proxy
   ```

2. Open a shell in the sandbox:

   ```sh
   docker compose -f ~/dev/dip-sandbox/compose.yml run --rm ruby-sandbox
   ```

3. Or run Claude Code directly:

   ```sh
   docker compose -f ~/dev/dip-sandbox/compose.yml run --rm ruby-sandbox claude
   ```

4. Watch the proxy log:

   ```sh
   docker compose -f ~/dev/dip-sandbox/compose.yml logs -f proxy
   ```

5. Stop the proxy:

   ```sh
   docker compose -f ~/dev/dip-sandbox/compose.yml stop proxy
   ```

The first run builds the image. Run `docker compose -f ~/dev/dip-sandbox/compose.yml build` to update Claude Code.

## The intended flow

The sandbox has its own gem volume. Install the dependencies in the sandbox in two phases: first with a proxy that allows RubyGems only, then with the agent proxy.

1. Start the proxy for RubyGems only. It needs no token: without one, the API port answers 503.

   ```sh
   PROXY_ALLOW_HOSTS="rubygems.org index.rubygems.org" dip up -d --force-recreate proxy
   ```

   Add `github.com` if your Gemfile has git sources.

2. Install the dependencies in the sandbox and make sure the project works:

   ```sh
   dip ruby:sandbox
   bundle install
   ```

3. Recreate the proxy with the token and the default (empty) allowlist:

   ```sh
   CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s claude-sandbox-token -w) dip up -d --force-recreate proxy
   ```

4. Run the agent:

   ```sh
   dip claude:sandbox
   ```

5. Review the changes before you run anything on the host (see [Security notes](#security-notes)).

With plain Docker Compose, replace `dip up` with `docker compose -f ~/dev/dip-sandbox/compose.yml up`, and `dip ruby:sandbox` with `docker compose -f ~/dev/dip-sandbox/compose.yml run --rm ruby-sandbox`.

## How it works

```
 ┌──────────── sandbox network (internal: no route out) ────────────┐
 │                                                                  │
 │  ruby-sandbox ── ANTHROPIC_BASE_URL ──▶ proxy:8080 (reverse) ────┼──▶ https://api.anthropic.com
 │  (fake token)                           adds the real token      │
 │                                                                  │
 │               ── HTTPS_PROXY ─────────▶ proxy:3128 (forward) ────┼──▶ allowed hosts only
 │                                         other hosts: 403         │
 └──────────────────────────────────────────────────────────────────┘
```

The `sandbox` network is `internal`, so it has no route out. A tool that ignores the proxy variables, or connects to a raw IP address, cannot reach the network.

## Allowed hosts

The default allowlist is empty. Claude Code needs no direct connections: its API calls go through port 8080. Install gems before you start the agent (see [The intended flow](#the-intended-flow)).

To allow hosts, set `PROXY_ALLOW_HOSTS` and recreate the proxy. For example, add RubyGems to let the agent run `bundle install`:

```sh
CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s claude-sandbox-token -w) \
  PROXY_ALLOW_HOSTS="rubygems.org index.rubygems.org" \
  docker compose -f ~/dev/dip-sandbox/compose.yml up -d --force-recreate proxy
```

Host names must match exactly. Each entry allows one port:

| Entry | Allows |
|---|---|
| `example.com` | Port 443 |
| `example.com:8443` | Port 8443 only |
| `*` | Every host on port 443 |

The proxy enforces these rules:

- **HTTPS only.** The proxy accepts `CONNECT` tunnels only. It refuses plain HTTP requests.
- **The TLS server name must match.** The first bytes in the tunnel must be a TLS ClientHello whose server name (SNI) equals the `CONNECT` host. Otherwise the proxy closes the tunnel. Many hosts share a CDN, and the CDN selects the site by the server name. Without this check, a tunnel to an allowed host could reach any other site on the same CDN. For the same reason, the proxy refuses a ClientHello that offers Encrypted Client Hello (ECH), because ECH hides the real server name. Clients that always send ECH placeholders, such as Chrome, cannot use the tunnel.
- **No private addresses.** The proxy refuses private, loopback, and link-local addresses, whatever the list says. This blocks the Docker host (`host.docker.internal`), the other containers, and cloud metadata endpoints. The proxy connects to the address that it checked, so a second DNS answer cannot point elsewhere.

Every allowed host is a possible upload channel. For example, with RubyGems on the list, an agent can `gem push` your code. The proxy cannot see the HTTP `Host` header inside the encrypted tunnel. A CDN that routes by that header could send a request to another site on the same CDN. Allow hosts only for the time you need them, then recreate the proxy without them.

## Allowed API routes

The reverse proxy (port 8080) adds the credential to the allowed routes only. Other routes get `403`. The default list covers Claude Code:

```
POST /v1/messages POST /v1/messages/count_tokens
```

Each route is a method and an exact path. The proxy ignores the query string. To change the list, set `PROXY_API_ROUTES` and recreate the proxy. The value `*` allows every route.

```sh
CLAUDE_CODE_OAUTH_TOKEN=$(security find-generic-password -s claude-sandbox-token -w) \
  PROXY_API_ROUTES="POST /v1/messages POST /v1/messages/count_tokens GET /v1/models" \
  docker compose -f ~/dev/dip-sandbox/compose.yml up -d --force-recreate proxy
```

A refused route shows in the proxy log as `deny api <METHOD> <path>`.

## Check the sandbox

Run these commands in `dip ruby:sandbox` (or `docker compose ... run --rm ruby-sandbox`):

```sh
curl -sI https://example.com                     # refused: 403 from the proxy
curl -sI --noproxy '*' https://example.com       # fails: no route out
env | grep sk-ant                                # prints nothing
claude -p "say hi"                               # answers through the proxy
```

## Security notes

- **The project directory is shared.** The sandbox writes to your project files. Some files run code when you, your editor, or a host-side tool next touches the project. Before you run anything on the host, review all changes, including untracked and ignored files (`git status --ignored`). Look especially at:
  - `bin/*` and other scripts
  - `Gemfile` (`path:` gems), `.bundle/config`
  - `.rubocop.yml` (`require:`), `.ruby-lsp/`
  - `.claude/settings*.json` (`hooks`, `env`, `apiKeyHelper`), `.mcp.json`, `CLAUDE.md`
  - `.envrc`, `mise.toml`, `.mise.toml`, `.tool-versions`: version managers and direnv run their env scripts when you `cd` into the project
  - `.yarnrc.yml` (`yarnPath`), `.npmrc`, `package.json` scripts
  - `Procfile*`, `.vscode/`

  If you run Claude Code on the host, `"allowManagedHooksOnly": true` in its managed settings stops project hooks that the agent planted. It also stops your own project hooks.
- **Project settings can send your real token elsewhere.** The `env` map in `.claude/settings.json` can set `ANTHROPIC_BASE_URL`. Claude Code then sends your token to that URL, even if your shell sets another value. The sandbox can write this file. The next time you run Claude Code in the project on the host (or in the `ruby` service), your real token goes to the URL that the agent chose. `apiKeyHelper` in the same file runs a command, and `env` can set variables such as `NODE_OPTIONS` for Claude Code and the commands it starts. To block the redirect, pin the URL in the host's managed settings. Managed settings take priority over project settings:

  ```json
  { "env": { "ANTHROPIC_BASE_URL": "https://api.anthropic.com" } }
  ```

  On macOS, the file is `/Library/Application Support/ClaudeCode/managed-settings.json`. On Linux and in containers, it is `/etc/claude-code/managed-settings.json`. Do not pin the URL if you use an API gateway on the host on purpose. The pin does not stop `apiKeyHelper` or other `env` variables: review those.
- **`.git` is read-only in the sandbox.** The agent cannot write hooks or `.git/config` (`core.hooksPath`, `core.fsmonitor`). It also cannot commit: commit the changes yourself on the host after review. Run the sandbox from the repository root. In a directory without `.git`, the sandbox does not start.
- **Nested repositories are not protected.** `.git` is read-only only at the project root. The sandbox can create `sub/.git` with its own config, for example `core.fsmonitor`. Git runs that config when you use git inside `sub/` on the host. Opening the project in an editor is enough: VS Code scans subfolders for repositories and runs git in each one. Before you use git or open an editor on the host after a session, run this command and delete anything it prints:

  ```sh
  find . -name .git -not -path ./.git
  ```

  In VS Code, set `"git.autoRepositoryDetection": "openEditors"` to stop the subfolder scan.
- **Run the sandbox from a project directory only.** The sandbox mounts `$PWD`. Started from `$HOME`, it can read `~/.ssh`, `~/.aws`, and `~/.claude`.
- **Do not open this repository in the sandbox.** An agent that edits `compose.yml` or `proxy.rb` controls the next proxy start, and the proxy holds the token and has full network access.
- **Do not add `api.anthropic.com` to the allowlist.** A tunnel to it bypasses the route list. An agent that finds another API key could then use it directly, for example to upload your code to another account.
- **The reverse proxy accepts one well-formed request per connection.** It refuses bare line feeds and control characters in the request head, `Transfer-Encoding`, and duplicate `Content-Length` headers. It forwards exactly `Content-Length` bytes of body and nothing after them. A client cannot smuggle a second request that carries the token.
- **The reverse proxy adds the token to the allowed routes.** The agent never sees the token, but it can use these routes: by default, it can spend your quota on messages. It cannot reach other endpoints, such as Files or Batches, unless you add them to `PROXY_API_ROUTES`.
- **Volumes are separate.** The sandbox has its own gem, history, and Claude config volumes. Code that the sandbox writes there never runs in the `ruby` service, where your real Claude login lives. Never mount the `ruby` volumes into the sandbox.
- **Sandbox volumes are shared between projects.** A session in one project can leave something behind for sessions in other projects: a changed gem, a user-level `CLAUDE.md`, a skill, or an agent definition in the Claude config volume.
- **The Claude Code configuration is pinned.** `claude-managed/managed-settings.json` is mounted read-only at `/etc/claude-code`. Claude Code gives managed settings the highest priority, and the agent cannot change the file or add drop-ins next to it. The settings:

  | Setting | Effect |
  |---|---|
  | `allowManagedHooksOnly: true` | Ignores hooks in user, project, and plugin settings |
  | `allowedMcpServers: []` | Allows no MCP servers, including the project's `.mcp.json` |
  | `strictKnownMarketplaces: []` | Refuses plugin marketplaces, so the agent cannot install plugins |

  So a hook or MCP server that one session plants does not run in later sessions. To use your own hooks or MCP servers in the sandbox, add them to the managed settings file.
- **Environment is not shared.** The `x-ruby` anchor goes to both services. Put secrets (database URLs, API tokens) on the `ruby` service only, never on the anchor.
- **The sandbox is hardened.** It runs with no Linux capabilities and `no-new-privileges`. It has limits for processes, memory, and CPU. To change the limits, set `SANDBOX_PIDS` (default 1024), `SANDBOX_MEMORY` (default `8g`), and `SANDBOX_CPUS` (default 4). It still runs as root inside the container.
- **No databases.** Do not connect database services to the `sandbox` network. A database container that is also on `default` gives the sandbox a second way out. For example, PostgreSQL `COPY ... PROGRAM` runs commands in that container.
- **The token is visible on the host.** `docker inspect` shows the proxy environment. This is acceptable because the host is outside the sandbox.
- **One VM for all containers.** Docker Desktop runs all containers in one Linux VM with a shared kernel. The best-practice guide recommends one VM for each agent.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The sandbox has no network at all | The proxy does not run. The sandbox does not start the proxy on purpose: a start without the token in the shell recreates the proxy without it. | Start the proxy first. |
| Claude Code fails with `sandbox proxy: no credential` | The proxy runs without a token, for example after the RubyGems phase. | Recreate the proxy with the token. |
| `bind source path does not exist: .../.git` | The current directory has no `.git`. | Run the sandbox from the repository root, or run `git init`. |
| `deny <host>` in the proxy log | The host or port is not on the allowlist. | Add the host (or `host:port`), then recreate the proxy. |
| `deny <host> (sni: ...)` in the proxy log | The TLS server name in the tunnel is not the `CONNECT` host, or the client sent no TLS. | The proxy never allows this. Connect to the host by its own name. |
| `deny ... (plain http)` in the proxy log | The client sent a plain HTTP request through the proxy. | Use HTTPS. |
| `deny <host> (private address)` in the proxy log | The host resolves to a private, loopback, or link-local address. | The proxy never allows this. Expose the service in another way. |
| Claude Code fails with `route not allowed`, or `deny api ...` in the proxy log | The API route is not on the route list. | Add the route to `PROXY_API_ROUTES`, then recreate the proxy. |
| The model picker does not show your plan's models | Claude Code did not load your account details. | Select the model by name: `/model claude-opus-5-5`. |
