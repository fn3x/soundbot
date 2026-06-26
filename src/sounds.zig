const std = @import("std");

// ---- Find <name>.* on disk regardless of extension, e.g. "test_sound" -> test_sound.mp3 ----

pub fn findSoundFile(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !?[]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open sounds dir '{s}': {}\n", .{ dir_path, err });
        return null;
    };
    defer dir.close();

    const prefix = try std.fmt.allocPrint(allocator, "{s}.", .{name});
    defer allocator.free(prefix);

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.startsWith(u8, entry.name, prefix)) {
            return try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        }
    }
    return null;
}

// Fallback for when findSoundFile finds no exact match: looks for "<name><digits>.<ext>"
// (du1.mp3, du2.mp3, ...) and picks one at random. Only reached when the exact name
// didn't match anything, so "!du1" - which DOES match du1.mp3 exactly above - never
// falls through to here; "!du" with no du.* file does, and lands on one of its
// numbered siblings.
pub fn findSoundFileFamily(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !?[]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open sounds dir '{s}': {}\n", .{ dir_path, err });
        return null;
    };
    defer dir.close();

    var matches = std.ArrayList([]const u8).init(allocator);
    defer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, name)) continue;

        // Everything between the name and the extension's dot must be all digits.
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

        try matches.append(try std.fs.path.join(allocator, &.{ dir_path, entry.name }));
    }

    if (matches.items.len == 0) return null;
    const idx = std.crypto.random.intRangeLessThan(usize, 0, matches.items.len);
    return try allocator.dupe(u8, matches.items[idx]);
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanStrMut(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// Builds the !sounds reply text, grouping numbered siblings under their shared
// family trigger:
//   Available sounds:
//
//   * !du (!du1 !du2)
//   * !fah
pub fn buildSoundsList(allocator: std.mem.Allocator, sounds_dir: []const u8) ![]u8 {
    var dir = try std.fs.cwd().openDir(sounds_dir, .{ .iterate = true });
    defer dir.close();

    // group key (family prefix, or the bare name for files with no numeric
    // suffix) -> list of individual member names (empty for non-family files).
    var groups = std.StringHashMap(std.ArrayList([]u8)).init(allocator);
    defer {
        var it = groups.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |m| allocator.free(m);
            entry.value_ptr.deinit();
            allocator.free(entry.key_ptr.*);
        }
        groups.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
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
            gop.value_ptr.* = std.ArrayList([]u8).init(allocator);
        }

        if (has_family) {
            var already = false;
            for (gop.value_ptr.items) |m| {
                if (std.mem.eql(u8, m, base)) {
                    already = true;
                    break;
                }
            }
            if (!already) try gop.value_ptr.append(try allocator.dupe(u8, base));
        }
    }

    var keys = std.ArrayList([]const u8).init(allocator);
    defer keys.deinit();
    var kit = groups.keyIterator();
    while (kit.next()) |k| try keys.append(k.*);
    std.mem.sort([]const u8, keys.items, {}, lessThanStr);

    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    if (keys.items.len == 0) {
        try out.appendSlice("No sounds available.");
    } else {
        try out.appendSlice("Available sounds:\n\n");
        for (keys.items) |key| {
            try out.appendSlice("* !");
            try out.appendSlice(key);

            const members = groups.getPtr(key).?.items;
            std.mem.sort([]u8, members, {}, lessThanStrMut);
            if (members.len > 0) {
                try out.appendSlice(" (");
                for (members, 0..) |m, i| {
                    if (i > 0) try out.append(' ');
                    try out.append('!');
                    try out.appendSlice(m);
                }
                try out.appendSlice(")");
            }
            try out.append('\n');
        }
    }
    return out.toOwnedSlice();
}

pub fn pickRandomSoundFile(allocator: std.mem.Allocator, dir_path: []const u8) !?[]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        std.debug.print("Could not open sounds dir '{s}': {}\n", .{ dir_path, err });
        return null;
    };
    defer dir.close();

    var matches = std.ArrayList([]const u8).init(allocator);
    defer {
        for (matches.items) |m| allocator.free(m);
        matches.deinit();
    }

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        try matches.append(try std.fs.path.join(allocator, &.{ dir_path, entry.name }));
    }

    if (matches.items.len == 0) return null;
    const idx = std.crypto.random.intRangeLessThan(usize, 0, matches.items.len);
    return try allocator.dupe(u8, matches.items[idx]);
}
