const std = @import("std");
const structs = @import("structs.zig");

fn Envelope(comptime T: type) type {
    return struct {
        ok: bool,
        result: ?T = null,
        error_code: ?i64 = null,
        description: ?[]const u8 = null,
    };
}

pub const TgClient = struct {
    token: []const u8,
    http_client: std.http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, io: std.Io, token: []const u8) Self {
        return .{
            .token = token,
            .http_client = .{ .allocator = allocator, .io = io, .write_buffer_size = 32768 },
        };
    }

    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
    }

    pub const ApiError = error{TelegramApiError};

    pub fn post(
        self: *Self,
        comptime Result: type,
        allocator: std.mem.Allocator,
        comptime method: []const u8,
        params: anytype,
    ) !Result {
        const body = try std.json.Stringify.valueAlloc(allocator, params, .{});

        const url = try std.fmt.allocPrint(
            allocator,
            "https://api.telegram.org/bot{s}/{s}",
            .{ self.token, method },
        );

        var response_buf: std.Io.Writer.Allocating = .init(allocator);

        _ = try self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response_buf.writer,
        });

        const envelope = try std.json.parseFromSliceLeaky(
            Envelope(Result),
            allocator,
            response_buf.written(),
            .{ .ignore_unknown_fields = true },
        );

        if (!envelope.ok) {
            std.debug.print("Telegram API error {?d}: {?s}\n", .{ envelope.error_code, envelope.description });
            return error.TelegramApiError;
        }
        return envelope.result.?;
    }

    pub fn getUpdates(self: *Self, allocator: std.mem.Allocator, params: structs.GetUpdatesParams) ![]structs.Update {
        return self.post([]structs.Update, allocator, "getUpdates", params);
    }

    pub fn sendMessage(self: *Self, allocator: std.mem.Allocator, params: structs.SendMessageParams) !structs.Message {
        return self.post(structs.Message, allocator, "sendMessage", params);
    }

    pub fn editMessageReplyMarkup(self: *Self, allocator: std.mem.Allocator, params: structs.EditMessageReplyMarkupParams) void {
        const body = std.json.Stringify.valueAlloc(allocator, params, .{}) catch return;
        const url = std.fmt.allocPrint(allocator, "https://api.telegram.org/bot{s}/editMessageReplyMarkup", .{self.token}) catch return;

        var response_buf: std.Io.Writer.Allocating = .init(allocator);
        defer response_buf.deinit();

        _ = self.http_client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .response_writer = &response_buf.writer,
        }) catch |err| {
            std.debug.print("[telegram] editMessageReplyMarkup failed: {}\n", .{err});
            return;
        };

        const envelope = std.json.parseFromSliceLeaky(
            Envelope(std.json.Value),
            allocator,
            response_buf.written(),
            .{ .ignore_unknown_fields = true },
        ) catch return;

        if (!envelope.ok) {
            if (envelope.error_code) |code| {
                if (code == 400) {
                    if (envelope.description) |desc| {
                        if (std.mem.indexOf(u8, desc, "message is not modified") != null) return;
                    }
                }
            }
            std.debug.print("[telegram] editMessageReplyMarkup failed: {?d} {?s}\n", .{ envelope.error_code, envelope.description });
        }
    }

    pub fn answerCallbackQuery(self: *Self, allocator: std.mem.Allocator, params: structs.AnswerCallbackQueryParams) void {
        _ = self.post(bool, allocator, "answerCallbackQuery", params) catch |err| {
            std.debug.print("[telegram] answerCallbackQuery failed: {}\n", .{err});
        };
    }
};
