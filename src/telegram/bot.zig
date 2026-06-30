const std = @import("std");
const sounds = @import("../sounds.zig");
const playback = @import("../playback.zig");
const queries = @import("queries.zig");
const structs = @import("structs.zig");
const queue_mod = @import("queue.zig");

const PAGE_SIZE = 10;

const family_prefix = "📁 ";
const refresh_family_prefix = "🔄 Refresh ";
const refresh_top_text = "🔄 Refresh";
const back_text = "« Back";
const close_text = "✖ Close";
const prev_prefix = "‹ Page ";
const next_prefix = "› Page ";
const play_prefix = "!";

const Action = union(enum) {
    play: []const u8,
    expand_family: []const u8,
    refresh_family: []const u8,
    refresh_top,
    back,
    close,
    goto_page: usize,
    show_keyboard,
};

fn parseButtonText(text: []const u8) ?Action {
    if (std.mem.eql(u8, text, close_text)) return .close;
    if (std.mem.eql(u8, text, back_text)) return .back;
    if (std.mem.eql(u8, text, refresh_top_text)) return .refresh_top;
    if (std.mem.startsWith(u8, text, "/sounds")) return .show_keyboard;

    if (std.mem.startsWith(u8, text, refresh_family_prefix)) {
        return .{ .refresh_family = text[refresh_family_prefix.len..] };
    }

    if (std.mem.startsWith(u8, text, family_prefix)) {
        const rest = text[family_prefix.len..];
        const key_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        return .{ .expand_family = rest[0..key_end] };
    }

    if (std.mem.startsWith(u8, text, prev_prefix)) {
        const n = std.fmt.parseInt(usize, text[prev_prefix.len..], 10) catch return null;
        if (n == 0) return null;
        return .{ .goto_page = n - 1 };
    }
    if (std.mem.startsWith(u8, text, next_prefix)) {
        const n = std.fmt.parseInt(usize, text[next_prefix.len..], 10) catch return null;
        if (n == 0) return null;
        return .{ .goto_page = n - 1 };
    }

    if (std.mem.startsWith(u8, text, play_prefix)) {
        return .{ .play = text[play_prefix.len..] };
    }

    return null;
}

fn findGroup(groups: []const sounds.SoundGroup, key: []const u8) ?sounds.SoundGroup {
    for (groups) |g| {
        if (std.mem.eql(u8, g.key, key)) return g;
    }
    return null;
}

fn buildTopLevelKeyboard(allocator: std.mem.Allocator, groups: []const sounds.SoundGroup, page: usize) !struct { markup: structs.ReplyKeyboardMarkup, total_pages: usize, safe_page: usize } {
    const total_pages = @max(1, (groups.len + PAGE_SIZE - 1) / PAGE_SIZE);
    const safe_page = if (page >= total_pages) total_pages - 1 else page;
    const start = safe_page * PAGE_SIZE;
    const end = @min(start + PAGE_SIZE, groups.len);
    const page_groups = groups[start..end];

    var rows: std.ArrayList([]const structs.KeyboardButton) = .empty;
    var current_row: std.ArrayList(structs.KeyboardButton) = .empty;

    for (page_groups) |group| {
        const is_family = group.members.len > 0;
        const text = if (is_family)
            try std.fmt.allocPrint(allocator, "{s}{s} ({d})", .{ family_prefix, group.key, group.members.len })
        else
            try std.fmt.allocPrint(allocator, "{s}{s}", .{ play_prefix, group.key });

        try current_row.append(allocator, .{ .text = text });
        if (current_row.items.len == 2) {
            try rows.append(allocator, try current_row.toOwnedSlice(allocator));
            current_row = .empty;
        }
    }
    if (current_row.items.len > 0) {
        try rows.append(allocator, try current_row.toOwnedSlice(allocator));
    }

    var nav_row: std.ArrayList(structs.KeyboardButton) = .empty;
    if (total_pages > 1) {
        if (safe_page > 0) {
            try nav_row.append(allocator, .{ .text = try std.fmt.allocPrint(allocator, "{s}{d}", .{ prev_prefix, safe_page }) });
        }
        if (safe_page + 1 < total_pages) {
            try nav_row.append(allocator, .{ .text = try std.fmt.allocPrint(allocator, "{s}{d}", .{ next_prefix, safe_page + 2 }) });
        }
    }
    if (nav_row.items.len > 0) {
        try rows.append(allocator, try nav_row.toOwnedSlice(allocator));
    }

    const bottom_row = try allocator.alloc(structs.KeyboardButton, 2);
    bottom_row[0] = .{ .text = refresh_top_text };
    bottom_row[1] = .{ .text = close_text };
    try rows.append(allocator, bottom_row);

    return .{
        .markup = .{ .keyboard = try rows.toOwnedSlice(allocator) },
        .total_pages = total_pages,
        .safe_page = safe_page,
    };
}

fn buildFamilyKeyboard(allocator: std.mem.Allocator, group: sounds.SoundGroup) !structs.ReplyKeyboardMarkup {
    var rows: std.ArrayList([]const structs.KeyboardButton) = .empty;
    var current_row: std.ArrayList(structs.KeyboardButton) = .empty;

    for (group.members) |member| {
        const text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ play_prefix, member });
        try current_row.append(allocator, .{ .text = text });
        if (current_row.items.len == 2) {
            try rows.append(allocator, try current_row.toOwnedSlice(allocator));
            current_row = .empty;
        }
    }
    if (current_row.items.len > 0) {
        try rows.append(allocator, try current_row.toOwnedSlice(allocator));
    }

    const bottom_row = try allocator.alloc(structs.KeyboardButton, 3);
    bottom_row[0] = .{ .text = try std.fmt.allocPrint(allocator, "{s}{s}", .{ refresh_family_prefix, group.key }) };
    bottom_row[1] = .{ .text = back_text };
    bottom_row[2] = .{ .text = close_text };
    try rows.append(allocator, bottom_row);

    return .{ .keyboard = try rows.toOwnedSlice(allocator) };
}

fn sendTopLevel(allocator: std.mem.Allocator, io: std.Io, tg_client: *queries.TgClient, chat_id: i64, sounds_dir: []const u8, page: usize) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var groups = sounds.buildSoundGroups(allocator, io, sounds_dir) catch |err| {
        std.debug.print("[telegram] failed to build sound groups: {}\n", .{err});
        return;
    };
    defer groups.deinit(allocator);

    const built = buildTopLevelKeyboard(arena, groups.groups, page) catch |err| {
        std.debug.print("[telegram] failed to build top-level keyboard: {}\n", .{err});
        return;
    };

    const text = if (built.total_pages > 1)
        std.fmt.allocPrint(arena, "Tap a sound to play it: (page {d}/{d})", .{ built.safe_page + 1, built.total_pages }) catch "Tap a sound to play it:"
    else
        "Tap a sound to play it:";

    _ = tg_client.sendMessage(arena, structs.SendMessageParams{
        .chat_id = chat_id,
        .text = text,
        .reply_markup = built.markup,
    }) catch |err| {
        std.debug.print("[telegram] failed to send top-level keyboard: {}\n", .{err});
    };
}

fn sendFamily(allocator: std.mem.Allocator, io: std.Io, tg_client: *queries.TgClient, chat_id: i64, sounds_dir: []const u8, key: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var groups = sounds.buildSoundGroups(allocator, io, sounds_dir) catch |err| {
        std.debug.print("[telegram] failed to rebuild sound groups for family view: {}\n", .{err});
        return;
    };
    defer groups.deinit(allocator);

    const group = findGroup(groups.groups, key) orelse {
        sendTopLevel(allocator, io, tg_client, chat_id, sounds_dir, 0);
        return;
    };

    const keyboard = buildFamilyKeyboard(arena, group) catch |err| {
        std.debug.print("[telegram] failed to build family keyboard: {}\n", .{err});
        return;
    };

    const text = std.fmt.allocPrint(arena, "{s} sounds:", .{key}) catch "Sounds:";
    _ = tg_client.sendMessage(arena, structs.SendMessageParams{
        .chat_id = chat_id,
        .text = text,
        .reply_markup = keyboard,
    }) catch |err| {
        std.debug.print("[telegram] failed to send family keyboard: {}\n", .{err});
    };
}

fn sendClose(allocator: std.mem.Allocator, tg_client: *queries.TgClient, chat_id: i64) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = tg_client.sendMessage(arena, structs.SendMessageRemoveKeyboardParams{
        .chat_id = chat_id,
        .text = "Keyboard closed. Send /sounds to bring it back.",
    }) catch |err| {
        std.debug.print("[telegram] failed to send keyboard-close message: {}\n", .{err});
    };
}

fn isAllowedChat(chat_ids: []const i64, chat_id: i64) bool {
    for (chat_ids) |id| {
        if (id == chat_id) return true;
    }
    return false;
}

pub fn consumeButtonPresses(allocator: std.mem.Allocator, io: std.Io, rand: std.Random, button_queue: *queue_mod.ButtonQueue, sounds_dir: []const u8) !void {
    while (true) {
        io.sleep(.fromMilliseconds(200), .awake) catch |err| {
            std.debug.print("[telegram] consumer sleep failed, stopping: {}\n", .{err});
            return;
        };

        const presses = button_queue.drain(allocator, io) catch |err| {
            std.debug.print("[telegram] failed to drain button queue: {}\n", .{err});
            continue;
        };
        defer allocator.free(presses);

        for (presses) |press| {
            defer allocator.free(press.data);
            const found = playback.triggerSound(allocator, io, rand, sounds_dir, press.data) catch |err| {
                std.debug.print("[telegram] failed to trigger '{s}': {}\n", .{ press.data, err });
                continue;
            };
            if (!found) {
                std.debug.print("[telegram] no sound found for button data '{s}'\n", .{press.data});
            }
        }
    }
}

pub fn pollLoop(allocator: std.mem.Allocator, io: std.Io, tg_client: *queries.TgClient, chat_ids: []const i64, sounds_dir: []const u8, button_queue: *queue_mod.ButtonQueue) !void {
    var offset: ?i64 = null;

    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const updates = tg_client.getUpdates(arena, .{ .offset = offset }) catch |err| {
            std.debug.print("[telegram] getUpdates failed: {}\n", .{err});
            io.sleep(.fromSeconds(5), .awake) catch {};
            continue;
        };

        for (updates) |update| {
            offset = update.update_id + 1;

            const msg = update.message orelse continue;
            if (!isAllowedChat(chat_ids, msg.chat.id)) {
                std.debug.print("[telegram] ignoring message from unauthorized chat {d}\n", .{msg.chat.id});
                continue;
            }
            const text = msg.text orelse continue;
            const action = parseButtonText(text) orelse continue;

            switch (action) {
                .show_keyboard => sendTopLevel(allocator, io, tg_client, msg.chat.id, sounds_dir, 0),
                .refresh_top => sendTopLevel(allocator, io, tg_client, msg.chat.id, sounds_dir, 0),
                .goto_page => |page| sendTopLevel(allocator, io, tg_client, msg.chat.id, sounds_dir, page),
                .back => sendTopLevel(allocator, io, tg_client, msg.chat.id, sounds_dir, 0),
                .expand_family => |key| sendFamily(allocator, io, tg_client, msg.chat.id, sounds_dir, key),
                .refresh_family => |key| sendFamily(allocator, io, tg_client, msg.chat.id, sounds_dir, key),
                .close => sendClose(allocator, tg_client, msg.chat.id),
                .play => |name| {
                    button_queue.push(allocator, io, name) catch |err| {
                        std.debug.print("[telegram] failed to queue button press: {}\n", .{err});
                    };
                },
            }
        }
    }
}
