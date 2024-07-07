const std = @import("std");
const testing = std.testing;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const t = @import("tokenize.zig");

pub const std_options = .{
    // Set the log level to info
    .log_level = .info,
};

const ASTNodeType = enum {
    CreateTable,
    ColumnDef,
    Insert,
    Select,
    TableName,
    ColumnList,
    ValueList,
    Literal,
    WhereClause,
    Comparison,
    BinaryExpression,
};

const ColumnType = union(enum) {
    Integer,
    Varchar: u64,
    Text,
    Decimal: struct { precision: u32, scale: u32 },
    Datetime,
};

const ColumnConstraint = enum {
    PrimaryKey,
    NotNull,
    Unique,
};

const data_pairs = [_]struct { []const u8, ColumnType }{
    .{ "INTEGER", .Integer },
    .{ "VARCHAR", .{ .Varchar = 255 } },
    .{ "TEXT", .Text },
    .{ "DECIMAL", .{ .Decimal = .{ .precision = 0, .scale = 0 } } },
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

    fn curretToken(self: *Parser) t.Token {
        return self.current_token;
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

        // std.log.info("start create table\n", .{});
        try self.consumeKeyword("CREATE");
        try self.consumeKeyword("TABLE");
        // std.log.info("end create table\n", .{});

        var tableName = try ASTNode.init(self.allocator, .TableName);
        // std.log.info("start table name parsing\n", .{});

        tableName.value = try self.consumeIdentifier();
        try node.children.append(tableName);

        try self.consumeToken(.LeftParen);
        // std.log.info("left paren\n", .{});

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
        // std.log.info("node {s}\n", .{node.value.?});

        // data type
        const dataType = try self.parseDataType();

        var typeNode = try ASTNode.init(self.allocator, .Literal);
        typeNode.value = @tagName(dataType);
        try node.children.append(typeNode);
        // std.log.info("typenode {s}\n", .{typeNode.value.?});
        // std.log.info("next token {any} {s}\n", .{ self.current_token, self.current_token.value });

        // parse constraint
        while (self.current_token.type == .Identifier) {
            const constraint = try self.parseConstraints();
            var constraintNode = try ASTNode.init(self.allocator, .Literal);

            constraintNode.value = @tagName(constraint);

            // std.log.info("constraint value {s}\n", .{constraintNode.value.?});
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
                    const num = self.current_token.value;

                    try self.consumeToken(.Number);
                    try self.consumeToken(.RightParen);

                    const size = try std.fmt.parseInt(u64, num, 10);
                    return .{ .Varchar = size };
                },
                .Decimal => {
                    try self.consumeToken(.LeftParen);

                    const _precision = self.current_token.value;
                    try self.consumeToken(.Number); // Precison

                    try self.consumeToken(.Comma);

                    const _scale = self.current_token.value;
                    try self.consumeToken(.Number); // Scale
                    try self.consumeToken(.RightParen);

                    const precision = try std.fmt.parseInt(u32, _precision, 10);
                    const scale = try std.fmt.parseInt(u32, _scale, 10);

                    return .{ .Decimal = .{ .precision = precision, .scale = scale } };
                },
                .Integer => {
                    return .Integer;
                },
                .Text => {
                    return .Text;
                },
                .Datetime => {
                    return .Datetime;
                },
            }
            return columnType;
        }

        return error.UnsupportedDataType;
    }

    fn parseConstraints(self: *Parser) !ColumnConstraint {
        var buf: [1024]u8 = undefined;

        // std.log.info("start constraint {any} {s}\n", .{ self.current_token, self.current_token.value });
        const constraint = try self.consumeIdentifier();
        const upperConstraint = std.ascii.upperString(&buf, constraint);

        if (self.constraint_map.get(upperConstraint)) |columnConstraint| {
            switch (columnConstraint) {
                .PrimaryKey => try self.consumeKeyword("KEY"),
                .NotNull => try self.consumeKeyword("NULL"),
                .Unique => {},
            }

            // std.log.info("col constraint {any}\n", .{columnConstraint});
            return columnConstraint;
        }

        return error.UnsupportedConstraint;
    }

    fn parseInsert(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .Insert);
        errdefer node.deinit();

        try self.consumeKeyword("INSERT");
        try self.consumeKeyword("INTO");

        std.log.info("token column list {s}\n", .{self.current_token.value});

        var tableName = try ASTNode.init(self.allocator, .TableName);
        tableName.value = try self.consumeIdentifier();
        try node.children.append(tableName);
        std.log.info("token column list {s}", .{self.current_token.value});

        try self.consumeToken(.LeftParen);

        const columnList = try self.parseColumnList();
        try node.children.append(columnList);

        try self.consumeToken(.RightParen);

        try self.consumeKeyword("VALUES");
        const valueList = try self.parseValueList();
        try node.children.append(valueList);

        try self.consumeToken(.Semicolon);

        return node;
    }

    // TODO: different parser classes for select, insert, create
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
            std.debug.print("parsing column list {any} {s}\n", .{ self.current_token, self.current_token.value });

            const columnList = try self.parseColumnList();
            try node.children.append(columnList);
        }

        std.debug.print("consuming from\n", .{});
        try self.consumeKeyword("FROM");

        var tableName = try ASTNode.init(self.allocator, .TableName);
        tableName.value = try self.consumeIdentifier();
        try node.children.append(tableName);

        std.debug.print("where {any} {s}\n", .{ self.current_token, tableName.value.? });
        // Check for WHERE clause
        if (std.ascii.eqlIgnoreCase(self.current_token.value, "WHERE")) {
            const whereClause = try self.parseWhereClause();
            try node.children.append(whereClause);
        }

        try self.consumeToken(.Semicolon);
        return node;
    }

    fn parseColumnList(self: *Parser) !ASTNode {
        var node = try ASTNode.init(self.allocator, .ColumnList);
        errdefer node.deinit();

        while (self.current_token.type == .Identifier) {
            var column = try ASTNode.init(self.allocator, .Literal);
            column.value = self.current_token.value;

            // column.value = try self.consumeIdentifier();
            try node.children.append(column);

            // std.debug.print("token token {any} {s}\n", .{ self.current_token.type, self.current_token.value });
            self.nextToken();

            if (self.current_token.type != .Comma) {
                break;
            }

            self.nextToken();
        }

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

    fn parseWhereClause(self: *Parser) !ASTNode {
        var whereNode = try ASTNode.init(self.allocator, .WhereClause);
        errdefer whereNode.deinit();

        try self.consumeKeyword("WHERE");

        const conditionNode = try self.parseCondition();
        try whereNode.children.append(conditionNode);

        return whereNode;
    }

    // (age > 18 AND name = 'John') OR (city = 'New York' AND age < 30);
    fn parseCondition(self: *Parser) !ASTNode {
        // parseComparison (age > 18)
        // operator: AND/OR
        // parseComparison name='John'
        const leftexpr = try self.parseComparison();
        const value = self.current_token.value;

        var node = try ASTNode.init(self.allocator, .BinaryExpression);

        if (std.ascii.eqlIgnoreCase(value, "and") or std.ascii.eqlIgnoreCase(value, "or")) {
            node.value = self.current_token.value;
            try node.children.append(leftexpr);

            self.nextToken(); // consume the operator

            const rightexpr = try self.parseComparison();
            try node.children.append(rightexpr);
        }

        return node;
    }
    // (age > 18)
    fn parseComparison(self: *Parser) !ASTNode {
        // TODO: parse parens later
        // left paren
        // parse left expression
        // operator
        // parse right expression
        // right paren
        // if (self.current_token.type == .LeftParen) {
        //     self.nextToken();
        // }

        const left = try self.parseExpression();
        const operator = try self.consumeOperator();
        const right = try self.parseExpression();

        var node = try ASTNode.init(self.allocator, .Comparison);
        node.value = operator;

        try node.children.append(left);
        try node.children.append(right);

        return node;
    }

    // age , 18, name , 'John'
    fn parseExpression(self: *Parser) !ASTNode {
        std.debug.print("parse expression {any} {s}\n", .{ self.current_token, self.current_token.value });
        var node = try ASTNode.init(self.allocator, .Literal);

        if (self.current_token.type == .Identifier) {
            node.value = try self.consumeIdentifier();
            return node;
        }

        // TODO: need to handle IN
        if (self.current_token.type == .String or self.current_token.type == .Number) {
            node.value = self.current_token.value;
            self.nextToken();
            return node;
        }

        return error.UnexpectedToken;
    }

    fn consumeOperator(self: *Parser) ![]const u8 {
        if (self.current_token.type == .Lesser or
            self.current_token.type == .LesserEquals or
            self.current_token.type == .GreaterEquals or
            self.current_token.type == .Greater or
            self.current_token.type == .NotEquals)
        {
            const value = self.current_token.value;
            self.nextToken();
            return value;
        }

        return error.UnexpectedToken;
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

// test "Parser - CREATE TABLE statement success" {
//     const input = "CREATE TABLE users (id INTEGER, name VARCHAR(255), age INTEGER);";
//     var lexer = t.Lexer.init(input);
//     var parser = try Parser.init(testing.allocator, &lexer);
//     defer parser.deinit();
//
//     const ast = try parser.parse();
//     defer ast.deinit();
//
//     try testing.expectEqual(ASTNodeType.CreateTable, ast.type);
//     try testing.expectEqual(@as(usize, 4), ast.children.items.len);
//
//     // Check table name
//     const tableName = ast.children.items[0];
//     try testing.expectEqual(ASTNodeType.TableName, tableName.type);
//     try testing.expectEqualStrings("users", tableName.value.?);
//
//     // Check column definitions
//     const idColumn = ast.children.items[1];
//     try testing.expectEqual(ASTNodeType.ColumnDef, idColumn.type);
//     try testing.expectEqualStrings("id", idColumn.value.?);
//     try testing.expectEqualStrings("Integer", idColumn.children.items[0].value.?);
//
//     const nameColumn = ast.children.items[2];
//     try testing.expectEqual(ASTNodeType.ColumnDef, nameColumn.type);
//     try testing.expectEqualStrings("name", nameColumn.value.?);
//     try testing.expectEqualStrings("Varchar", nameColumn.children.items[0].value.?);
//
//     const ageColumn = ast.children.items[3];
//     try testing.expectEqual(ASTNodeType.ColumnDef, ageColumn.type);
//     try testing.expectEqualStrings("age", ageColumn.value.?);
//     try testing.expectEqualStrings("Integer", ageColumn.children.items[0].value.?);
// }

// test "Parser - CREATE TABLE TEXT statement success" {
//     const input = "CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email VARCHAR(255) UNIQUE);";
//     var lexer = t.Lexer.init(input);
//     var parser = try Parser.init(testing.allocator, &lexer);
//     defer parser.deinit();
//
//     const ast = try parser.parse();
//     defer ast.deinit();
//
//     try testing.expectEqual(ASTNodeType.CreateTable, ast.type);
//     try testing.expectEqual(@as(usize, 4), ast.children.items.len);
//
//     // Check table name
//     const tableName = ast.children.items[0];
//     try testing.expectEqual(ASTNodeType.TableName, tableName.type);
//     try testing.expectEqualStrings("users", tableName.value.?);
//
//     // Check column definitions
//     const idColumn = ast.children.items[1];
//     try testing.expectEqual(ASTNodeType.ColumnDef, idColumn.type);
//     try testing.expectEqualStrings("id", idColumn.value.?);
//     try testing.expectEqualStrings(@tagName(ColumnConstraint.PrimaryKey), idColumn.children.items[1].value.?);
//
//     const nameColumn = ast.children.items[2];
//     try testing.expectEqual(ASTNodeType.ColumnDef, nameColumn.type);
//     try testing.expectEqualStrings("name", nameColumn.value.?);
//     try testing.expectEqualStrings(@tagName(ColumnConstraint.NotNull), nameColumn.children.items[1].value.?);
//
//     const ageColumn = ast.children.items[3];
//     try testing.expectEqual(ASTNodeType.ColumnDef, ageColumn.type);
//     try testing.expectEqualStrings("email", ageColumn.value.?);
//     try testing.expectEqualStrings(@tagName(ColumnConstraint.Unique), ageColumn.children.items[1].value.?);
// }

test "Parser - SELECT statement success" {
    const input = "SELECT id, name FROM users WHERE age > 18;";
    var lexer = t.Lexer.init(input);
    var parser = try Parser.init(testing.allocator, &lexer);
    defer parser.deinit();

    const ast = try parser.parse();
    defer ast.deinit();

    try testing.expectEqual(ASTNodeType.Select, ast.type);
    // try testing.expectEqual(@as(usize, 4), ast.children.items.len);

    // Check table name
    const tableName = ast.children.items[0];
    try testing.expectEqual(ASTNodeType.TableName, tableName.type);
    try testing.expectEqualStrings("users", tableName.value.?);
    try testing.expectEqual(0, ast.children.items.len);
}
