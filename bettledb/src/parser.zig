const std = @import("std");
const testing = std.testing;

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

const ColumnType = enum {
    Integer,
    Varchar,
    Text,
    Decimal,
    Datetime,
};

const ColumnConstraint = enum {
    PrimaryKey,
    NotNull,
    Unique,
};

const data_pairs = [_]struct { []const u8, ColumnType }{
    .{ "INTEGER", .Integer },
    .{ "VARCHAR", .Varchar },
    .{ "TEXT", .Text },
    .{ "DECIMAL", .Decimal },
    .{ "DATETIME", .Datetime },
};
const constraint_pairs = [_]struct { []const u8, ColumnConstraint }{
    .{ "PRIMARY", .PrimaryKey },
    .{ "NOT", .NotNull },
    .{ "UNIQUE", .Unique },
};

pub const ASTNode = struct {
    type: ASTNodeType,
    children: ArrayList(ASTNode),
    value: ?[]const u8 = null,

    fn init(allocator: Allocator, nodeType: ASTNodeType) !ASTNode {
        return ASTNode{
            .type = nodeType,
            .children = ArrayList(ASTNode).init(allocator),
        };
    }

    fn deinit(self: *const ASTNode) void {
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

    data_type_map: std.StringHashMap(ColumnType),
    constraint_map: std.StringHashMap(ColumnConstraint),

    fn init(allocator: Allocator, lexer: *t.Lexer) !Parser {
        var data_type_map = std.StringHashMap(ColumnType).init(allocator);
        var constraint_map = std.StringHashMap(ColumnConstraint).init(allocator);

        for (data_pairs) |pair| {
            try data_type_map.put(pair[0], pair[1]);
        }

        for (constraint_pairs) |pair| {
            try constraint_map.put(pair[0], pair[1]);
        }

        var parser = Parser{
            .allocator = allocator,
            .lexer = lexer,
            .current_token = undefined,
            .data_type_map = data_type_map,
            .constraint_map = constraint_map,
        };
        parser.nextToken();
        return parser;
    }

    fn deinit(self: *Parser) void {
        self.data_type_map.deinit();
        self.constraint_map.deinit();
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

        std.debug.print("token {}\n", .{self.current_token});

        try self.consumeToken(.RightParen);
        try self.consumeToken(.Semicolon);

        return node;
    }

    fn parseColumnDef(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .ColumnDef);
        errdefer node.deinit();

        node.value = try self.consumeIdentifier();

        const dataType = try self.parseDataType();
        var typeNode = try ASTNode.init(self.allocator, .Literal);
        typeNode.value = @tagName(dataType);

        try node.children.append(typeNode);

        // parse constraint
        while (self.current_token.type == .Keyword) {
            const constraint = try self.parseConstraints();
            var constraintNode = try ASTNode.init(self.allocator, .Literal);

            constraintNode.value = @tagName(constraint);
            try node.children.append(constraintNode);
        }

        return node;
    }

    fn parseDataType(self: *Parser) !ColumnType {
        var buf: [1024]u8 = undefined;
        const data_type = try self.consumeIdentifier();
        const upperDataType = std.ascii.upperString(&buf, data_type);

        if (self.data_type_map.get(upperDataType)) |columnType| {
            switch (columnType) {
                .Varchar => {
                    try self.consumeToken(.LeftParen);
                    _ = try self.consumeToken(.Number); // Ignore size for now
                    try self.consumeToken(.RightParen);
                },
                .Decimal => {
                    try self.consumeToken(.LeftParen);
                    _ = try self.consumeToken(.Number); // Precision
                    try self.consumeToken(.Comma);
                    _ = try self.consumeToken(.Number); // Scale
                    try self.consumeToken(.RightParen);
                },
                else => {},
            }
            return columnType;
        }

        return error.UnsupportedDataType;
    }

    fn parseConstraints(self: *Parser) !ColumnConstraint {
        var buf: [1024]u8 = undefined;
        const constraint = try self.consumeIdentifier();
        const upperConstraint = std.ascii.upperString(&buf, constraint);

        if (self.constraint_map.get(upperConstraint)) |columnConstraint| {
            switch (columnConstraint) {
                .PrimaryKey => try self.consumeKeyword("KEY"),
                .NotNull => try self.consumeKeyword("NULL"),
                .Unique => {},
            }
            return columnConstraint;
        }

        return error.UnsupportedConstraint;
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

test "Parser - CREATE TABLE statement success" {
    const input = "CREATE TABLE users (id INT, name VARCHAR(255), age INT);";
    var lexer = t.Lexer.init(input);
    var parser = try Parser.init(testing.allocator, &lexer);
    defer parser.deinit();

    const ast = try parser.parse();
    defer ast.deinit();

    try testing.expectEqual(ASTNodeType.CreateTable, ast.type);
    try testing.expectEqual(@as(usize, 4), ast.children.items.len);

    // Check table name
    const tableName = ast.children.items[0];
    try testing.expectEqual(ASTNodeType.TableName, tableName.type);
    try testing.expectEqualStrings("users", tableName.value.?);

    // Check column definitions
    const idColumn = ast.children.items[1];
    try testing.expectEqual(ASTNodeType.ColumnDef, idColumn.type);
    try testing.expectEqualStrings("id", idColumn.value.?);

    const nameColumn = ast.children.items[2];
    try testing.expectEqual(ASTNodeType.ColumnDef, nameColumn.type);
    try testing.expectEqualStrings("name", nameColumn.value.?);

    const ageColumn = ast.children.items[3];
    try testing.expectEqual(ASTNodeType.ColumnDef, ageColumn.type);
    try testing.expectEqualStrings("age", ageColumn.value.?);
}
