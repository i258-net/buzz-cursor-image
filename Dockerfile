# A Buzz agent image that runs Cursor's CLI (`cursor-agent`, in `acp` mode)
# instead of Buzz's built-in agent.
#
# The stock image (ghcr.io/block/buzz-sprig) ships one Rust multicall binary,
# `sprig`, and nothing else — no node, no `cursor-agent`. The harness inside
# it (`buzz-acp`) spawns whatever `BUZZ_ACP_AGENT_COMMAND` names, so a
# cursor-runtime agent deployed on the stock image dies the same way a
# claude-runtime one does on it (see i258-net/buzz-claude-image):
#
#     ERROR buzz_acp: agent failed to spawn: IO error: No such file or directory
#
# This image keeps the same harness and dev tooling, and adds cursor-agent.
#
# Why glibc and not Alpine: verified directly, not just inferred from Cursor
# calling it "a native binary." cursor-agent bundles its own Node.js runtime
# (no system node needed), and that bundled `node` binary is
# `ELF ... dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2` — the
# glibc dynamic linker path. Musl systems (Alpine) use /lib/ld-musl-*.so.1
# and lack this interpreter entirely; cursor-agent cannot run there.
#
# `sprig` is built on rust:alpine with openssl-libs-static, so it should be a
# fully static musl binary that runs unchanged here — that assumption is
# verified at build time by the RUN step below (also independently confirmed
# with `ldd`: "statically linked", zero libc dependency either way), which
# fails the build rather than shipping a broken image.
#
# cursor-agent has no official Docker image, and there is no version-pin flag
# or env var on Cursor's own install script (cursor.com/install, read in full
# — 203 lines, no integrity check at all). So rather than piping that script
# into bash at build time (silently following whatever's "latest" on rebuild
# day), this Dockerfile downloads from the exact versioned URL the script
# resolves to and verifies the tarball's sha256 before extracting — stricter
# than Cursor's own installer. Bumping the version is a two-ARG change plus a
# re-derived sha256. No third-party/community image is used here, ever
# (ghcr.io/redknife/cursor-cli was evaluated and rejected on supply-chain
# grounds during I25-69).

# Pin the stock image we lift `sprig` out of. Bump deliberately, not with :latest.
ARG SPRIG_IMAGE=ghcr.io/block/buzz-sprig@sha256:554990d94b103f1f366a8cfca1aa0c0f97e21e9928fb55e29bc9a4f07dce0460
FROM ${SPRIG_IMAGE} AS sprig

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241

ARG CURSOR_AGENT_VERSION=2026.08.04-aaa8809
ARG CURSOR_AGENT_TARBALL_SHA256=e282068dcb5cdd668b8ce2e3456c58be13bb64a834e1ad49f8534b5cd7aa2fe5

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      bash ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --create-home --home-dir /home/agent --shell /bin/bash agent \
 && install -d -o agent -g agent /workspace /home/agent

# cursor-agent, installed system-wide (not into a user $HOME) so it keeps
# working regardless of the provider's per-agent `run_as_user`. Directory
# layout borrows the official installer's own naming
# (versions/<version>/cursor-agent) purely for familiarity — nothing reads it
# by convention here, unlike the installer's own ~/.local/bin symlink dance.
RUN mkdir -p "/opt/cursor-agent/versions/${CURSOR_AGENT_VERSION}" \
 && curl -fSL "https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/x64/agent-cli-package.tar.gz" -o /tmp/cursor-agent.tar.gz \
 && echo "${CURSOR_AGENT_TARBALL_SHA256}  /tmp/cursor-agent.tar.gz" | sha256sum -c - \
 && tar --strip-components=1 -xzf /tmp/cursor-agent.tar.gz -C "/opt/cursor-agent/versions/${CURSOR_AGENT_VERSION}" \
 && rm /tmp/cursor-agent.tar.gz \
 && ln -s "/opt/cursor-agent/versions/${CURSOR_AGENT_VERSION}/cursor-agent" /usr/local/bin/cursor-agent \
 && ln -s "/opt/cursor-agent/versions/${CURSOR_AGENT_VERSION}/cursor-agent" /usr/local/bin/agent

# The harness, the developer MCP server, the buzz CLI and the git helpers.
# All of these are the same `sprig` binary under different argv[0] names.
COPY --from=sprig /usr/local/bin/sprig /usr/local/bin/sprig
COPY --from=sprig /usr/local/bin/sprig-entrypoint /usr/local/bin/sprig-entrypoint

# Same symlink set as the stock image, deliberately — including `rg`, which
# buzz-dev-mcp dispatches on. If cursor-agent ever misbehaves on search, this
# shadowing is the first thing to suspect (see README, Known risks).
RUN for name in \
      buzz-acp buzz-agent buzz-dev-mcp rg tree buzz \
      git-credential-nostr git-sign-nostr; do \
        ln -s sprig "/usr/local/bin/$name"; \
    done \
 && chmod 0755 /usr/local/bin/sprig /usr/local/bin/sprig-entrypoint \
 && git config --system gpg.format x509 \
 && git config --system gpg.x509.program /usr/local/bin/git-sign-nostr \
 && git config --system commit.gpgSign true \
 && git config --system tag.gpgSign true

# Fail the build here rather than ship an image whose harness or agent can't
# start. This is the load-bearing check on the "sprig is static musl" and
# "cursor-agent runs on glibc" assumptions above.
RUN set -eux; \
    /usr/local/bin/sprig --version; \
    buzz-acp --help >/dev/null 2>&1 || true; \
    command -v cursor-agent; \
    cursor-agent --version

ENV HOME=/home/agent \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin

WORKDIR /home/agent
USER agent
ENTRYPOINT ["/usr/local/bin/sprig-entrypoint"]
