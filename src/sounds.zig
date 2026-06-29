const std = @import("std");

pub fn findSoundFile(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, name: []const u8) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open sounds dir '{s}': {}\n", .{ dir_path, err });
        return null;
    };
    defer dir.close(io);

    const prefix = try std.fmt.allocPrint(allocator, "{s}.", .{name});
    defer allocator.free(prefix);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            return try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        }
    }
    return null;
}

pub fn findSoundFileFamily(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, dir_path: []const u8, name: []const u8) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open sounds dir '{s}': {}\n", .{ dir_path, err });
        return null;
    };
    defer dir.close(io);

    var matches: std.ArrayList([]const u8) = .empty;
    defer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, name)) continue;

        const rest = entry.name[name.len..];
        const dot_index = std.mem.indexOfScalar(u8, rest, '.') orelse continue;
        const digits_part = rest[0..dot_index];
        if (digits_part.len == 0) continue;
        var all_digits = true;
        for (digits_part) |c| {
            if (!std.ascii.isDigit(c)) {
                all_digits = false;
                break;
            }
        }
        if (!all_digits) continue;

        try matches.append(allocator, try std.fs.path.join(allocator, &.{ dir_path, entry.name }));
    }

    if (matches.items.len == 0) return null;
    const idx = rand.intRangeLessThan(usize, 0, matches.items.len);
    return try allocator.dupe(u8, matches.items[idx]);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanByTrailingNumber(_: void, a: []u8, b: []u8) bool {
    return trailingNumber(a) < trailingNumber(b);
}

fn trailingNumber(s: []const u8) u64 {
    var i: usize = s.len;
    while (i > 0 and std.ascii.isDigit(s[i - 1])) i -= 1;
    return std.fmt.parseInt(u64, s[i..], 10) catch 0;
}

pub const SoundGroup = struct {
    key: []const u8,
    members: [][]const u8,
};

pub const SoundGroups = struct {
    groups: []SoundGroup,

    pub fn deinit(self: *SoundGroups, allocator: std.mem.Allocator) void {
        for (self.groups) |g| {
            for (g.members) |m| allocator.free(m);
            allocator.free(g.members);
            allocator.free(g.key);
        }
        allocator.free(self.groups);
    }
};

pub fn buildSoundGroups(allocator: std.mem.Allocator, io: std.Io, sounds_dir: []const u8) !SoundGroups {
    var dir = try std.Io.Dir.cwd().openDir(io, sounds_dir, .{ .iterate = true });
    defer dir.close(io);

    var groups: std.StringHashMap(std.ArrayList([]u8)) = .init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |m| allocator.free(m);
            entry.value_ptr.deinit(allocator);
            allocator.free(entry.key_ptr.*);
        }
        groups.deinit();
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const dot = std.mem.indexOfScalar(u8, entry.name, '.') orelse continue;
        const base = entry.name[0..dot];
        if (base.len == 0) continue;

        var digit_start: usize = base.len;
        while (digit_start > 0 and std.ascii.isDigit(base[digit_start - 1])) digit_start -= 1;
        const has_family = digit_start < base.len and digit_start > 0;

        const key = if (has_family) base[0..digit_start] else base;

        const gop = try groups.getOrPut(key);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, key);
            gop.value_ptr.* = .empty;
        }

        if (has_family) {
            var already = false;
            for (gop.value_ptr.items) |m| {
                if (std.mem.eql(u8, m, base)) {
                    already = true;
                    break;
                }
            }
            if (!already) try gop.value_ptr.append(allocator, try allocator.dupe(u8, base));
        }
    }

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(allocator);
    var kit = groups.keyIterator();
    while (kit.next()) |k| try keys.append(allocator, k.*);
    std.mem.sort([]const u8, keys.items, {}, lessThanStr);

    var result: std.ArrayList(SoundGroup) = .empty;
    errdefer {
        for (result.items) |g| {
            for (g.members) |m| allocator.free(m);
            allocator.free(g.members);
            allocator.free(g.key);
        }
        result.deinit(allocator);
    }
    for (keys.items) |key| {
        const members = groups.getPtr(key).?.items;
        std.mem.sort([]u8, members, {}, lessThanByTrailingNumber);

        const owned_members = try allocator.alloc([]const u8, members.len);
        for (members, 0..) |m, i| owned_members[i] = try allocator.dupe(u8, m);

        try result.append(allocator, .{ .key = try allocator.dupe(u8, key), .members = owned_members });
    }

    return .{ .groups = try result.toOwnedSlice(allocator) };
}

pub fn buildSoundsList(allocator: std.mem.Allocator, io: std.Io, sounds_dir: []const u8) ![]u8 {
    var sound_groups = try buildSoundGroups(allocator, io, sounds_dir);
    defer sound_groups.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (sound_groups.groups.len == 0) {
        try out.appendSlice(allocator, "No sounds available.");
    } else {
        try out.appendSlice(allocator, "Available sounds:\n\n");
        for (sound_groups.groups) |group| {
            try out.appendSlice(allocator, "* !");
            try out.appendSlice(allocator, group.key);

            if (group.members.len > 0) {
                try out.appendSlice(allocator, " (");
                for (group.members, 0..) |m, i| {
                    if (i > 0) try out.append(allocator, ' ');
                    try out.append(allocator, '!');
                    try out.appendSlice(allocator, m);
                }
                try out.appendSlice(allocator, ")");
            }
            try out.append(allocator, '\n');
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn pickRandomSoundFile(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, dir_path: []const u8) !?[]const u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open sounds dir '{s}': {}\n", .{ dir_path, err });
        return null;
    };
    defer dir.close(io);

    var matches: std.ArrayList([]const u8) = .empty;
    defer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try matches.append(allocator, try std.fs.path.join(allocator, &.{ dir_path, entry.name }));
    }

    if (matches.items.len == 0) return null;
    const idx = rand.intRangeLessThan(usize, 0, matches.items.len);
    return try allocator.dupe(u8, matches.items[idx]);
}
