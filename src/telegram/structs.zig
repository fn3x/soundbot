pub const InlineKeyboardButton = struct {
    text: []const u8,
    callback_data: ?[]const u8,
};

pub const InlineKeyboardMarkup = struct {
    inline_keyboard: []const []const InlineKeyboardButton,
};

pub const SendMessageParams = struct {
    chat_id: i64,
    text: []const u8,
    reply_markup: ?InlineKeyboardMarkup = null,
};

pub const EditMessageReplyMarkupParams = struct {
    chat_id: i64,
    message_id: i64,
    reply_markup: ?InlineKeyboardMarkup = null,
};

pub const GetUpdatesParams = struct {
    offset: ?i64 = null,
    timeout: i64 = 30,
    allowed_updates: []const []const u8 = &.{ "callback_query", "message" },
};

pub const Chat = struct {
    id: i64,
};

pub const Message = struct {
    message_id: i64,
    chat: Chat,
};

pub const User = struct {
    id: i64,
    is_bot: bool,
    first_name: []const u8,
};

pub const CallbackQuery = struct {
    id: []const u8,
    from: User,
    message: ?Message = null,
    data: ?[]const u8 = null,
};

pub const Update = struct {
    update_id: i64,
    callback_query: ?CallbackQuery = null,
    message: ?IncomingMessage = null,
};

pub const IncomingMessage = struct {
    message_id: i64,
    chat: Chat,
    text: ?[]const u8 = null,
    from: ?User = null,
};

pub const AnswerCallbackQueryParams = struct {
    callback_query_id: []const u8,
    text: ?[]const u8 = null,
    show_alert: bool = false,
};
