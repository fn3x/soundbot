# ---- Stage 1: build the Zig bot ----
FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz

WORKDIR /src
COPY build.zig ./
COPY build.zig.zon ./
COPY src ./src

RUN /opt/zig/zig build --fetch
RUN /opt/zig/zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# ---- Stage 2: runtime ----
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    xvfb x11vnc x11-utils \
    pulseaudio pulseaudio-utils libasound2-plugins alsa-utils \
    ffmpeg mpg123 sox libsox-fmt-all \
    openssh-client sshpass \
    ca-certificates curl unzip util-linux awscli \
    libqt5widgets5 libqt5multimedia5 libqt5x11extras5 libqt5dbus5 libqt5network5 \
    libopenal1 \
    && rm -rf /var/lib/apt/lists/*

# PulseAudio actively refuses to run as root (by design), so the whole
# container runs as a real unprivileged user instead.
RUN useradd --create-home --shell /bin/bash appuser

WORKDIR /opt/soundbot

COPY --from=builder /src/zig-out/bin/soundbot ./soundbot
RUN chmod +x ./soundbot

# Sound files and the TS3 client are NOT baked into the image.
# The TS3 client: download from teamspeak.com yourself, extract here.
RUN mkdir -p ./sounds ./teamspeak-client

RUN curl -L https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp -o /usr/local/bin/yt-dlp \
    && chmod a+rx /usr/local/bin/yt-dlp

RUN curl -fsSL https://deno.land/install.sh | DENO_INSTALL=/usr/local sh

RUN chown -R appuser:appuser /home/appuser /opt/soundbot

RUN mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

COPY scripts/entrypoint.sh /entrypoint.sh
COPY scripts/entrypoint-inner.sh /entrypoint-inner.sh
RUN chmod +x /entrypoint.sh /entrypoint-inner.sh

ENTRYPOINT ["/entrypoint.sh"]
