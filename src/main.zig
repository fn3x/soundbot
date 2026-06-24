const std = @import("std");

// ---- Config, loaded from env vars (with defaults for the quick local test) ----

const Config = struct {
    ssh_host: []const u8,
    ssh_port: []const u8,
    ssh_user: []const u8,
    ssh_pass: []const u8,
    vserver_id: []const u8,
    channel_id: []const u8,
    sounds_dir: []const u8,
    sink: []const u8,
    ptt_key: []const u8,
    voice_nickname: []const u8,

    fn load(allocator: std.mem.Allocator) !Config {
        return Config{
            .ssh_host = try getEnvOr(allocator, "TS_SSH_HOST", "127.0.0.1"),
            .ssh_port = try getEnvOr(allocator, "TS_SSH_PORT", "10022"),
            .ssh_user = try getEnvOr(allocator, "TS_SSH_USER", "soundbot"),
            .ssh_pass = try getEnvRequired(allocator, "TS_SSH_PASS"),
            .vserver_id = try getEnvOr(allocator, "TS_VSERVER_ID", "1"),
            .channel_id = try getEnvRequired(allocator, "TS_CHANNEL_ID"),
            .sounds_dir = try getEnvOr(allocator, "TS_SOUNDS_DIR", "sounds"),
            .sink = try getEnvOr(allocator, "TS_SINK", "ts_bot_sink"),
            .ptt_key = try getEnvOr(allocator, "TS_PTT_KEY", "F12"),
            .voice_nickname = try getEnvRequired(allocator, "TS_VOICE_NICKNAME"),
        };
    }
};

fn getEnvOr(allocator: std.mem.Allocator, name: []const u8, default: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => try allocator.dupe(u8, default),
        else => return err,
    };
}

fn getEnvRequired(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            std.debug.print("Missing required env var: {s}\n", .{name});
            return err;
        },
        else => return err,
    };
}

// ---- Clean shutdown: send "quit" to the ServerQuery session instead of just dying ----
// Without this, Ctrl+C (or any kill) just severs the pipe, leaving a half-closed
// session server-side that can cause the *next* launch to fail (stale session /
// anti-flood heuristics tripping on a rapid reconnect from the same IP).

var g_ssh_stdin: ?std.fs.File = null;

fn handleShutdownSignal(_: c_int) callconv(.C) void {
    if (g_ssh_stdin) |f| {
        _ = f.write("quit\n") catch {};
    }
    std.process.exit(0);
}

fn installShutdownHandler() !void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    };
    try std.posix.sigaction(std.posix.SIG.INT, &act, null);
    try std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

// ---- Small helper to run a subprocess and wait for it, no captured output ----

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    _ = try child.wait();
}

// ---- TS3/TS6 ServerQuery string unescaping (\s -> space, \p -> |, etc.) ----

fn unescapeTs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const c = input[i + 1];
            const replacement: u8 = switch (c) {
                's' => ' ',
                'p' => '|',
                '/' => '/',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => c,
            };
            try out.append(replacement);
            i += 2;
        } else {
            try out.append(input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

// ---- Reverse direction - needed now that the bot replies in chat itself ----

fn escapeTs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (input) |c| {
        switch (c) {
            ' ' => try out.appendSlice("\\s"),
            '|' => try out.appendSlice("\\p"),
            '/' => try out.appendSlice("\\/"),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(c),
        }
    }
    return out.toOwnedSlice();
}

// ---- Pull a "key=value" token's value out of a space-delimited ServerQuery line ----

fn extractField(line: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, line, ' ');
    while (it.next()) |token| {
        if (std.mem.startsWith(u8, token, key)) {
            return token[key.len..];
        }
    }
    return null;
}

// ---- Find <name>.* on disk regardless of extension, e.g. "test_sound" -> test_sound.mp3 ----

fn findSoundFile(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !?[]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open sounds dir '{s}': {}\n", .{ dir_path, err });
        return null;
    };
    defer dir.close();

    const prefix = try std.fmt.allocPrint(allocator, "{s}.", .{name});
    defer allocator.free(prefix);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            return try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        }
    }
    return null;
}

// Fallback for when findSoundFile finds no exact match: looks for "<name><digits>.<ext>"
// (du1.mp3, du2.mp3, ...) and picks one at random. Only reached when the exact name
// didn't match anything, so "!du1" - which DOES match du1.mp3 exactly above - never
// falls through to here; "!du" with no du.* file does, and lands on one of its
// numbered siblings.
fn findSoundFileFamily(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !?[]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open sounds dir '{s}': {}\n", .{ dir_path, err });
        return null;
    };
    defer dir.close();

    var matches = std.ArrayList([]const u8).init(allocator);
    defer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, name)) continue;

        // Everything between the name and the extension's dot must be all digits.
        const rest = entry.name[name.len..];
        const dot_index = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
        const digits_part = rest[0..dot_index];
        if (digits_part.len == 0) continue;
        var all_digits = true;
        for (digits_part) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) continue;

        try matches.append(try std.fs.path.join(allocator, &.{ dir_path, entry.name }));
    }

    if (matches.items.len == 0) return null;
    const idx = std.crypto.random.intRangeLessThan(usize, 0, matches.items.len);
    return try allocator.dupe(u8, matches.items[idx]);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanStrMut(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// Builds the !sounds reply text, grouping numbered siblings under their shared
// family trigger:
//   Available sounds:
//
//   * !du (!du1 !du2)
//   * !fah
fn buildSoundsList(allocator: std.mem.Allocator, sounds_dir: []const u8) ![]u8 {
    var dir = try std.fs.cwd().openDir(sounds_dir, .{ .iterate = true });
    defer dir.close();

    // group key (family prefix, or the bare name for files with no numeric
    // suffix) -> list of individual member names (empty for non-family files).
    var groups = std.StringHashMap(std.ArrayList([]u8)).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |m| allocator.free(m);
            entry.value_ptr.deinit();
            allocator.free(entry.key_ptr.*);
        }
        groups.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        const dot = std.mem.indexOfScalar(u8, entry.name, '.') orelse continue;
        const base = entry.name[0..dot];
        if (base.len == 0) continue;

        var digit_start: usize = base.len;
        while (digit_start > 0 and std.ascii.isDigit(base[digit_start - 1])) digit_start -= 1;
        const has_family = digit_start < base.len and digit_start > 0;

        const key = if (has_family) base[0..digit_start] else base;

        const gop = try groups.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, key);
            gop.value_ptr.* = std.ArrayList([]u8).init(allocator);
        }

        if (has_family) {
            var already = false;
            for (gop.value_ptr.items) |m| {
                if (std.mem.eql(u8, m, base)) {
                    already = true;
                    break;
                }
            }
            if (!already) try gop.value_ptr.append(try allocator.dupe(u8, base));
        }
    }

    var keys = std.ArrayList([]const u8).init(allocator);
    defer keys.deinit();
    var kit = groups.keyIterator();
    while (kit.next()) |k| try keys.append(k.*);
    std.mem.sort([]const u8, keys.items, {}, lessThanStr);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    if (keys.items.len == 0) {
        try out.appendSlice("No sounds available.");
    } else {
        try out.appendSlice("Available sounds:\n\n");
        for (keys.items) |key| {
            try out.appendSlice("* !");
            try out.appendSlice(key);

            const members = groups.getPtr(key).?.items;
            std.mem.sort([]u8, members, {}, lessThanStrMut);
            if (members.len > 0) {
                try out.appendSlice(" (");
                for (members, 0..) |m, i| {
                    if (i > 0) try out.append(' ');
                    try out.append('!');
                    try out.appendSlice(m);
                }
                try out.appendSlice(")");
            }
            try out.append('\n');
        }
    }
    return out.toOwnedSlice();
}

// ---- Playback queue: one persistent player thread plays sounds back-to-back ----
// (replaces the old "single playing flag + detached thread per trigger" approach,
// which dropped triggers instead of queueing them)

const Effect = enum { none, slow, fast };

const QueueItem = struct {
    sound_path: []const u8,
    effect: Effect,
    delete_after: bool, // true for dynamically-generated files (TTS output) that should be cleaned up after playing
};

var queue_mutex: std.Thread.Mutex = .{};
var queue_cond: std.Thread.Condition = .{};
var sound_queue: std.ArrayList(QueueItem) = undefined; // initialized in main()

// pid of the currently-running ffmpeg, or -1 if nothing is playing right now.
// Only ever *read* by the stop-handler thread and *written* by the player thread,
// so a plain atomic is enough - no need to share the std.process.Child itself
// across threads (that would risk two threads both calling wait() on it).
var current_pid = std.atomic.Value(i32).init(-1);

// Runtime-tunable via !chance / !slow / !fast - not persisted across restarts.
// slow_factor/fast_factor affect pitch AND speed together (like a record played
// at the wrong speed) - 0.7 = deeper voice + slower, 1.3 = higher voice + faster.
const EffectSettings = struct {
    chance_percent: u32 = 10,
    slow_factor: f64 = 0.7,
    fast_factor: f64 = 1.3, // a starting guess - tune with !fast if 1.3 isn't what you want
};

var effect_mutex: std.Thread.Mutex = .{};
var effect_settings: EffectSettings = .{};

fn getEffectSettings() EffectSettings {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    return effect_settings;
}

fn setEffectChance(percent: u32) void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings.chance_percent = percent;
}

fn setEffectSlow(factor: f64) void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings.slow_factor = factor;
}

fn setEffectFast(factor: f64) void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings.fast_factor = factor;
}

fn rollEffect() Effect {
    const settings = getEffectSettings();
    const roll = std.crypto.random.intRangeLessThan(u32, 0, 100);
    if (roll >= settings.chance_percent) return .none;
    return if (std.crypto.random.boolean()) .slow else .fast;
}

const PlayerCtx = struct {
    allocator: std.mem.Allocator,
    ptt_key: []const u8,
    sink: []const u8,
};

fn enqueueSound(sound_path: []const u8, delete_after: bool) !void {
    const effect = rollEffect();
    queue_mutex.lock();
    defer queue_mutex.unlock();
    try sound_queue.append(.{ .sound_path = sound_path, .effect = effect, .delete_after = delete_after });
    queue_cond.signal();
}

fn clearQueueAndStopCurrent(allocator: std.mem.Allocator) void {
    queue_mutex.lock();
    for (sound_queue.items) |item| {
        if (item.delete_after) std.fs.cwd().deleteFile(item.sound_path) catch {};
        allocator.free(item.sound_path);
    }
    sound_queue.clearRetainingCapacity();
    queue_mutex.unlock();

    const pid = current_pid.load(.acquire);
    if (pid != -1) {
        std.posix.kill(pid, std.posix.SIG.KILL) catch |err| {
            std.debug.print("[soundbot] failed to kill current playback: {}\n", .{err});
        };
    }

    std.debug.print("[soundbot] queue cleared, current sound stopped\n", .{});
}

fn playerLoop(ctx: *const PlayerCtx) void {
    while (true) {
        queue_mutex.lock();
        while (sound_queue.items.len == 0) {
            queue_cond.wait(&queue_mutex);
        }
        const item = sound_queue.orderedRemove(0);
        queue_mutex.unlock();

        playOne(ctx, item.sound_path, item.effect);
        if (item.delete_after) std.fs.cwd().deleteFile(item.sound_path) catch {};
        ctx.allocator.free(item.sound_path);
    }
}

fn playOne(ctx: *const PlayerCtx, sound_path: []const u8, effect: Effect) void {
    const effect_label: []const u8 = switch (effect) {
        .none => "",
        .slow => " (slowed + pitched down)",
        .fast => " (sped up + pitched up)",
    };
    std.debug.print("[soundbot] playing {s}{s}\n", .{ sound_path, effect_label });

    runCmd(ctx.allocator, &.{ "xdotool", "keydown", ctx.ptt_key }) catch |err| {
        std.debug.print("[soundbot] keydown failed: {}\n", .{err});
    };
    // Short margin so the PTT key has registered before audio starts - shrunk from
    // an earlier, more conservative 200ms. If you ever see the very start of a clip
    // clipped, bump this back up; if not, it can likely go even lower than this.
    std.time.sleep(50 * std.time.ns_per_ms);

    playFile(ctx, sound_path, effect) catch |err| {
        std.debug.print("[soundbot] playback failed: {}\n", .{err});
    };

    std.time.sleep(50 * std.time.ns_per_ms);
    runCmd(ctx.allocator, &.{ "xdotool", "keyup", ctx.ptt_key }) catch |err| {
        std.debug.print("[soundbot] keyup failed: {}\n", .{err});
    };
}

// asetrate needs a literal numeric sample rate, not an expression (confirmed
// the hard way - "sample_rate" is not a recognized constant in its eval
// context). This gets the input file's actual rate via ffprobe so the pitch
// shift's math is correct regardless of what rate any given file happens to
// be at, rather than assuming a fixed value.
fn probeSampleRate(allocator: std.mem.Allocator, sound_path: []const u8) !u32 {
    var child = std.process.Child.init(&.{
        "ffprobe", "-v",              "error",
        "-select_streams", "a:0",
        "-show_entries", "stream=sample_rate",
        "-of", "csv=p=0",
        sound_path,
    }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const stdout = child.stdout.?;
    var buf: [32]u8 = undefined;
    const n = try stdout.readAll(&buf);
    _ = child.wait() catch {};

    const trimmed = std.mem.trim(u8, buf[0..n], " \r\n\t");
    return std.fmt.parseInt(u32, trimmed, 10) catch 48000;
}

fn runAndTrack(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    current_pid.store(@intCast(child.id), .release);
    // If a stop command killed it, this just returns (possibly with a non-zero
    // exit status) instead of erroring - either way the caller still releases
    // the PTT key regardless of why playback stopped.
    _ = child.wait() catch {};
    current_pid.store(-1, .release);
}

fn playFile(ctx: *const PlayerCtx, sound_path: []const u8, effect: Effect) !void {
    // No effect: same lightweight, format-specific fast paths as before.
    if (effect == .none) {
        if (std.mem.endsWith(u8, sound_path, ".wav")) {
            return runAndTrack(ctx.allocator, &.{ "paplay", "--device", ctx.sink, sound_path });
        }
        if (std.mem.endsWith(u8, sound_path, ".mp3")) {
            return runAndTrack(ctx.allocator, &.{ "mpg123", "-q", "-o", "pulse", "-a", ctx.sink, sound_path });
        }
        return runAndTrack(ctx.allocator, &.{ "ffmpeg", "-nostdin", "-loglevel", "error", "-i", sound_path, "-f", "pulse", ctx.sink });
    }

    // An effect is active: transcode to a temp WAV file first (plain file I/O,
    // no live-device timing involved at all), then play that file through the
    // same paplay path already proven reliable. ffmpeg writing the atempo'd
    // audio straight to the live pulse sink was the actual bug behind sped-up
    // clips sometimes not being audible: it can exit right after handing off
    // the last chunk, before PulseAudio has actually finished draining it.
    // Slowed clips take long enough to write that this mostly went unnoticed;
    // sped-up ones finish writing fast enough to exit before anything plays.
    const factor: f64 = switch (effect) {
        .none => unreachable,
        .slow => getEffectSettings().slow_factor,
        .fast => getEffectSettings().fast_factor,
    };

    // Combined pitch + speed change, tied together via the same factor - like a
    // record played at the wrong speed: asetrate reinterprets the audio at a
    // scaled sample rate, shifting pitch and tempo together. asetrate needs a
    // literal number here, not an expression, so the file's actual rate is
    // probed first rather than assumed.
    const original_rate = probeSampleRate(ctx.allocator, sound_path) catch 48000;
    const new_rate: f64 = @as(f64, @floatFromInt(original_rate)) * factor;

    var filter_buf: [64]u8 = undefined;
    const filter_arg = try std.fmt.bufPrint(
        &filter_buf,
        "asetrate={d:.0},aresample={d}",
        .{ new_rate, original_rate },
    );

    const tmp_path = try std.fmt.allocPrint(ctx.allocator, "/tmp/soundbot_effect_{d}.wav", .{std.time.milliTimestamp()});
    defer ctx.allocator.free(tmp_path);
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    try runAndTrack(ctx.allocator, &.{
        "ffmpeg", "-nostdin", "-loglevel", "error", "-y",
        "-i",     sound_path,
        "-filter:a", filter_arg,
        tmp_path,
    });

    try runAndTrack(ctx.allocator, &.{ "paplay", "--device", ctx.sink, tmp_path });
}

fn triggerSound(allocator: std.mem.Allocator, cfg: *const Config, name: []const u8) !void {
    if (try findSoundFile(allocator, cfg.sounds_dir, name)) |path| {
        try enqueueSound(path, false);
        return;
    }

    if (try findSoundFileFamily(allocator, cfg.sounds_dir, name)) |path| {
        try enqueueSound(path, false);
        return;
    }

    std.debug.print("[soundbot] no sound file found for !{s}\n", .{name});
}

// ---- Text-to-speech via Amazon Polly, through the AWS CLI ----
// Calling Polly's API directly would mean implementing AWS SigV4 request
// signing from scratch - a real cryptographic protocol, not something to
// improvise without being able to test against live AWS. The AWS CLI already
// handles that correctly, so it's used as a subprocess instead, the same way
// this bot already shells out to ssh/ffmpeg/xdotool rather than reimplementing
// any of those protocols either. Credentials (AWS_ACCESS_KEY_ID,
// AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION) are expected as plain environment
// variables on the container - the aws CLI picks those up on its own, and
// std.process.Child inherits the parent's environment by default, so no
// credential-handling code is needed here at all.

const max_tts_chars = 150;

// All standard-engine voices (no neural ones - those need a per-voice --engine
// override, which got dropped along with Kevin, the only voice that needed it).
// Add a new voice by adding a line here; no dispatch-logic changes needed.
const TtsVoice = struct {
    cmd: []const u8,
    voice_id: []const u8,
    language: []const u8,
};

const tts_voices = [_]TtsVoice{
    .{ .cmd = "ttsg", .voice_id = "Giorgio", .language = "Italian" },
    .{ .cmd = "ttsb", .voice_id = "Brian", .language = "British English" },
    .{ .cmd = "ttsjo", .voice_id = "Joanna", .language = "US English" },
    .{ .cmd = "ttsma", .voice_id = "Matthew", .language = "US English" },
    .{ .cmd = "ttssa", .voice_id = "Salli", .language = "US English" },
    .{ .cmd = "ttsam", .voice_id = "Amy", .language = "British English" },
    .{ .cmd = "ttsem", .voice_id = "Emma", .language = "British English" },
    .{ .cmd = "ttsju", .voice_id = "Justin", .language = "US English" },
    .{ .cmd = "ttsni", .voice_id = "Nicole", .language = "Australian English" },
    .{ .cmd = "ttsca", .voice_id = "Carla", .language = "Italian" },
    .{ .cmd = "ttsm", .voice_id = "Maxim", .language = "Russian" },
    .{ .cmd = "ttst", .voice_id = "Tatyana", .language = "Russian" },
};

fn findTtsVoice(name: []const u8) ?[]const u8 {
    inline for (tts_voices) |v| {
        if (std.mem.eql(u8, name, v.cmd)) return v.voice_id;
    }
    return null;
}

fn buildVoicesList(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("Available voices:\n\n");
    for (tts_voices) |v| {
        try out.appendSlice("* !");
        try out.appendSlice(v.cmd);
        try out.appendSlice(" -");
        try out.appendSlice(v.voice_id);
        try out.appendSlice(" (");
        try out.appendSlice(v.language);
        try out.appendSlice(")\n");
    }
    try out.appendSlice("* !tts - random voice\n");
    return out.toOwnedSlice();
}

fn synthesizeTts(allocator: std.mem.Allocator, voice_id: []const u8, engine: ?[]const u8, text: []const u8, out_path: []const u8) !void {
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{
        "aws",          "polly", "synthesize-speech",
        "--output-format", "mp3",
        "--voice-id",   voice_id,
        "--text",       text,
    });
    if (engine) |e| {
        try argv.appendSlice(&.{ "--engine", e });
    }
    try argv.append(out_path);
    try runAndTrack(allocator, argv.items);
}

// Caught/logged here rather than propagated with `try`, deliberately unlike
// most of this bot's other multi-step command handlers - a network call to an
// external API is far more likely to transiently fail than a local SSH
// command, and a flaky Polly request shouldn't be able to take the whole bot
// down with it.
fn handleTtsCommand(allocator: std.mem.Allocator, voice_id: []const u8, engine: ?[]const u8, raw_text: []const u8) void {
    const text = if (raw_text.len > max_tts_chars) raw_text[0..max_tts_chars] else raw_text;
    if (text.len == 0) {
        std.debug.print("[soundbot] tts command needs some text after it, e.g. !ttsb hello there\n", .{});
        return;
    }

    const out_path = std.fmt.allocPrint(allocator, "/tmp/soundbot_tts_{d}.mp3", .{std.time.milliTimestamp()}) catch |err| {
        std.debug.print("[soundbot] tts failed to build temp path: {}\n", .{err});
        return;
    };

    synthesizeTts(allocator, voice_id, engine, text, out_path) catch |err| {
        std.debug.print("[soundbot] tts synthesis failed: {}\n", .{err});
        allocator.free(out_path);
        return;
    };

    enqueueSound(out_path, true) catch |err| {
        std.debug.print("[soundbot] failed to queue tts output: {}\n", .{err});
        allocator.free(out_path);
    };
}

// ---- ServerQuery helpers: send a command, read lines until "error id=" terminator ----

var stdin_mutex: std.Thread.Mutex = .{};

fn sendCommand(stdin: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    stdin_mutex.lock();
    defer stdin_mutex.unlock();
    try stdin.writer().print(fmt ++ "\n", args);
}

// Sends a harmless command periodically so the idle ServerQuery session doesn't
// get disconnected by the server's own inactivity timeout during quiet periods.
// Its response needs no special handling - it just flows through the main loop's
// existing "ignore anything that isn't notifytextmessage" logic.
fn keepaliveLoop(stdin: std.fs.File) void {
    while (true) {
        std.time.sleep(60 * std.time.ns_per_s);
        stdin_mutex.lock();
        defer stdin_mutex.unlock();
        stdin.writer().print("version\n", .{}) catch |err| {
            std.debug.print("[soundbot] keepalive write failed: {}\n", .{err});
        };
    }
}

fn readUntilError(allocator: std.mem.Allocator, reader: anytype) !std.ArrayList([]u8) {
    var lines = std.ArrayList([]u8).init(allocator);
    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 8192);
        const line = maybe_line orelse break;
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len == 0) {
            allocator.free(line);
            continue;
        }
        try lines.append(line);
        if (std.mem.startsWith(u8, trimmed, "error id=")) break;
    }
    return lines;
}

// For "fire and forget" setup commands (use, clientmove, servernotifyregister, ...)
// where we don't need the response content - just whether it actually succeeded.
// Without this, a failed command (wrong permission, rejected argument, whatever)
// was previously completely silent: discarded along with the rest of the response.
fn doCommand(allocator: std.mem.Allocator, stdin: std.fs.File, reader: anytype, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try sendCommand(stdin, fmt, args);
    var lines = try readUntilError(allocator, reader);
    defer freeLines(allocator, &lines);
    if (lines.items.len > 0) {
        const last = std.mem.trim(u8, lines.items[lines.items.len - 1], "\r\n ");
        if (!std.mem.startsWith(u8, last, "error id=0")) {
            std.debug.print("[soundbot] {s} failed: {s}\n", .{ label, last });
        }
    }
}

fn freeLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]u8)) void {
    for (lines.items) |l| allocator.free(l);
    lines.deinit();
}

// Replies in chat - reuses the SAME targetmode/target the triggering message
// arrived on, so a reply to a channel message goes back to that channel, and a
// reply to a server-wide chat message goes back to server-wide chat, with no
// extra lookup needed either way.
fn sendReply(allocator: std.mem.Allocator, stdin: std.fs.File, reader: anytype, targetmode: []const u8, target: []const u8, message: []const u8) !void {
    const escaped = try escapeTs(allocator, message);
    defer allocator.free(escaped);
    try doCommand(allocator, stdin, reader, "sendtextmessage", "sendtextmessage targetmode={s} target={s} msg={s}", .{ targetmode, target, escaped });
}

// clientlist responses pack multiple clients into one line, separated by '|' -
// e.g. "clid=1 cid=2 client_nickname=Foo|clid=3 cid=4 client_nickname=Bar".
// Split on '|' first to get clean per-client records before pulling fields out.
fn findClientIdByNickname(allocator: std.mem.Allocator, lines: []const []const u8, nickname: []const u8) !?[]u8 {
    for (lines) |line| {
        var records = std.mem.splitScalar(u8, line, '|');
        while (records.next()) |record| {
            const raw_nick = extractField(record, "client_nickname=") orelse continue;
            const nick = try unescapeTs(allocator, raw_nick);
            defer allocator.free(nick);
            if (std.mem.eql(u8, nick, nickname)) {
                if (extractField(record, "clid=")) |clid_val| {
                    return try allocator.dupe(u8, clid_val);
                }
            }
        }
    }
    return null;
}

// Same shape as the lookup above, but the other direction: given a clid (from a
// notification's invokerid=), find that client's current channel (cid=). Needed
// because server-wide chat notifications don't carry a channel id directly - only
// per-channel chat does.
fn findChannelIdByClid(allocator: std.mem.Allocator, lines: []const []const u8, target_clid: []const u8) !?[]u8 {
    for (lines) |line| {
        var records = std.mem.splitScalar(u8, line, '|');
        while (records.next()) |record| {
            const raw_clid = extractField(record, "clid=") orelse continue;
            if (std.mem.eql(u8, raw_clid, target_clid)) {
                if (extractField(record, "cid=")) |cid_val| {
                    return try allocator.dupe(u8, cid_val);
                }
            }
        }
    }
    return null;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try Config.load(allocator);

    sound_queue = std.ArrayList(QueueItem).init(allocator);

    const player_ctx = try allocator.create(PlayerCtx);
    player_ctx.* = .{
        .allocator = allocator,
        .ptt_key = cfg.ptt_key,
        .sink = cfg.sink,
    };
    const player_thread = try std.Thread.spawn(.{}, playerLoop, .{player_ctx});
    player_thread.detach();

    const target = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ cfg.ssh_user, cfg.ssh_host });
    defer allocator.free(target);

    const ssh_argv = &[_][]const u8{
        "sshpass",
        "-p",
        cfg.ssh_pass,
        "ssh",
        "-p",
        cfg.ssh_port,
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "UserKnownHostsFile=/dev/null",
        target,
    };

    var child = std.process.Child.init(ssh_argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    try child.spawn();

    const stdin = child.stdin.?;
    const stdout = child.stdout.?;

    g_ssh_stdin = stdin;
    try installShutdownHandler();

    var buffered = std.io.bufferedReader(stdout.reader());
    const reader = buffered.reader();

    // Give the SSH banner a moment to arrive before we start issuing commands.
    std.time.sleep(1 * std.time.ns_per_s);

    // 1. Select the virtual server.
    try doCommand(allocator, stdin, reader, "use", "use {s}", .{cfg.vserver_id});

    // 2. Find our own client id so we can move ourselves into the target channel.
    try sendCommand(stdin, "whoami", .{});
    var my_clid: ?[]u8 = null;
    {
        var lines = try readUntilError(allocator, reader);
        defer freeLines(allocator, &lines);
        for (lines.items) |line| {
            if (extractField(line, "client_id=")) |val| {
                my_clid = try allocator.dupe(u8, val);
            }
        }
    }
    const clid = my_clid orelse {
        std.debug.print("[soundbot] could not determine own client_id from whoami\n", .{});
        return error.NoClientId;
    };
    defer allocator.free(clid);

    // 3. Move into the configured channel.
    try doCommand(allocator, stdin, reader, "clientmove (startup)", "clientmove clid={s} cid={s}", .{ clid, cfg.channel_id });

    // 4. Register for chat notifications: per-channel (for normal triggers) and
    //    server-wide (so a bare "!join" typed from any channel's chat - or the
    //    server chat tab - can still reach us, since textchannel notifications
    //    are scoped to wherever we're currently sitting).
    try doCommand(allocator, stdin, reader, "servernotifyregister textchannel", "servernotifyregister event=textchannel", .{});
    try doCommand(allocator, stdin, reader, "servernotifyregister textserver", "servernotifyregister event=textserver", .{});

    std.debug.print("[soundbot] ready - watching channel {s} for !sound<N>\n", .{cfg.channel_id});

    const keepalive_thread = try std.Thread.spawn(.{}, keepaliveLoop, .{stdin});
    keepalive_thread.detach();

    // 5. Main loop: read lines forever, react to notifytextmessage.
    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 8192);
        const line = maybe_line orelse break; // ssh connection closed
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (!std.mem.startsWith(u8, trimmed, "notifytextmessage")) continue;

        const raw_msg = extractField(trimmed, "msg=") orelse continue;
        const msg = try unescapeTs(allocator, raw_msg);
        defer allocator.free(msg);

        if (!std.mem.startsWith(u8, msg, "!")) continue;
        const after_bang = msg[1..];

        // Command name is everything up to the first whitespace (so "!sound1 extra text" still works).
        var name_end: usize = 0;
        while (name_end < after_bang.len and !std.ascii.isWhitespace(after_bang[name_end])) : (name_end += 1) {}
        const name = after_bang[0..name_end];
        if (name.len == 0) continue;

        // Restrict to a safe filename charset - this string becomes part of a path on disk,
        // so don't let chat input contain '/', '..', etc.
        var name_is_safe = true;
        for (name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) {
                name_is_safe = false;
                break;
            }
        }
        if (!name_is_safe) continue;

        if (std.mem.eql(u8, name, "stop")) {
            clearQueueAndStopCurrent(allocator);
            continue;
        }

        if (std.mem.eql(u8, name, "sounds")) {
            const list_msg = buildSoundsList(allocator, cfg.sounds_dir) catch |err| {
                std.debug.print("[soundbot] failed to build sounds list: {}\n", .{err});
                continue;
            };
            defer allocator.free(list_msg);

            const reply_targetmode = extractField(trimmed, "targetmode=") orelse "2";
            const reply_target = extractField(trimmed, "target=") orelse cfg.channel_id;

            sendReply(allocator, stdin, reader, reply_targetmode, reply_target, list_msg) catch |err| {
                std.debug.print("[soundbot] failed to send sounds list: {}\n", .{err});
            };
            continue;
        }

        if (std.mem.eql(u8, name, "voices")) {
            const list_msg = buildVoicesList(allocator) catch |err| {
                std.debug.print("[soundbot] failed to build voices list: {}\n", .{err});
                continue;
            };
            defer allocator.free(list_msg);
 
            const reply_targetmode = extractField(trimmed, "targetmode=") orelse "2";
            const reply_target = extractField(trimmed, "target=") orelse cfg.channel_id;
 
            sendReply(allocator, stdin, reader, reply_targetmode, reply_target, list_msg) catch |err| {
                std.debug.print("[soundbot] failed to send voices list: {}\n", .{err});
            };
            continue;
        }

        if (findTtsVoice(name)) |voice_id| {
            const text = std.mem.trim(u8, after_bang[name_end..], " \t");
            handleTtsCommand(allocator, voice_id, null, text);
            continue;
        }

        if (std.mem.eql(u8, name, "tts")) {
            const text = std.mem.trim(u8, after_bang[name_end..], " \t");
            const voice_id = tts_voices[std.crypto.random.intRangeLessThan(usize, 0, tts_voices.len)].voice_id;
            handleTtsCommand(allocator, voice_id, null, text);
            continue;
        }

        if (std.mem.eql(u8, name, "chance")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const percent = std.fmt.parseInt(u32, rest, 10) catch {
                std.debug.print("[soundbot] !chance needs a whole number 0-100, e.g. !chance 10\n", .{});
                continue;
            };
            if (percent > 100) {
                std.debug.print("[soundbot] !chance must be 0-100, got {d}\n", .{percent});
                continue;
            }
            setEffectChance(percent);
            std.debug.print("[soundbot] effect chance set to {d}%\n", .{percent});
            continue;
        }

        if (std.mem.eql(u8, name, "slow")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const factor = std.fmt.parseFloat(f64, rest) catch {
                std.debug.print("[soundbot] !slow needs a number, e.g. !slow 0.7\n", .{});
                continue;
            };
            if (factor < 0.5 or factor > 2.0) {
                std.debug.print("[soundbot] !slow should be 0.5-2.0 (outside that it stops sounding like a usable effect), got {d}\n", .{factor});
                continue;
            }
            setEffectSlow(factor);
            std.debug.print("[soundbot] slow+pitch-down factor set to {d}x\n", .{factor});
            continue;
        }

        if (std.mem.eql(u8, name, "fast")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const factor = std.fmt.parseFloat(f64, rest) catch {
                std.debug.print("[soundbot] !fast needs a number, e.g. !fast 1.3\n", .{});
                continue;
            };
            if (factor < 0.5 or factor > 2.0) {
                std.debug.print("[soundbot] !fast should be 0.5-2.0 (outside that it stops sounding like a usable effect), got {d}\n", .{factor});
                continue;
            }
            setEffectFast(factor);
            std.debug.print("[soundbot] fast+pitch-up factor set to {d}x\n", .{factor});
            continue;
        }

        if (std.mem.eql(u8, name, "join")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");

            const target_cid: []u8 = blk: {
                if (rest.len == 0) {
                    const mode = extractField(trimmed, "targetmode=") orelse "0";

                    if (std.mem.eql(u8, mode, "2")) {
                        // Channel chat - target= is the channel id directly.
                        const raw = extractField(trimmed, "target=") orelse {
                            std.debug.print("[soundbot] !join: couldn't determine your channel; try !join <channel_id>\n", .{});
                            continue;
                        };
                        break :blk try allocator.dupe(u8, raw);
                    }

                    // Anything else (server-wide chat, most likely) - server chat doesn't
                    // carry a channel id, so look up the sender's current channel instead.
                    const invoker_clid = extractField(trimmed, "invokerid=") orelse {
                        std.debug.print("[soundbot] !join: couldn't determine who sent this; try !join <channel_id>\n", .{});
                        continue;
                    };
                    try sendCommand(stdin, "clientlist", .{});
                    var found_cid: ?[]u8 = null;
                    {
                        var lookup_lines = try readUntilError(allocator, reader);
                        defer freeLines(allocator, &lookup_lines);
                        found_cid = try findChannelIdByClid(allocator, lookup_lines.items, invoker_clid);
                    }
                    break :blk found_cid orelse {
                        std.debug.print("[soundbot] !join: couldn't find your channel automatically; try !join <channel_id>\n", .{});
                        continue;
                    };
                }

                var rest_is_digits = true;
                for (rest) |c| {
                    if (!std.ascii.isDigit(c)) {
                        rest_is_digits = false;
                        break;
                    }
                }
                if (!rest_is_digits) {
                    std.debug.print("[soundbot] !join channel id must be numeric, got '{s}'\n", .{rest});
                    continue;
                }
                break :blk try allocator.dupe(u8, rest);
            };
            defer allocator.free(target_cid);

            // 1. Find the voice client (the actual TS6 GUI client transmitting audio) by nickname.
            try sendCommand(stdin, "clientlist", .{});
            var voice_clid: ?[]u8 = null;
            {
                var lines = try readUntilError(allocator, reader);
                defer freeLines(allocator, &lines);
                voice_clid = try findClientIdByNickname(allocator, lines.items, cfg.voice_nickname);
            }
            const v_clid = voice_clid orelse {
                std.debug.print("[soundbot] no connected client named '{s}' - is the voice client online?\n", .{cfg.voice_nickname});
                continue;
            };
            defer allocator.free(v_clid);

            // 2. Drop the old chat subscription before moving, so it doesn't straddle channels
            //    (servernotifyregister's textchannel scope follows wherever this session sits).
            try doCommand(allocator, stdin, reader, "servernotifyunregister", "servernotifyunregister", .{});

            // 3. Move our own ServerQuery session into the new channel.
            try doCommand(allocator, stdin, reader, "clientmove (listener)", "clientmove clid={s} cid={s}", .{ clid, target_cid });

            // 4. Re-subscribe - this picks up whatever channel we're now sitting in,
            //    plus server-wide chat again for future cross-channel !join calls.
            try doCommand(allocator, stdin, reader, "servernotifyregister textchannel", "servernotifyregister event=textchannel", .{});
            try doCommand(allocator, stdin, reader, "servernotifyregister textserver", "servernotifyregister event=textserver", .{});

            // 5. Move the actual voice client too, so speaking follows listening.
            try doCommand(allocator, stdin, reader, "clientmove (voice)", "clientmove clid={s} cid={s}", .{ v_clid, target_cid });

            std.debug.print("[soundbot] moved to channel {s}\n", .{target_cid});
            continue;
        }

        triggerSound(allocator, &cfg, name) catch |err| {
            std.debug.print("[soundbot] trigger failed: {}\n", .{err});
        };
    }

    g_ssh_stdin = null; // avoid the signal handler racing a write to an already-closing pipe
    _ = stdin.write("quit\n") catch {};
    _ = try child.wait();
}
