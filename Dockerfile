# syntax=docker/dockerfile:1.4
# Build stage
FROM elixir:1.16-otp-26-alpine AS builder

RUN apk add --no-cache build-base git nodejs npm

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

COPY config config
COPY priv priv
COPY lib lib
COPY assets assets
COPY rel rel

RUN --mount=type=secret,id=SESSION_SIGNING_SALT \
    --mount=type=secret,id=SESSION_ENCRYPTION_SALT \
    export SESSION_SIGNING_SALT=$(cat /run/secrets/SESSION_SIGNING_SALT) && \
    export SESSION_ENCRYPTION_SALT=$(cat /run/secrets/SESSION_ENCRYPTION_SALT) && \
    mix assets.deploy && mix compile && mix release

# Runtime stage
FROM alpine:3.19 AS runtime

RUN apk add --no-cache libstdc++ openssl ncurses-libs wget && \
    addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/ad_butler ./

RUN chown -R appuser:appgroup /app
USER appuser

ENV PHX_SERVER=true

EXPOSE 4000

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://localhost:4000/health/liveness || exit 1

CMD ["/app/bin/ad_butler", "start"]
