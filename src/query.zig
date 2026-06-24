const std = @import("std");
const ts_protocol = @import("ts_protocol.zig");

// ---- ServerQuery helpers: send a command, read lines until "error id=" terminator ----

var stdin_mutex: std.Thread.Mutex = .{};

pub fn sendCommand(stdin: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    stdin_mutex.lock();
    defer stdin_mutex.unlock();
    try stdin.writer().print(fmt ++ "\n", args);
}

// Sends a harmless command periodically so the idle ServerQuery session doesn't
// get disconnected by the server's own inactivity timeout during quiet periods.
// Its response needs no special handling - it just flows through the main loop's
// existing "ignore anything that isn't notifytextmessage" logic.
pub fn keepaliveLoop(stdin: std.fs.File) void {
    while (true) {
        std.time.sleep(60 * std.time.ns_per_s);
        stdin_mutex.lock();
        defer stdin_mutex.unlock();
        stdin.writer().print("version\n", .{}) catch |err| {
            std.debug.print("[soundbot] keepalive write failed: {}\n", .{err});
        };
    }
}

pub fn readUntilError(allocator: std.mem.Allocator, reader: anytype) !std.ArrayList([]u8) {
    var lines = std.ArrayList([]u8).init(allocator);
    while (true) {
        const maybe_line = try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 8192);
        const line = maybe_line orelse break;
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len == 0) {
            allocator.free(line);
            continue;
        }
        try lines.append(line);
        if (std.mem.startsWith(u8, trimmed, "error id=")) break;
    }
    return lines;
}

// For "fire and forget" setup commands (use, clientmove, servernotifyregister, ...)
// where we don't need the response content - just whether it actually succeeded.
// Without this, a failed command (wrong permission, rejected argument, whatever)
// was previously completely silent: discarded along with the rest of the response.
pub fn doCommand(allocator: std.mem.Allocator, stdin: std.fs.File, reader: anytype, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try sendCommand(stdin, fmt, args);
    var lines = try readUntilError(allocator, reader);
    defer freeLines(allocator, &lines);
    if (lines.items.len > 0) {
        const last = std.mem.trim(u8, lines.items[lines.items.len - 1], "\r\n ");
        if (!std.mem.startsWith(u8, last, "error id=0")) {
            std.debug.print("[soundbot] {s} failed: {s}\n", .{ label, last });
        }
    }
}

pub fn freeLines(allocator: std.mem.Allocator, lines: *std.ArrayList([]u8)) void {
    for (lines.items) |l| allocator.free(l);
    lines.deinit();
}

// Replies in chat - reuses the SAME targetmode/target the triggering message
// arrived on, so a reply to a channel message goes back to that channel, and a
// reply to a server-wide chat message goes back to server-wide chat, with no
// extra lookup needed either way.
pub fn sendReply(allocator: std.mem.Allocator, stdin: std.fs.File, reader: anytype, targetmode: []const u8, target: []const u8, message: []const u8) !void {
    const escaped = try ts_protocol.escapeTs(allocator, message);
    defer allocator.free(escaped);
    try doCommand(allocator, stdin, reader, "sendtextmessage", "sendtextmessage targetmode={s} target={s} msg={s}", .{ targetmode, target, escaped });
}

// clientlist responses pack multiple clients into one line, separated by '|' -
// e.g. "clid=1 cid=2 client_nickname=Foo|clid=3 cid=4 client_nickname=Bar".
// Split on '|' first to get clean per-client records before pulling fields out.
pub fn findClientIdByNickname(allocator: std.mem.Allocator, lines: []const []const u8, nickname: []const u8) !?[]u8 {
    for (lines) |line| {
        var records = std.mem.splitScalar(u8, line, '|');
        while (records.next()) |record| {
            const raw_nick = ts_protocol.extractField(record, "client_nickname=") orelse continue;
            const nick = try ts_protocol.unescapeTs(allocator, raw_nick);
            defer allocator.free(nick);
            if (std.mem.eql(u8, nick, nickname)) {
                if (ts_protocol.extractField(record, "clid=")) |clid_val| {
                    return try allocator.dupe(u8, clid_val);
                }
            }
        }
    }
    return null;
}

// Same shape as the lookup above, but the other direction: given a clid (from a
// notification's invokerid=), find that client's current channel (cid=). Needed
// because server-wide chat notifications don't carry a channel id directly - only
// per-channel chat does.
pub fn findChannelIdByClid(allocator: std.mem.Allocator, lines: []const []const u8, target_clid: []const u8) !?[]u8 {
    for (lines) |line| {
        var records = std.mem.splitScalar(u8, line, '|');
        while (records.next()) |record| {
            const raw_clid = ts_protocol.extractField(record, "clid=") orelse continue;
            if (std.mem.eql(u8, raw_clid, target_clid)) {
                if (ts_protocol.extractField(record, "cid=")) |cid_val| {
                    return try allocator.dupe(u8, cid_val);
                }
            }
        }
    }
    return null;
}
