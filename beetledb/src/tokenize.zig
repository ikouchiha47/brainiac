const std = @import("std");
const testing = std.testing;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

pub const TokenType = enum {
    Keyword,
    Identifier,
    String,
    Number,
    Comma,
    LeftParen,
    RightParen,
    Greater,
    Lesser,
    Equals,
    GreaterEquals,
    LesserEquals,
    NotEquals,
    Star,
    Semicolon,
    EOF,
};

pub const Token = struct {
    type: TokenType,
    value: []const u8,
};

const Keywords = [_][]const u8{ "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "CREATE", "TABLE", "IF", "EXISTS", "KEY", "NULL" };

pub const Lexer = struct {
    input: []const u8,
    position: usize,
    read_position: usize,
    ch: u8,

    pub fn init(input: []const u8) Lexer {
        var lexer = Lexer{
            .input = input,
            .position = 0,
            .read_position = 0,
            .ch = 0,
        };
        lexer.readChar();
        return lexer;
    }

    fn readChar(self: *Lexer) void {
        if (self.read_position >= self.input.len) {
            self.ch = 0;
        } else {
            self.ch = self.input[self.read_position];
        }
        self.position = self.read_position;
        self.read_position += 1;
    }

    fn peekChar(self: *Lexer) u8 {
        if (self.read_position >= self.input.len) {
            return 0;
        } else {
            return self.input[self.read_position];
        }
    }

    pub fn nextToken(self: *Lexer) Token {
        self.skipWhitespace();

        const token: Token = switch (self.ch) {
            ',' => .{ .type = .Comma, .value = "," },
            '(' => .{ .type = .LeftParen, .value = "(" },
            ')' => .{ .type = .RightParen, .value = ")" },
            '>' => blk: {
                if (self.peekChar() == '=') {
                    self.readChar();
                    break :blk .{ .type = .GreaterEquals, .value = ">=" };
                }
                break :blk .{ .type = .Greater, .value = ">" };
            },
            '<' => blk: {
                if (self.peekChar() == '=') {
                    self.readChar();
                    break :blk .{ .type = .LesserEquals, .value = "<=" };
                }
                break :blk .{ .type = .Lesser, .value = "<" };
            },
            '=' => .{ .type = .Equals, .value = "=" },
            '!' => blk: {
                if (self.peekChar() == '=') {
                    self.readChar();
                    break :blk .{ .type = .NotEquals, .value = "<=" };
                }
                break :blk .{ .type = .EOF, .value = "ILLEGAL" };
            },
            ';' => .{ .type = .Semicolon, .value = ";" },
            '*' => .{ .type = .Star, .value = "*" },
            '"', '\'' => self.readString(),
            '0'...'9' => self.readNumber(),
            'a'...'z', 'A'...'Z', '_' => self.readIdentifier(),
            0 => .{ .type = .EOF, .value = "" },
            else => .{ .type = .EOF, .value = "ILLEGAL" },
        };

        self.readChar();
        return token;
    }

    fn readString(self: *Lexer) Token {
        const quote = self.ch;
        const start_position = self.position + 1;
        self.readChar();
        while (self.ch != quote and self.ch != 0) {
            self.readChar();
        }
        return .{ .type = .String, .value = self.input[start_position..self.position] };
    }

    fn readNumber(self: *Lexer) Token {
        const start_position = self.position;
        while (std.ascii.isDigit(self.ch)) {
            self.readChar();
        }
        self.read_position -= 1;
        return .{ .type = .Number, .value = self.input[start_position..self.position] };
    }

    fn readIdentifier(self: *Lexer) Token {
        const start_position = self.position;
        while (std.ascii.isAlphanumeric(self.ch) or self.ch == '_') {
            self.readChar();
        }
        self.read_position -= 1;
        const value = self.input[start_position..self.position];

        // const token_type = if (isKeyword(value)) .Keyword else .Identifier;
        const token_type = blk: {
            if (isKeyword(value)) {
                break :blk TokenType.Keyword;
            }
            break :blk TokenType.Identifier;
        };

        return .{ .type = token_type, .value = value };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.ch == ' ' or self.ch == '\t' or self.ch == '\n' or self.ch == '\r') {
            self.readChar();
        }
    }

    fn isKeyword(word: []const u8) bool {
        for (Keywords) |keyword| {
            if (std.ascii.eqlIgnoreCase(word, keyword)) {
                return true;
            }
        }
        return false;
    }
};

test "CREATE TABLE statement - success" {
    const input = "CREATE TABLE users (id INT PRIMARY KEY, name VARCHAR(255));";

    var lexer = Lexer.init(input);

    // create table users (
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    try testing.expectEqual(TokenType.LeftParen, lexer.nextToken().type);
    // id INT PRIMARY
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    // key ,
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    try testing.expectEqual(TokenType.Comma, lexer.nextToken().type);
    // name
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    // VARCHAR
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    try testing.expectEqual(TokenType.LeftParen, lexer.nextToken().type);
    try testing.expectEqual(TokenType.Number, lexer.nextToken().type);
    try testing.expectEqual(TokenType.RightParen, lexer.nextToken().type);
    try testing.expectEqual(TokenType.RightParen, lexer.nextToken().type);
    try testing.expectEqual(TokenType.Semicolon, lexer.nextToken().type);
    try testing.expectEqual(TokenType.EOF, lexer.nextToken().type);
}

test "SELECT statement - success" {
    const input = "SELECT id, name FROM users WHERE age > 18;";
    var lexer = Lexer.init(input);

    // select
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    // id
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    //,
    try testing.expectEqual(TokenType.Comma, lexer.nextToken().type);
    // name
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    // from
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    // users
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    // where
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    // age
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    // >
    try testing.expectEqual(TokenType.Greater, lexer.nextToken().type);
    // 18
    try testing.expectEqual(TokenType.Number, lexer.nextToken().type);
    // ;
    try testing.expectEqual(TokenType.Semicolon, lexer.nextToken().type);
    try testing.expectEqual(TokenType.EOF, lexer.nextToken().type);
}

test "INSERT statement - success" {
    const input = "INSERT INTO users (id, name) VALUES (1, 'John Doe');";
    var lexer = Lexer.init(input);

    // insert
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    // into
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    // users
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    // (
    try testing.expectEqual(TokenType.LeftParen, lexer.nextToken().type);
    // id
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    // ,
    try testing.expectEqual(TokenType.Comma, lexer.nextToken().type);
    // name
    try testing.expectEqual(TokenType.Identifier, lexer.nextToken().type);
    // )
    try testing.expectEqual(TokenType.RightParen, lexer.nextToken().type);
    // values
    try testing.expectEqual(TokenType.Keyword, lexer.nextToken().type);
    // (
    try testing.expectEqual(TokenType.LeftParen, lexer.nextToken().type);
    // 1
    try testing.expectEqual(TokenType.Number, lexer.nextToken().type);
    // ,
    try testing.expectEqual(TokenType.Comma, lexer.nextToken().type);
    // John Doe
    try testing.expectEqual(TokenType.String, lexer.nextToken().type);
    // )
    try testing.expectEqual(TokenType.RightParen, lexer.nextToken().type);
    // ;
    try testing.expectEqual(TokenType.Semicolon, lexer.nextToken().type);
    try testing.expectEqual(TokenType.EOF, lexer.nextToken().type);
}
