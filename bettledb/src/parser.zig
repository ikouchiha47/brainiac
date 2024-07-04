const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const t = @import("tokenize.zig");

const ASTNodeType = enum {
    CreateTable,
    ColumnDef,
    Insert,
    Select,
    TableName,
    ColumnList,
    ValueList,
    Literal,
};

pub const ASTNode = struct {
    type: ASTNodeType,
    value: ?[]const u8 = null,
    children: ArrayList(ASTNode),

    fn init(allocator: Allocator, nodeType: ASTNodeType) !ASTNode {
        return ASTNode{
            .type = nodeType,
            .children = ArrayList(ASTNode).init(allocator),
        };
    }

    fn deinit(self: *ASTNode) void {
        for (self.children.items) |*child| {
            child.deinit();
        }
        self.children.deinit();
    }
};

const Parser = struct {
    allocator: Allocator,
    lexer: *t.Lexer,
    current_token: t.Token,

    fn init(allocator: Allocator, lexer: *t.Lexer) Parser {
        var parser = Parser{
            .allocator = allocator,
            .lexer = lexer,
            .current_token = undefined,
        };
        parser.nextToken();
        return parser;
    }

    fn nextToken(self: *Parser) void {
        self.current_token = self.lexer.nextToken();
    }

    fn parse(self: *Parser) !ASTNode {
        return switch (self.current_token.type) {
            .Keyword => switch (self.current_token.value[0]) {
                'C', 'c' => self.parseCreateTable(),
                'I', 'i' => self.parseInsert(),
                'S', 's' => self.parseSelect(),
                else => error.UnexpectedToken,
            },
            else => error.UnexpectedToken,
        };
    }

    fn parseCreateTable(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .CreateTable);
        errdefer node.deinit();

        try self.consumeKeyword("CREATE");
        try self.consumeKeyword("TABLE");

        var tableName = try ASTNode.init(self.allocator, .TableName);
        tableName.value = try self.consumeIdentifier();
        try node.children.append(tableName);

        try self.consumeToken(.LeftParen);

        while (self.current_token.type != .RightParen) {
            const columnDef = try self.parseColumnDef();
            try node.children.append(columnDef);
            if (self.current_token.type == .Comma) {
                self.nextToken();
            } else break;
        }

        try self.consumeToken(.RightParen);
        try self.consumeToken(.Semicolon);

        return node;
    }

    fn parseColumnDef(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .ColumnDef);
        errdefer node.deinit();

        node.value = try self.consumeIdentifier();
        _ = try self.consumeIdentifier(); // Data type
        // Here you would typically store the data type and any constraints
        // For simplicity, we're not storing them in this example

        return node;
    }

    fn parseInsert(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .Insert);
        errdefer node.deinit();

        try self.consumeKeyword("INSERT");
        try self.consumeKeyword("INTO");

        var tableName = try ASTNode.init(self.allocator, .TableName);
        tableName.value = try self.consumeIdentifier();
        try node.children.append(tableName);

        const columnList = try self.parseColumnList();
        try node.children.append(columnList);

        try self.consumeKeyword("VALUES");

        const valueList = try self.parseValueList();
        try node.children.append(valueList);

        try self.consumeToken(.Semicolon);

        return node;
    }

    fn parseColumnList(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .ColumnList);
        errdefer node.deinit();

        try self.consumeToken(.LeftParen);

        while (self.current_token.type != .RightParen) {
            var column = try ASTNode.init(self.allocator, .Literal);
            column.value = try self.consumeIdentifier();
            try node.children.append(column);
            if (self.current_token.type == .Comma) {
                self.nextToken();
            } else break;
        }

        try self.consumeToken(.RightParen);

        return node;
    }

    fn parseValueList(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .ValueList);
        errdefer node.deinit();

        try self.consumeToken(.LeftParen);

        while (self.current_token.type != .RightParen) {
            var value = try ASTNode.init(self.allocator, .Literal);
            value.value = switch (self.current_token.type) {
                .String, .Number => blk: {
                    const val = self.current_token.value;
                    self.nextToken();
                    break :blk val;
                },
                else => return error.UnexpectedToken,
            };
            try node.children.append(value);
            if (self.current_token.type == .Comma) {
                self.nextToken();
            } else break;
        }

        try self.consumeToken(.RightParen);

        return node;
    }

    fn parseSelect(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .Select);
        errdefer node.deinit();

        try self.consumeKeyword("SELECT");

        if (self.current_token.type == .Star) {
            var star = try ASTNode.init(self.allocator, .Literal);
            star.value = self.current_token.value;
            try node.children.append(star);
            self.nextToken();
        } else {
            const columnList = try self.parseColumnList();
            try node.children.append(columnList);
        }

        try self.consumeKeyword("FROM");

        var tableName = try ASTNode.init(self.allocator, .TableName);
        tableName.value = try self.consumeIdentifier();
        try node.children.append(tableName);

        try self.consumeToken(.Semicolon);

        return node;
    }

    fn consumeToken(self: *Parser, tokenType: t.TokenType) !void {
        if (self.current_token.type != tokenType) {
            return error.UnexpectedToken;
        }
        self.nextToken();
    }

    fn consumeKeyword(self: *Parser, keyword: []const u8) !void {
        if (self.current_token.type != .Keyword or !std.ascii.eqlIgnoreCase(self.current_token.value, keyword)) {
            return error.UnexpectedToken;
        }
        self.nextToken();
    }

    fn consumeIdentifier(self: *Parser) ![]const u8 {
        if (self.current_token.type != .Identifier) {
            return error.UnexpectedToken;
        }
        const value = self.current_token.value;
        self.nextToken();
        return value;
    }
};
