const std = @import("std");
const Sounds = @import("zound").Sounds;
const Playback = @import("zound").Playback;

pub const PlayerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    ptt_key: []const u8,
    sink: []const u8,
};

pub fn playerLoop(ctx: *const PlayerCtx) !void {
    while (true) {
        try Playback.queue_mutex.lock(ctx.io);
        while (Playback.sound_queue.items.len == 0) {
            try Playback.queue_cond.wait(ctx.io, &Playback.queue_mutex);
        }
        const item = Playback.sound_queue.orderedRemove(0);

        defer ctx.allocator.free(item.sound_path);
        defer ctx.allocator.free(item.name);

        Playback.queue_mutex.unlock(ctx.io);

        Playback.setCurrentName(ctx.allocator, ctx.io, item.name) catch |err| {
            std.debug.print("[soundbot] set current name failed: {}\n", .{err});
            continue;
        };
        playOne(ctx, item.sound_path, item.effect, item.reverb, item.skip_effects);
        Playback.clearCurrentName(ctx.allocator, ctx.io) catch |err| {
            std.debug.print("[soundbot] clear current name failed: {}\n", .{err});
            continue;
        };

        if (item.delete_after) std.Io.Dir.cwd().deleteFile(ctx.io, item.sound_path) catch {};
    }
}

fn playOne(ctx: *const PlayerCtx, sound_path: []const u8, effect: Playback.Effect, reverb: bool, skip_effects: bool) void {
    const effect_label: []const u8 = switch (effect) {
        .none => "",
        .slow => " (slowed + pitched down)",
        .fast => " (sped up + pitched up)",
    };
    const reverb_label: []const u8 = if (reverb) " (reverb)" else "";
    std.debug.print("[soundbot] playing {s}{s}{s}\n", .{ sound_path, effect_label, reverb_label });

    Playback.current_is_yt.store(skip_effects, .release);
    const master = Playback.getMasterSettings(ctx.io) catch |err| {
        std.debug.print("[soundbot] get master settings failed: {}\n", .{err});
        return;
    };
    Playback.applySinkVolume(ctx.io, ctx.sink, if (skip_effects) master.ytvolume_percent else master.volume_percent) catch |err| {
        std.debug.print("[soundbot] apply sink volume failed: {}\n", .{err});
        return;
    };

    Playback.runCmd(ctx.io, &.{ "xdotool", "keydown", ctx.ptt_key }) catch |err| {
        std.debug.print("[soundbot] keydown failed: {}\n", .{err});
    };

    defer ctx.io.sleep(.fromMilliseconds(50), .awake) catch {};
    defer Playback.runCmd(ctx.io, &.{ "xdotool", "keyup", ctx.ptt_key }) catch |err| {
        std.debug.print("[soundbot] keyup failed: {}\n", .{err});
    };

    ctx.io.sleep(.fromMilliseconds(50), .awake) catch {};

    const player_ctx = ctx.allocator.create(Playback.PlayerCtx) catch |err| {
        std.debug.print("[soundbot] player context allocation failed: {}\n", .{err});
        return;
    };

    player_ctx.* = .{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .sink = ctx.sink,
    };

    const play_file = ctx.allocator.create(Playback.PlayFile) catch |err| {
        std.debug.print("[soundbot] play file allocation failed: {}\n", .{err});
        return;
    };

    play_file.* = .{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .sink = ctx.sink,
        .sound_path = sound_path,
        .effect = effect,
        .reverb = reverb,
        .skip_effects = skip_effects,
    };
    Playback.playFile(play_file) catch |err| {
        std.debug.print("[soundbot] playback failed: {}\n", .{err});
    };
}
