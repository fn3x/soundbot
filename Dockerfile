# ---- Stage 1: build the Zig bot ----
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pinned to 0.13.0 deliberately - 0.16+ changed std.process/I/O significantly,
# and this is the version the rest of this project was written/tested against.
RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

WORKDIR /src
COPY build.zig ./
COPY src ./src

# musl target = fully static binary, no glibc-version or dynamic-linker-path
# dependency on whatever runs the final image.
RUN /opt/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# ---- Stage 2: runtime ----
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb x11vnc x11-utils \
    pulseaudio pulseaudio-utils libasound2-plugins alsa-utils \
    ffmpeg xdotool mpg123 sox libsox-fmt-all \
    openssh-client sshpass \
    ca-certificates curl unzip util-linux awscli \
    libnotify4 libatomic1 libnspr4 libnss3 \
    libatk1.0-0 libatk-bridge2.0-0 libcups2 libatspi2.0-0 \
    libxcomposite1 \
    && rm -rf /var/lib/apt/lists/*

# PulseAudio actively refuses to run as root (by design - it's meant to be a
# per-user session daemon), so the whole container runs as a real unprivileged
# user instead of relying on a flag/workaround.
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /opt/soundbot

COPY --from=builder /src/zig-out/bin/soundbot ./soundbot
RUN chmod +x ./soundbot

# Sound files and the TS6 client are NOT baked into the image - they're mounted
# in at runtime (see docker-compose.soundbot.yml). Sounds because they're your
# personal content with no reason to live in a public repo/image; the TS6 client
# because of licensing (get it from teamspeak.com yourself, not a mirror, and
# never commit/publish it). These mkdirs just give the entrypoint stable mount points.
RUN mkdir -p ./sounds ./teamspeak-client

# Standalone binary, not the apt package - distro packages of yt-dlp
# consistently lag behind YouTube's own site changes, and the project's own
# docs recommend this exact approach for that reason. It's a self-contained
# executable (bundles its own Python interpreter), so no separate python3
# install is needed - it just needs ffmpeg on PATH, which is already installed.
RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
    && chmod a+rx /usr/local/bin/yt-dlp

# As of yt-dlp 2025.11.12, an external JS runtime is a hard requirement for
# full YouTube support - without one, only image formats are available
# ("Requested format is not available"). Deno is yt-dlp's top recommendation
# (sandboxed, no filesystem/network access by default) and is auto-detected
# with zero extra flags once it's on PATH. The yt-dlp-ejs scripts that drive
# it are already bundled into the standalone binary above, so nothing else is
# needed beyond the runtime itself. DENO_INSTALL=/usr/local puts the binary
# straight at /usr/local/bin/deno, already on PATH.
RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh

# Right ownership on appuser's home dir *before* a volume ever gets mounted
# there - Docker copies a fresh named volume's initial permissions from
# whatever already exists in the image at that path, so this is what makes
# the persisted profile actually writable by appuser later. (The entrypoint
# also re-chowns this at container start, since a volume mount overrides
# whatever's baked in here anyway - this is just the baseline for that.)
RUN chown -R appuser:appuser /home/appuser /opt/soundbot

# Xvfb normally relies on root to create this socket directory - since the
# container now runs as a regular user, it has to already exist with the
# standard sticky-bit world-writable permissions X11 expects.
RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/entrypoint-inner.sh /entrypoint-inner.sh
RUN chmod +x /entrypoint.sh /entrypoint-inner.sh

ENTRYPOINT ["/entrypoint.sh"]
