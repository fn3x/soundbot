const std = @import("std");

pub const Config = struct {
    ssh_host: []const u8,
    ssh_port: []const u8,
    ssh_user: []const u8,
    ssh_pass: []const u8,
    vserver_id: []const u8,
    channel_id: []const u8,
    sounds_dir: []const u8,
    sink: []const u8,
    ptt_key: []const u8,
    voice_nickname: []const u8,
    yt_cookies_path: ?[]const u8,
    tg_bot_token: ?[]const u8,
    tg_chat_ids: ?[]i64,

    pub fn load(allocator: std.mem.Allocator) !Config {
        const tg_bot_token = try getEnvOptional(allocator, "TG_BOT_TOKEN");

        const tg_chat_ids: ?[]i64 = if (tg_bot_token != null) blk: {
            const raw = try getEnvRequired(allocator, "TG_CHAT_IDS");
            defer allocator.free(raw);
            var ids: std.ArrayList(i64) = .empty;
            var it = std.mem.splitScalar(u8, raw, ',');
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " ");
                const id = std.fmt.parseInt(i64, trimmed, 10) catch {
                    std.debug.print("TG_CHAT_IDS: '{s}' is not a valid integer\n", .{trimmed});
                    return error.InvalidTgChatId;
                };
                try ids.append(allocator, id);
            }
            if (ids.items.len == 0) {
                std.debug.print("TG_CHAT_IDS must contain at least one chat id\n", .{});
                return error.InvalidTgChatId;
            }
            break :blk try ids.toOwnedSlice(allocator);
        } else null;

        return Config{
            .ssh_host = try getEnvOr(allocator, "TS_SSH_HOST", "127.0.0.1"),
            .ssh_port = try getEnvOr(allocator, "TS_SSH_PORT", "10022"),
            .ssh_user = try getEnvOr(allocator, "TS_SSH_USER", "soundbot"),
            .ssh_pass = try getEnvRequired(allocator, "TS_SSH_PASS"),
            .vserver_id = try getEnvOr(allocator, "TS_VSERVER_ID", "1"),
            .channel_id = try getEnvRequired(allocator, "TS_CHANNEL_ID"),
            .sounds_dir = try getEnvOr(allocator, "TS_SOUNDS_DIR", "sounds"),
            .sink = try getEnvOr(allocator, "TS_SINK", "ts_bot_sink"),
            .ptt_key = try getEnvOr(allocator, "TS_PTT_KEY", "F12"),
            .voice_nickname = try getEnvRequired(allocator, "TS_VOICE_NICKNAME"),
            .yt_cookies_path = try getEnvOptional(allocator, "TS_YT_COOKIES_PATH"),
            .tg_bot_token = tg_bot_token,
            .tg_chat_ids = tg_chat_ids,
        };
    }
};

fn getEnvRaw(name: [*:0]const u8) ?[]const u8 {
    const ptr = std.c.getenv(name) orelse return null;
    return std.mem.span(ptr);
}

fn getEnvOr(allocator: std.mem.Allocator, name: [*:0]const u8, default: []const u8) ![]const u8 {
    if (getEnvRaw(name)) |value| {
        return try allocator.dupe(u8, value);
    }
    return try allocator.dupe(u8, default);
}

fn getEnvOptional(allocator: std.mem.Allocator, name: [*:0]const u8) !?[]const u8 {
    const value = getEnvRaw(name) orelse return null;
    if (value.len == 0) return null;
    return try allocator.dupe(u8, value);
}

fn getEnvRequired(allocator: std.mem.Allocator, name: [*:0]const u8) ![]const u8 {
    if (getEnvRaw(name)) |value| {
        return try allocator.dupe(u8, value);
    }
    std.debug.print("Missing required env var: {s}\n", .{name});
    return error.MissingEnvVar;
}
