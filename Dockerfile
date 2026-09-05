# syntax=docker/dockerfile:1
#
# Builds the Godot web export and packages it as a self-contained web server.
#
# --- Docker crash course, in the order things happen -------------------------
#
# A Dockerfile is a recipe for an *image* (a frozen filesystem + a default
# command). `docker build` runs the recipe; `docker run` starts a *container*
# from the resulting image.
#
# Each instruction below creates a layer, and Docker caches layers: if nothing
# an instruction depends on has changed, it reuses the previous result. That is
# why the expensive, rarely-changing steps (downloading toolchains) come BEFORE
# `COPY . .` — otherwise editing one .gd file would re-download Godot.
#
# This is a *multi-stage* build: several `FROM` lines, each starting a fresh
# filesystem. Stages can copy files out of earlier stages. We need it because
# Emscripten and Godot are two large, unrelated toolchains, and because the
# final image should contain neither of them — just a web server and the
# compressed output, instead of several GB of compilers.
#
#   Stage 1 "wasm"    emcc      -> nbody.js + nbody.wasm
#   Stage 2 "export"  godot     -> build/web/, then pre-compressed
#   Stage 3 (final)   caddy     -> serves build/web/ on port 80
#
# Build it:   docker build -t orrery .
# Run it:     docker run --rm -p 8080:80 orrery    then open http://localhost:8080
#
# =============================================================================
# Stage 1 — compile the N-body physics kernel to WebAssembly
# =============================================================================
# `FROM <image> AS <name>` starts a stage from a published image. The official
# emsdk image already has the Emscripten toolchain installed and on PATH.
# The tag is pinned on purpose: `latest` would make your builds change silently
# under you. Any recent emsdk works here (the kernel is independent of Godot's
# own runtime), so bumping this number is safe.
FROM emscripten/emsdk:3.1.64 AS wasm

# WORKDIR is `mkdir -p` plus `cd`, and it persists for the rest of the stage.
WORKDIR /src

# Copy in ONLY what this stage needs. Two reasons: caching (this layer is
# invalidated only when the C++ actually changes) and speed. The web kernel is
# plain C++ with no Godot dependency, so native/src is genuinely all it takes.
COPY native/src ./native/src
COPY scripts/build-web.sh ./scripts/

# RUN executes a command *at build time* and freezes the result into the image.
# Invoked as `bash <script>` rather than `./<script>` on purpose: that works
# regardless of whether the executable bit survived being authored on Windows
# and round-tripped through git.
RUN bash scripts/build-web.sh --wasm-only


# =============================================================================
# Stage 2 — export the Godot project to a web build
# =============================================================================
# Fresh filesystem again — nothing from stage 1 is here unless we copy it in.
FROM debian:bookworm-slim AS export

# ARG declares a build-time variable. Override it without editing this file:
#   docker build --build-arg GODOT_VERSION=4.5 -t orrery .
# This MUST match the Godot version the project was authored in — export
# templates are version-specific and Godot refuses to mix them.
ARG GODOT_VERSION=4.4.1
ARG GODOT_RELEASE=stable

# Why `apt-get update` and `install` are chained into one RUN: each RUN is a
# separately cached layer, so a cached `update` paired with a later `install`
# would try to fetch package versions that no longer exist. The
# `rm -rf /var/lib/apt/lists/*` cleanup has to happen in the SAME RUN to help at
# all, because a later layer can hide files but never shrink an earlier one.
#   curl/unzip     fetch and unpack Godot
#   brotli/gzip    pre-compress the output (see the end of this stage)
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl unzip brotli gzip \
    && rm -rf /var/lib/apt/lists/*

# Install the Godot editor binary (it doubles as the headless CLI exporter) and
# the export templates — the prebuilt engine binaries that get stamped together
# with your game data to produce index.wasm. Godot looks for them at this exact
# path, and the directory name must be "<version>.<release>".
RUN set -eux; \
    base="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-${GODOT_RELEASE}"; \
    name="Godot_v${GODOT_VERSION}-${GODOT_RELEASE}"; \
    curl -fsSL -o /tmp/godot.zip "${base}/${name}_linux.x86_64.zip"; \
    unzip -q /tmp/godot.zip -d /tmp; \
    mv "/tmp/${name}_linux.x86_64" /usr/local/bin/godot; \
    chmod +x /usr/local/bin/godot; \
    curl -fsSL -o /tmp/templates.tpz "${base}/${name}_export_templates.tpz"; \
    unzip -q /tmp/templates.tpz -d /tmp; \
    tpl="/root/.local/share/godot/export_templates/${GODOT_VERSION}.${GODOT_RELEASE}"; \
    mkdir -p "$tpl"; \
    mv /tmp/templates/* "$tpl/"; \
    rm -rf /tmp/godot.zip /tmp/templates.tpz /tmp/templates

WORKDIR /src

# Now the part that changes on every commit. Everything above this line stays
# cached, so a normal code change rebuilds in seconds instead of re-downloading
# ~1 GB of toolchain. `.dockerignore` controls what `COPY . .` actually sends.
COPY . .

# Pull the compiled kernel out of stage 1. This is the payoff of multi-stage:
# we get those two output files without Emscripten existing in this filesystem.
COPY --from=wasm /src/native/web-wasm ./native/web-wasm

# Run the export. See scripts/build-web.sh for the two non-obvious steps it
# handles: importing resources (a clean checkout has no .godot/ cache, and
# without an import pass the export ships no assets), and temporarily moving
# bin/orrery_native.gdextension aside — it points at desktop/Android libraries
# that don't exist here, and the web build doesn't use it anyway.
RUN bash scripts/build-web.sh --export-only

# Pre-compress the big files. index.wasm is ~44 MB raw and Brotli takes it to
# roughly a fifth of that — this is the single most important thing for a usable
# first load. Doing it here means it happens ONCE at build time; the server then
# just picks the right file per request, instead of burning CPU re-compressing
# 44 MB on every cold visit.
#
# -k keeps the original alongside the .br/.gz (still needed for clients that
# don't accept the encoding). Only compressible types are listed — .png and
# friends are already compressed, so squeezing them again just wastes time.
# `brotli -q 11` is the slow step (a minute or two on the big wasm); drop to
# -q 9 if you would rather have faster CI than ~5% smaller files.
RUN find build/web -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.html' \
        -o -name '*.pck' -o -name '*.json' -o -name '*.svg' -o -name '*.css' \) \
        -exec brotli -k -q 11 {} + \
    && find build/web -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.html' \
        -o -name '*.pck' -o -name '*.json' -o -name '*.svg' -o -name '*.css' \) \
        -exec gzip -k -9 {} +


# =============================================================================
# Stage 3 — the image you actually deploy
# =============================================================================
# No `AS` name: the last stage is what `docker build` produces. Nothing from the
# stages above is included except the files explicitly copied in below, so what
# ships is a small web server plus the game, not a multi-gigabyte build env.
#
# Caddy rather than nginx for one concrete reason: serving pre-compressed Brotli
# is built in (`precompressed br`), whereas stock nginx has no Brotli module and
# would need a custom build. Caddy can also do automatic HTTPS, but this image
# deliberately speaks plain HTTP on :80 so it drops in behind whatever reverse
# proxy your Ubuntu box already runs. TLS is a front-door concern, not this
# container's job.
FROM caddy:2-alpine

# The server config, kept in its own file so it can be read on its own terms.
# See docker/Caddyfile for the compression and caching rules.
COPY docker/Caddyfile /etc/caddy/Caddyfile

# And finally the game — the only artifact that survives from stage 2.
COPY --from=export /src/build/web /srv

# Documentation only: EXPOSE publishes nothing by itself. You pick the host port
# at run time with `-p 8080:80`.
EXPOSE 80
