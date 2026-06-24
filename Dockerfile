# ---- Stage 1: build the Zig bot ----
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Pinned to 0.13.0 deliberately - 0.16+ changed std.process/I/O significantly,
# and this is the version the rest of this project was written/tested against.
RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.13.0/zig-linux-x86_64-0.13.0.tar.xz \
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
    xvfb x11vnc \
    pulseaudio pulseaudio-utils libasound2-plugins alsa-utils \
    ffmpeg xdotool \
    openssh-client sshpass \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/soundbot

COPY --from=builder /src/zig-out/bin/soundbot ./soundbot
RUN chmod +x ./soundbot

# Sound files and the TS6 client are NOT baked into the image - they're mounted
# in at runtime (see docker-compose.soundbot.yml). Sounds because they're your
# personal content with no reason to live in a public repo/image; the TS6 client
# because of licensing (get it from teamspeak.com yourself, not a mirror, and
# never commit/publish it). These mkdirs just give the entrypoint stable mount points.
RUN mkdir -p ./sounds ./teamspeak-client

COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
