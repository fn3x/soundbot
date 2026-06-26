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
- `!default` — reset effect and master settings to default values
- `!status` — show current effect and master settings
- `!sound1`, `!test_sound`, etc. — plays the matching file; queued if something's already playing
- `!r` or `!random` - queue a random sound
- `!sequence <name1> <name2>` - queue a sequence of sounds
- `!du` (with `du1.mp3`/`du2.mp3`/... present) — plays one of the numbered siblings at random
- `!sounds` — replies in chat listing every available trigger name
- `!stop` — clears the queue, stops whatever's currently playing
- `!skip` - skip current sound or cancel an in-progress download; queue keeps playing
- `!join` — moves the bot to your current channel (works from a channel's chat or the "Server" chat tab)
- `!join <channel_id>` — moves it to a specific channel regardless of where typed
- `!chance <0-100>` — % chance a played sound gets pitch+speed shifted
- `!slow <0.5-2.0>` / `!fast <0.5-2.0>` — how much, when it does (0.7/1.3 by default)
- `!chancereverb <0-100>` — % chance a played sound gets reverb, completely
  independent of `!chance` - a sound can be slowed *and* reverby, sped up *and*
  reverby, or reverby on its own
- `!reverbamount <0-100>` — how much reverb, when it does (50 by default; maps
  directly to sox's "reverberance" parameter)
- `!volume <0-100>` — overall volume (100 by default). Unlike `!chance`/`!chancereverb`,
  this isn't randomly rolled and isn't exempted for `!yt` audio - it's a
  deliberate, persistent setting that applies to absolutely everything
- `!compressor on`/`!compressor off` — evens out loud/quiet sounds (off by
  default). `!compressor <threshold 1-100> <ratio 1-20> <makeup 1-64>` tunes
  and enables it in one step, e.g. `!compressor 10 4 1` (the defaults).
  Threshold is on the same 0-100 scale as everything else in this bot,
  converted internally to ffmpeg's actual linear 0-1 range rather than
  exposing that directly. Attack (20ms) and release (250ms) stay fixed -
  three tunable values felt like the right amount of knobs, not every
  parameter `acompressor` supports. Exempted for !yt audio specifically -
  same reasoning as the random pitch/reverb effects: squashing the dynamics
  of an entire song is a bigger, more disruptive change than it is on a short
  clip.
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

**If `!yt` fails with "Sign in to confirm you're not a bot"**: this is YouTube's
bot-detection, and it hits datacenter/VPS IPs (exactly what this runs on)
especially hard. The bot already spoofs the Android client as the most
commonly reported fix that needs no credentials - if that's not enough for a
given video, the more reliable fallback is supplying real cookies from a
logged-in YouTube account:
 
1. On your own PC, while logged into YouTube in a browser, export cookies to a
   `cookies.txt` file (a "Get cookies.txt" browser extension is the easiest way).
2. Copy that file onto the VPS, next to `docker-compose.soundbot.yml`, named
   exactly `cookies.txt`.
3. That's it - `docker-compose.soundbot.yml` already declares it as a proper
   Docker Compose **secret** (not a generic bind-mount), mounted read-only at
   `/run/secrets/yt_cookies` with tighter default permissions than a regular
   volume gets. `TS_YT_COOKIES_PATH` already defaults to that path.
4. `docker compose -f docker-compose.yml -f docker-compose.soundbot.yml up -d`
   to pick it up.

**Important behavior change**: because the secret is declared at the top level,
`cookies.txt` is now a file Compose expects to exist for *any* `up`, not just
when you actually want cookies enabled - if you don't want to use this feature
yet, create an empty placeholder (`touch cookies.txt`) so Compose doesn't
refuse to start the whole stack over a missing file. An empty file is harmless
- yt-dlp just finds no cookies in it and proceeds without authentication,
same as if `TS_YT_COOKIES_PATH` were never set at all.
If you'd rather avoid that requirement entirely, the bot still also checks the
old conventional bind-mount path (`/opt/soundbot/cookies.txt`) as a fallback if
you set things up that way instead - but the secret is the better-practice
default now.
 
Worth deciding deliberately rather than defaulting into it: this puts a real
account's session on the server, with some risk of that account getting
rate-limited or flagged if it's used this way a lot. Also worth knowing:
exported cookies are a frozen snapshot, not a live link to your browser
session - they'll eventually stop working as Google rotates session state
server-side, and `!yt` failing with this same error again later is the
symptom, not a new bug. Re-exporting a fresh `cookies.txt` is the fix each
time. A secondary account dedicated to this is worth considering over your
main one, given that recurring need.

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
- `!yt`/`!tts*` run on their own background thread specifically so `!stop` can
  actually interrupt an in-progress download/synthesis call (without that, the
  chat-reading loop itself would be blocked for the whole call, meaning
  `!stop` couldn't even be read until it finished anyway). One real limitation
  from that: if two such calls happen to be in flight at once (e.g. `!yt` and
  `!ttsb` fired back to back before either finishes), they share a single
  pid-tracking slot, so `!stop` reliably kills whichever one most recently
  claimed it, not necessarily both.
