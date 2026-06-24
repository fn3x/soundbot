#!/bin/bash
set -e

# This runs as root. Its only job is fixing ownership on whatever's mounted
# into appuser's home directory - chown'ing in the Dockerfile only affects the
# image's own baked-in layer; a volume mounted at that same path overrides it
# completely at container start. Without this, leftover root-owned data from
# before this container ran as non-root (or a fresh volume Docker initialized
# as root) is unreadable by appuser, which looks exactly like a missing/corrupt
# TS6 profile - hence having to log in again after every redeploy.
chown -R appuser:appuser /home/appuser

# setpriv changes the effective UID/GID but does NOT update these to match -
# without this, PulseAudio, the TS6 client's own profile-path detection, and
# anything else that derives its config/data location from $HOME would still
# think it's /root, which appuser has no permission to read or write.
export HOME=/home/appuser
export USER=appuser
export LOGNAME=appuser

exec setpriv --reuid=appuser --regid=appuser --init-groups /entrypoint-inner.sh
