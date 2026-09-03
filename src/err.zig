pub const fs = error {
    FileOpenError,
    FileReadError
};

pub const logger = error {
    LoggerInitializationError
};

pub const client = error {
    ConnectionError,
    PacketReadError,
    ServerDisconnect,
    ServerNoResponse,
    UnexpectedResponse
};
