const std = @import("std");
const config_mod = @import("config.zig");
const ts_protocol = @import("ts_protocol.zig");
const sounds = @import("sounds.zig");
const query = @import("query.zig");
const playback = @import("playback.zig");
const tts = @import("tts.zig");
const youtube = @import("youtube.zig");

const Config = config_mod.Config;

const help_text =
    \\Commands:
    \\
    \\* !<name> - play a sound (see !sounds for the list)
    \\* !random (!r) - play a random sound (see !sounds for the list)
    \\* !sequence (!seq) <name1> <name2> - play a sequence of sounds (see !sounds for the list)
    \\* !skip - skip current sound or cancel an in-progress download; queue keeps playing
    \\* !stop - clear the queue, stop current playback
    \\* !current - show what's playing right now
    \\* !queue - show what's waiting in the queue
    \\* !sounds - list available sound triggers
    \\* !voices - list available TTS voices
    \\* !ttsg/!ttsb/!ttsjo/!ttsma/!ttssa/!ttsam/!ttsem/!ttsju/!ttsni/!ttsca/!ttsm/!ttst <text> - text-to-speech (see !voices)
    \\* !tts <text> - text-to-speech, random voice
    \\* !volume <0-100> — overall volume (80 by default). YouTube volume is set with !ytvolume
    \\* !yt <url or search> - play audio from YouTube (or anywhere yt-dlp supports)
    \\* !ytlength <seconds> - cap yt clip length (0 = no cap)
    \\* !ytvolume <0-100> - volume for YoutTube audio specifically (50 by default)
    \\* !chance <0-100> - % chance a sound gets pitch+speed shifted
    \\* !slow / !fast <0.5-2.0> - how much, when it does
    \\* !chancereverb <0-100> - % chance a sound gets reverb (independent of !chance)
    \\* !reverbamount <0-100> - how much reverb, when it does
    \\* !compressor on/off, or !compressor <threshold 1-100> <ratio 1-20> <makeup 1-64>
    \\* !default - reset effect and master settings to default values
    \\* !status - show current effect and master settings
    \\* !help - this message
;

// ---- Clean shutdown: send "quit" to the ServerQuery session instead of just dying ----
// Without this, Ctrl+C (or any kill) just severs the pipe, leaving a half-closed
// session server-side that can cause the *next* launch to fail (stale session /
// anti-flood heuristics tripping on a rapid reconnect from the same IP).

var g_ssh_stdin: ?std.Io.File = null;

fn handleShutdownSignal(_: @TypeOf(std.posix.SIG.INT)) callconv(.c) void {
    std.process.exit(0);
}

fn installShutdownHandler() !void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
}

fn buildStatusText(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const eff = playback.getEffectSettings(io);
    const mas = playback.getMasterSettings(io);
    const yt_len = youtube.getMaxSeconds(io);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [128]u8 = undefined;

    try out.appendSlice(allocator, "Current settings:\n\n");
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "* !chance: {d}% (!slow={d:.2}x, !fast={d:.2}x)\n", .{ eff.chance_percent, eff.slow_factor, eff.fast_factor }) catch "* !chance: (error formatting)\n");
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "* !chancereverb: {d}% (!reverbamount={d})\n", .{ eff.reverb_chance_percent, eff.reverb_amount }) catch "* !chancereverb: (error formatting)\n");
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "* !volume: {d}%\n", .{mas.volume_percent}) catch "* !volume: (error formatting)\n");
    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "* !ytvolume: {d}%\n", .{mas.ytvolume_percent}) catch "* !ytvolume: (error formatting)\n");
    if (mas.compressor_enabled) {
        try out.appendSlice(allocator, std.fmt.bufPrint(
            &buf,
            "* !compressor: on (threshold={d}, ratio={d:.2}:1, makeup={d:.2}x)\n",
            .{ mas.compressor_threshold_percent, mas.compressor_ratio, mas.compressor_makeup },
        ) catch "* !compressor: on (error formatting)\n");
    } else {
        try out.appendSlice(allocator, "* !compressor: off\n");
    }
    if (yt_len == 0) {
        try out.appendSlice(allocator, "* !ytlength: 0 (no cap)\n");
    } else {
        try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "* !ytlength: {d}\n", .{yt_len}) catch "* !ytlength: (error formatting)\n");
    }

    return out.toOwnedSlice(allocator);
}

fn buildQueueText(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const queue_names = try playback.getCurrentQueue(allocator, io);
    defer playback.freeCurrentQueue(allocator, queue_names);

    if (queue_names.len == 0) {
        return try allocator.dupe(u8, "Queue is empty.");
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [16]u8 = undefined;

    try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "Queue ({d}):\n\n", .{queue_names.len}) catch "Queue:\n\n");
    for (queue_names, 0..) |item_name, i| {
        try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}. ", .{i + 1}) catch "- ");
        try out.appendSlice(allocator, item_name);
        try out.append(allocator, '\n');
    }

    return out.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const rng_impl: std.Random.IoSource = .{ .io = io };
    const rand = rng_impl.interface();

    try installShutdownHandler();

    const cfg = try Config.load(allocator);
    youtube.setCookiesPath(io, cfg.yt_cookies_path);

    const player_ctx = try allocator.create(playback.PlayerCtx);
    player_ctx.* = .{
        .allocator = allocator,
        .io = io,
        .ptt_key = cfg.ptt_key,
        .sink = cfg.sink,
    };
    const player_thread = try std.Thread.spawn(.{}, playback.playerLoop, .{player_ctx});
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

    var child = try std.process.spawn(io, .{
        .argv = ssh_argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    const stdin = child.stdin.?;
    const stdout = child.stdout.?;

    var read_buf: [8192]u8 = undefined;
    var line_reader = query.LineReader.init(stdout, io, &read_buf);

    // Give the SSH banner a moment to arrive before we start issuing commands.
    io.sleep(.fromSeconds(1), .awake) catch {};

    // 1. Select the virtual server.
    try query.doCommand(allocator, io, stdin, &line_reader, "use", "use {s}", .{cfg.vserver_id});

    // 2. Find our own client id so we can move ourselves into the target channel.
    try query.sendCommand(allocator, io, stdin, "whoami", .{});
    var my_clid: ?[]u8 = null;
    {
        var lines = try query.readUntilError(allocator, &line_reader);
        defer query.freeLines(allocator, &lines);
        for (lines.items) |line| {
            if (ts_protocol.extractField(line, "client_id=")) |val| {
                my_clid = try allocator.dupe(u8, val);
            }
        }
    }
    const clid = my_clid orelse {
        std.debug.print("[soundbot] could not determine own client_id from whoami\n", .{});
        return error.NoClientId;
    };
    defer allocator.free(clid);

    try query.doCommand(allocator, io, stdin, &line_reader, "clientmove (startup)", "clientmove clid={s} cid={s}", .{ clid, cfg.channel_id });
    try query.doCommand(allocator, io, stdin, &line_reader, "servernotifyregister textchannel", "servernotifyregister event=textchannel", .{});

    std.debug.print("[soundbot] ready - watching channel {s} for commands\n", .{cfg.channel_id});

    const keepalive_thread = try std.Thread.spawn(.{}, query.keepaliveLoop, .{ io, stdin });
    keepalive_thread.detach();

    while (true) {
        const maybe_line = try line_reader.readLine(allocator);
        const line = maybe_line orelse break; // ssh connection closed
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (!std.mem.startsWith(u8, trimmed, "notifytextmessage")) continue;

        const raw_msg = ts_protocol.extractField(trimmed, "msg=") orelse continue;
        const msg = try ts_protocol.unescapeTs(allocator, raw_msg);
        defer allocator.free(msg);

        if (!std.mem.startsWith(u8, msg, "!")) continue;
        const after_bang = msg[1..];

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

        if (std.mem.eql(u8, name, "yt")) {
            const query_text = std.mem.trim(u8, after_bang[name_end..], " \t");
            const owned_query = allocator.dupe(u8, query_text) catch |err| {
                std.debug.print("[soundbot] yt: failed to allocate: {}\n", .{err});
                continue;
            };
            const thread = std.Thread.spawn(.{}, youtube.handleYtCommandThread, .{ allocator, io, rand, owned_query }) catch |err| {
                std.debug.print("[soundbot] failed to spawn yt download thread: {}\n", .{err});
                allocator.free(owned_query);
                continue;
            };
            thread.detach();
            continue;
        }

        if (tts.findTtsVoice(name)) |voice_id| {
            const text = std.mem.trim(u8, after_bang[name_end..], " \t");
            const owned_text = allocator.dupe(u8, text) catch |err| {
                std.debug.print("[soundbot] tts: failed to allocate: {}\n", .{err});
                continue;
            };
            const thread = std.Thread.spawn(.{}, tts.handleTtsCommandThread, .{ allocator, io, rand, voice_id, null, owned_text }) catch |err| {
                std.debug.print("[soundbot] failed to spawn tts thread: {}\n", .{err});
                allocator.free(owned_text);
                continue;
            };
            thread.detach();
            continue;
        }

        if (std.mem.eql(u8, name, "tts")) {
            const text = std.mem.trim(u8, after_bang[name_end..], " \t");
            const voice_id = tts.tts_voices[rand.intRangeLessThan(usize, 0, tts.tts_voices.len)].voice_id;
            const owned_text = allocator.dupe(u8, text) catch |err| {
                std.debug.print("[soundbot] tts: failed to allocate: {}\n", .{err});
                continue;
            };
            const thread = std.Thread.spawn(.{}, tts.handleTtsCommandThread, .{ allocator, io, rand, voice_id, null, owned_text }) catch |err| {
                std.debug.print("[soundbot] failed to spawn tts thread: {}\n", .{err});
                allocator.free(owned_text);
                continue;
            };
            thread.detach();
            continue;
        }

        _ = std.ascii.lowerString(name, name);

        if (std.mem.eql(u8, name, "help")) {
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, help_text);
            continue;
        }

        if (std.mem.eql(u8, name, "status")) {
            const status_msg = buildStatusText(allocator, io) catch |err| {
                std.debug.print("[soundbot] failed to build status: {}\n", .{err});
                continue;
            };
            defer allocator.free(status_msg);
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, status_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "default")) {
            playback.resetEffectSettings(io);
            playback.resetMasterSettings(io, cfg.sink);
            youtube.setMaxSeconds(io, 0);
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "All tunable settings reset to defaults.");
            continue;
        }

        if (std.mem.eql(u8, name, "stop")) {
            playback.clearQueueAndStopCurrent(allocator, io);
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Queue cleared, playback stopped.");
            continue;
        }

        if (std.mem.eql(u8, name, "skip")) {
            switch (playback.skipCurrent()) {
                .nothing => query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Nothing is currently playing or downloading to skip."),
                .playback => query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Skipped - playing the next sound in queue."),
                .download => query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Cancelled the in-progress download/synthesis."),
            }
            continue;
        }

        if (std.mem.eql(u8, name, "current")) {
            const current_name = playback.getCurrentName(allocator, io) catch |err| {
                std.debug.print("[soundbot] failed to get current name: {}\n", .{err});
                continue;
            };
            defer allocator.free(current_name);
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, current_name);
            continue;
        }

        if (std.mem.eql(u8, name, "queue")) {
            const queue_msg = buildQueueText(allocator, io) catch |err| {
                std.debug.print("[soundbot] failed to build queue text: {}\n", .{err});
                continue;
            };
            defer allocator.free(queue_msg);
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, queue_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "sounds")) {
            const list_msg = sounds.buildSoundsList(allocator, io, cfg.sounds_dir) catch |err| {
                std.debug.print("[soundbot] failed to build sounds list: {}\n", .{err});
                continue;
            };
            defer allocator.free(list_msg);

            const reply_targetmode = ts_protocol.extractField(trimmed, "targetmode=") orelse "2";
            const reply_target = ts_protocol.extractField(trimmed, "target=") orelse cfg.channel_id;

            query.sendReply(allocator, io, stdin, &line_reader, reply_targetmode, reply_target, list_msg) catch |err| {
                std.debug.print("[soundbot] failed to send sounds list: {}\n", .{err});
            };
            continue;
        }

        if (std.mem.eql(u8, name, "voices")) {
            const list_msg = tts.buildVoicesList(allocator) catch |err| {
                std.debug.print("[soundbot] failed to build voices list: {}\n", .{err});
                continue;
            };
            defer allocator.free(list_msg);

            const reply_targetmode = ts_protocol.extractField(trimmed, "targetmode=") orelse "2";
            const reply_target = ts_protocol.extractField(trimmed, "target=") orelse cfg.channel_id;

            query.sendReply(allocator, io, stdin, &line_reader, reply_targetmode, reply_target, list_msg) catch |err| {
                std.debug.print("[soundbot] failed to send voices list: {}\n", .{err});
            };
            continue;
        }

        if (std.mem.eql(u8, name, "ytlength")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const seconds = std.fmt.parseInt(u32, rest, 10) catch {
                std.debug.print("[soundbot] !ytlength needs a whole number of seconds (0 for no cap), e.g. !ytlength 30\n", .{});
                continue;
            };
            if (seconds != 0 and (seconds < 5 or seconds > 3600)) {
                std.debug.print("[soundbot] !ytlength should be 0 (no cap) or 5-3600 seconds, got {d}\n", .{seconds});
                continue;
            }
            youtube.setMaxSeconds(io, seconds);
            if (seconds == 0) {
                std.debug.print("[soundbot] yt length cap removed - full tracks will play\n", .{});
            } else {
                std.debug.print("[soundbot] yt clip length capped at {d}s\n", .{seconds});
            }
            continue;
        }

        if (std.mem.eql(u8, name, "chance")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const percent = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "!chance needs a whole number 0-100, e.g. !chance 10");
                continue;
            };
            if (percent > 100) {
                var buf: [64]u8 = undefined;
                const ok_msg = std.fmt.bufPrint(&buf, "!chance must be 0-100, got {d}", .{percent}) catch "!chance must be 0-100";
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, ok_msg);
                continue;
            }
            playback.setEffectChance(io, percent);
            var buf: [64]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&buf, "Effect chance set to {d}%", .{percent}) catch "Effect chance updated";
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, err_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "slow")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const factor = std.fmt.parseFloat(f64, rest) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "!slow needs a number, e.g. !slow 0.7");
                continue;
            };
            if (factor < 0.5 or factor > 2.0) {
                var buf: [96]u8 = undefined;
                const ok_msg = std.fmt.bufPrint(&buf, "!slow should be 0.5-2.0 (outside that it stops sounding like a usable effect), got {d}", .{factor}) catch "!slow should be 0.5-2.0";
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, ok_msg);
                continue;
            }
            playback.setEffectSlow(io, factor);
            var buf: [64]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&buf, "Slow+pitch-down factor set to {d}x", .{factor}) catch "Slow factor updated";
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, err_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "fast")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const factor = std.fmt.parseFloat(f64, rest) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "!fast needs a number, e.g. !fast 1.3");
                continue;
            };
            if (factor < 0.5 or factor > 2.0) {
                var buf: [96]u8 = undefined;
                const ok_msg = std.fmt.bufPrint(&buf, "!fast should be 0.5-2.0 (outside that it stops sounding like a usable effect), got {d}", .{factor}) catch "!fast should be 0.5-2.0";
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, ok_msg);
                continue;
            }
            playback.setEffectFast(io, factor);
            var buf: [64]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&buf, "Fast+pitch-up factor set to {d}x", .{factor}) catch "Fast factor updated";
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, err_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "chancereverb")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const percent = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "!chancereverb needs a whole number 0-100, e.g. !chancereverb 10");
                continue;
            };
            if (percent > 100) {
                var buf: [64]u8 = undefined;
                const ok_msg = std.fmt.bufPrint(&buf, "!chancereverb must be 0-100, got {d}", .{percent}) catch "!chancereverb must be 0-100";
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, ok_msg);
                continue;
            }
            playback.setReverbChance(io, percent);
            var buf: [96]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&buf, "Reverb chance set to {d}% (independent of !chance)", .{percent}) catch "Reverb chance updated";
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, err_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "reverbamount")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const amount = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "!reverbamount needs a whole number 0-100, e.g. !reverbamount 50");
                continue;
            };
            if (amount > 100) {
                var buf: [64]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!reverbamount must be 0-100, got {d}", .{amount}) catch "!reverbamount must be 0-100";
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setReverbAmount(io, amount);
            var buf: [64]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "Reverb amount set to {d}", .{amount}) catch "Reverb amount updated";
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "volume")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const percent = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "!volume needs a whole number 0-100, e.g. !volume 80");
                continue;
            };
            if (percent > 100) {
                var buf: [64]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!volume must be 0-100, got {d}", .{percent}) catch "!volume must be 0-100";
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setVolume(io, percent, cfg.sink);
            var buf: [128]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "Volume set to {d}%", .{percent}) catch "Volume updated";
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "ytvolume")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const percent = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "!ytvolume needs a whole number 0-100, e.g. !ytvolume 80");
                continue;
            };
            if (percent > 100) {
                var buf: [64]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!ytvolume must be 0-100, got {d}", .{percent}) catch "!ytvolume must be 0-100";
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setYtVolume(io, percent, cfg.sink);
            var buf: [128]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "YouTube volume set to {d}%", .{percent}) catch "Yt volume updated";
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "compressor")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            if (std.mem.eql(u8, rest, "on")) {
                playback.setCompressorEnabled(io, true);
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Compressor enabled - evens out loud/quiet sounds.");
                continue;
            }
            if (std.mem.eql(u8, rest, "off")) {
                playback.setCompressorEnabled(io, false);
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Compressor disabled.");
                continue;
            }

            const usage_msg = "!compressor needs 'on', 'off', or exactly 3 numbers: !compressor <threshold 1-100> <ratio 1-20> <makeup 1-64>, e.g. !compressor 10 4 1";

            var parts = std.mem.splitScalar(u8, rest, ' ');
            const part1 = parts.next();
            const part2 = parts.next();
            const part3 = parts.next();
            const extra = parts.next();

            if (part1 == null or part2 == null or part3 == null or extra != null) {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, usage_msg);
                continue;
            }

            const threshold_percent = std.fmt.parseInt(u32, part1.?, 10) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, usage_msg);
                continue;
            };
            const ratio = std.fmt.parseFloat(f64, part2.?) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, usage_msg);
                continue;
            };
            const makeup = std.fmt.parseFloat(f64, part3.?) catch {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, usage_msg);
                continue;
            };

            if (threshold_percent < 1 or threshold_percent > 100) {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Threshold must be 1-100.");
                continue;
            }
            if (ratio < 1.0 or ratio > 20.0) {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Ratio must be 1-20 (ffmpeg's acompressor limit).");
                continue;
            }
            if (makeup < 1.0 or makeup > 64.0) {
                query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, "Makeup must be 1-64 (ffmpeg's acompressor limit).");
                continue;
            }

            playback.setCompressorParams(io, threshold_percent, ratio, makeup);
            var buf: [128]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(
                &buf,
                "Compressor enabled: threshold={d}, ratio={d}:1, makeup={d}x",
                .{ threshold_percent, ratio, makeup },
            ) catch "Compressor settings updated and enabled";
            query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "seq") or std.mem.eql(u8, name, "sequence")) {
            _ = std.ascii.lowerString(after_bang[name_end..], after_bang[name_end..]);

            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");

            var parts = std.mem.splitScalar(u8, rest, ' ');

            while (parts.next()) |sound| {
                if (sound.len == 0 or sound.len >= 100) continue;

                const found = playback.triggerSound(allocator, io, rand, cfg.sounds_dir, sound) catch |err| {
                    std.debug.print("[soundbot] Couldn't play {s}: {}\n", .{ sound, err });
                    continue;
                };
                if (!found) {
                    var buf: [128]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&buf, "Sound not found: {s}", .{sound}) catch "Sound not found";
                    query.replyToTrigger(allocator, io, stdin, &line_reader, trimmed, cfg.channel_id, err_msg);
                }
            }

            continue;
        }

        if (std.mem.eql(u8, name, "r") or std.mem.eql(u8, name, "random")) {
            _ = playback.triggerRandomSound(allocator, io, rand, cfg.sounds_dir) catch |err| {
                std.debug.print("[soundbot] Couldn't play a random sound: {}\n", .{err});
            };

            continue;
        }

        if (name.len >= 100) continue;

        _ = playback.triggerSound(allocator, io, rand, cfg.sounds_dir, name) catch |err| {
            std.debug.print("[soundbot] trigger failed: {}\n", .{err});
        };
    }

    _ = stdin.writeStreamingAll(io, "quit\n") catch {};
    _ = try child.wait(io);
}
