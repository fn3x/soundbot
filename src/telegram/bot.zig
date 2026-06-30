const std = @import("std");
const sounds = @import("../sounds.zig");
const playback = @import("../playback.zig");
const queries = @import("queries.zig");
const structs = @import("structs.zig");
const queue_mod = @import("queue.zig");

const Kind = enum { play, favorite, unfavorite, expand, page, refresh };
const Menu = enum { main, favorites };

const ParsedCallback = struct {
    kind: Kind,
    menu: Menu,
    payload: []const u8,
};

// Format: "<menu>:<kind>:<payload>", e.g. "main:play:cod14" or "favorites:unfavorite:cod14".
fn parseCallbackData(data: []const u8) ?ParsedCallback {
    const first_colon = std.mem.indexOfScalar(u8, data, ':') orelse return null;
    const menu_str = data[0..first_colon];
    const rest = data[first_colon + 1 ..];

    const second_colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    const kind_str = rest[0..second_colon];
    const payload = rest[second_colon + 1 ..];

    const menu: Menu = if (std.mem.eql(u8, menu_str, "favorites")) .favorites else .main;

    if (std.mem.eql(u8, kind_str, "play")) return .{ .menu = menu, .kind = .play, .payload = payload };
    if (std.mem.eql(u8, kind_str, "expand")) return .{ .menu = menu, .kind = .expand, .payload = payload };
    if (std.mem.eql(u8, kind_str, "page")) return .{ .menu = menu, .kind = .page, .payload = payload };
    if (std.mem.eql(u8, kind_str, "refresh")) return .{ .menu = menu, .kind = .refresh, .payload = payload };
    if (std.mem.eql(u8, kind_str, "favorite")) return .{ .menu = menu, .kind = .favorite, .payload = payload };
    if (std.mem.eql(u8, kind_str, "unfavorite")) return .{ .menu = menu, .kind = .unfavorite, .payload = payload };
    return null;
}

const MAX_TRACKED_KEYBOARDS = 200;

const MessageOwners = struct {
    owners: std.AutoHashMap(i64, i64),
    order: std.ArrayList(i64),

    fn init(allocator: std.mem.Allocator) MessageOwners {
        return .{ .owners = std.AutoHashMap(i64, i64).init(allocator), .order = .empty };
    }

    fn record(self: *MessageOwners, allocator: std.mem.Allocator, message_id: i64, user_id: i64) void {
        self.owners.put(message_id, user_id) catch |err| {
            std.debug.print("[telegram] failed to record keyboard owner: {}\n", .{err});
            return;
        };
        self.order.append(allocator, message_id) catch {};

        if (self.order.items.len > MAX_TRACKED_KEYBOARDS) {
            const oldest = self.order.orderedRemove(0);
            _ = self.owners.remove(oldest);
        }
    }

    fn ownerOf(self: *const MessageOwners, message_id: i64) ?i64 {
        return self.owners.get(message_id);
    }
};

const UserFavorites = struct {
    map: std.AutoHashMap(i64, std.StringHashMap(void)), // user_id -> set of owned sound-name strings
    folder: []const u8,

    fn init(allocator: std.mem.Allocator, folder: []const u8) UserFavorites {
        return .{ .map = std.AutoHashMap(i64, std.StringHashMap(void)).init(allocator), .folder = folder };
    }

    fn ensureFolder(self: *const UserFavorites, io: std.Io) void {
        std.Io.Dir.cwd().createDirPath(io, self.folder) catch |err| {
            std.debug.print("[telegram] failed to create favorites folder '{s}': {}\n", .{ self.folder, err });
        };
    }

    fn loadAll(self: *UserFavorites, allocator: std.mem.Allocator, io: std.Io) void {
        var dir = std.Io.Dir.cwd().openDir(io, self.folder, .{ .iterate = true }) catch |err| {
            std.debug.print("[telegram] could not open favorites folder '{s}', starting with no favorites loaded: {}\n", .{ self.folder, err });
            return;
        };
        defer dir.close(io);

        var it = dir.iterate();
        while (true) {
            const entry = it.next(io) catch |err| {
                std.debug.print("[telegram] error while listing favorites folder: {}\n", .{err});
                break;
            } orelse break;
            if (entry.kind != .file) continue;

            const user_id = std.fmt.parseInt(i64, entry.name, 10) catch continue; // skip anything not named as a plain user id

            var file = dir.openFile(io, entry.name, .{}) catch |err| {
                std.debug.print("[telegram] failed to open favorites file for user {d}: {}\n", .{ user_id, err });
                continue;
            };
            defer file.close(io);

            var read_buf: [4096]u8 = undefined;
            var file_reader = file.reader(io, &read_buf);
            const content = file_reader.interface.allocRemaining(allocator, .limited(64 * 1024)) catch |err| {
                std.debug.print("[telegram] failed to read favorites file for user {d}: {}\n", .{ user_id, err });
                continue;
            };
            defer allocator.free(content);

            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\n\t");
                if (trimmed.len == 0) continue;
                self.addNoSave(allocator, user_id, trimmed);
            }
        }
    }

    fn saveUser(self: *UserFavorites, allocator: std.mem.Allocator, io: std.Io, user_id: i64) void {
        const path = std.fmt.allocPrint(allocator, "{s}/{d}", .{ self.folder, user_id }) catch return;
        defer allocator.free(path);

        var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
            std.debug.print("[telegram] failed to save favorites for user {d}: {}\n", .{ user_id, err });
            return;
        };
        defer file.close(io);

        const set = self.map.getPtr(user_id) orelse return;
        var it = set.keyIterator();
        while (it.next()) |name| {
            file.writeStreamingAll(io, name.*) catch |err| {
                std.debug.print("[telegram] failed to write favorite for user {d}: {}\n", .{ user_id, err });
                return;
            };
            file.writeStreamingAll(io, "\n") catch {};
        }
    }

    fn addNoSave(self: *UserFavorites, allocator: std.mem.Allocator, user_id: i64, name: []const u8) void {
        const gop = self.map.getOrPut(user_id) catch |err| {
            std.debug.print("[telegram] failed to add favorite: {}\n", .{err});
            return;
        };
        if (!gop.found_existing) gop.value_ptr.* = std.StringHashMap(void).init(allocator);
        if (gop.value_ptr.contains(name)) return;
        const owned = allocator.dupe(u8, name) catch |err| {
            std.debug.print("[telegram] failed to add favorite: {}\n", .{err});
            return;
        };
        gop.value_ptr.put(owned, {}) catch |err| {
            std.debug.print("[telegram] failed to add favorite: {}\n", .{err});
            allocator.free(owned);
        };
    }

    fn add(self: *UserFavorites, allocator: std.mem.Allocator, io: std.Io, user_id: i64, name: []const u8) void {
        self.addNoSave(allocator, user_id, name);
        self.saveUser(allocator, io, user_id);
    }

    fn remove(self: *UserFavorites, allocator: std.mem.Allocator, io: std.Io, user_id: i64, name: []const u8) void {
        const set = self.map.getPtr(user_id) orelse return;
        if (set.fetchRemove(name)) |kv| {
            allocator.free(kv.key);
            self.saveUser(allocator, io, user_id);
        }
    }

    fn isFavorited(self: *const UserFavorites, user_id: i64, name: []const u8) bool {
        const set = self.map.get(user_id) orelse return false;
        return set.contains(name);
    }

    fn list(self: *const UserFavorites, allocator: std.mem.Allocator, user_id: i64) ![]const []const u8 {
        const set = self.map.get(user_id) orelse return &.{};
        var result: std.ArrayList([]const u8) = .empty;
        var it = set.keyIterator();
        while (it.next()) |k| try result.append(allocator, k.*);
        std.mem.sort([]const u8, result.items, {}, lessThanStr);
        return result.toOwnedSlice(allocator);
    }
};

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const PAGE_SIZE = 10;

fn appendSoundWithStar(allocator: std.mem.Allocator, current_row: *std.ArrayList(structs.InlineKeyboardButton), label: []const u8, play_data: []const u8, sound_name: []const u8, favorites: *const UserFavorites, user_id: i64) !void {
    try current_row.append(allocator, .{ .text = label, .callback_data = play_data });

    const is_fav = favorites.isFavorited(user_id, sound_name);
    const star_text = if (is_fav) "💛" else "⭐";
    const star_kind = if (is_fav) "unfavorite" else "favorite";
    const star_data = try std.fmt.allocPrint(allocator, "main:{s}:{s}", .{ star_kind, sound_name });
    try current_row.append(allocator, .{ .text = star_text, .callback_data = star_data });
}

fn buildTopLevelKeyboard(allocator: std.mem.Allocator, groups: []const sounds.SoundGroup, page: usize, favorites: *const UserFavorites, user_id: i64) !structs.InlineKeyboardMarkup {
    const total_pages = (groups.len + PAGE_SIZE - 1) / PAGE_SIZE;
    const safe_page = if (page >= total_pages and total_pages > 0) total_pages - 1 else page;
    const start = safe_page * PAGE_SIZE;
    const end = @min(start + PAGE_SIZE, groups.len);
    const page_groups = groups[start..end];

    var rows: std.ArrayList([]const structs.InlineKeyboardButton) = .empty;
    var current_row: std.ArrayList(structs.InlineKeyboardButton) = .empty;
    var items_in_row: usize = 0;

    for (page_groups) |group| {
        const is_family = group.members.len > 0;
        const text = if (is_family)
            try std.fmt.allocPrint(allocator, "{s} ({d})", .{ group.key, group.members.len })
        else
            try std.fmt.allocPrint(allocator, "{s}", .{group.key});

        const data = try std.fmt.allocPrint(allocator, "main:{s}:{s}", .{ if (is_family) "expand" else "play", group.key });

        if (is_family) {
            try current_row.append(allocator, .{ .text = text, .callback_data = data });
        } else {
            try appendSoundWithStar(allocator, &current_row, text, data, group.key, favorites, user_id);
        }
        items_in_row += 1;

        if (items_in_row >= 2) {
            try rows.append(allocator, try current_row.toOwnedSlice(allocator));
            current_row = .empty;
            items_in_row = 0;
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
                .callback_data = try std.fmt.allocPrint(allocator, "main:page:{d}", .{safe_page - 1}),
            });
        }
        try nav_row.append(allocator, .{
            .text = try std.fmt.allocPrint(allocator, "{d}/{d}", .{ safe_page + 1, total_pages }),
            .callback_data = try std.fmt.allocPrint(allocator, "main:page:{d}", .{safe_page}),
        });
        if (safe_page + 1 < total_pages) {
            try nav_row.append(allocator, .{
                .text = "Next ›",
                .callback_data = try std.fmt.allocPrint(allocator, "main:page:{d}", .{safe_page + 1}),
            });
        }
    }
    try nav_row.append(allocator, .{
        .text = "🔄",
        .callback_data = try std.fmt.allocPrint(allocator, "main:refresh:{d}", .{safe_page}),
    });
    try nav_row.append(allocator, .{
        .text = "🌟 Favorites",
        .callback_data = "favorites:page:0",
    });
    try rows.append(allocator, try nav_row.toOwnedSlice(allocator));

    return .{ .inline_keyboard = try rows.toOwnedSlice(allocator) };
}

fn buildFamilyKeyboard(allocator: std.mem.Allocator, group: sounds.SoundGroup, favorites: *const UserFavorites, user_id: i64) !structs.InlineKeyboardMarkup {
    var rows: std.ArrayList([]const structs.InlineKeyboardButton) = .empty;
    var current_row: std.ArrayList(structs.InlineKeyboardButton) = .empty;

    for (group.members) |member| {
        const text = try std.fmt.allocPrint(allocator, "{s}", .{member});
        const data = try std.fmt.allocPrint(allocator, "main:play:{s}", .{member}); // BUG FIX: was missing the "main:" menu prefix
        try appendSoundWithStar(allocator, &current_row, text, data, member, favorites, user_id);

        if (current_row.items.len >= 4) {
            try rows.append(allocator, try current_row.toOwnedSlice(allocator));
            current_row = .empty;
        }
    }
    if (current_row.items.len > 0) {
        try rows.append(allocator, try current_row.toOwnedSlice(allocator));
    }

    const bottom_row = try allocator.alloc(structs.InlineKeyboardButton, 2);
    bottom_row[0] = .{ .text = "🔄 Refresh", .callback_data = try std.fmt.allocPrint(allocator, "main:expand:{s}", .{group.key}) };
    bottom_row[1] = .{ .text = "« Back", .callback_data = "main:page:0" };
    try rows.append(allocator, bottom_row);

    return .{ .inline_keyboard = try rows.toOwnedSlice(allocator) };
}

fn buildFavoriteKeyboard(allocator: std.mem.Allocator, names: []const []const u8) !structs.InlineKeyboardMarkup {
    var rows: std.ArrayList([]const structs.InlineKeyboardButton) = .empty;
    var current_row: std.ArrayList(structs.InlineKeyboardButton) = .empty;

    for (names) |name| {
        const text = try std.fmt.allocPrint(allocator, "{s}", .{name});
        const play_data = try std.fmt.allocPrint(allocator, "favorites:play:{s}", .{name});
        try current_row.append(allocator, .{ .text = text, .callback_data = play_data });

        const remove_data = try std.fmt.allocPrint(allocator, "favorites:unfavorite:{s}", .{name});
        try current_row.append(allocator, .{ .text = "❌", .callback_data = remove_data });

        if (current_row.items.len >= 4) {
            try rows.append(allocator, try current_row.toOwnedSlice(allocator));
            current_row = .empty;
        }
    }
    if (current_row.items.len > 0) {
        try rows.append(allocator, try current_row.toOwnedSlice(allocator));
    }

    const bottom_row = try allocator.alloc(structs.InlineKeyboardButton, 2);
    bottom_row[0] = .{ .text = "🏘 Main menu", .callback_data = "main:page:0" };
    bottom_row[1] = .{ .text = "🔄 Refresh", .callback_data = "favorites:page:0" };
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

pub fn sendKeyboard(allocator: std.mem.Allocator, io: std.Io, tg_client: *queries.TgClient, chat_id: i64, owner_user_id: ?i64, owners: *MessageOwners, favorites: *const UserFavorites, sounds_dir: []const u8) void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var groups = sounds.buildSoundGroups(allocator, io, sounds_dir) catch |err| {
        std.debug.print("[telegram] failed to build sound groups for /sounds: {}\n", .{err});
        return;
    };
    defer groups.deinit(allocator);

    const star_check_id = owner_user_id orelse -1;

    const keyboard = buildTopLevelKeyboard(arena, groups.groups, 0, favorites, star_check_id) catch |err| {
        std.debug.print("[telegram] failed to build keyboard: {}\n", .{err});
        return;
    };
    const sent = tg_client.sendMessage(arena, .{
        .chat_id = chat_id,
        .text = "Tap a sound to play it:",
        .reply_markup = keyboard,
    }) catch |err| {
        std.debug.print("[telegram] failed to send keyboard: {}\n", .{err});
        return;
    };
    if (owner_user_id) |uid| {
        owners.record(allocator, sent.message_id, uid);
    }
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

pub fn pollLoop(allocator: std.mem.Allocator, io: std.Io, tg_client: *queries.TgClient, chat_ids: []const i64, sounds_dir: []const u8, favorites_folder: []const u8, button_queue: *queue_mod.ButtonQueue) !void {
    var offset: ?i64 = null;
    var owners = MessageOwners.init(allocator);
    var favorites = UserFavorites.init(allocator, favorites_folder);
    favorites.ensureFolder(io);
    favorites.loadAll(allocator, io);

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
                    const owner_user_id: ?i64 = if (msg.from) |sender| sender.id else null;
                    sendKeyboard(allocator, io, tg_client, msg.chat.id, owner_user_id, &owners, &favorites, sounds_dir);
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

            if (owners.ownerOf(message.message_id)) |owner_id| {
                if (owner_id != cq.from.id) {
                    std.debug.print("[telegram] rejecting button press from user {d} on a keyboard owned by {d}\n", .{ cq.from.id, owner_id });
                    tg_client.answerCallbackQuery(arena, .{
                        .callback_query_id = cq.id,
                        .text = "This isn't your keyboard - send /sounds to get your own.",
                        .show_alert = true,
                    });
                    continue;
                }
            }

            switch (parsed.menu) {
                .main => {
                    switch (parsed.kind) {
                        .play => {
                            button_queue.push(allocator, io, parsed.payload) catch |err| {
                                std.debug.print("[telegram] failed to queue button press: {}\n", .{err});
                            };
                            tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id, .text = "Playing..." });
                        },
                        .favorite => {
                            favorites.add(allocator, io, cq.from.id, parsed.payload);
                            tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id, .text = "⭐ Added to favorites" });
                        },
                        .unfavorite => {
                            favorites.remove(allocator, io, cq.from.id, parsed.payload);
                            tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id, .text = "Removed from favorites" });
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
                            const keyboard = buildFamilyKeyboard(arena, group, &favorites, cq.from.id) catch |err| {
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
                            const keyboard = buildTopLevelKeyboard(arena, groups.groups, target_page, &favorites, cq.from.id) catch |err| {
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
                },
                .favorites => {
                    switch (parsed.kind) {
                        .play => {
                            button_queue.push(allocator, io, parsed.payload) catch |err| {
                                std.debug.print("[telegram] failed to queue button press: {}\n", .{err});
                            };
                            tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id, .text = "Playing..." });
                        },
                        .unfavorite => {
                            favorites.remove(allocator, io, cq.from.id, parsed.payload);
                            const names = favorites.list(arena, cq.from.id) catch &.{};
                            const keyboard = buildFavoriteKeyboard(arena, names) catch |err| {
                                std.debug.print("[telegram] failed to build favorites keyboard: {}\n", .{err});
                                tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                                continue;
                            };
                            const text = if (names.len == 0) "No favorites yet - tap ⭐ next to any sound to add one." else "⭐ Your favorites:";
                            tg_client.editMessageText(arena, .{
                                .chat_id = message.chat.id,
                                .message_id = message.message_id,
                                .text = text,
                                .reply_markup = keyboard,
                            });
                            tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id, .text = "Removed from favorites" });
                        },
                        .page, .favorite, .expand, .refresh => {
                            const names = favorites.list(arena, cq.from.id) catch &.{};
                            const keyboard = buildFavoriteKeyboard(arena, names) catch |err| {
                                std.debug.print("[telegram] failed to build favorites keyboard: {}\n", .{err});
                                tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                                continue;
                            };
                            const text = if (names.len == 0) "No favorites yet - tap ⭐ next to any sound to add one." else "⭐ Your favorites:";
                            tg_client.editMessageText(arena, .{
                                .chat_id = message.chat.id,
                                .message_id = message.message_id,
                                .text = text,
                                .reply_markup = keyboard,
                            });
                            tg_client.answerCallbackQuery(arena, .{ .callback_query_id = cq.id });
                        },
                    }
                },
            }
        }
    }
}
