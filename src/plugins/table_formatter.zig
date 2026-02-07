const std = @import("std");

const Allocator = std.mem.Allocator;

pub const TableFormatterPlugin = struct {
    allocator: Allocator,
    concealment_mode: bool,
    max_width: usize,

    pub fn init(allocator: Allocator) TableFormatterPlugin {
        return TableFormatterPlugin{
            .allocator = allocator,
            .concealment_mode = true,
            .max_width = 120,
        };
    }

    pub fn formatMarkdownTables(self: *TableFormatterPlugin, text: []const u8) ![]const u8 {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var idx: usize = 0;
        while (idx < text.len) {
            if (self.isTableStart(text[idx..])) {
                const table_start = idx;
                if (self.findTableEnd(text[table_start..])) |end| {
                    const table_slice = text[table_start .. table_start + end];

                    const formatted_table = try self.formatTable(table_slice);
                    try result.appendSlice(formatted_table);

                    idx = table_start + end;
                    continue;
                }
            }

            try result.append(text[idx]);
            idx += 1;
        }

        return result.toOwnedSlice();
    }

    pub fn formatTableAfterAICompletion(self: *TableFormatterPlugin, text: []const u8) ![]const u8 {
        return self.formatMarkdownTables(text);
    }

    fn isTableStart(self: *TableFormatterPlugin, slice: []const u8) bool {
        _ = self;
        return (std.mem.startsWith(slice, "|") or
            std.mem.startsWith(slice, "|---") or
            (self.containsTableRow(slice)));
    }

    fn containsTableRow(self: *TableFormatterPlugin, slice: []const u8) bool {
        _ = self;

        var pipe_count: usize = 0;
        var in_cell = false;

        for (slice) |char| {
            if (char == '|') {
                pipe_count += 1;
                in_cell = false;
            } else if (!std.ascii.isWhitespace(char)) {
                in_cell = true;
            }
        }

        return pipe_count >= 2 and in_cell;
    }

    fn findTableEnd(self: *TableFormatterPlugin, text: []const u8) ?usize {
        _ = self;

        var i: usize = 0;
        var found_table_content = false;
        var consecutive_newlines = 0;

        while (i < text.len) {
            if (text[i] == '\n') {
                if (found_table_content) {
                    consecutive_newlines += 1;
                    if (consecutive_newlines >= 2) {
                        return i;
                    }
                }
            } else if (!std.ascii.isWhitespace(text[i])) {
                found_table_content = true;
                consecutive_newlines = 0;
            }

            i += 1;
        }

        return null;
    }

    fn formatTable(self: *TableFormatterPlugin, table_text: []const u8) ![]const u8 {
        var lines = std.mem.splitScalar(u8, table_text, '\n');
        var rows = std.ArrayList(Table).init(self.allocator);
        defer rows.deinit();

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            if (self.isSeparatorLine(line)) continue;

            if (line[0] == '|') {
                const row = try self.parseTableRow(line);
                try rows.append(row);
            }
        }

        if (rows.items.len == 0) return table_text;

        const col_count = rows.items[0].cells.len;
        var col_widths = try self.allocator.alloc(usize, col_count);
        defer self.allocator.free(col_widths);
        std.mem.set(usize, col_widths, 0);

        for (rows.items) |row| {
            for (row.cells, i) |cell, col| {
                const display_width = if (self.concealment_mode)
                    self.calculateConcealedWidth(cell)
                else
                    self.calculateDisplayWidth(cell);

                col_widths[col] = @max(col_widths[col], display_width);
            }
        }

        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        for (rows.items, 0..) |row, row_idx| {
            try result.append("|");

            for (row.cells, i) |cell, col| {
                const padding = col_widths[col] - if (self.concealment_mode)
                    self.calculateConcealedWidth(cell)
                else
                    self.calculateDisplayWidth(cell);

                try result.append(' ');
                try result.appendSlice(cell);
                try result.append(' ');
                try result.append('|');
            }

            try result.append('\n');

            if (row_idx == 0) {
                try result.append("|");
                for (col_widths, i) |width, col| {
                    try result.append('-');
                    var j: usize = 0;
                    while (j < width + 2) : (j += 1) {
                        try result.append('-');
                    }
                    try result.append('|');
                }
                try result.append('\n');
            }
        }

        return result.toOwnedSlice();
    }

    fn parseTableRow(self: *TableFormatterPlugin, line: []const u8) !Table {
        _ = self;

        var cells = std.ArrayList([]const u8).init(self.allocator);
        defer cells.deinit();

        var i: usize = 1;
        var start = i;
        var in_cell = false;

        while (i < line.len) {
            if (line[i] == '|' and i > 0) {
                if (in_cell) {
                    const cell = std.mem.trim(u8, line[start..i], " \t");
                    try cells.append(cell);
                    in_cell = false;
                }
                start = i + 1;
            } else if (!std.ascii.isWhitespace(line[i])) {
                in_cell = true;
            }
            i += 1;
        }

        if (in_cell and start < line.len) {
            const cell = std.mem.trim(u8, line[start..line.len], " \t");
            try cells.append(cell);
        }

        return Table{
            .cells = cells.toOwnedSlice(),
        };
    }

    fn isSeparatorLine(self: *TableFormatterPlugin, line: []const u8) bool {
        _ = self;

        var i: usize = 0;
        var pipe_count: usize = 0;
        var has_dash = false;

        while (i < line.len) {
            switch (line[i]) {
                '|' => pipe_count += 1,
                '-' => has_dash = true,
                ':' => {},
                ' ' => {},
                else => return false,
            }
            i += 1;
        }

        return pipe_count >= 2 and has_dash;
    }

    fn calculateDisplayWidth(self: *TableFormatterPlugin, text: []const u8) usize {
        _ = self;

        var width: usize = 0;
        var i: usize = 0;

        while (i < text.len) {
            if (text[i] == '\x1b') {
                var j = i + 1;
                while (j < text.len and text[j] != 'm') {
                    j += 1;
                }
                if (j < text.len) j += 1;
                i = j;
            } else if (text[i] >= 0x80) {
                width += 2;
                i += 1;
            } else {
                width += 1;
                i += 1;
            }
        }

        return width;
    }

    fn calculateConcealedWidth(self: *TableFormatterPlugin, text: []const u8) usize {
        _ = self;

        var width: usize = 0;
        var i: usize = 0;
        var in_code = false;
        var in_bold = false;
        var in_italic = false;

        while (i < text.len) {
            switch (text[i]) {
                '`' => {
                    in_code = !in_code;
                    if (in_code) i += 1;
                },
                '*' => {
                    if (i + 1 < text.len and text[i + 1] == '*') {
                        in_bold = !in_bold;
                        i += 2;
                    } else {
                        in_italic = !in_italic;
                        i += 1;
                    }
                },
                '_' => {
                    in_italic = !in_italic;
                    i += 1;
                },
                else => {
                    if (!in_code and !in_bold and !in_italic) {
                        width += if (text[i] >= 0x80) 2 else 1;
                    }
                    i += 1;
                },
            }
        }

        return width;
    }
};

const Table = struct {
    cells: [][]const u8,
};
