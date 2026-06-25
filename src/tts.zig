const std = @import("std");
const playback = @import("playback.zig");

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
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    try out.appendSlice("Available voices:\n\n");
    for (tts_voices) |v| {
        try out.appendSlice("* !");
        try out.appendSlice(v.cmd);
        try out.appendSlice(" - ");
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
    try playback.runAndTrackDownload(allocator, argv.items);
}
 
pub fn handleTtsCommand(allocator: std.mem.Allocator, voice_id: []const u8, engine: ?[]const u8, raw_text: []const u8) void {
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
 
    playback.enqueueSound(out_path, true, false) catch |err| {
        std.debug.print("[soundbot] failed to queue tts output: {}\n", .{err});
        allocator.free(out_path);
    };
}
 
// Thread entry point - same reasoning as youtube.zig's handleYtCommandThread:
// running this synchronously in the chat-dispatch loop would block it for the
// whole Polly call, during which !stop couldn't even be read from chat, let
// alone act on it. voice_id/engine are static/null and don't need freeing;
// raw_text does, since the caller must dupe it before spawning this (the
// original slice it was trimmed from is freed at the end of that loop
// iteration, long before a slow API call would actually return).
pub fn handleTtsCommandThread(allocator: std.mem.Allocator, voice_id: []const u8, engine: ?[]const u8, raw_text: []u8) void {
    defer allocator.free(raw_text);
    handleTtsCommand(allocator, voice_id, engine, raw_text);
}
