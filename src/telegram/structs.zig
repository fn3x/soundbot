pub const KeyboardButton = struct {
    text: []const u8,
};

pub const ReplyKeyboardMarkup = struct {
    keyboard: []const []const KeyboardButton,
    resize_keyboard: bool = true,
    one_time_keyboard: bool = false,
};

pub const ReplyKeyboardRemove = struct {
    remove_keyboard: bool = true,
};

pub const SendMessageParams = struct {
    chat_id: i64,
    text: []const u8,
    reply_markup: ?ReplyKeyboardMarkup = null,
};

pub const SendMessageRemoveKeyboardParams = struct {
    chat_id: i64,
    text: []const u8,
    reply_markup: ReplyKeyboardRemove = .{},
};

pub const GetUpdatesParams = struct {
    offset: ?i64 = null,
    timeout: i64 = 30,
    allowed_updates: []const []const u8 = &.{"message"},
};

pub const Chat = struct {
    id: i64,
};

pub const IncomingMessage = struct {
    message_id: i64,
    chat: Chat,
    text: ?[]const u8 = null,
};

pub const Update = struct {
    update_id: i64,
    message: ?IncomingMessage = null,
};

pub const SentMessage = struct {
    message_id: i64,
};
