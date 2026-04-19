const std = @import("std");
const array_list_compat = @import("array_list_compat");

/// Column alignment options.
pub const Alignment = enum { left, center, right };

/// A single column definition.
pub const TableColumn = struct {
    header: []const u8,
    /// Explicit width in characters, or null for auto-sizing.
    width: ?u16 = null,
    col_align: Alignment = .left,
};

/// Structured data table widget for CLI output (plain text, no vaxis dependency).
/// Stores rows as a flat array (row-major order).
pub const DataTable = struct {
    allocator: std.mem.Allocator,
    columns: []TableColumn,
    /// Flat row-major array of cell values. Length = columns.len * row_count.
    rows: array_list_compat.ArrayList([]const u8),
    row_count: u32,

    /// Initialize a DataTable with the given column definitions.
    /// The columns slice is referenced, not copied.
    pub fn init(allocator: std.mem.Allocator, columns: []TableColumn) DataTable {
        return .{
            .allocator = allocator,
            .columns = columns,
            .rows = array_list_compat.ArrayList([]const u8).init(allocator),
            .row_count = 0,
        };
    }

    /// Release all allocated memory (row cell values).
    pub fn deinit(self: *DataTable) void {
        for (self.rows.items) |cell| {
            self.allocator.free(cell);
        }
        self.rows.deinit();
    }

    /// Add a row of values. `values.len` must equal `columns.len`.
    pub fn addRow(self: *DataTable, values: []const []const u8) !void {
        if (values.len != self.columns.len) return error.ColumnCountMismatch;
        for (values) |val| {
            const dup = try self.allocator.dupe(u8, val);
            try self.rows.append(dup);
        }
        self.row_count += 1;
    }

    /// Render the table as a bordered string with +---+ style.
    pub fn render(self: *DataTable) ![]const u8 {
        const widths = try self.calcWidths();
        defer self.allocator.free(widths);

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        // Top border: +---+---+
        try renderBorderRow(&buf, widths);

        // Header row
        try self.renderHeaderDataRow(&buf, self.allocator, self.columns, widths);

        // Separator border
        try renderBorderRow(&buf, widths);

        // Data rows
        var row_idx: u32 = 0;
        while (row_idx < self.row_count) : (row_idx += 1) {
            const row_values = self.rowSlice(row_idx);
            try renderDataRow(&buf, self.allocator, row_values, widths, self.columns);
        }

        // Bottom border
        try renderBorderRow(&buf, widths);

        return buf.toOwnedSlice();
    }

    /// Render the table as plain text (space-separated, no borders).
    pub fn renderPlain(self: *DataTable) ![]const u8 {
        const widths = try self.calcWidths();
        defer self.allocator.free(widths);

        var buf = array_list_compat.ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        // Header row
        try self.renderPlainHeaderRow(&buf, self.allocator, self.columns, widths);

        // Data rows
        var row_idx: u32 = 0;
        while (row_idx < self.row_count) : (row_idx += 1) {
            const row_values = self.rowSlice(row_idx);
            try renderPlainRow(&buf, self.allocator, row_values, widths, self.columns);
        }

        return buf.toOwnedSlice();
    }

    /// Calculate the effective width of each column.
    /// If a column has an explicit width, use that.
    /// Otherwise, use max(header_len, max_value_len) + 1 padding each side.
    fn calcWidths(self: *DataTable) ![]u16 {
        const num_cols = self.columns.len;
        const widths = try self.allocator.alloc(u16, num_cols);

        for (self.columns, 0..) |col, i| {
            if (col.width) |w| {
                widths[i] = w;
            } else {
                var max_len: usize = col.header.len;
                var row_idx: u32 = 0;
                while (row_idx < self.row_count) : (row_idx += 1) {
                    const cell_val = self.rows.items[row_idx * num_cols + i];
                    if (cell_val.len > max_len) max_len = cell_val.len;
                }
                widths[i] = @intCast(@min(max_len + 2, std.math.maxInt(u16)));
            }
        }
        return widths;
    }

    /// Get row cell values for a given row index.
    fn rowSlice(self: *const DataTable, row_idx: u32) []const []const u8 {
        const num_cols = self.columns.len;
        const start = @as(usize, row_idx) * num_cols;
        return self.rows.items[start .. start + num_cols];
    }

    fn renderBorderRow(buf: *array_list_compat.ArrayList(u8), widths: []const u16) !void {
        for (widths, 0..) |w, i| {
            if (i == 0) try buf.append('+');
            var j: u16 = 0;
            while (j < w) : (j += 1) {
                try buf.append('-');
            }
            try buf.append('+');
        }
        try buf.append('\n');
    }

    fn renderDataRow(
        buf: *array_list_compat.ArrayList(u8),
        allocator: std.mem.Allocator,
        values: []const []const u8,
        widths: []const u16,
        columns: []TableColumn,
    ) !void {
        for (values, 0..) |val, i| {
            try buf.append('|');
            const aligned = try alignValue(allocator, val, widths[i], columns[i].col_align);
            defer allocator.free(aligned);
            try buf.appendSlice(aligned);
        }
        try buf.append('|');
        try buf.append('\n');
    }

    fn renderPlainRow(
        buf: *array_list_compat.ArrayList(u8),
        allocator: std.mem.Allocator,
        values: []const []const u8,
        widths: []const u16,
        columns: []TableColumn,
    ) !void {
        for (values, 0..) |val, i| {
            if (i > 0) try buf.append(' ');
            const aligned = try alignValue(allocator, val, widths[i], columns[i].col_align);
            defer allocator.free(aligned);
            try buf.appendSlice(aligned);
        }
        try buf.append('\n');
    }

    /// Align a value within a given width, returning an owned string.
    fn alignValue(allocator: std.mem.Allocator, value: []const u8, width: u16, alignment: Alignment) ![]const u8 {
        const w: usize = @intCast(width);
        const val_len = @min(value.len, w);

        if (val_len >= w) {
            return allocator.dupe(u8, value[0..w]);
        }

        const pad = w - val_len;
        var result = try allocator.alloc(u8, w);

        switch (alignment) {
            .left => {
                @memcpy(result[0..val_len], value[0..val_len]);
                @memset(result[val_len..], ' ');
            },
            .right => {
                @memset(result[0..pad], ' ');
                @memcpy(result[pad..w], value[0..val_len]);
            },
            .center => {
                const left_pad = pad / 2;
                @memset(result[0..left_pad], ' ');
                @memcpy(result[left_pad .. left_pad + val_len], value[0..val_len]);
                @memset(result[left_pad + val_len .. w], ' ');
            },
        }
        return result;
    }

    /// Helper to render header row (uses columns directly since headerSlice returns empty).
    fn renderHeaderDataRow(
        buf: *array_list_compat.ArrayList(u8),
        allocator: std.mem.Allocator,
        columns: []TableColumn,
        widths: []const u16,
    ) !void {
        for (columns, 0..) |col, i| {
            try buf.append('|');
            const aligned = try alignValue(allocator, col.header, widths[i], col.col_align);
            defer allocator.free(aligned);
            try buf.appendSlice(aligned);
        }
        try buf.append('|');
        try buf.append('\n');
    }

    /// Helper to render plain header row.
    fn renderPlainHeaderRow(
        buf: *array_list_compat.ArrayList(u8),
        allocator: std.mem.Allocator,
        columns: []TableColumn,
        widths: []const u16,
    ) !void {
        for (columns, 0..) |col, i| {
            if (i > 0) try buf.append(' ');
            const aligned = try alignValue(allocator, col.header, widths[i], col.col_align);
            defer allocator.free(aligned);
            try buf.appendSlice(aligned);
        }
        try buf.append('\n');
    }
};

// Override render to use proper header handling
/// Full render function that correctly handles headers.
pub fn renderDataTable(table: *DataTable) ![]const u8 {
    const widths = try table.calcWidths();
    defer table.allocator.free(widths);

    var buf = array_list_compat.ArrayList(u8).init(table.allocator);
    defer buf.deinit();

    // Top border
    try renderDataTableBorderRow(&buf, widths);

    // Header row
    try DataTable.renderHeaderDataRow(&buf, table.allocator, table.columns, widths);

    // Separator border
    try renderDataTableBorderRow(&buf, widths);

    // Data rows
    var row_idx: u32 = 0;
    while (row_idx < table.row_count) : (row_idx += 1) {
        const row_values = table.rowSlice(row_idx);
        try DataTable.renderDataRow(&buf, table.allocator, row_values, widths, table.columns);
    }

    // Bottom border
    try renderDataTableBorderRow(&buf, widths);

    return buf.toOwnedSlice();
}

/// Full plain render function that correctly handles headers.
pub fn renderDataTablePlain(table: *DataTable) ![]const u8 {
    const widths = try table.calcWidths();
    defer table.allocator.free(widths);

    var buf = array_list_compat.ArrayList(u8).init(table.allocator);
    defer buf.deinit();

    // Header row
    try DataTable.renderPlainHeaderRow(&buf, table.allocator, table.columns, widths);

    // Data rows
    var row_idx: u32 = 0;
    while (row_idx < table.row_count) : (row_idx += 1) {
        const row_values = table.rowSlice(row_idx);
        try DataTable.renderPlainRow(&buf, table.allocator, row_values, widths, table.columns);
    }

    return buf.toOwnedSlice();
}

fn renderDataTableBorderRow(buf: *array_list_compat.ArrayList(u8), widths: []const u16) !void {
    for (widths, 0..) |w, i| {
        if (i == 0) try buf.append('+');
        var j: u16 = 0;
        while (j < w) : (j += 1) {
            try buf.append('-');
        }
        try buf.append('+');
    }
    try buf.append('\n');
}

// --- Tests ---

test "DataTable - init and deinit" {
    const allocator = std.testing.allocator;
    var columns = [_]TableColumn{
        .{ .header = "Name" },
        .{ .header = "Value" },
    };
    var table = DataTable.init(allocator, &columns);
    defer table.deinit();
    try std.testing.expectEqual(@as(u32, 0), table.row_count);
    try std.testing.expectEqual(@as(usize, 2), table.columns.len);
}

test "DataTable - addRow" {
    const allocator = std.testing.allocator;
    var columns = [_]TableColumn{
        .{ .header = "A" },
        .{ .header = "B" },
    };
    var table = DataTable.init(allocator, &columns);
    defer table.deinit();

    try table.addRow(&.{ "hello", "world" });
    try std.testing.expectEqual(@as(u32, 1), table.row_count);

    try table.addRow(&.{ "foo", "bar" });
    try std.testing.expectEqual(@as(u32, 2), table.row_count);
}

test "DataTable - addRow rejects wrong column count" {
    const allocator = std.testing.allocator;
    var columns = [_]TableColumn{
        .{ .header = "A" },
        .{ .header = "B" },
    };
    var table = DataTable.init(allocator, &columns);
    defer table.deinit();

    const result = table.addRow(&.{"only_one"});
    try std.testing.expectError(error.ColumnCountMismatch, result);
}

test "DataTable - renderPlain output" {
    const allocator = std.testing.allocator;
    var columns = [_]TableColumn{
        .{ .header = "Name" },
        .{ .header = "Type" },
    };
    var table = DataTable.init(allocator, &columns);
    defer table.deinit();

    try table.addRow(&.{ "foo", "bar" });
    try table.addRow(&.{ "baz", "qux" });

    const output = try renderDataTablePlain(&table);
    defer allocator.free(output);

    try std.testing.expect(output.len > 0);
    // Should contain header names and values
    try std.testing.expect(std.mem.indexOf(u8, output, "Name") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Type") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "foo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "baz") != null);
}

test "DataTable - alignment left pads on right" {
    const allocator = std.testing.allocator;
    const aligned = try DataTable.alignValue(allocator, "hi", 6, .left);
    defer allocator.free(aligned);
    try std.testing.expectEqualStrings("hi    ", aligned);
}

test "DataTable - alignment right pads on left" {
    const allocator = std.testing.allocator;
    const aligned = try DataTable.alignValue(allocator, "hi", 6, .right);
    defer allocator.free(aligned);
    try std.testing.expectEqualStrings("    hi", aligned);
}

test "DataTable - alignment center pads both sides" {
    const allocator = std.testing.allocator;
    const aligned = try DataTable.alignValue(allocator, "hi", 6, .center);
    defer allocator.free(aligned);
    try std.testing.expectEqualStrings("  hi  ", aligned);
}

test "DataTable - alignment truncates when value exceeds width" {
    const allocator = std.testing.allocator;
    const aligned = try DataTable.alignValue(allocator, "hello", 3, .left);
    defer allocator.free(aligned);
    try std.testing.expectEqualStrings("hel", aligned);
}

test "DataTable - render bordered output" {
    const allocator = std.testing.allocator;
    var columns = [_]TableColumn{
        .{ .header = "X" },
        .{ .header = "Y" },
    };
    var table = DataTable.init(allocator, &columns);
    defer table.deinit();

    try table.addRow(&.{ "1", "2" });

    const output = try renderDataTable(&table);
    defer allocator.free(output);

    // Should contain border characters
    try std.testing.expect(std.mem.indexOf(u8, output, "+") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "|") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "-") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "X") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1") != null);
}
