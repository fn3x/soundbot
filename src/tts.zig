const std = @import("std");
const playback = @import("playback.zig");

const max_tts_chars = 150;

const TtsVoice = struct {
    cmd: []const u8,
    voice_id: []const u8,
    language: []const u8,
};

pub const tts_voices = [_]TtsVoice{
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

pub fn findTtsVoice(name: []const u8) ?[]const u8 {
    inline for (tts_voices) |v| {
        if (std.mem.eql(u8, name, v.cmd)) return v.voice_id;
    }
    return null;
}

pub fn buildVoicesList(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "Available voices:\n\n");
    for (tts_voices) |v| {
        try out.appendSlice(allocator, "* !");
        try out.appendSlice(allocator, v.cmd);
        try out.appendSlice(allocator, " - ");
        try out.appendSlice(allocator, v.voice_id);
        try out.appendSlice(allocator, " (");
        try out.appendSlice(allocator, v.language);
        try out.appendSlice(allocator, ")\n");
    }
    try out.appendSlice(allocator, "* !tts - random voice\n");
    return out.toOwnedSlice(allocator);
}

fn synthesizeTts(allocator: std.mem.Allocator, io: std.Io, voice_id: []const u8, engine: ?[]const u8, text: []const u8, out_path: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "aws",          "polly", "synthesize-speech",
        "--output-format", "mp3",
        "--voice-id",   voice_id,
        "--text",       text,
    });
    if (engine) |e| {
        try argv.appendSlice(allocator, &.{ "--engine", e });
    }
    try argv.append(allocator, out_path);
    try playback.runAndTrackDownload(io, argv.items);
}
 
pub fn handleTtsCommand(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, voice_id: []const u8, engine: ?[]const u8, raw_text: []const u8) void {
    const text = if (raw_text.len > max_tts_chars) raw_text[0..max_tts_chars] else raw_text;
    if (text.len == 0) {
        std.debug.print("[soundbot] tts command needs some text after it, e.g. !ttsb hello there\n", .{});
        return;
    }
 
    const out_path = std.fmt.allocPrint(allocator, "/tmp/soundbot_tts_{d}.mp3", .{std.Io.Clock.real.now(io).nanoseconds}) catch |err| {
        std.debug.print("[soundbot] tts failed to build temp path: {}\n", .{err});
        return;
    };
 
    synthesizeTts(allocator, io, voice_id, engine, text, out_path) catch |err| {
        std.debug.print("[soundbot] tts synthesis failed: {}\n", .{err});
        allocator.free(out_path);
        return;
    };
 
    var name_buf: [64]u8 = undefined;
    const text_preview_len = @min(text.len, 40);
    const display_name = std.fmt.bufPrint(&name_buf, "tts ({s}): {s}", .{ voice_id, text[0..text_preview_len] }) catch "tts";

    _ = playback.enqueueSound(allocator, io, rand, display_name, out_path, true, false) catch |err| {
        std.debug.print("[soundbot] failed to queue tts output: {}\n", .{err});
        allocator.free(out_path);
    };
}
 
pub fn handleTtsCommandThread(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, voice_id: []const u8, engine: ?[]const u8, raw_text: []u8) void {
    defer allocator.free(raw_text);
    handleTtsCommand(allocator, io, rand, voice_id, engine, raw_text);
}
