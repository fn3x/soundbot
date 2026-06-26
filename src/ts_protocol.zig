const std = @import("std");

// ---- TS3/TS6 ServerQuery string unescaping (\s -> space, \p -> |, etc.) ----

pub fn unescapeTs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\' and i + 1 < input.len) {
            const c = input[i + 1];
            const replacement: u8 = switch (c) {
                's' => ' ',
                'p' => '|',
                '/' => '/',
                '\\' => '\\',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => c,
            };
            try out.append(allocator, replacement);
            i += 2;
        } else {
            try out.append(allocator, input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---- Reverse direction - needed now that the bot replies in chat itself ----

pub fn escapeTs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        switch (c) {
            ' ' => try out.appendSlice(allocator, "\\s"),
            '|' => try out.appendSlice(allocator, "\\p"),
            '/' => try out.appendSlice(allocator, "\\/"),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, c),
        }
    }
    return out.toOwnedSlice(allocator);
}

// ---- Pull a "key=value" token's value out of a space-delimited ServerQuery line ----

pub fn extractField(line: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, line, ' ');
    while (it.next()) |token| {
        if (std.mem.startsWith(u8, token, key)) {
            return token[key.len..];
        }
    }
    return null;
}
