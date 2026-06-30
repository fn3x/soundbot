const std = @import("std");
const sounds = @import("../sounds.zig");
const playback = @import("../playback.zig");
const queries = @import("queries.zig");
const structs = @import("structs.zig");
const queue_mod = @import("queue.zig");

const Kind = enum { play, expand, page, refresh };

const ParsedCallback = struct {
    kind: Kind,
    payload: []const u8,
};

fn parseCallbackData(data: []const u8) ?ParsedCallback {
    const colon = std.mem.indexOfScalar(u8, data, ':') orelse return null;
    const kind_str = data[0..colon];
    const payload = data[colon + 1 ..];
    if (std.mem.eql(u8, kind_str, "play")) return .{ .kind = .play, .payload = payload };
    if (std.mem.eql(u8, kind_str, "expand")) return .{ .kind = .expand, .payload = payload };
    if (std.mem.eql(u8, kind_str, "page")) return .{ .kind = .page, .payload = payload };
    if (std.mem.eql(u8, kind_str, "refresh")) return .{ .kind = .refresh, .payload = payload };
    return null;
}

const PAGE_SIZE = 10;

fn buildTopLevelKeyboard(allocator: std.mem.Allocator, groups: []const sounds.SoundGroup, page: usize) !structs.InlineKeyboardMarkup {
    const total_pages = (groups.len + PAGE_SIZE - 1) / PAGE_SIZE;
    const safe_page = if (page >= total_pages and total_pages > 0) total_pages - 1 else page;
    const start = safe_page * PAGE_SIZE;
    const end = @min(start + PAGE_SIZE, groups.len);
    const page_groups = groups[start..end];

    var rows: std.ArrayList([]const structs.InlineKeyboardButton) = .empty;
    var current_row: std.ArrayList(structs.InlineKeyboardButton) = .empty;

    for (page_groups) |group| {
        const is_family = group.members.len > 0;
        const text = if (is_family)
            try std.fmt.allocPrint(allocator, "{s} ({d})", .{ group.key, group.members.len })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{group.key});

        const data = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ if (is_family) "expand" else "play", group.key });

        try current_row.append(allocator, .{ .text = text, .callback_data = data });
        if (current_row.items.len == 2) {
            try rows.append(allocator, try current_row.toOwnedSlice(allocator));
            current_row = .empty;
        }
    }
    if (current_row.items.len > 0) {
        try rows.append(allocator, try current_row.toOwnedSlice(allocator));
    }

    var nav_row: std.ArrayList(structs.InlineKeyboardButton) = .empty;
    if (total_pages > 1) {
        if (safe_page > 0) {
            try nav_row.append(allocator, .{
                .text = "‹ Prev",
                .callback_data = try std.fmt.allocPrint(allocator, "page:{d}", .{safe_page - 1}),
            });
        }
        try nav_row.append(allocator, .{
            .text = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ safe_page + 1, total_pages }),
            .callback_data = try std.fmt.allocPrint(allocator, "page:{d}", .{safe_page}),
        });
        if (safe_page + 1 < total_pages) {
            try nav_row.append(allocator, .{
                .text = "Next ›",
                .callback_data = try std.fmt.allocPrint(allocator, "page:{d}", .{safe_page + 1}),
            });
        }
    }
    try nav_row.append(allocator, .{
        .text = "🔄",
        .callback_data = try std.fmt.allocPrint(allocator, "refresh:{d}", .{safe_page}),
    });
    try rows.append(allocator, try nav_row.toOwnedSlice(allocator));

    return .{ .inline_keyboard = try rows.toOwnedSlice(allocator) };
}

fn buildFamilyKeyboard(allocator: std.mem.Allocator, group: sounds.SoundGroup) !structs.InlineKeyboardMarkup {
    var rows: std.ArrayList([]const structs.InlineKeyboardButton) = .empty;
    var current_row: std.ArrayList(structs.InlineKeyboardButton) = .empty;

    for (group.members) |member| {
        const text = try std.fmt.allocPrint(allocator, "{s}", .{member});
        const data = try std.fmt.allocPrint(allocator, "play:{s}", .{member});
        try current_row.append(allocator, .{ .text = text, .callback_data = data });
        if (current_row.items.len == 2) {
            try rows.append(allocator, try current_row.toOwnedSlice(allocator));
            current_row = .empty;
        }
    }
    if (current_row.items.len > 0) {
        try rows.append(allocator, try current_row.toOwnedSlice(allocator));
    }

    const bottom_row = try allocator.alloc(structs.InlineKeyboardButton, 2);
    bottom_row[0] = .{ .text = "🔄 Refresh", .callback_data = try std.fmt.allocPrint(allocator, "expand:{s}", .{group.key}) };
    bottom_row[1] = .{ .text = "« Back", .callback_data = "page:0" };
    try rows.append(allocator, bottom_row);

    return .{ .inline_keyboard = try rows.toOwnedSlice(allocator) };
}

fn findGroup(groups: []const sounds.SoundGroup, key: []const u8) ?sounds.SoundGroup {
    for (groups) |g| {
        if (std.mem.eql(u8, g.key, key)) return g;
    }
    return null;
}

fn isAllowedChat(chat_ids: []const i64, chat_id: i64) bool {
    for (chat_ids) |id| {
        if (id == chat_id) return true;
    }
    return false;
}

pub fn sendKeyboard(allocator: std.mem.Allocator, io: std.Io, tg_client: *queries.TgClient, chat_id: i64, sounds_dir: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var groups = sounds.buildSoundGroups(allocator, io, sounds_dir) catch |err| {
        std.debug.print("[telegram] failed to build sound groups for /sounds: {}\n", .{err});
        return;
    };
    defer groups.deinit(allocator);

    const keyboard = buildTopLevelKeyboard(arena, groups.groups, 0) catch |err| {
        std.debug.print("[telegram] failed to build keyboard: {}\n", .{err});
        return;
    };
    _ = tg_client.sendMessage(arena, .{
        .chat_id = chat_id,
        .text = "Tap a sound to play it:",
        .reply_markup = keyboard,
    }) catch |err| {
        std.debug.print("[telegram] failed to send keyboard: {}\n", .{err});
    };
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

            if (update.message) |msg| {
                if (!isAllowedChat(chat_ids, msg.chat.id)) {
                    std.debug.print("[telegram] ignoring message from unauthorized chat {d}\n", .{msg.chat.id});
                    continue;
                }
                const text = msg.text orelse continue;
                if (std.mem.startsWith(u8, text, "/sounds")) {
                    sendKeyboard(allocator, io, tg_client, msg.chat.id, sounds_dir);
                }
                continue;
            }

            const cq = update.callback_query orelse continue;
            const message = cq.message orelse continue;

            if (!isAllowedChat(chat_ids, message.chat.id)) {
                std.debug.print("[telegram] ignoring button press from unauthorized chat {d}\n", .{message.chat.id});
                continue;
            }

            const data = cq.data orelse continue;
            const parsed = parseCallbackData(data) orelse continue;

            switch (parsed.kind) {
                .play => {
                    button_queue.push(allocator, io, parsed.payload) catch |err| {
                        std.debug.print("[telegram] failed to queue button press: {}\n", .{err});
                    };
                    tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id, .text = "Playing..." });
                },
                .expand => {
                    const groups = sounds.buildSoundGroups(arena, io, sounds_dir) catch |err| {
                        std.debug.print("[telegram] failed to rebuild sound groups for expand: {}\n", .{err});
                        tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                        continue;
                    };
                    const group = findGroup(groups.groups, parsed.payload) orelse {
                        tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                        continue;
                    };
                    const keyboard = buildFamilyKeyboard(arena, group) catch |err| {
                        std.debug.print("[telegram] failed to build family keyboard: {}\n", .{err});
                        tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                        continue;
                    };
                    tg_client.editMessageReplyMarkup(arena, .{
                        .chat_id = message.chat.id,
                        .message_id = message.message_id,
                        .reply_markup = keyboard,
                    });
                    tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                },
                .page, .refresh => {
                    const target_page = std.fmt.parseInt(usize, parsed.payload, 10) catch 0;
                    const groups = sounds.buildSoundGroups(arena, io, sounds_dir) catch |err| {
                        std.debug.print("[telegram] failed to rebuild sound groups for page/refresh: {}\n", .{err});
                        tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                        continue;
                    };
                    const keyboard = buildTopLevelKeyboard(arena, groups.groups, target_page) catch |err| {
                        std.debug.print("[telegram] failed to build top-level keyboard: {}\n", .{err});
                        tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                        continue;
                    };
                    tg_client.editMessageReplyMarkup(arena, .{
                        .chat_id = message.chat.id,
                        .message_id = message.message_id,
                        .reply_markup = keyboard,
                    });
                    tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                },
            }
        }
    }
}
