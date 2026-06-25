const std = @import("std");
const playback = @import("playback.zig");

var settings_mutex: std.Thread.Mutex = .{};
var max_seconds: u32 = 0; // 0 = no cap, play the whole thing (the default - good for songs)
var cookies_path_override: ?[]const u8 = null;

// Fallback when no override is set - if a cookies.txt file has been mounted
// in at this conventional path (see README), it's still picked up
// automatically, same as before TS_YT_COOKIES_PATH existed.
const default_cookies_path = "/opt/soundbot/cookies.txt";

pub fn setMaxSeconds(seconds: u32) void {
    settings_mutex.lock();
    defer settings_mutex.unlock();
    max_seconds = seconds;
}

fn getMaxSeconds() u32 {
    settings_mutex.lock();
    defer settings_mutex.unlock();
    return max_seconds;
}

// Set once at startup from TS_YT_COOKIES_PATH (see main.zig) - null is valid
// and means "no override configured", not "explicitly disabled".
pub fn setCookiesPath(path: ?[]const u8) void {
    settings_mutex.lock();
    defer settings_mutex.unlock();
    cookies_path_override = path;
}

// An explicitly configured path is trusted as-is (if it's wrong, yt-dlp's own
// error is more informative than silently skipping it). The conventional
// fallback path is only used if it's actually there, since unlike an explicit
// env var, its mere presence is the only signal that it's meant to be used.
fn resolveCookiesPath() ?[]const u8 {
    settings_mutex.lock();
    const override = cookies_path_override;
    settings_mutex.unlock();

    if (override) |p| return p;

    std.fs.cwd().access(default_cookies_path, .{}) catch return null;
    return default_cookies_path;
}

fn looksLikeUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

fn downloadAudio(allocator: std.mem.Allocator, query_or_url: []const u8, seconds: u32, out_path: []const u8) !void {
    // A bare URL is used as-is; anything else is treated as a YouTube search,
    // taking the top result - lets people type a title instead of pasting a link.
    const target = if (looksLikeUrl(query_or_url))
        try allocator.dupe(u8, query_or_url)
    else
        try std.fmt.allocPrint(allocator, "ytsearch1:{s}", .{query_or_url});
    defer allocator.free(target);

    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{
        "yt-dlp",
        "--no-playlist",
        "-x",
        "--audio-format", "mp3",
    });

    if (resolveCookiesPath()) |cookies_path| {
        try argv.appendSlice(&.{ "--cookies", cookies_path });
    }

    // "*0-N" downloads only that exact time range (the "*" means real
    // timestamps, not chapter markers). Only added when a cap is actually set -
    // omitting it entirely downloads (and plays) the full track.
    var section_buf: [32]u8 = undefined;
    if (seconds > 0) {
        const section_arg = try std.fmt.bufPrint(&section_buf, "*0-{d}", .{seconds});
        try argv.appendSlice(&.{ "--download-sections", section_arg });
    }

    try argv.appendSlice(&.{ "-o", out_path, target });
    try playback.runAndTrack(allocator, argv.items);

    // runAndTrack doesn't surface yt-dlp's exit code, so check for the actual
    // output file instead - simpler, and it's the only thing that actually
    // matters for whether playback can proceed. A failed extraction (bot
    // detection, deleted video, region lock, etc.) means no file ever exists,
    // and without this check that silently got queued anyway, surfacing as a
    // confusing "file not found" deep in playback instead of a clear error here.
    std.fs.cwd().access(out_path, .{}) catch {
        return error.YtDlpProducedNoFile;
    };
}

// Caught/logged here rather than propagated with `try`, same reasoning as the
// TTS handler: a network call to a third-party site is far more likely to
// transiently fail (rate limiting, a deleted video, a site layout change) than
// a local command, and that shouldn't be able to take the whole bot down.
pub fn handleYtCommand(allocator: std.mem.Allocator, raw_query: []const u8) void {
    if (raw_query.len == 0) {
        std.debug.print("[soundbot] !yt needs a URL or search query, e.g. !yt never gonna give you up\n", .{});
        return;
    }

    const out_path = std.fmt.allocPrint(allocator, "/tmp/soundbot_yt_{d}.mp3", .{std.time.milliTimestamp()}) catch |err| {
        std.debug.print("[soundbot] yt failed to build temp path: {}\n", .{err});
        return;
    };

    downloadAudio(allocator, raw_query, getMaxSeconds(), out_path) catch |err| {
        std.debug.print("[soundbot] yt-dlp download failed: {}\n", .{err});
        allocator.free(out_path);
        return;
    };

    playback.enqueueSound(out_path, true, true) catch |err| {
        std.debug.print("[soundbot] failed to queue yt-dlp output: {}\n", .{err});
        allocator.free(out_path);
    };
}
