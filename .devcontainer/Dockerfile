# Pinned to match .tool-versions (erlang 28.5.0.5, elixir 1.20.3-otp-28).
# Debian rather than Alpine: glibc, apt, and script(1) for a full PTY.
FROM hexpm/elixir:1.20.3-erlang-28.5.0.5-debian-trixie-20260824

RUN apt-get update && apt-get install -y --no-install-recommends \
      git build-essential inotify-tools postgresql-client ca-certificates \
      curl util-linux bsdextrautils \
    && rm -rf /var/lib/apt/lists/*

# Non-root, uid 1000: the devcontainer CLI remaps it to the workspace owner on
# Linux (updateRemoteUserUID), and CodeLead execs run as it via remoteUser.
# Without it, root-owned files in the worktree block teardown later.
RUN useradd -m -u 1000 -s /bin/bash dev

# Hex/rebar outside $HOME: CodeLead overrides HOME per task, so a toolchain
# living under ~ is invisible to agents.
# MIX_BUILD_ROOT off the shared workspace mount: a host checkout's _build holds
# darwin-compiled artifacts (NIFs, the esbuild/tailwind binaries) that would
# poison Linux builds, and vice versa.
ENV MIX_HOME=/opt/mix HEX_HOME=/opt/hex MIX_BUILD_ROOT=/opt/build LANG=C.UTF-8
RUN mkdir -p /opt/mix /opt/hex /opt/build \
    && chown -R dev:dev /opt/mix /opt/hex /opt/build

# The preview command runs under a login shell, which re-sources /etc/profile.
RUN printf 'export MIX_HOME=/opt/mix\nexport HEX_HOME=/opt/hex\nexport MIX_BUILD_ROOT=/opt/build\n' \
      > /etc/profile.d/mix.sh

USER dev
RUN mix local.hex --force && mix local.rebar --force
