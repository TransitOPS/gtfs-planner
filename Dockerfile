# syntax=docker/dockerfile:1

# https://hub.docker.com/r/hexpm/elixir
ARG ELIXIR_VERSION=1.19.2
ARG ERLANG_VERSION=28.1.1

# https://gallery.ecr.aws/docker/library/debian
ARG DEBIAN_RELEASE=bookworm
ARG DEBIAN_VERSION=${DEBIAN_RELEASE}-20251103

FROM hexpm/elixir:$ELIXIR_VERSION-erlang-$ERLANG_VERSION-debian-$DEBIAN_VERSION AS elixir-builder

ENV LANG=C.UTF-8 \
    MIX_ENV=prod

RUN apt-get update --allow-releaseinfo-change && apt-get install -y --no-install-recommends ca-certificates curl git gnupg \
    build-essential

RUN mix local.hex --force && mix local.rebar --force

WORKDIR /app

COPY mix.exs mix.exs
COPY mix.lock mix.lock

RUN mix do deps.get --only prod

COPY config/config.exs config/
COPY config/prod.exs config/

RUN mix deps.compile

COPY lib lib
COPY priv priv
RUN mkdir -p priv/static/uploads
RUN mix compile

COPY assets assets
RUN mix assets.setup
RUN chmod +x /app/_build/esbuild-* /app/_build/tailwind-* 2>/dev/null || true
RUN mix assets.deploy

COPY config/runtime.exs config
COPY rel rel

RUN curl https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem > priv/repo/rds.pem
RUN mix release

FROM public.ecr.aws/docker/library/debian:${DEBIAN_VERSION}-slim AS release

WORKDIR /app
RUN chown nobody /app

EXPOSE 4000 4369 46942
ENV MIX_ENV=prod TERM=xterm LANG="C.UTF-8" PORT=4000

COPY --from=elixir-builder --chown=nobody:root /app/_build/prod/rel/gtfs_planner .

# Install dependencies including Java 21 from Eclipse Temurin
RUN apt-get update --allow-releaseinfo-change && apt-get upgrade -y --no-install-recommends && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    dumb-init \
    gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /etc/apt/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends temurin-21-jre \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives && \
    export DATABASE_URL= SECRET_KEY_BASE= GEOAPIFY_API_KEY= && \
    /app/bin/gtfs_planner eval "[_ | _] = :crypto.supports()" || exit 1 && \
    /app/bin/gtfs_planner eval ":ok = :public_key.cacerts_load()" || exit 1

# Install OpenTripPlanner 2.8.1 (not started automatically)
RUN mkdir -p /opt/otp/data && \
    curl -fL --retry 3 --retry-delay 2 -o /opt/otp/otp.jar \
    "https://github.com/opentripplanner/OpenTripPlanner/releases/download/v2.8.1/otp-shaded-2.8.1.jar" && \
    curl -fL --retry 3 --retry-delay 2 -o /opt/otp/data/philadelphia.osm.pbf \
    "https://download.bbbike.org/osm/bbbike/Philadelphia/Philadelphia.osm.pbf" && \
    chown -R nobody:root /opt/otp

# Install MobilityData GTFS Validator 7.1.0 (not started automatically)
RUN mkdir -p /opt/gtfs-validator && \
    curl -L -o /opt/gtfs-validator/gtfs-validator-cli.jar \
    "https://github.com/MobilityData/gtfs-validator/releases/download/v7.1.0/gtfs-validator-7.1.0-cli.jar" && \
    chown -R nobody:root /opt/gtfs-validator

USER nobody

ENTRYPOINT ["/usr/bin/dumb-init", "/app/bin/gtfs_planner"]
HEALTHCHECK CMD ["sh", "-c", "curl -fsS http://127.0.0.1:$PORT/health"]
CMD ["start"]
