const std = @import("std");
const sounds = @import("sounds.zig");

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    _ = try child.wait();
}

const Effect = enum { none, slow, fast };

const QueueItem = struct {
    sound_path: []const u8,
    effect: Effect,
    reverb: bool, // independent of effect - can combine with none/slow/fast alike
    skip_effects: bool, // true for !yt - also suppresses the compressor at play time, not just the random pitch/reverb roll at enqueue time
    delete_after: bool, // true for dynamically-generated files (TTS output) that should be cleaned up after playing
};

var queue_mutex: std.Thread.Mutex = .{};
var queue_cond: std.Thread.Condition = .{};
var sound_queue: std.ArrayList(QueueItem) = undefined; // initialized via initQueue()

// QueueItem is private to this module, so main() can't construct
// std.ArrayList(QueueItem) directly - this is the public init entry point instead.
pub fn initQueue(allocator: std.mem.Allocator) void {
    sound_queue = std.ArrayList(QueueItem).init(allocator);
}

// pid of the currently-running ffmpeg, or -1 if nothing is playing right now.
// Only ever *read* by the stop-handler thread and *written* by the player thread,
// so a plain atomic is enough - no need to share the std.process.Child itself
// across threads (that would risk two threads both calling wait() on it).
var current_pid = std.atomic.Value(i32).init(-1);

// Same idea, but for an in-progress yt-dlp download or TTS synthesis call -
// kept separate from current_pid since those run on their own background
// thread (see runAndTrackDownload), concurrently with whatever the player
// thread might independently be doing, so a single shared pid var would risk
// the two stepping on each other's tracking.
var download_pid = std.atomic.Value(i32).init(-1);

// Runtime-tunable via !chance / !slow / !fast / !chancereverb / !reverbamount -
// not persisted across restarts. slow_factor/fast_factor affect pitch AND speed
// together (like a record played at the wrong speed) - 0.7 = deeper voice +
// slower, 1.3 = higher voice + faster. reverb_chance_percent and reverb_amount
// are rolled/applied completely independently of the pitch/speed effect, so a
// sound can be slowed *and* reverby, sped up *and* reverby, or reverby on its own.
const EffectSettings = struct {
    chance_percent: u32 = 10,
    slow_factor: f64 = 0.7,
    fast_factor: f64 = 1.3, // a starting guess - tune with !fast if 1.3 isn't what you want
    reverb_chance_percent: u32 = 10,
    reverb_amount: u32 = 50, // maps directly to sox's reverb "reverberance" 0-100
};

var effect_mutex: std.Thread.Mutex = .{};
var effect_settings: EffectSettings = .{};

pub fn getEffectSettings() EffectSettings {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    return effect_settings;
}

pub fn resetEffectSettings() void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings = .{};
}

pub fn setEffectChance(percent: u32) void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings.chance_percent = percent;
}

pub fn setEffectSlow(factor: f64) void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings.slow_factor = factor;
}

pub fn setEffectFast(factor: f64) void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings.fast_factor = factor;
}

pub fn setReverbChance(percent: u32) void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings.reverb_chance_percent = percent;
}

pub fn setReverbAmount(amount: u32) void {
    effect_mutex.lock();
    defer effect_mutex.unlock();
    effect_settings.reverb_amount = amount;
}

fn rollEffect() Effect {
    const settings = getEffectSettings();
    const roll = std.crypto.random.intRangeLessThan(u32, 0, 100);
    if (roll >= settings.chance_percent) return .none;
    return if (std.crypto.random.boolean()) .slow else .fast;
}

fn rollReverb() bool {
    const settings = getEffectSettings();
    const roll = std.crypto.random.intRangeLessThan(u32, 0, 100);
    return roll < settings.reverb_chance_percent;
}

// Always-applied master controls (!volume / !compressor). Volume is never
// exempted for any source (it's sink-level, applying to literally everything
// flowing through ts_bot_sink, including yt-dlp audio - see setVolume). The
// compressor *is* exempted for yt-dlp audio though, via skip_effects in
// playFile, for the same reasoning as the random pitch/reverb effects: a
// compressor squashing the dynamics of an entire song is a bigger, more
// disruptive change than it is on a short clip.
const MasterSettings = struct {
    volume_percent: u32 = 100,
    compressor_enabled: bool = false,
    compressor_threshold_percent: u32 = 10, // -> linear 0.1 (~-20dB) when passed to acompressor
    compressor_ratio: f64 = 4,
    compressor_makeup: f64 = 1,
};

var master_mutex: std.Thread.Mutex = .{};
var master_settings: MasterSettings = .{};

pub fn getMasterSettings() MasterSettings {
    master_mutex.lock();
    defer master_mutex.unlock();
    return master_settings;
}

pub fn resetMasterSettings(allocator: std.mem.Allocator, sink: []const u8) void {
    master_mutex.lock();
    master_settings = .{};
    master_mutex.unlock();
    applySinkVolume(allocator, sink, 100);
}

// Applies live via the sink's own volume (pactl set-sink-volume), not an
// ffmpeg filter - this is what actually lets it affect a sound that's already
// playing, since it adjusts the live PulseAudio connection itself rather than
// baking a gain value into a file before playback even starts. Works cleanly
// for this bot specifically because exactly one thing ever plays through
// ts_bot_sink at a time (the player thread is strictly sequential) - there's
// no ambiguity about "which stream" to adjust, unlike a general-purpose mixer
// with multiple concurrent streams.
pub fn setVolume(allocator: std.mem.Allocator, percent: u32, sink: []const u8) void {
    master_mutex.lock();
    master_settings.volume_percent = percent;
    master_mutex.unlock();
    applySinkVolume(allocator, sink, percent);
}

fn applySinkVolume(allocator: std.mem.Allocator, sink: []const u8, percent: u32) void {
    var buf: [8]u8 = undefined;
    const percent_arg = std.fmt.bufPrint(&buf, "{d}%", .{percent}) catch return;
    runCmd(allocator, &.{ "pactl", "set-sink-volume", sink, percent_arg }) catch |err| {
        std.debug.print("[soundbot] failed to set live sink volume: {}\n", .{err});
    };
}

pub fn setCompressorEnabled(enabled: bool) void {
    master_mutex.lock();
    defer master_mutex.unlock();
    master_settings.compressor_enabled = enabled;
}

// Setting specific values implies wanting the compressor active, so this
// enables it too rather than requiring a separate !compressor on afterward.
pub fn setCompressorParams(threshold_percent: u32, ratio: f64, makeup: f64) void {
    master_mutex.lock();
    defer master_mutex.unlock();
    master_settings.compressor_threshold_percent = threshold_percent;
    master_settings.compressor_ratio = ratio;
    master_settings.compressor_makeup = makeup;
    master_settings.compressor_enabled = true;
}

pub const PlayerCtx = struct {
    allocator: std.mem.Allocator,
    ptt_key: []const u8,
    sink: []const u8,
};

pub fn enqueueSound(sound_path: []const u8, delete_after: bool, skip_effects: bool) !void {
    const effect: Effect = if (skip_effects) .none else rollEffect();
    const reverb: bool = if (skip_effects) false else rollReverb();
    queue_mutex.lock();
    defer queue_mutex.unlock();
    try sound_queue.append(.{ .sound_path = sound_path, .effect = effect, .reverb = reverb, .skip_effects = skip_effects, .delete_after = delete_after });
    queue_cond.signal();
}

pub fn clearQueueAndStopCurrent(allocator: std.mem.Allocator) void {
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

    const dl_pid = download_pid.load(.acquire);
    if (dl_pid != -1) {
        std.posix.kill(dl_pid, std.posix.SIG.KILL) catch |err| {
            std.debug.print("[soundbot] failed to kill current download/synthesis: {}\n", .{err});
        };
    }

    std.debug.print("[soundbot] queue cleared, current sound/download stopped\n", .{});
}

// Unlike clearQueueAndStopCurrent, this never touches the rest of the queue -
// the player thread just moves on to the next item once playOne returns.
// Kills whichever of {current playback, an in-progress !yt/!tts download or
// synthesis call} is actually active, since from a user's perspective "skip
// this" reasonably means either one, regardless of which phase it's in.
//
// One known rough edge: if a playback kill lands during one of the brief
// ffmpeg/sox pre-processing stages of an effect-laden clip (pitch/reverb/
// compressor), rather than during final playback, the remaining stages still
// run against the now-truncated intermediate file before reaching paplay -
// so a skip timed exactly into that narrow window could produce a brief
// glitch rather than an instant clean cut, rather than failing outright. Not
// fixed here, since it would need threading a cancellation flag through
// every stage of playFile for what's normally a very small window in practice.
pub const SkipResult = enum { nothing, playback, download };

pub fn skipCurrent() SkipResult {
    var result: SkipResult = .nothing;

    const dl_pid = download_pid.load(.acquire);
    if (dl_pid != -1) {
        std.posix.kill(dl_pid, std.posix.SIG.KILL) catch |err| {
            std.debug.print("[soundbot] failed to skip current download/synthesis: {}\n", .{err});
        };
        result = .download;
    }

    const pid = current_pid.load(.acquire);
    if (pid != -1) {
        std.posix.kill(pid, std.posix.SIG.KILL) catch |err| {
            std.debug.print("[soundbot] failed to skip current playback: {}\n", .{err});
        };
        result = .playback; // takes priority in the reported result on the rare chance both were active
    }

    return result;
}

pub fn playerLoop(ctx: *const PlayerCtx) void {
    while (true) {
        queue_mutex.lock();
        while (sound_queue.items.len == 0) {
            queue_cond.wait(&queue_mutex);
        }
        const item = sound_queue.orderedRemove(0);
        queue_mutex.unlock();

        playOne(ctx, item.sound_path, item.effect, item.reverb, item.skip_effects);
        if (item.delete_after) std.fs.cwd().deleteFile(item.sound_path) catch {};
        ctx.allocator.free(item.sound_path);
    }
}

fn playOne(ctx: *const PlayerCtx, sound_path: []const u8, effect: Effect, reverb: bool, skip_effects: bool) void {
    const effect_label: []const u8 = switch (effect) {
        .none => "",
        .slow => " (slowed + pitched down)",
        .fast => " (sped up + pitched up)",
    };
    const reverb_label: []const u8 = if (reverb) " (reverb)" else "";
    std.debug.print("[soundbot] playing {s}{s}{s}\n", .{ sound_path, effect_label, reverb_label });

    runCmd(ctx.allocator, &.{ "xdotool", "keydown", ctx.ptt_key }) catch |err| {
        std.debug.print("[soundbot] keydown failed: {}\n", .{err});
    };
    // Short margin so the PTT key has registered before audio starts - shrunk from
    // an earlier, more conservative 200ms. If you ever see the very start of a clip
    // clipped, bump this back up; if not, it can likely go even lower than this.
    std.time.sleep(50 * std.time.ns_per_ms);

    playFile(ctx, sound_path, effect, reverb, skip_effects) catch |err| {
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
        "ffprobe",            "-v",  "error",
        "-select_streams",    "a:0", "-show_entries",
        "stream=sample_rate", "-of", "csv=p=0",
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

fn runAndTrackPid(allocator: std.mem.Allocator, argv: []const []const u8, pid_var: *std.atomic.Value(i32)) !void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    pid_var.store(@intCast(child.id), .release);
    // If a stop command killed it, this just returns (possibly with a non-zero
    // exit status) instead of erroring - either way the caller still releases
    // the PTT key (or otherwise handles cleanup) regardless of why it stopped.
    _ = child.wait() catch {};
    pid_var.store(-1, .release);
}

pub fn runAndTrack(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    return runAndTrackPid(allocator, argv, &current_pid);
}

// For yt-dlp downloads and TTS synthesis - these run on their own background
// thread (not the player thread), so tracking their pid separately from
// current_pid lets !stop kill an in-progress download/synthesis call even
// while something else is independently playing, and vice versa.
pub fn runAndTrackDownload(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    return runAndTrackPid(allocator, argv, &download_pid);
}

fn playFile(ctx: *const PlayerCtx, sound_path: []const u8, effect: Effect, reverb: bool, skip_effects: bool) !void {
    const master = getMasterSettings();
    const compressor_active = master.compressor_enabled and !skip_effects;

    // Nothing active at all: same lightweight, format-specific fast paths as before.
    // Volume is handled live via the sink itself now (see setVolume), so it no
    // longer needs to route through here at all - only the compressor does,
    // since that's genuine signal processing a sink-level gain knob can't do.
    if (effect == .none and !reverb and !compressor_active) {
        if (std.mem.endsWith(u8, sound_path, ".wav")) {
            return runAndTrack(ctx.allocator, &.{ "paplay", "--device", ctx.sink, sound_path });
        }
        if (std.mem.endsWith(u8, sound_path, ".mp3")) {
            return runAndTrack(ctx.allocator, &.{ "mpg123", "-q", "-o", "pulse", "-a", ctx.sink, sound_path });
        }
        return runAndTrack(ctx.allocator, &.{ "ffmpeg", "-nostdin", "-loglevel", "error", "-i", sound_path, "-f", "pulse", ctx.sink });
    }

    // At least one of {pitch/speed, reverb, compressor} is active -
    // route everything through one or more temp-file stages (plain file I/O,
    // no live-device timing involved), then play the final result through the
    // same paplay path already proven reliable. Writing effect-processed audio
    // straight to the live pulse sink was the actual bug behind sped-up clips
    // sometimes not being audible: ffmpeg can exit right after handing off the
    // last chunk, before PulseAudio has actually finished draining it.
    var temp_paths: [3][]const u8 = undefined;
    var temp_count: usize = 0;
    defer {
        var i: usize = 0;
        while (i < temp_count) : (i += 1) {
            std.fs.cwd().deleteFile(temp_paths[i]) catch {};
            ctx.allocator.free(temp_paths[i]);
        }
    }

    var current_path: []const u8 = sound_path;

    if (effect != .none) {
        // Combined pitch + speed change, tied together via the same factor -
        // like a record played at the wrong speed: asetrate reinterprets the
        // audio at a scaled sample rate, shifting pitch and tempo together.
        // asetrate needs a literal number here, not an expression, so the
        // file's actual rate is probed first rather than assumed.
        const factor: f64 = switch (effect) {
            .none => unreachable,
            .slow => getEffectSettings().slow_factor,
            .fast => getEffectSettings().fast_factor,
        };
        const original_rate = probeSampleRate(ctx.allocator, current_path) catch 48000;
        const new_rate: f64 = @as(f64, @floatFromInt(original_rate)) * factor;

        var filter_buf: [64]u8 = undefined;
        const filter_arg = try std.fmt.bufPrint(
            &filter_buf,
            "asetrate={d:.0},aresample={d}",
            .{ new_rate, original_rate },
        );

        const tmp_path = try std.fmt.allocPrint(ctx.allocator, "/tmp/soundbot_pitch_{d}.wav", .{std.time.milliTimestamp()});
        try runAndTrack(ctx.allocator, &.{
            "ffmpeg", "-nostdin",   "-loglevel", "error",    "-y",
            "-i",     current_path, "-filter:a", filter_arg, tmp_path,
        });

        temp_paths[temp_count] = tmp_path;
        temp_count += 1;
        current_path = tmp_path;
    }

    if (reverb) {
        // sox's "reverberance" parameter is already a plain 0-100 percentage,
        // matching !reverbamount directly with no rescaling needed.
        const amount = getEffectSettings().reverb_amount;
        var amount_buf: [8]u8 = undefined;
        const amount_arg = try std.fmt.bufPrint(&amount_buf, "{d}", .{amount});

        const tmp_path = try std.fmt.allocPrint(ctx.allocator, "/tmp/soundbot_reverb_{d}.wav", .{std.time.milliTimestamp()});
        try runAndTrack(ctx.allocator, &.{ "sox", current_path, tmp_path, "reverb", amount_arg });

        temp_paths[temp_count] = tmp_path;
        temp_count += 1;
        current_path = tmp_path;
    }

    if (compressor_active) {
        // Threshold is kept on the same 0-100 scale as everything else in this
        // bot and converted to ffmpeg's actual linear 0-1 range here, rather
        // than exposing that raw range directly in chat commands.
        var filter_buf: [128]u8 = undefined;
        const threshold_linear = @as(f64, @floatFromInt(master.compressor_threshold_percent)) / 100.0;
        const filter_arg = try std.fmt.bufPrint(
            &filter_buf,
            "acompressor=threshold={d:.4}:ratio={d:.2}:attack=20:release=250:makeup={d:.2}",
            .{ threshold_linear, master.compressor_ratio, master.compressor_makeup },
        );

        const tmp_path = try std.fmt.allocPrint(ctx.allocator, "/tmp/soundbot_master_{d}.wav", .{std.time.milliTimestamp()});
        try runAndTrack(ctx.allocator, &.{
            "ffmpeg", "-nostdin",   "-loglevel", "error",    "-y",
            "-i",     current_path, "-filter:a", filter_arg, tmp_path,
        });

        temp_paths[temp_count] = tmp_path;
        temp_count += 1;
        current_path = tmp_path;
    }

    try runAndTrack(ctx.allocator, &.{ "paplay", "--device", ctx.sink, current_path });
}

pub fn triggerSound(allocator: std.mem.Allocator, sounds_dir: []const u8, name: []const u8) !bool {
    if (try sounds.findSoundFile(allocator, sounds_dir, name)) |path| {
        try enqueueSound(path, false, false);
        return true;
    }

    if (try sounds.findSoundFileFamily(allocator, sounds_dir, name)) |path| {
        try enqueueSound(path, false, false);
        return true;
    }

    std.debug.print("[soundbot] no sound file found for !{s}\n", .{name});
    return false;
}
