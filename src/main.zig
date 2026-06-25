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
    \\* !stop - clear the queue, stop current playback
    \\* !sounds - list available sound triggers
    \\* !voices - list available TTS voices
    \\* !ttsg/!ttsb/!ttsjo/!ttsma/!ttssa/!ttsam/!ttsem/!ttsju/!ttsni/!ttsca/!ttsm/!ttst <text> - text-to-speech (see !voices)
    \\* !tts <text> - text-to-speech, random voice
    \\* !yt <url or search> - play audio from YouTube (or anywhere yt-dlp supports)
    \\* !ytlength <seconds> - cap yt clip length (0 = no cap)
    \\* !join [channel_id] - move the bot here (or to a specific channel)
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

fn buildStatusText(allocator: std.mem.Allocator) ![]u8 {
    const effect_settings = playback.getEffectSettings();
    const master_settings = playback.getMasterSettings();

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    const w = out.writer();

    try w.writeAll("Current settings:\n\n");

    inline for (std.meta.fields(@TypeOf(effect_settings))) |field| {
        try w.print("* {s} = {any}\n", .{ field.name, @field(effect_settings, field.name) });
    }
    inline for (std.meta.fields(@TypeOf(master_settings))) |field| {
        try w.print("* {s} = {any}\n", .{ field.name, @field(master_settings, field.name) });
    }

    return out.toOwnedSlice();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try Config.load(allocator);
    youtube.setCookiesPath(cfg.yt_cookies_path);

    playback.initQueue(allocator);

    const player_ctx = try allocator.create(playback.PlayerCtx);
    player_ctx.* = .{
        .allocator = allocator,
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
    try query.doCommand(allocator, stdin, reader, "use", "use {s}", .{cfg.vserver_id});

    // 2. Find our own client id so we can move ourselves into the target channel.
    try query.sendCommand(stdin, "whoami", .{});
    var my_clid: ?[]u8 = null;
    {
        var lines = try query.readUntilError(allocator, reader);
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

    // 3. Move into the configured channel.
    try query.doCommand(allocator, stdin, reader, "clientmove (startup)", "clientmove clid={s} cid={s}", .{ clid, cfg.channel_id });

    // 4. Register for chat notifications: per-channel (for normal triggers) and
    //    server-wide (so a bare "!join" typed from any channel's chat - or the
    //    server chat tab - can still reach us, since textchannel notifications
    //    are scoped to wherever we're currently sitting).
    try query.doCommand(allocator, stdin, reader, "servernotifyregister textchannel", "servernotifyregister event=textchannel", .{});
    try query.doCommand(allocator, stdin, reader, "servernotifyregister textserver", "servernotifyregister event=textserver", .{});

    std.debug.print("[soundbot] ready - watching channel {s} for !sound<N>\n", .{cfg.channel_id});

    const keepalive_thread = try std.Thread.spawn(.{}, query.keepaliveLoop, .{stdin});
    keepalive_thread.detach();

    // 5. Main loop: read lines forever, react to notifytextmessage.
    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 8192);
        const line = maybe_line orelse break; // ssh connection closed
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (!std.mem.startsWith(u8, trimmed, "notifytextmessage")) continue;

        const raw_msg = ts_protocol.extractField(trimmed, "msg=") orelse continue;
        const msg = try ts_protocol.unescapeTs(allocator, raw_msg);
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

        if (std.mem.eql(u8, name, "help")) {
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, help_text);
            continue;
        }

        if (std.mem.eql(u8, name, "default")) {
            playback.resetEffectsSettings();
            playback.resetMasterSettings();
            std.debug.print("[soundbot] Default settings restored.\n", .{});
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "Default settings restored.");
            continue;
        }

        if (std.mem.eql(u8, name, "status")) {
            const status_msg = buildStatusText(allocator) catch |err| {
                std.debug.print("[soundbot] failed to build status list: {}\n", .{err});
                continue;
            };
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, status_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "stop")) {
            playback.clearQueueAndStopCurrent(allocator);
            std.debug.print("[soundbot] Queue cleared, playback stopped.\n", .{});
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "Queue cleared, playback stopped.");
            continue;
        }

        if (std.mem.eql(u8, name, "sounds")) {
            const list_msg = sounds.buildSoundsList(allocator, cfg.sounds_dir) catch |err| {
                std.debug.print("[soundbot] failed to build sounds list: {}\n", .{err});
                continue;
            };
            defer allocator.free(list_msg);

            const reply_targetmode = ts_protocol.extractField(trimmed, "targetmode=") orelse "2";
            const reply_target = ts_protocol.extractField(trimmed, "target=") orelse cfg.channel_id;

            query.sendReply(allocator, stdin, reader, reply_targetmode, reply_target, list_msg) catch |err| {
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

            query.sendReply(allocator, stdin, reader, reply_targetmode, reply_target, list_msg) catch |err| {
                std.debug.print("[soundbot] failed to send voices list: {}\n", .{err});
            };
            continue;
        }

        if (tts.findTtsVoice(name)) |voice_id| {
            const text = std.mem.trim(u8, after_bang[name_end..], " \t");
            tts.handleTtsCommand(allocator, voice_id, null, text);
            continue;
        }

        if (std.mem.eql(u8, name, "tts")) {
            const text = std.mem.trim(u8, after_bang[name_end..], " \t");
            const voice_id = tts.tts_voices[std.crypto.random.intRangeLessThan(usize, 0, tts.tts_voices.len)].voice_id;
            tts.handleTtsCommand(allocator, voice_id, null, text);
            continue;
        }

        if (std.mem.eql(u8, name, "yt")) {
            const yt_query = std.mem.trim(u8, after_bang[name_end..], " \t");
            youtube.handleYtCommand(allocator, yt_query);
            continue;
        }

        if (std.mem.eql(u8, name, "ytlength")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const seconds = std.fmt.parseInt(u32, rest, 10) catch {
                std.debug.print("[soundbot] !ytlength needs a whole number of seconds (0 for no cap), e.g. !ytlength 30\n", .{});
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "!ytlength needs a whole number of seconds (0 for no cap), e.g. !ytlength 30");
                continue;
            };
            if (seconds != 0 and (seconds < 5 or seconds > 3600)) {
                std.debug.print("[soundbot] !ytlength should be 0 (no cap) or 5-3600 seconds, got {d}\n", .{seconds});
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "!ytlength should be 0 (no cap) or 5-3600 seconds");
                continue;
            }
            youtube.setMaxSeconds(seconds);
            if (seconds == 0) {
                std.debug.print("[soundbot] yt length cap removed - full tracks will play\n", .{});
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "yt length cap removed - full tracks will play");
            } else {
                std.debug.print("[soundbot] yt clip length capped at {d}s\n", .{seconds});

                var buf: [64]u8 = undefined;
                const ok_msg = std.fmt.bufPrint(&buf, "yt clip length capped at {d} seconds", .{seconds}) catch "yt clip length capped";
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, ok_msg);
            }
            continue;
        }

        if (std.mem.eql(u8, name, "chance")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const percent = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "!chance needs a whole number 0-100, e.g. !chance 10");
                continue;
            };
            if (percent > 100) {
                var buf: [64]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!chance must be 0-100, got {d}", .{percent}) catch "!chance must be 0-100";
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setEffectChance(percent);
            var buf: [64]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "Effect chance set to {d}%", .{percent}) catch "Effect chance updated";
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "slow")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const factor = std.fmt.parseFloat(f64, rest) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "!slow needs a number, e.g. !slow 0.7");
                continue;
            };
            if (factor < 0.5 or factor > 2.0) {
                var buf: [96]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!slow should be 0.5-2.0 (outside that it stops sounding like a usable effect), got {d}", .{factor}) catch "!slow should be 0.5-2.0";
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setEffectSlow(factor);
            var buf: [64]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "Slow+pitch-down factor set to {d}x", .{factor}) catch "Slow factor updated";
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "fast")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const factor = std.fmt.parseFloat(f64, rest) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "!fast needs a number, e.g. !fast 1.3");
                continue;
            };
            if (factor < 0.5 or factor > 2.0) {
                var buf: [96]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!fast should be 0.5-2.0 (outside that it stops sounding like a usable effect), got {d}", .{factor}) catch "!fast should be 0.5-2.0";
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setEffectFast(factor);
            var buf: [64]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "Fast+pitch-up factor set to {d}x", .{factor}) catch "Fast factor updated";
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "chancereverb")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const percent = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "!chancereverb needs a whole number 0-100, e.g. !chancereverb 10");
                continue;
            };
            if (percent > 100) {
                var buf: [64]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!chancereverb must be 0-100, got {d}", .{percent}) catch "!chancereverb must be 0-100";
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setReverbChance(percent);
            var buf: [96]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "Reverb chance set to {d}% (independent of !chance)", .{percent}) catch "Reverb chance updated";
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "reverbamount")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const amount = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "!reverbamount needs a whole number 0-100, e.g. !reverbamount 50");
                continue;
            };
            if (amount > 100) {
                var buf: [64]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!reverbamount must be 0-100, got {d}", .{amount}) catch "!reverbamount must be 0-100";
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setReverbAmount(amount);
            var buf: [64]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "Reverb amount set to {d}", .{amount}) catch "Reverb amount updated";
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "volume")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            const percent = std.fmt.parseInt(u32, rest, 10) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "!volume needs a whole number 0-100, e.g. !volume 80");
                continue;
            };
            if (percent > 100) {
                var buf: [64]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&buf, "!volume must be 0-100, got {d}", .{percent}) catch "!volume must be 0-100";
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, err_msg);
                continue;
            }
            playback.setVolume(percent);
            var buf: [64]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(&buf, "Volume set to {d}% (applies to everything)", .{percent}) catch "Volume updated";
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }
 
        if (std.mem.eql(u8, name, "compressor")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");
            if (std.mem.eql(u8, rest, "on")) {
                playback.setCompressorEnabled(true);
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "Compressor enabled - evens out loud/quiet sounds.");
                continue;
            }
            if (std.mem.eql(u8, rest, "off")) {
                playback.setCompressorEnabled(false);
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "Compressor disabled.");
                continue;
            }
 
            const usage_msg = "!compressor needs 'on', 'off', or exactly 3 numbers: !compressor <threshold 1-100> <ratio 1-20> <makeup 1-64>, e.g. !compressor 10 4 1";
 
            var parts = std.mem.splitScalar(u8, rest, ' ');
            const part1 = parts.next();
            const part2 = parts.next();
            const part3 = parts.next();
            const extra = parts.next();
 
            if (part1 == null or part2 == null or part3 == null or extra != null) {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, usage_msg);
                continue;
            }
 
            const threshold_percent = std.fmt.parseInt(u32, part1.?, 10) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, usage_msg);
                continue;
            };
            const ratio = std.fmt.parseFloat(f64, part2.?) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, usage_msg);
                continue;
            };
            const makeup = std.fmt.parseFloat(f64, part3.?) catch {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, usage_msg);
                continue;
            };
 
            // Bounds match ffmpeg's own acompressor limits, so an out-of-range
            // value fails clearly here instead of being silently rejected/clamped
            // by ffmpeg later with no chat feedback at all.
            if (threshold_percent < 1 or threshold_percent > 100) {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "Threshold must be 1-100.");
                continue;
            }
            if (ratio < 1.0 or ratio > 20.0) {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "Ratio must be 1-20 (ffmpeg's acompressor limit).");
                continue;
            }
            if (makeup < 1.0 or makeup > 64.0) {
                query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, "Makeup must be 1-64 (ffmpeg's acompressor limit).");
                continue;
            }
 
            playback.setCompressorParams(threshold_percent, ratio, makeup);
            var buf: [128]u8 = undefined;
            const ok_msg = std.fmt.bufPrint(
                &buf,
                "Compressor enabled: threshold={d}, ratio={d}:1, makeup={d}x",
                .{ threshold_percent, ratio, makeup },
            ) catch "Compressor settings updated and enabled";
            query.replyToTrigger(allocator, stdin, reader, trimmed, cfg.channel_id, ok_msg);
            continue;
        }

        if (std.mem.eql(u8, name, "join")) {
            const rest = std.mem.trim(u8, after_bang[name_end..], " \t");

            const target_cid: []u8 = blk: {
                if (rest.len == 0) {
                    const mode = ts_protocol.extractField(trimmed, "targetmode=") orelse "0";

                    if (std.mem.eql(u8, mode, "2")) {
                        // Channel chat - target= is the channel id directly.
                        const raw = ts_protocol.extractField(trimmed, "target=") orelse {
                            std.debug.print("[soundbot] !join: couldn't determine your channel; try !join <channel_id>\n", .{});
                            continue;
                        };
                        break :blk try allocator.dupe(u8, raw);
                    }

                    // Anything else (server-wide chat, most likely) - server chat doesn't
                    // carry a channel id, so look up the sender's current channel instead.
                    const invoker_clid = ts_protocol.extractField(trimmed, "invokerid=") orelse {
                        std.debug.print("[soundbot] !join: couldn't determine who sent this; try !join <channel_id>\n", .{});
                        continue;
                    };
                    try query.sendCommand(stdin, "clientlist", .{});
                    var found_cid: ?[]u8 = null;
                    {
                        var lookup_lines = try query.readUntilError(allocator, reader);
                        defer query.freeLines(allocator, &lookup_lines);
                        found_cid = try query.findChannelIdByClid(allocator, lookup_lines.items, invoker_clid);
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
            try query.sendCommand(stdin, "clientlist", .{});
            var voice_clid: ?[]u8 = null;
            {
                var lines = try query.readUntilError(allocator, reader);
                defer query.freeLines(allocator, &lines);
                voice_clid = try query.findClientIdByNickname(allocator, lines.items, cfg.voice_nickname);
            }
            const v_clid = voice_clid orelse {
                std.debug.print("[soundbot] no connected client named '{s}' - is the voice client online?\n", .{cfg.voice_nickname});
                continue;
            };
            defer allocator.free(v_clid);

            // 2. Drop the old chat subscription before moving, so it doesn't straddle channels
            //    (servernotifyregister's textchannel scope follows wherever this session sits).
            try query.doCommand(allocator, stdin, reader, "servernotifyunregister", "servernotifyunregister", .{});

            // 3. Move our own ServerQuery session into the new channel.
            try query.doCommand(allocator, stdin, reader, "clientmove (listener)", "clientmove clid={s} cid={s}", .{ clid, target_cid });

            // 4. Re-subscribe - this picks up whatever channel we're now sitting in,
            //    plus server-wide chat again for future cross-channel !join calls.
            try query.doCommand(allocator, stdin, reader, "servernotifyregister textchannel", "servernotifyregister event=textchannel", .{});
            try query.doCommand(allocator, stdin, reader, "servernotifyregister textserver", "servernotifyregister event=textserver", .{});

            // 5. Move the actual voice client too, so speaking follows listening.
            try query.doCommand(allocator, stdin, reader, "clientmove (voice)", "clientmove clid={s} cid={s}", .{ v_clid, target_cid });

            std.debug.print("[soundbot] moved to channel {s}\n", .{target_cid});
            continue;
        }

        playback.triggerSound(allocator, cfg.sounds_dir, name) catch |err| {
            std.debug.print("[soundbot] trigger failed: {}\n", .{err});
        };
    }

    g_ssh_stdin = null; // avoid the signal handler racing a write to an already-closing pipe
    _ = stdin.write("quit\n") catch {};
    _ = try child.wait();
}
