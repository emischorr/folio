# Once:
# - docker buildx create --name multiarch --driver docker-container --use
# - docker login ghcr.io
# build & push it:
# docker buildx build --platform=linux/amd64,linux/arm64 --no-cache -t ghcr.io/emischorr/folio:0.1.0 -t ghcr.io/emischorr/folio:latest --push .

ARG RELEASE_NAME=folio

ARG ELIXIR_VERSION="1.20.3"
ARG ERLANG_VERSION="28.5.0.5"
ARG ALPINE_VERSION="3.23.5"

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${ERLANG_VERSION}-alpine-${ALPINE_VERSION}"
ARG RUNNER_IMAGE="alpine:${ALPINE_VERSION}"

# -----------------------------------------------------------------------------
ARG MIX_ENV="prod"

# build stage
FROM ${BUILDER_IMAGE} AS builder

# install build dependencies
RUN apk add --no-cache build-base git python3 curl

# sets work dir
WORKDIR /app

# Needed for cross platform builds with newer erlang (27+). Also prevent Erlang from trying to initialize a TTY during the build
# see: https://elixirforum.com/t/mix-deps-get-memory-explosion-when-doing-cross-platform-docker-build/57157/3
ENV ERL_FLAGS="-noinput +JPperf true"

# install hex + rebar
RUN mix local.hex --force && \
  mix local.rebar --force

# redeclare it as it is lost after the FROM above
ARG MIX_ENV
ENV MIX_ENV="${MIX_ENV}"

COPY . /app

# install mix dependencies
RUN mix deps.get --only $MIX_ENV

# compile dependencies
RUN mix deps.compile

# compile project
RUN mix compile

# Compile assets
RUN mix assets.deploy

# assemble release
RUN mix release $RELEASE_NAME


# -----------------------------------------------------------------------------

# app stage
FROM ${RUNNER_IMAGE} AS runner

ARG RELEASE_NAME
ARG MIX_ENV

# install runtime dependencies
RUN apk add --no-cache libstdc++ openssl ncurses-libs ca-certificates

ENV USER="elixir"

WORKDIR "/app"

# Create unprivileged user to run the release
RUN \
  addgroup \
  -g 1000 \
  -S "${USER}" \
  && adduser \
  -s /bin/sh \
  -u 1000 \
  -G "${USER}" \
  -h "/home/${USER}" \
  -D "${USER}" \
  && su "${USER}" \
  && chown "${USER}":"${USER}" /app

# run as user
USER "${USER}"

# copy release executables
COPY --from=builder --chown="${USER}":"${USER}" /app/_build/"${MIX_ENV}"/rel/"${RELEASE_NAME}" ./

CMD ["/app/bin/server"]
