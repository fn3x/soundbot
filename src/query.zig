const std = @import("std");
const ts_protocol = @import("ts_protocol.zig");

// ---- ServerQuery helpers: send a command, read lines until "error id=" terminator ----

var stdin_mutex: std.Io.Mutex = .init;

// Builds the formatted command into a heap-allocated buffer rather than a
// fixed-size stack one, deliberately: some commands (sendtextmessage replies
// in particular, e.g. !sounds' list) can be long enough that a fixed buffer
// risked silently truncating or failing on them.
pub fn sendCommand(allocator: std.mem.Allocator, io: std.Io, stdin: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt ++ "\n", args);
    defer allocator.free(formatted);
    try stdin_mutex.lock(io);
    defer stdin_mutex.unlock(io);
    try stdin.writeStreamingAll(io, formatted);
}

// Sends a harmless command periodically so the idle ServerQuery session doesn't
// get disconnected by the server's own inactivity timeout during quiet periods.
// Its response needs no special handling - it just flows through the main loop's
// existing "ignore anything that isn't notifytextmessage" logic.
//
// Locks stdin_mutex directly rather than calling sendCommand, since the text
// here is a fixed literal needing no allocation/formatting, and calling
// sendCommand would double-lock the same mutex.
pub fn keepaliveLoop(io: std.Io, stdin: std.Io.File) void {
    while (true) {
        io.sleep(.fromSeconds(60), .awake) catch {};
        stdin_mutex.lock(io) catch {};
        defer stdin_mutex.unlock(io);
        stdin.writeStreamingAll(io, "version\n") catch |err| {
            std.debug.print("[soundbot] keepalive write failed: {}\n", .{err});
        };
    }
}

// Thin wrapper around std.Io.File.Reader + std.Io.Reader.takeDelimiter,
// confirmed directly against std/Io/Reader.zig's actual source. Its test
// suite confirms the exact semantics needed: returns each line (delimiter
// excluded) including one final unterminated line at EOF, then null once
// truly exhausted - matching what the old readUntilDelimiterOrEofAlloc did.
// io is captured once here at construction (inside file.reader), not passed
// per-call, since takeDelimiter's own signature takes no io parameter at all.
//
// The slice takeDelimiter returns points into the Reader's own internal
// buffer and is invalidated by the next read - readLine immediately dupes it
// into independently-owned memory, since the rest of this code keeps lines
// around (in an ArrayList) well past when the next read would invalidate them.
//
// The backing buffer is passed in by the caller rather than owned here,
// deliberately: embedding a buffer directly in this struct would create a
// self-referential pointer (file_reader storing a slice into a sibling field)
// that breaks if the struct is ever copied or moved after construction.
// Keeping the buffer as a separate, independently-stable allocation in the
// caller's own stack frame avoids that risk entirely.
pub const LineReader = struct {
    file_reader: std.Io.File.Reader,

    pub fn init(file: std.Io.File, io: std.Io, buffer: []u8) LineReader {
        return .{ .file_reader = file.reader(io, buffer) };
    }

    pub fn readLine(self: *LineReader, allocator: std.mem.Allocator) !?[]u8 {
        const slice = (try self.file_reader.interface.takeDelimiter('\n')) orelse return null;
        return try allocator.dupe(u8, slice);
    }
};

pub fn readUntilError(allocator: std.mem.Allocator, line_reader: *LineReader) !std.ArrayList([]u8) {
    var lines: std.ArrayList([]u8) = .empty;
    while (true) {
        const maybe_line = try line_reader.readLine(allocator);
        const line = maybe_line orelse break;
        const trimmed = std.mem.trim(u8, line, "\r\n ");
        if (trimmed.len == 0) {
            allocator.free(line);
            continue;
        }
        try lines.append(allocator, line);
        if (std.mem.startsWith(u8, trimmed, "error id=")) break;
    }
    return lines;
}

// For "fire and forget" setup commands (use, clientmove, servernotifyregister, ...)
// where we don't need the response content - just whether it actually succeeded.
// Without this, a failed command (wrong permission, rejected argument, whatever)
// was previously completely silent: discarded along with the rest of the response.
pub fn doCommand(allocator: std.mem.Allocator, io: std.Io, stdin: std.Io.File, line_reader: *LineReader, label: []const u8, comptime fmt: []const u8, args: anytype) !void {
    try sendCommand(allocator, io, stdin, fmt, args);
    var lines = try readUntilError(allocator, line_reader);
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
    lines.deinit(allocator);
}

// Replies in chat - reuses the SAME targetmode/target the triggering message
// arrived on, so a reply to a channel message goes back to that channel, and a
// reply to a server-wide chat message goes back to server-wide chat, with no
// extra lookup needed either way.
pub fn sendReply(allocator: std.mem.Allocator, io: std.Io, stdin: std.Io.File, line_reader: *LineReader, targetmode: []const u8, target: []const u8, message: []const u8) !void {
    const escaped = try ts_protocol.escapeTs(allocator, message);
    defer allocator.free(escaped);
    try doCommand(allocator, io, stdin, line_reader, "sendtextmessage", "sendtextmessage targetmode={s} target={s} msg={s}", .{ targetmode, target, escaped });
}

// Convenience wrapper around sendReply for command-confirmation/error messages:
// pulls targetmode/target from the triggering notification line itself (same
// as sendReply expects), and catches its own errors so call sites - of which
// there are many, for every settings command - don't each need their own
// try/catch boilerplate just to talk back in chat.
pub fn replyToTrigger(allocator: std.mem.Allocator, io: std.Io, stdin: std.Io.File, line_reader: *LineReader, trimmed_line: []const u8, default_target: []const u8, message: []const u8) void {
    const targetmode = ts_protocol.extractField(trimmed_line, "targetmode=") orelse "2";
    const target = ts_protocol.extractField(trimmed_line, "target=") orelse default_target;
    sendReply(allocator, io, stdin, line_reader, targetmode, target, message) catch |err| {
        std.debug.print("[soundbot] failed to send reply: {}\n", .{err});
    };
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
