# buzz-cursor-image

A container image for running **Buzz agents as Kubernetes pods with Cursor's
CLI** (`cursor-agent`, in `acp` mode), on Daniel's **personal** Cursor
account rather than a work one. Sibling to
[`i258-net/buzz-claude-image`](https://github.com/i258-net/buzz-claude-image) —
same shape, different runtime.

## Why this exists

Buzz Desktop 0.5.4 (2026-08-03) added a **Run on → kubernetes** option. It runs one
pod per agent, with per-agent `run_as_user`, a per-attempt Secret holding the
agent's private key, and a ServiceAccount that mounts no API token.

The default image it points at, `ghcr.io/block/buzz-sprig`, contains exactly one
binary — `sprig`, a Rust multicall that is simultaneously the ACP harness
(`buzz-acp`), Buzz's own built-in agent (`buzz-agent`), and the developer MCP
server (`buzz-dev-mcp`). There is no node and no `cursor-agent`.

So a `cursor`-runtime agent deployed on the stock image comes up, connects to the
relay, subscribes to its channels — and then dies at the first turn, the same
way a `claude`-runtime one does (see buzz-claude-image's README):

```
ERROR buzz_acp: agent failed to spawn: IO error: No such file or directory (os error 2)
```

## What's in it

- `debian:bookworm-slim` base (glibc — verified directly, not just assumed:
  `cursor-agent` bundles its own Node.js runtime, and that binary is
  `dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2` — the glibc
  linker path. Musl has no such interpreter; Alpine cannot run this.)
- `cursor-agent`, installed system-wide at `/opt/cursor-agent/versions/<version>`
  with symlinks in `/usr/local/bin` — not into a user `$HOME`, so it keeps
  working regardless of the provider's per-agent `run_as_user`
- `sprig` and `sprig-entrypoint`, copied from a digest-pinned `buzz-sprig`, with
  the same symlink set the stock image uses
- The same system-wide git signing config as upstream (`git-sign-nostr`,
  `commit.gpgSign true`)
- Non-root `agent` user, `WORKDIR /home/agent`

Neither `sprig` nor its entrypoint script are rebuilt or vendored here — both are
lifted straight out of the upstream image at a pinned digest (`COPY --from=sprig`),
so this repo tracks upstream rather than forking it.

### cursor-agent pinning

Cursor publishes no official Docker image, and no third-party/community image is
used here (`ghcr.io/redknife/cursor-cli` was evaluated and rejected on
supply-chain grounds during I25-69 — it would run with Daniel's Cursor
credential). Cursor's own install script (`cursor.com/install`) has **no version-pin
flag or env var, and no integrity check at all** — it hardcodes whatever version
is current into a `downloads.cursor.com/lab/<version>/...` URL and pipes straight
to `tar`. Rather than `curl | bash` at build time — which would silently follow
whatever Cursor publishes next, defeating the whole point of digest-pinning the
rest of this image — the Dockerfile downloads from that same versioned URL
directly and verifies the tarball's sha256 before extracting: stricter than
Cursor's own installer, same distribution channel. Bumping the version is a
two-`ARG` change (`CURSOR_AGENT_VERSION`, `CURSOR_AGENT_TARBALL_SHA256`) plus a
re-derived sha256 for the new tarball.

The build also asserts both pinning assumptions hold, failing the build rather
than shipping a broken image — see the last `RUN` step in the Dockerfile.

## Build

Push to `main`, or run the workflow manually. The build happens in GitHub Actions
on `linux/amd64` — **not locally**: the i258 nodes are amd64 and a native build on
an arm64 Mac produces an image the provider rejects with *"has no variant for the
architecture of the nodes it was scheduled on."*

The workflow prints the digest to paste into Desktop, in the run summary and as a
run annotation.

## Deploy

1. **Make the GHCR package public**, or attach a pull secret.

   The image contains no secrets — a public package is the simple answer, and is
   what this repo uses (matching buzz-claude-image). If you keep it private, note
   that the Buzz provider's config schema has **no `imagePullSecrets` field**; the
   workaround is to create a ServiceAccount in the agent namespace carrying
   `imagePullSecrets` and set the provider's `service_account` to it. Otherwise the
   pull fails and, per the provider's own error text, *"retries indefinitely and
   will not succeed on its own."*

2. **In Buzz Desktop → Edit agent:**
   - Agent harness → **Cursor** (`agent_command_override` → `cursor-agent`, args `acp`)
   - Run on → **kubernetes**
   - Agent image → the `@sha256:...` digest from the workflow summary
   - Environment variables → `CURSOR_API_KEY` = a key from Daniel's **personal**
     Cursor account. Never a work account — standing rule, not a detail (Daniel,
     2026-08-08: "I'm not using any work accounts here - and have no plan to -
     this should be avoided at all costs").
   - Namespace / kubeconfig context → as appropriate

   Use the **per-agent** environment variables, not the global agent settings — a
   global entry injects the credential into every agent on the machine, including
   local ones that don't need it.

## Known risks

- **`rg` is shadowed.** Upstream symlinks `rg` to `sprig` for `buzz-dev-mcp`, and
  this image keeps that for parity. If search misbehaves inside an agent, this is
  the first thing to suspect.
- **`sprig` must be static** to run unmodified regardless of base libc. Verified
  directly (`ldd`/`file`: `static-pie linked`, "statically linked" — zero runtime
  dependency on glibc or musl) as well as asserted at build time
  (`sprig --version` in the last `RUN` step), so a wrong assumption fails the
  build rather than shipping.
- **A `CURSOR_API_KEY` in a cluster Secret is a metered credential on a personal
  account.** It authenticates as that account and drains it directly — inventory
  and rotate it accordingly (Vigil's Domain #2).
- **The workspace is probably ephemeral.** The provider's config schema exposes no
  PersistentVolumeClaim field, and Buzz's own agent describes itself as having
  "no persistence." Assume nothing written inside the pod survives it until
  proven otherwise. Acceptable for this runtime specifically: a cursor-runtime
  agent's durable state lives in the channel, git, and Cursor's own side, not the
  pod's filesystem.

## References

- Upstream image: [`block/buzz`](https://github.com/block/buzz) → `Dockerfile.sprig`
- Sibling image: [`i258-net/buzz-claude-image`](https://github.com/i258-net/buzz-claude-image)
- Release introducing the backend: Buzz 0.5.4, `feat(k8s): Kubernetes backend plugin + desktop deploy path (#4289)`
- `I25-68` (k8s backend pilot), `I25-69` (this image) in `i258-net/dotbuzz`'s `PLANS/ISSUES/`
