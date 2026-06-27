const std = @import("std");
const sounds = @import("sounds.zig");

fn runCmd(io: std.Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });

    _ = try child.wait(io);
}

const Effect = enum { none, slow, fast };

const QueueItem = struct {
    name: []const u8,
    sound_path: []const u8,
    effect: Effect,
    reverb: bool,
    skip_effects: bool,
    delete_after: bool,
};

var queue_mutex: std.Io.Mutex = .init;
var queue_cond: std.Io.Condition = .init;
var sound_queue: std.ArrayList(QueueItem) = .empty;

var current_item_name: ?[]u8 = null;

fn setCurrentName(allocator: std.mem.Allocator, io: std.Io, name: []const u8) void {
    queue_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] queue mutex lock error on setting current name: {}\n", .{err});
        return;
    };
    defer queue_mutex.unlock(io);
    if (current_item_name) |old| allocator.free(old);
    current_item_name = allocator.dupe(u8, name) catch |err| {
        std.debug.print("[soundbot] failed to set current name: {}\n", .{err});
        return;
    };
}

fn clearCurrentName(allocator: std.mem.Allocator, io: std.Io) void {
    queue_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] queue mutex lock error on clearing current name: {}\n", .{err});
        return;
    };
    defer queue_mutex.unlock(io);
    if (current_item_name) |old| allocator.free(old);
    current_item_name = null;
}

pub fn getCurrentName(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    queue_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] queue mutex lock error on getting current name: {}\n", .{err});
        return err;
    };
    defer queue_mutex.unlock(io);
    if (current_item_name) |name| {
        return try allocator.dupe(u8, name);
    }
    return try allocator.dupe(u8, "Nothing is playing right now");
}

pub fn getCurrentQueue(allocator: std.mem.Allocator, io: std.Io) ![][]const u8 {
    queue_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] queue mutex lock error on getting current queue: {}\n", .{err});
        return err;
    };
    defer queue_mutex.unlock(io);

    var queue_list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (queue_list.items) |name| allocator.free(name);
        queue_list.deinit(allocator);
    }
    for (sound_queue.items) |item| {
        try queue_list.append(allocator, try allocator.dupe(u8, item.name));
    }
    return queue_list.toOwnedSlice(allocator);
}

pub fn freeCurrentQueue(allocator: std.mem.Allocator, list: [][]const u8) void {
    for (list) |name| allocator.free(name);
    allocator.free(list);
}

var current_pid = std.atomic.Value(i32).init(-1);
var download_pid = std.atomic.Value(i32).init(-1);

var current_is_yt = std.atomic.Value(bool).init(false);

const EffectSettings = struct {
    chance_percent: u32 = 10,
    slow_factor: f64 = 0.7,
    fast_factor: f64 = 1.3,
    reverb_chance_percent: u32 = 30,
    reverb_amount: u32 = 80,
};

var effect_mutex: std.Io.Mutex = .init;
var effect_settings: EffectSettings = .{};

pub fn getEffectSettings(io: std.Io) EffectSettings {
    effect_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking effect mutex on getting effects {}", .{err});
        return .{};
    };
    defer effect_mutex.unlock(io);
    return effect_settings;
}

pub fn resetEffectSettings(io: std.Io) void {
    effect_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking effect mutex on reset effects {}", .{err});
        return;
    };
    defer effect_mutex.unlock(io);
    effect_settings = .{};
}

pub fn setEffectChance(io: std.Io, percent: u32) void {
    effect_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking effect mutex on effect chance {}", .{err});
        return;
    };
    defer effect_mutex.unlock(io);
    effect_settings.chance_percent = percent;
}

pub fn setEffectSlow(io: std.Io, factor: f64) void {
    effect_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking effect mutex on slow effect {}", .{err});
        return;
    };
    defer effect_mutex.unlock(io);
    effect_settings.slow_factor = factor;
}

pub fn setEffectFast(io: std.Io, factor: f64) void {
    effect_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking effect mutex on fast effect {}", .{err});
        return;
    };
    defer effect_mutex.unlock(io);
    effect_settings.fast_factor = factor;
}

pub fn setReverbChance(io: std.Io, percent: u32) void {
    effect_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking effect mutex on reverb chance {}", .{err});
        return;
    };
    defer effect_mutex.unlock(io);
    effect_settings.reverb_chance_percent = percent;
}

pub fn setReverbAmount(io: std.Io, amount: u32) void {
    effect_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking effect mutex on reverb amount {}", .{err});
        return;
    };
    defer effect_mutex.unlock(io);
    effect_settings.reverb_amount = amount;
}

fn rollEffect(io: std.Io, rand: std.Random) Effect {
    const settings = getEffectSettings(io);
    const roll = rand.intRangeLessThan(u32, 0, 100);
    if (roll >= settings.chance_percent) return .none;
    return if (rand.boolean()) .slow else .fast;
}

fn rollReverb(io: std.Io, rand: std.Random) bool {
    const settings = getEffectSettings(io);
    const roll = rand.intRangeLessThan(u32, 0, 100);
    return roll < settings.reverb_chance_percent;
}

const MasterSettings = struct {
    volume_percent: u32 = 80,
    ytvolume_percent: u32 = 50,
    compressor_enabled: bool = true,
    compressor_threshold_percent: u32 = 5,
    compressor_ratio: f64 = 4,
    compressor_makeup: f64 = 1,
};

var master_mutex: std.Io.Mutex = .init;
var master_settings: MasterSettings = .{};

pub fn getMasterSettings(io: std.Io) MasterSettings {
    master_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking master settings mutex on getting master settings {}", .{err});
        return .{};
    };
    defer master_mutex.unlock(io);
    return master_settings;
}

pub fn resetMasterSettings(io: std.Io, sink: []const u8) void {
    master_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error resetting master settings mutex {}", .{err});
        return;
    };
    master_settings = .{};
    master_mutex.unlock(io);
    if (current_is_yt.load(.acquire)) {
        applySinkVolume(io, sink, master_settings.ytvolume_percent);
    } else {
        applySinkVolume(io, sink, master_settings.volume_percent);
    }
}

pub fn setVolume(io: std.Io, percent: u32, sink: []const u8) void {
    master_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error setting master settings volume mutex {}", .{err});
        return;
    };
    master_settings.volume_percent = percent;
    master_mutex.unlock(io);
    if (!current_is_yt.load(.acquire)) {
        applySinkVolume(io, sink, percent);
    }
}

pub fn setYtVolume(io: std.Io, percent: u32, sink: []const u8) void {
    master_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error setting master settings yt volume mutex {}", .{err});
        return;
    };
    master_settings.ytvolume_percent = percent;
    master_mutex.unlock(io);
    if (current_is_yt.load(.acquire)) {
        applySinkVolume(io, sink, percent);
    }
}

fn applySinkVolume(io: std.Io, sink: []const u8, percent: u32) void {
    var buf: [8]u8 = undefined;
    const percent_arg = std.fmt.bufPrint(&buf, "{d}%", .{percent}) catch return;
    runCmd(io, &.{ "pactl", "set-sink-volume", sink, percent_arg }) catch |err| {
        std.debug.print("[soundbot] failed to set live sink volume: {}\n", .{err});
    };
}

pub fn setCompressorEnabled(io: std.Io, enabled: bool) void {
    master_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error enabling master settings compressor mutex {}", .{err});
        return;
    };
    defer master_mutex.unlock(io);
    master_settings.compressor_enabled = enabled;
}

pub fn setCompressorParams(io: std.Io, threshold_percent: u32, ratio: f64, makeup: f64) void {
    master_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error setting master settings compressor mutex {}", .{err});
        return;
    };
    defer master_mutex.unlock(io);
    master_settings.compressor_threshold_percent = threshold_percent;
    master_settings.compressor_ratio = ratio;
    master_settings.compressor_makeup = makeup;
    master_settings.compressor_enabled = true;
}

pub const PlayerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ptt_key: []const u8,
    sink: []const u8,
};

pub fn enqueueSound(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, name: []const u8, sound_path: []const u8, delete_after: bool, skip_effects: bool) !void {
    const effect: Effect = if (skip_effects) .none else rollEffect(io, rand);
    const reverb: bool = if (skip_effects) false else rollReverb(io, rand);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    queue_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking queue mutex {}", .{err});
        return;
    };
    defer queue_mutex.unlock(io);
    try sound_queue.append(allocator, .{ .name = owned_name, .sound_path = sound_path, .effect = effect, .reverb = reverb, .skip_effects = skip_effects, .delete_after = delete_after });
    queue_cond.signal(io);
}

pub fn clearQueueAndStopCurrent(allocator: std.mem.Allocator, io: std.Io) void {
    queue_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error locking queue mutex on clear {}", .{err});
        return;
    };
    for (sound_queue.items) |item| {
        if (item.delete_after) std.Io.Dir.cwd().deleteFile(io, item.sound_path) catch {};
        allocator.free(item.sound_path);
    }
    sound_queue.clearRetainingCapacity();
    queue_mutex.unlock(io);

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
        result = .playback;
    }

    return result;
}

pub fn playerLoop(ctx: *const PlayerCtx) !void {
    while (true) {
        try queue_mutex.lock(ctx.io);
        while (sound_queue.items.len == 0) {
            try queue_cond.wait(ctx.io, &queue_mutex);
        }
        const item = sound_queue.orderedRemove(0);
        queue_mutex.unlock(ctx.io);

        setCurrentName(ctx.allocator, ctx.io, item.name);
        playOne(ctx, item.sound_path, item.effect, item.reverb, item.skip_effects);
        clearCurrentName(ctx.allocator, ctx.io);

        if (item.delete_after) std.Io.Dir.cwd().deleteFile(ctx.io, item.sound_path) catch {};
        ctx.allocator.free(item.sound_path);
        ctx.allocator.free(item.name);
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

    current_is_yt.store(skip_effects, .release);
    const master = getMasterSettings(ctx.io);
    applySinkVolume(ctx.io, ctx.sink, if (skip_effects) master.ytvolume_percent else master.volume_percent);

    runCmd(ctx.io, &.{ "xdotool", "keydown", ctx.ptt_key }) catch |err| {
        std.debug.print("[soundbot] keydown failed: {}\n", .{err});
    };
    ctx.io.sleep(.fromMilliseconds(50), .awake) catch {};

    playFile(ctx, sound_path, effect, reverb, skip_effects) catch |err| {
        std.debug.print("[soundbot] playback failed: {}\n", .{err});
    };

    ctx.io.sleep(.fromMilliseconds(50), .awake) catch {};
    runCmd(ctx.io, &.{ "xdotool", "keyup", ctx.ptt_key }) catch |err| {
        std.debug.print("[soundbot] keyup failed: {}\n", .{err});
    };
}

// asetrate needs a literal numeric sample rate
fn probeSampleRate(io: std.Io, sound_path: []const u8) !u32 {
    var child = try std.process.spawn(io, .{
        .argv = &.{
            "ffprobe",            "-v",  "error",
            "-select_streams",    "a:0", "-show_entries",
            "stream=sample_rate", "-of", "csv=p=0",
            sound_path,
        },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    });

    const stdout = child.stdout.?;
    var buf: [32]u8 = undefined;
    var dest = [_][]u8{&buf};
    const n = try stdout.readStreaming(io, &dest);
    _ = child.wait(io) catch {};

    const trimmed = std.mem.trim(u8, buf[0..n], " \r\n\t");
    return std.fmt.parseInt(u32, trimmed, 10) catch 48000;
}

fn runAndTrackPid(io: std.Io, argv: []const []const u8, pid_var: *std.atomic.Value(i32)) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });

    const pid = child.id orelse return error.NoPid;
    pid_var.store(@intCast(pid), .release);
    _ = child.wait(io) catch {};
    pid_var.store(-1, .release);
}

pub fn runAndTrack(io: std.Io, argv: []const []const u8) !void {
    return runAndTrackPid(io, argv, &current_pid);
}

pub fn runAndTrackDownload(io: std.Io, argv: []const []const u8) !void {
    return runAndTrackPid(io, argv, &download_pid);
}

fn playFile(ctx: *const PlayerCtx, sound_path: []const u8, effect: Effect, reverb: bool, skip_effects: bool) !void {
    const master = getMasterSettings(ctx.io);
    const compressor_active = master.compressor_enabled and !skip_effects;

    if (effect == .none and !reverb and !compressor_active) {
        if (std.mem.endsWith(u8, sound_path, ".wav")) {
            return runAndTrack(ctx.io, &.{ "paplay", "--device", ctx.sink, sound_path });
        }
        if (std.mem.endsWith(u8, sound_path, ".mp3")) {
            return runAndTrack(ctx.io, &.{ "mpg123", "-q", "-o", "pulse", "-a", ctx.sink, sound_path });
        }
        return runAndTrack(ctx.io, &.{ "ffmpeg", "-nostdin", "-loglevel", "error", "-i", sound_path, "-f", "pulse", ctx.sink });
    }

    var temp_paths: [3][]const u8 = undefined;
    var temp_count: usize = 0;
    defer {
        var i: usize = 0;
        while (i < temp_count) : (i += 1) {
            std.Io.Dir.cwd().deleteFile(ctx.io, temp_paths[i]) catch {};
            ctx.allocator.free(temp_paths[i]);
        }
    }

    var current_path: []const u8 = sound_path;

    if (effect != .none) {
        const factor: f64 = switch (effect) {
            .none => unreachable,
            .slow => getEffectSettings(ctx.io).slow_factor,
            .fast => getEffectSettings(ctx.io).fast_factor,
        };
        const original_rate = probeSampleRate(ctx.io, current_path) catch 48000;
        const new_rate: f64 = @as(f64, @floatFromInt(original_rate)) * factor;

        var filter_buf: [64]u8 = undefined;
        const filter_arg = try std.fmt.bufPrint(
            &filter_buf,
            "asetrate={d:.0},aresample={d}",
            .{ new_rate, original_rate },
        );

        const tmp_path = try std.fmt.allocPrint(ctx.allocator, "/tmp/soundbot_pitch_{d}.wav", .{std.Io.Clock.real.now(ctx.io).nanoseconds});
        try runAndTrack(ctx.io, &.{
            "ffmpeg", "-nostdin",   "-loglevel", "error",    "-y",
            "-i",     current_path, "-filter:a", filter_arg, tmp_path,
        });

        temp_paths[temp_count] = tmp_path;
        temp_count += 1;
        current_path = tmp_path;
    }

    if (reverb) {
        const amount = getEffectSettings(ctx.io).reverb_amount;
        var amount_buf: [8]u8 = undefined;
        const amount_arg = try std.fmt.bufPrint(&amount_buf, "{d}", .{amount});

        const tmp_path = try std.fmt.allocPrint(ctx.allocator, "/tmp/soundbot_reverb_{d}.wav", .{std.Io.Clock.real.now(ctx.io).nanoseconds});
        try runAndTrack(ctx.io, &.{ "sox", current_path, tmp_path, "reverb", amount_arg });

        temp_paths[temp_count] = tmp_path;
        temp_count += 1;
        current_path = tmp_path;
    }

    if (compressor_active) {
        var filter_buf: [128]u8 = undefined;
        const threshold_linear = @as(f64, @floatFromInt(master.compressor_threshold_percent)) / 100.0;
        const filter_arg = try std.fmt.bufPrint(
            &filter_buf,
            "acompressor=threshold={d:.4}:ratio={d:.2}:attack=20:release=250:makeup={d:.2}",
            .{ threshold_linear, master.compressor_ratio, master.compressor_makeup },
        );

        const tmp_path = try std.fmt.allocPrint(ctx.allocator, "/tmp/soundbot_master_{d}.wav", .{std.Io.Clock.real.now(ctx.io).nanoseconds});
        try runAndTrack(ctx.io, &.{
            "ffmpeg", "-nostdin",   "-loglevel", "error",    "-y",
            "-i",     current_path, "-filter:a", filter_arg, tmp_path,
        });

        temp_paths[temp_count] = tmp_path;
        temp_count += 1;
        current_path = tmp_path;
    }

    try runAndTrack(ctx.io, &.{ "paplay", "--device", ctx.sink, current_path });
}

pub fn triggerSound(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, sounds_dir: []const u8, name: []const u8) !bool {
    if (try sounds.findSoundFile(allocator, io, sounds_dir, name)) |path| {
        try enqueueSound(allocator, io, rand, name, path, false, false);
        return true;
    }

    if (try sounds.findSoundFileFamily(allocator, io, rand, sounds_dir, name)) |path| {
        try enqueueSound(allocator, io, rand, name, path, false, false);
        return true;
    }

    std.debug.print("[soundbot] no sound file found for !{s}\n", .{name});
    return false;
}

pub fn triggerRandomSound(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, sounds_dir: []const u8) !bool {
    if (try sounds.pickRandomSoundFile(allocator, io, rand, sounds_dir)) |path| {
        try enqueueSound(allocator, io, rand, std.fs.path.basename(path), path, false, false);
        return true;
    }
    return false;
}
