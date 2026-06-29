const std = @import("std");
const ts_protocol = @import("ts_protocol.zig");

var stdin_mutex: std.Io.Mutex = .init;

pub fn sendCommand(allocator: std.mem.Allocator, io: std.Io, stdin: std.Io.File, comptime fmt: []const u8, args: anytype) !void {
    const formatted = try std.fmt.allocPrint(allocator, fmt ++ "\n", args);
    defer allocator.free(formatted);
    try stdin_mutex.lock(io);
    defer stdin_mutex.unlock(io);
    try stdin.writeStreamingAll(io, formatted);
}

pub fn keepaliveLoop(io: std.Io, stdin: std.Io.File) void {
    while (true) {
        io.sleep(.fromSeconds(60), .awake) catch |err| {
            std.debug.print("[soundbot] keepalive sleep failed, stopping keepalive thread: {}\n", .{err});
            return;
        };
        stdin_mutex.lock(io) catch {};
        defer stdin_mutex.unlock(io);
        stdin.writeStreamingAll(io, "version\n") catch |err| {
            std.debug.print("[soundbot] keepalive write failed: {}\n", .{err});
        };
    }
}

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

pub fn sendReply(allocator: std.mem.Allocator, io: std.Io, stdin: std.Io.File, line_reader: *LineReader, targetmode: []const u8, target: []const u8, message: []const u8) !void {
    const escaped = try ts_protocol.escapeTs(allocator, message);
    defer allocator.free(escaped);
    try doCommand(allocator, io, stdin, line_reader, "sendtextmessage", "sendtextmessage targetmode={s} target={s} msg={s}", .{ targetmode, target, escaped });
}

pub fn replyToTrigger(allocator: std.mem.Allocator, io: std.Io, stdin: std.Io.File, line_reader: *LineReader, trimmed_line: []const u8, default_target: []const u8, message: []const u8) void {
    const targetmode = ts_protocol.extractField(trimmed_line, "targetmode=") orelse "2";
    const target = ts_protocol.extractField(trimmed_line, "target=") orelse default_target;
    sendReply(allocator, io, stdin, line_reader, targetmode, target, message) catch |err| {
        std.debug.print("[soundbot] failed to send reply: {}\n", .{err});
    };
}

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
