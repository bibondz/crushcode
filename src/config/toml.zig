const std = @import("std");
const array_list_compat = @import("array_list_compat");

const Allocator = std.mem.Allocator;

/// TOML value — can be a string, integer, float, boolean, or array
pub const TomlValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    array: []const TomlValue,

    pub fn deinit(self: *TomlValue, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |arr| {
                for (arr) |*item| {
                    var mutable = item.*;
                    mutable.deinit(allocator);
                }
                allocator.free(arr);
            },
            else => {},
        }
    }
};

/// A TOML table — maps string keys to values
pub const TomlTable = struct {
    entries: std.StringHashMap(TomlValue),
    allocator: Allocator,

    pub fn init(allocator: Allocator) TomlTable {
        return TomlTable{
            .entries = std.StringHashMap(TomlValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TomlTable) void {
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var val = entry.value_ptr.*;
            val.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    pub fn put(self: *TomlTable, key: []const u8, value: TomlValue) !void {
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        // If key already exists, free old value
        // Note: StringHashMap.fetchPut keeps old key, returns it — don't free old.key
        if (try self.entries.fetchPut(key_copy, value)) |old| {
            self.allocator.free(key_copy); // New key not needed — old key is retained
            var old_val = old.value;
            old_val.deinit(self.allocator);
        }
    }

    pub fn get(self: *const TomlTable, key: []const u8) ?TomlValue {
        return self.entries.get(key);
    }

    pub fn getString(self: *const TomlTable, key: []const u8) ?[]const u8 {
        if (self.get(key)) |val| {
            if (val == .string) return val.string;
        }
        return null;
    }

    pub fn getInt(self: *const TomlTable, key: []const u8) ?i64 {
        if (self.get(key)) |val| {
            if (val == .integer) return val.integer;
        }
        return null;
    }

    pub fn getFloat(self: *const TomlTable, key: []const u8) ?f64 {
        if (self.get(key)) |val| {
            if (val == .float) return val.float;
        }
        return null;
    }

    pub fn getBool(self: *const TomlTable, key: []const u8) ?bool {
        if (self.get(key)) |val| {
            if (val == .boolean) return val.boolean;
        }
        return null;
    }

    /// Get a sub-table (stored as a TomlValue.string containing serialized entries)
    /// In our simplified model, sections are separate tables in the root
    pub fn count(self: *const TomlTable) usize {
        return self.entries.count();
    }
};

/// Result of parsing a TOML document
pub const TomlDocument = struct {
    /// Root-level key-value pairs
    root: TomlTable,
    /// Named sections: [section_name] → key-value pairs
    sections: std.StringHashMap(*TomlTable),
    /// Array of tables: [[table_name]] → list of tables
    array_tables: std.StringHashMap(array_list_compat.ArrayList(*TomlTable)),
    allocator: Allocator,

    pub fn init(allocator: Allocator) TomlDocument {
        return TomlDocument{
            .root = TomlTable.init(allocator),
            .sections = std.StringHashMap(*TomlTable).init(allocator),
            .array_tables = std.StringHashMap(array_list_compat.ArrayList(*TomlTable)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TomlDocument) void {
        self.root.deinit();

        var sec_iter = self.sections.iterator();
        while (sec_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sections.deinit();

        var arr_iter = self.array_tables.iterator();
        while (arr_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*.items) |table| {
                table.deinit();
                self.allocator.destroy(table);
            }
            entry.value_ptr.*.deinit();
        }
        self.array_tables.deinit();
    }

    /// Get a section by name
    pub fn getSection(self: *const TomlDocument, name: []const u8) ?*const TomlTable {
        return self.sections.get(name);
    }

    /// Get all entries for an array of tables
    pub fn getArrayTable(self: *const TomlDocument, name: []const u8) ?[]const *TomlTable {
        if (self.array_tables.get(name)) |list| {
            return list.items;
        }
        return null;
    }

    /// Parse a TOML document from string
    pub fn parse(allocator: Allocator, content: []const u8) !TomlDocument {
        var doc = TomlDocument.init(allocator);
        errdefer doc.deinit();

        var current_section: ?*TomlTable = null;
        var current_array_name: ?[]const u8 = null;

        var line_iter = std.mem.splitScalar(u8, content, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Array of tables: [[name]]
            if (trimmed.len >= 4 and std.mem.startsWith(u8, trimmed, "[[") and std.mem.endsWith(u8, trimmed, "]]")) {
                const name = std.mem.trim(u8, trimmed[2 .. trimmed.len - 2], " \t");
                if (name.len == 0) continue;

                // Create a new table for this array entry
                const table = try allocator.create(TomlTable);
                table.* = TomlTable.init(allocator);

                const name_copy = try allocator.dupe(u8, name);
                const result = try doc.array_tables.getOrPut(name_copy);
                if (result.found_existing) {
                    allocator.free(name_copy);
                }
                if (!result.found_existing) {
                    result.value_ptr.* = array_list_compat.ArrayList(*TomlTable).init(allocator);
                }
                try result.value_ptr.*.append(table);

                current_section = table;
                current_array_name = name_copy;
                continue;
            }

            // Section: [name]
            if (trimmed.len >= 2 and trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                const name = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
                if (name.len == 0) continue;

                const name_copy = try allocator.dupe(u8, name);

                // Create or get the section table
                const table = try allocator.create(TomlTable);
                table.* = TomlTable.init(allocator);

                // Free old section if overwriting
                if (try doc.sections.fetchPut(name_copy, table)) |old| {
                    allocator.free(old.key);
                    old.value.deinit();
                    allocator.destroy(old.value);
                }

                current_section = table;
                current_array_name = null;
                continue;
            }

            // Key-value pair
            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            if (key.len == 0) continue;

            const raw_value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");
            if (raw_value.len == 0) continue;

            const value = parseValue(allocator, raw_value) catch |err| {
                if (err == error.InvalidValue) continue;
                return err;
            };

            const target = current_section orelse &doc.root;
            try target.put(key, value);
        }

        return doc;
    }

    /// Serialize a TomlDocument back to TOML string
    pub fn serialize(self: *const TomlDocument, allocator: Allocator) ![]const u8 {
        var buf = array_list_compat.ArrayList(u8).init(allocator);
        const writer = buf.writer();

        // Root-level key-value pairs first
        var root_iter = self.root.entries.iterator();
        while (root_iter.next()) |entry| {
            try writeKeyValue(writer, entry.key_ptr.*, entry.value_ptr.*);
        }

        // Sections
        var sec_iter = self.sections.iterator();
        while (sec_iter.next()) |entry| {
            try writer.print("\n[{s}]\n", .{entry.key_ptr.*});
            var inner_iter = entry.value_ptr.*.entries.iterator();
            while (inner_iter.next()) |inner_entry| {
                try writeKeyValue(writer, inner_entry.key_ptr.*, inner_entry.value_ptr.*);
            }
        }

        // Array of tables
        var arr_iter = self.array_tables.iterator();
        while (arr_iter.next()) |entry| {
            for (entry.value_ptr.*.items) |table| {
                try writer.print("\n[[{s}]]\n", .{entry.key_ptr.*});
                var inner_iter = table.entries.iterator();
                while (inner_iter.next()) |inner_entry| {
                    try writeKeyValue(writer, inner_entry.key_ptr.*, inner_entry.value_ptr.*);
                }
            }
        }

        return buf.toOwnedSlice();
    }

    fn writeKeyValue(writer: array_list_compat.ArrayList(u8).Writer, key: []const u8, value: TomlValue) !void {
        switch (value) {
            .string => |s| try writer.print("{s} = \"{s}\"\n", .{ key, s }),
            .integer => |i| try writer.print("{s} = {d}\n", .{ key, i }),
            .float => |f| try writer.print("{s} = {d}\n", .{ key, f }),
            .boolean => |b| try writer.print("{s} = {s}\n", .{ key, if (b) "true" else "false" }),
            .array => |arr| {
                try writer.print("{s} = [", .{key});
                for (arr, 0..) |item, i| {
                    if (i > 0) try writer.print(", ", .{});
                    switch (item) {
                        .string => |s| try writer.print("\"{s}\"", .{s}),
                        .integer => |v| try writer.print("{d}", .{v}),
                        .float => |v| try writer.print("{d}", .{v}),
                        .boolean => |v| try writer.print("{s}", .{if (v) "true" else "false"}),
                        else => try writer.print("?", .{}),
                    }
                }
                try writer.print("]\n", .{});
            },
        }
    }
};

const ParseError = error{ OutOfMemory, InvalidValue };

/// Parse a single TOML value from a raw string
fn parseValue(allocator: Allocator, raw: []const u8) ParseError!TomlValue {
    // String: "..." or '...'
    if ((raw[0] == '"' and raw.len >= 2 and raw[raw.len - 1] == '"') or
        (raw[0] == '\'' and raw.len >= 2 and raw[raw.len - 1] == '\''))
    {
        const content = raw[1 .. raw.len - 1];
        return TomlValue{ .string = try allocator.dupe(u8, content) };
    }

    // Array: [...]
    if (raw[0] == '[' and raw.len >= 2 and raw[raw.len - 1] == ']') {
        return parseArray(allocator, raw[1 .. raw.len - 1]);
    }

    // Boolean
    if (std.mem.eql(u8, raw, "true")) return TomlValue{ .boolean = true };
    if (std.mem.eql(u8, raw, "false")) return TomlValue{ .boolean = false };

    // Try integer
    if (std.fmt.parseInt(i64, raw, 10)) |i| {
        return TomlValue{ .integer = i };
    } else |_| {}

    // Try float
    if (std.fmt.parseFloat(f64, raw)) |f| {
        return TomlValue{ .float = f };
    } else |_| {}

    // Bare string (unquoted) — treat as string
    return TomlValue{ .string = try allocator.dupe(u8, raw) };
}

/// Parse an inline array: "a, b, c"
fn parseArray(allocator: Allocator, content: []const u8) ParseError!TomlValue {
    var items = array_list_compat.ArrayList(TomlValue).init(allocator);
    defer items.deinit();

    // Handle empty array
    const trimmed = std.mem.trim(u8, content, " \t");
    if (trimmed.len == 0) {
        const empty = try allocator.alloc(TomlValue, 0);
        return TomlValue{ .array = empty };
    }

    var start: usize = 0;
    var in_string = false;
    var string_char: u8 = 0;

    for (trimmed, 0..) |ch, i| {
        if (in_string) {
            if (ch == string_char) in_string = false;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            in_string = true;
            string_char = ch;
            continue;
        }
        if (ch == ',') {
            const item_str = std.mem.trim(u8, trimmed[start..i], " \t");
            if (item_str.len > 0) {
                try items.append(try parseValue(allocator, item_str));
            }
            start = i + 1;
        }
    }

    // Last item
    const last_str = std.mem.trim(u8, trimmed[start..], " \t");
    if (last_str.len > 0) {
        try items.append(try parseValue(allocator, last_str));
    }

    return TomlValue{ .array = try items.toOwnedSlice() };
}

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "TomlValue - string deinit" {
    var val = TomlValue{ .string = try testing.allocator.dupe(u8, "hello") };
    val.deinit(testing.allocator);
}

test "TomlValue - array deinit" {
    const items = try testing.allocator.alloc(TomlValue, 2);
    items[0] = .{ .string = try testing.allocator.dupe(u8, "a") };
    items[1] = .{ .string = try testing.allocator.dupe(u8, "b") };
    var val = TomlValue{ .array = items };
    val.deinit(testing.allocator);
}

test "TomlTable - put and get" {
    var table = TomlTable.init(testing.allocator);
    defer table.deinit();

    try table.put("name", .{ .string = try testing.allocator.dupe(u8, "crushcode") });
    try table.put("port", .{ .integer = 8080 });
    try table.put("enabled", .{ .boolean = true });
    try table.put("ratio", .{ .float = 0.85 });

    try testing.expectEqualStrings("crushcode", table.getString("name").?);
    try testing.expectEqual(@as(i64, 8080), table.getInt("port").?);
    try testing.expectEqual(true, table.getBool("enabled").?);
    try testing.expectEqual(@as(f64, 0.85), table.getFloat("ratio").?);
    try testing.expect(table.getString("nonexistent") == null);
}

test "TomlTable - put overwrites and frees old" {
    var table = TomlTable.init(testing.allocator);
    defer table.deinit();

    try table.put("key", .{ .string = try testing.allocator.dupe(u8, "old") });
    try table.put("key", .{ .string = try testing.allocator.dupe(u8, "new") });

    try testing.expectEqualStrings("new", table.getString("key").?);
    try testing.expectEqual(@as(usize, 1), table.count());
}

test "TomlDocument - parse root key-value pairs" {
    const input =
        \\name = "crushcode"
        \\version = 42
        \\enabled = true
        \\ratio = 3.14
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expectEqualStrings("crushcode", doc.root.getString("name").?);
    try testing.expectEqual(@as(i64, 42), doc.root.getInt("version").?);
    try testing.expectEqual(true, doc.root.getBool("enabled").?);
    try testing.expectEqual(@as(f64, 3.14), doc.root.getFloat("ratio").?);
}

test "TomlDocument - parse sections" {
    const input =
        \\default_provider = "openai"
        \\
        \\[api_keys]
        \\openai = "sk-test"
        \\anthropic = "sk-ant-test"
        \\
        \\[performance]
        \\timeout = 30
        \\keep_alive = true
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expectEqualStrings("openai", doc.root.getString("default_provider").?);

    const api_keys = doc.getSection("api_keys").?;
    try testing.expectEqualStrings("sk-test", api_keys.getString("openai").?);
    try testing.expectEqualStrings("sk-ant-test", api_keys.getString("anthropic").?);

    const perf = doc.getSection("performance").?;
    try testing.expectEqual(@as(i64, 30), perf.getInt("timeout").?);
    try testing.expectEqual(true, perf.getBool("keep_alive").?);
}

test "TomlDocument - parse array of tables" {
    const input =
        \\[[mcp_servers]]
        \\name = "filesystem"
        \\transport = "stdio"
        \\
        \\[[mcp_servers]]
        \\name = "github"
        \\transport = "sse"
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    const servers = doc.getArrayTable("mcp_servers").?;
    try testing.expectEqual(@as(usize, 2), servers.len);
    try testing.expectEqualStrings("filesystem", servers[0].getString("name").?);
    try testing.expectEqualStrings("stdio", servers[0].getString("transport").?);
    try testing.expectEqualStrings("github", servers[1].getString("name").?);
}

test "TomlDocument - parse inline arrays" {
    const input =
        \\tags = ["ai", "cli", "zig"]
        \\ports = [8080, 443, 3000]
        \\flags = [true, false, true]
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    const tags = doc.root.get("tags").?;
    try testing.expect(tags == .array);
    try testing.expectEqual(@as(usize, 3), tags.array.len);
    try testing.expectEqualStrings("ai", tags.array[0].string);
    try testing.expectEqualStrings("cli", tags.array[1].string);

    const ports = doc.root.get("ports").?;
    try testing.expectEqual(@as(i64, 8080), ports.array[0].integer);
    try testing.expectEqual(@as(i64, 443), ports.array[1].integer);
    try testing.expectEqual(@as(i64, 3000), ports.array[2].integer);

    const flags = doc.root.get("flags").?;
    try testing.expectEqual(true, flags.array[0].boolean);
    try testing.expectEqual(false, flags.array[1].boolean);
}

test "TomlDocument - comments and blank lines ignored" {
    const input =
        \\# This is a comment
        \\
        \\name = "test"
        \\  # indented comment
        \\# value = "commented out"
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expectEqualStrings("test", doc.root.getString("name").?);
    try testing.expect(doc.root.get("value") == null);
}

test "TomlDocument - single-quoted strings" {
    const input =
        \\name = 'single-quoted'
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expectEqualStrings("single-quoted", doc.root.getString("name").?);
}

test "TomlDocument - bare unquoted values treated as strings" {
    const input =
        \\provider = openai
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expectEqualStrings("openai", doc.root.getString("provider").?);
}

test "TomlDocument - negative integers" {
    const input =
        \\offset = -42
        \\zero = 0
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    try testing.expectEqual(@as(i64, -42), doc.root.getInt("offset").?);
    try testing.expectEqual(@as(i64, 0), doc.root.getInt("zero").?);
}

test "TomlDocument - full config.toml structure" {
    const input =
        \\# Crushcode Configuration
        \\default_provider = "openrouter"
        \\default_model = "gpt-4o"
        \\
        \\[api_keys]
        \\openai = "sk-test-key"
        \\anthropic = "sk-ant-key"
        \\ollama = ""
        \\
        \\[quantization]
        \\enabled = false
        \\key_bits = 3
        \\head_dim = 128
        \\
        \\[[mcp_servers]]
        \\name = "filesystem"
        \\transport = "stdio"
        \\command = "npx"
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    // Root
    try testing.expectEqualStrings("openrouter", doc.root.getString("default_provider").?);
    try testing.expectEqualStrings("gpt-4o", doc.root.getString("default_model").?);

    // Section
    const api_keys = doc.getSection("api_keys").?;
    try testing.expectEqualStrings("sk-test-key", api_keys.getString("openai").?);
    try testing.expectEqualStrings("sk-ant-key", api_keys.getString("anthropic").?);
    try testing.expectEqualStrings("", api_keys.getString("ollama").?);

    // Section with ints/bools
    const quant = doc.getSection("quantization").?;
    try testing.expectEqual(false, quant.getBool("enabled").?);
    try testing.expectEqual(@as(i64, 3), quant.getInt("key_bits").?);
    try testing.expectEqual(@as(i64, 128), quant.getInt("head_dim").?);

    // Array of tables
    const servers = doc.getArrayTable("mcp_servers").?;
    try testing.expectEqual(@as(usize, 1), servers.len);
    try testing.expectEqualStrings("filesystem", servers[0].getString("name").?);
}

test "TomlDocument - serialize round-trip" {
    const input =
        \\name = "test"
        \\count = 10
        \\
        \\[section]
        \\enabled = true
    ;

    var doc = try TomlDocument.parse(testing.allocator, input);
    defer doc.deinit();

    const output = try TomlDocument.serialize(&doc, testing.allocator);
    defer testing.allocator.free(output);

    // Parse again and verify
    var doc2 = try TomlDocument.parse(testing.allocator, output);
    defer doc2.deinit();

    try testing.expectEqualStrings("test", doc2.root.getString("name").?);
    try testing.expectEqual(@as(i64, 10), doc2.root.getInt("count").?);

    const sec = doc2.getSection("section").?;
    try testing.expectEqual(true, sec.getBool("enabled").?);
}

test "TomlDocument - empty input" {
    var doc = try TomlDocument.parse(testing.allocator, "");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.root.count());
}
