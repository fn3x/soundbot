const std = @import("std");
pub const ButtonPress = struct {
    data: []const u8,
};

pub const ButtonQueue = struct {
    mutex: std.Io.Mutex = .init,
    items: std.ArrayList(ButtonPress) = .empty,

    pub fn init() ButtonQueue {
        return .{};
    }

    pub fn push(self: *ButtonQueue, allocator: std.mem.Allocator, io: std.Io, data: []const u8) !void {
        const owned = try allocator.dupe(u8, data);
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        try self.items.append(allocator, .{ .data = owned });
    }

    pub fn drain(self: *ButtonQueue, allocator: std.mem.Allocator, io: std.Io) ![]ButtonPress {
        try self.mutex.lock(io);
        defer self.mutex.unlock(io);
        return self.items.toOwnedSlice(allocator);
    }
};
