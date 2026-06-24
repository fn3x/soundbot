#!/bin/bash
set -e

export DISPLAY="${DISPLAY:-:99}"
SINK_NAME="${TS_SINK:-ts_bot_sink}"
DISPLAY_NUM="${DISPLAY#:}"

# Clean up anything left behind by a previously crashed Xvfb in this same
# container (restart != recreation, so /tmp survives between the two).
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

echo "[entrypoint] starting Xvfb on $DISPLAY"
Xvfb "$DISPLAY" -screen 0 1024x768x24 &
for i in $(seq 1 20); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
        echo "[entrypoint] Xvfb is ready"
        break
    fi
    sleep 0.5
done

echo "[entrypoint] starting x11vnc (for one-time manual setup / occasional debugging)"
x11vnc -display "$DISPLAY" -nopw -listen 0.0.0.0 -xkb -forever -shared &

echo "[entrypoint] starting PulseAudio and creating virtual sink '$SINK_NAME'"
pulseaudio --start --exit-idle-time=-1
sleep 1
pactl load-module module-null-sink sink_name="$SINK_NAME" sink_properties=device.description="$SINK_NAME" 2>/dev/null || true
pactl set-default-source "${SINK_NAME}.monitor"

echo "[entrypoint] launching TS6 client"
cd /opt/soundbot/teamspeak-client
if [ ! -x ./TeamSpeak ]; then
    echo "[entrypoint] ERROR: /opt/soundbot/teamspeak-client/TeamSpeak not found or not executable."
    echo "[entrypoint] Did you mount your teamspeak-client/ folder into this container? See README."
    exit 1
fi
DISPLAY="$DISPLAY" ./TeamSpeak --no-sandbox &
sleep 5

echo "[entrypoint] starting soundbot"
cd /opt/soundbot
exec ./soundbot
