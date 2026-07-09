#!/bin/bash
set -e

export DISPLAY="${DISPLAY:-:99}"
SINK_NAME="${TS_SINK:-ts_bot_sink}"
DISPLAY_NUM="${DISPLAY#:}"

# Clean up anything left behind by a previously crashed Xvfb in this same
# container (restart != recreation, so /tmp survives between the two).
rm -f "/tmp/.X${DISPLAY_NUM}-lock" "/tmp/.X11-unix/X${DISPLAY_NUM}"

echo "[entrypoint] starting Xvfb on $DISPLAY"
Xvfb "$DISPLAY" -screen 0 1024x768x16 &
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
# Larger fragments prevent the "Underflow occurred on device" warnings that
# appear in headless/virtual-sink setups when PulseAudio runs out of data
# faster than the source produces it. Default fragments (4x5ms=20ms) are
# tuned for real hardware with DMA interrupts; virtual sinks need more headroom.
mkdir -p /etc/pulse
cat > /etc/pulse/daemon.conf << PULSE_EOF
default-sample-rate = 48000
default-fragments = 8
default-fragment-size-msec = 25
PULSE_EOF
pulseaudio --start --exit-idle-time=-1
sleep 1
pactl load-module module-null-sink sink_name="$SINK_NAME" sink_properties=device.description="$SINK_NAME" 2>/dev/null || true
pactl set-default-source "${SINK_NAME}.monitor"
 
# A second sink for the TS3 client's own playback output (what it receives
# from other speakers in the channel). Without this, the client would output
# to the same sink used as its mic source, creating a feedback loop.
pactl load-module module-null-sink sink_name="${SINK_NAME}_output" sink_properties=device.description="${SINK_NAME}_output" 2>/dev/null || true
pactl set-default-sink "${SINK_NAME}_output"
 
echo "[entrypoint] launching TS3 client"
cd /opt/soundbot/teamspeak-client
if [ ! -x ./ts3client_runscript.sh ]; then
    echo "[entrypoint] ERROR: /opt/soundbot/teamspeak-client/ts3client_runscript.sh not found or not executable."
    echo "[entrypoint] Did you mount your teamspeak-client/ folder into this container? See README."
    exit 1
fi
 
# The TS3 client connects automatically to whatever bookmark has
# "Connect on startup" enabled - set this up once via VNC during
# the one-time manual setup, and it persists in the profile volume.
DISPLAY="$DISPLAY" ./ts3client_runscript.sh &
sleep 5
 
echo "[entrypoint] starting soundbot"
cd /opt/soundbot
exec ./soundbot
