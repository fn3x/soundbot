const std = @import("std");
const playback = @import("playback.zig");

var settings_mutex: std.Io.Mutex = .init;
var max_seconds: u32 = 0;
var cookies_path_override: ?[]const u8 = null;

const default_cookies_path = "/opt/soundbot/cookies.txt";

pub fn setMaxSeconds(io: std.Io, seconds: u32) void {
    settings_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error setting youtube max seconds mutex {}", .{err});
        return;
    };
    defer settings_mutex.unlock(io);
    max_seconds = seconds;
}

pub fn getMaxSeconds(io: std.Io) u32 {
    settings_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error getting youtube max seconds mutex {}", .{err});
        return 0;
    };
    defer settings_mutex.unlock(io);
    return max_seconds;
}

pub fn setCookiesPath(io: std.Io, path: ?[]const u8) void {
    settings_mutex.lock(io) catch |err| {
        std.debug.print("[soundbot] Error setting youtube cookies mutex {}", .{err});
        return;
    };
    defer settings_mutex.unlock(io);
    cookies_path_override = path;
}

fn resolveCookiesPath(io: std.Io) !?[]const u8 {
    try settings_mutex.lock(io);
    const override = cookies_path_override;
    settings_mutex.unlock(io);

    if (override) |p| return p;

    std.Io.Dir.cwd().access(io, default_cookies_path, .{}) catch return null;
    return default_cookies_path;
}

fn looksLikeUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://");
}

fn copyToWritableTemp(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8) ![]const u8 {
    const tmp_path = try std.fmt.allocPrint(allocator, "/tmp/soundbot_yt_cookies_{d}.txt", .{std.Io.Clock.real.now(io).nanoseconds});
    errdefer allocator.free(tmp_path);
    try std.Io.Dir.cwd().copyFile(source_path, std.Io.Dir.cwd(), tmp_path, io, .{});
    return tmp_path;
}

fn downloadAudio(allocator: std.mem.Allocator, io: std.Io, query_or_url: []const u8, seconds: u32, out_path: []const u8) !void {
    const target = if (looksLikeUrl(query_or_url))
        try allocator.dupe(u8, query_or_url)
    else
        try std.fmt.allocPrint(allocator, "ytsearch1:{s}", .{query_or_url});
    defer allocator.free(target);

    var cookies_temp_path: ?[]const u8 = null;
    defer if (cookies_temp_path) |p| {
        std.Io.Dir.cwd().deleteFile(io, p) catch {};
        allocator.free(p);
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        "yt-dlp",
        "--no-playlist",
        "-x",
        "--audio-format",
        "mp3",
    });

    if (try resolveCookiesPath(io)) |cookies_path| {
        if (copyToWritableTemp(allocator, io, cookies_path)) |tmp| {
            cookies_temp_path = tmp;
            try argv.appendSlice(allocator, &.{ "--cookies", tmp });
        } else |err| {
            std.debug.print("[soundbot] failed to copy cookies to writable temp file, continuing without cookies: {}\n", .{err});
        }
    }

    var section_buf: [32]u8 = undefined;
    if (seconds > 0) {
        const section_arg = try std.fmt.bufPrint(&section_buf, "*0-{d}", .{seconds});
        try argv.appendSlice(allocator, &.{ "--download-sections", section_arg });
    }

    try argv.appendSlice(allocator, &.{ "-o", out_path, target });
    try playback.runAndTrackDownload(io, argv.items);

    std.Io.Dir.cwd().access(io, out_path, .{}) catch {
        return error.YtDlpProducedNoFile;
    };
}

pub fn handleYtCommand(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, raw_query: []const u8) void {
    if (raw_query.len == 0) {
        std.debug.print("[soundbot] !yt needs a URL or search query, e.g. !yt never gonna give you up\n", .{});
        return;
    }

    const out_path = std.fmt.allocPrint(allocator, "/tmp/soundbot_yt_{d}.mp3", .{std.Io.Clock.real.now(io).nanoseconds}) catch |err| {
        std.debug.print("[soundbot] yt failed to build temp path: {}\n", .{err});
        return;
    };

    downloadAudio(allocator, io, raw_query, getMaxSeconds(io), out_path) catch |err| {
        std.debug.print("[soundbot] yt-dlp download failed: {}\n", .{err});
        allocator.free(out_path);
        return;
    };

    var name_buf: [64]u8 = undefined;
    const query_preview_len = @min(raw_query.len, 50);
    const display_name = std.fmt.bufPrint(&name_buf, "yt: {s}", .{raw_query[0..query_preview_len]}) catch "yt";

    playback.enqueueSound(allocator, io, rand, display_name, out_path, true, true) catch |err| {
        std.debug.print("[soundbot] failed to queue yt-dlp output: {}\n", .{err});
        allocator.free(out_path);
    };
}

pub fn handleYtCommandThread(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, raw_query: []u8) void {
    defer allocator.free(raw_query);
    handleYtCommand(allocator, io, rand, raw_query);
}
