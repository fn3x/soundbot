# soundbot

CI builds and pushes the image. The host only needs two folders it can't get
from a public repo: the licensed TS6 client binary, and your personal sound
files. Everything else — Xvfb, PulseAudio, ffmpeg, xdotool, the Zig bot
itself — lives inside the image.

## Repo layout

```
your-repo/
├── .github/workflows/docker-build.yml   <- builds + pushes to GHCR on push to main
├── soundbot/
│   ├── Dockerfile
│   ├── build.zig
│   ├── src/
│   │   ├── main.zig        (entrypoint + chat dispatch loop)
│   │   ├── config.zig      (env-var loading)
│   │   ├── ts_protocol.zig (TS3/TS6 string escaping, field extraction)
│   │   ├── sounds.zig      (sound-file lookup, !sounds list)
│   │   ├── query.zig       (ServerQuery I/O, chat replies, client/channel lookups)
│   │   ├── playback.zig    (queue, pitch/speed effects, the player thread)
│   │   ├── tts.zig         (Amazon Polly via the AWS CLI)
│   │   └── youtube.zig     (yt-dlp playback)
│   └── scripts/entrypoint.sh
└── docker-compose.soundbot.yml          <- for the HOST, not really part of the image build
```

Push this to GitHub, and the workflow builds + pushes
`ghcr.io/<your-github-username>/<repo-name>:latest` automatically.

**GHCR packages are private by default.** Either:
- make the package public (repo → Packages → the package → Package settings → Change visibility), or
- on the VPS, `docker login ghcr.io` with a Personal Access Token that has `read:packages` scope, before pulling.

## What the host actually needs

```
deploy-dir/
├── docker-compose.yml          ← your existing TS6 server compose file, untouched
├── docker-compose.soundbot.yml ← copy from this repo
├── .env                        ← secrets + image reference, you create this
├── teamspeak-client/           ← you provide: download from teamspeak.com yourself, extract here
└── sounds/                     ← you provide: your sound files, named soundN.ext or anything.ext
```

That's it — no Zig, no apt installs, no build step on the VPS at all.

### `.env`

```
SOUNDBOT_IMAGE=ghcr.io/yourname/yourrepo:latest
TS_SSH_PASS=<password from queryloginadd>
TS_CHANNEL_ID=2
TS_VOICE_NICKNAME=SoundBot

# For !ttsg/!ttsk/!ttsb/!tts (Amazon Polly) - omit these and the tts commands
# just fail with an auth error in the logs; everything else still works fine.
AWS_ACCESS_KEY_ID=<from an IAM user with polly:SynthesizeSpeech permission>
AWS_SECRET_ACCESS_KEY=<...>
AWS_DEFAULT_REGION=us-east-1
```

### ServerQuery account (one-time, on the TS6 server itself)

```
use 0
queryloginadd client_login_name=soundbot
use 1
servergroupaddclient sgid=2 cldbid=<cldbid from the line above>
```

### Start it

```bash
docker compose -f docker-compose.yml -f docker-compose.soundbot.yml pull
docker compose -f docker-compose.yml -f docker-compose.soundbot.yml up -d
```

## One-time manual setup (the part that isn't automated)

The TS6 client needs to connect and have its capture device set once:

```bash
ssh -L 5900:<container-ip>:5900 youruser@your-vps
```
(`docker inspect soundbot --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'` for the IP)

VNC to `localhost:5900` → connect to `teamspeak:9987` → join your channel →
sign into a myTS account → create/select an identity named to match
`TS_VOICE_NICKNAME` → set capture device to `ts_bot_sink` (or its monitor).

This is saved to the `soundbot-ts-profile` volume (survives restarts and
`docker compose down`, not `down -v`). **Whether the client actually
auto-reconnects after a restart without redoing this is unverified** — worth
testing deliberately rather than assuming.

## Updating

Push to `main` → CI rebuilds the image → on the VPS:
```bash
docker compose -f docker-compose.yml -f docker-compose.soundbot.yml pull
docker compose -f docker-compose.yml -f docker-compose.soundbot.yml up -d
```

## Chat commands
- `!help` — replies in chat with the full command reference
- `!sound1`, `!test_sound`, etc. — plays the matching file; queued if something's already playing
- `!du` (with `du1.mp3`/`du2.mp3`/... present) — plays one of the numbered siblings at random
- `!sounds` — replies in chat listing every available trigger name
- `!stop` — clears the queue, stops whatever's currently playing
- `!join` — moves the bot to your current channel (works from a channel's chat or the "Server" chat tab)
- `!join <channel_id>` — moves it to a specific channel regardless of where typed
- `!chance <0-100>` — % chance a played sound gets pitch+speed shifted
- `!slow <0.5-2.0>` / `!fast <0.5-2.0>` — how much, when it does (0.7/1.3 by default)
- `!chancereverb <0-100>` — % chance a played sound gets reverb, completely
  independent of `!chance` - a sound can be slowed *and* reverby, sped up *and*
  reverby, or reverby on its own
- `!reverbamount <0-100>` — how much reverb, when it does (50 by default; maps
  directly to sox's "reverberance" parameter)
- `!tts[g|b|jo|ma|sa|am|em|ju|ni|ca|m|t] <text>` —
  text-to-speech via Amazon Polly: Giorgio, Brian, Joanna, Matthew, Salli, Amy,
  Emma, Justin, Nicole, Carla, Maxim, Tatyana (all standard-engine, non-neural voices). `!tts <text>`
  picks one of these at random. Capped at 150 characters - longer input is
  silently truncated, not rejected. Real AWS cost per character past the free
  tier - worth keeping an eye on usage if this gets used a lot. The IAM user
  behind the access key needs `polly:SynthesizeSpeech` permission at minimum.
- `!yt <url or search query>` — downloads audio via yt-dlp and queues it like
  any other sound. A bare URL is used as-is; anything else is treated as a
  YouTube search, taking the top result. Plays the **full track by default** -
  `!ytlength <seconds>` sets a cap if you want one for a specific use case
  (e.g. `!ytlength 30` for clips), `!ytlength 0` removes it again. A cap also
  limits download time and how long the bot occupies the queue/PTT on one
  clip - worth setting one if the channel gets used for long videos/streams
  rather than songs. Worth knowing: yt-dlp supports over a thousand sites, not
  just YouTube, so this isn't actually restricted to youtube.com links -
  anything yt-dlp recognizes will work.

## Logs

```bash
docker logs -f soundbot
```

## Known gaps, stated plainly

- Ctrl+C/container-stop sends a clean `quit` to the ServerQuery session, but
  doesn't kill an in-flight `ffmpeg`/release the PTT key first.
- A failed step inside `!join`'s multi-command sequence aborts the whole bot
  rather than failing just that command.
- `!sounds`/`!voices` reply in chat, but most other commands (`!tts`, `!yt`,
  `!chance`, etc.) only log to `docker logs` - no chat confirmation that they
  actually worked.
- `!yt` lets anyone in the channel make the bot fetch from the open internet.
  There's a length cap but no rate limit, cooldown, or per-user restriction -
  worth keeping in mind if the server has people you don't fully trust.
