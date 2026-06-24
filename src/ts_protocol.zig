const std = @import("std");

// ---- TS3/TS6 ServerQuery string unescaping (\s -> space, \p -> |, etc.) ----

pub fn unescapeTs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
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
            try out.append(replacement);
            i += 2;
        } else {
            try out.append(input[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

// ---- Reverse direction - needed now that the bot replies in chat itself ----

pub fn escapeTs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(allocator);
    errdefer out.deinit();
    for (input) |c| {
        switch (c) {
            ' ' => try out.appendSlice("\\s"),
            '|' => try out.appendSlice("\\p"),
            '/' => try out.appendSlice("\\/"),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\r' => try out.appendSlice("\\r"),
            '\t' => try out.appendSlice("\\t"),
            else => try out.append(c),
        }
    }
    return out.toOwnedSlice();
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
