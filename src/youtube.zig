const std = @import("std");
const playback = @import("playback.zig");

// ---- Playback from YouTube (or anything else yt-dlp supports) ----
// yt-dlp itself handles is its own large surface area - format selection,
// site-specific extraction, etc. - so this stays thin: build a reasonable
// command line, let yt-dlp do the work, queue the result like any other sound.
//
// Worth knowing: yt-dlp supports over a thousand sites, not just YouTube, so
// a bare URL to practically anything it recognizes will work here, not only
// youtube.com links.

var settings_mutex: std.Thread.Mutex = .{};
var max_seconds: u32 = 0; // 0 = no cap, play the whole thing (the default - good for songs)

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

    playback.enqueueSound(out_path, true) catch |err| {
        std.debug.print("[soundbot] failed to queue yt-dlp output: {}\n", .{err});
        allocator.free(out_path);
    };
}
