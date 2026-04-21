/// Vaxis renderer for syntax highlighted code
/// Converts highlighted code segments to vaxis Text objects for terminal display
const std = @import("std");
const vaxis = @import("vaxis");
const highlighter = @import("highlighter.zig");
const themes = @import("themes.zig");

pub const VaxisRenderer = struct {
    allocator: std.mem.Allocator,
    theme: *const themes.Theme,
    
    /// Rendering options
    pub const Options = struct {
        line_numbers: bool = true,
        wrap_text: bool = true,
        max_width: usize = 80,
        tab_width: usize = 4,
        show_whitespace: bool = false,
        highlight_current_line: bool = false,
        current_line: usize = 0,
    };
    
    /// Render context for code blocks
    pub const RenderContext = struct {
        line_number: usize = 0,
        char_offset: usize = 0,
        current_style: vaxis.Style = .{},
        is_first_line: bool = true,
    };
    
    pub fn init(allocator: std.mem.Allocator, theme: *const themes.Theme) VaxisRenderer {
        return VaxisRenderer{
            .allocator = allocator,
            .theme = theme,
        };
    }
    
    /// Render highlighted code to vaxis Text objects
    pub fn renderCode(self: *VaxisRenderer, highlighted_code: *const highlighter.HighlightedCode, options: Options) ![]vaxis.Text {
        const vaxis_colors = self.theme.toVaxisColors();
        
        var lines = std.ArrayList(vaxis.Text).init(self.allocator);
        errdefer {
            for (lines.items) |*text| {
                text.deinit();
            }
            lines.deinit();
        }
        
        var current_line = std.ArrayList(vaxis.Segment).init(self.allocator);
        defer current_line.deinit();
        
        var context = RenderContext{};
        
        // Process highlighted segments
        for (highlighted_code.segments) |segment| {
            try self.renderSegment(segment, &vaxis_colors, &current_line, &lines, &context, options);
        }
        
        // Add the last line if it has content
        if (current_line.items.len > 0) {
            const line_text = vaxis.Text.init(self.allocator, current_line.items);
            try lines.append(line_text);
        }
        
        return lines.toOwnedSlice();
    }
    
    /// Render a single highlighted segment
    fn renderSegment(self: *VaxisRenderer, segment: highlighter.HighlightedSegment, colors: *const themes.VaxisColors, current_line: *std.ArrayList(vaxis.Segment), lines: *std.ArrayList(vaxis.Text), context: *RenderContext, options: Options) !void {
        var lines_iter = std.mem.splitSequence(u8, segment.text, "\n");
        var first_part = true;
        
        while (lines_iter.next()) |line_part| {
            if (!first_part) {
                // End of line - create line text
                if (current_line.items.len > 0) {
                    const line_text = vaxis.Text.init(self.allocator, current_line.items);
                    try lines.append(line_text);
                    current_line.clearRetainingCapacity();
                }
                
                // Add line number if enabled
                if (options.line_numbers) {
                    const line_num_text = try self.formatLineNumber(context.line_number, options);
                    try current_line.appendSlice(line_num_text);
                }
                
                context.line_number += 1;
                context.char_offset = 0;
                context.is_first_line = false;
            }
            
            if (line_part.len > 0) {
                try self.renderLinePart(line_part, segment, colors, current_line, context, options);
            }
            
            first_part = false;
        }
    }
    
    /// Render a part of a line (without newlines)
    fn renderLinePart(self: *VaxisRenderer, text: []const u8, segment: highlighter.HighlightedSegment, colors: *const themes.VaxisColors, current_line: *std.ArrayList(vaxis.Segment), context: *RenderContext, options: Options) !void {
        var words_iter = std.mem.splitScalar(u8, text, ' ');
        var first_word = true;
        
        while (words_iter.next()) |word| {
            if (!first_word) {
                try current_line.append(.{
                    .text = " ",
                    .style = context.current_style,
                });
                context.char_offset += 1;
            }
            
            if (word.len > 0) {
                try self.renderWord(word, segment, colors, current_line, context, options);
            }
            
            first_word = false;
        }
    }
    
    /// Render a single word with appropriate styling
    fn renderWord(self: *VaxisRenderer, word: []const u8, segment: highlighter.HighlightedSegment, colors: *const themes.VaxisColors, current_line: *std.ArrayList(vaxis.Segment), context: *RenderContext, options: Options) !void {
        const style = self.createStyle(segment, colors, context, options);
        
        // Handle tabs
        if (std.mem.indexOfScalar(u8, word, '\t')) |_| {
            try self.renderWithTabs(word, style, current_line, context, options);
        } else {
            try current_line.append(.{
                .text = word,
                .style = style,
            });
            context.char_offset += word.len;
        }
    }
    
    /// Render text with tab expansion
    fn renderWithTabs(self: *VaxisRenderer, text: []const u8, style: vaxis.Style, current_line: *std.ArrayList(vaxis.Segment), context: *RenderContext, options: Options) !void {
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\t') {
                const spaces = options.tab_width - (context.char_offset % options.tab_width);
                var j: usize = 0;
                while (j < spaces) : (j += 1) {
                    if (options.show_whitespace) {
                        try current_line.append(.{
                            .text = "·",
                            .style = style,
                        });
                    } else {
                        try current_line.append(.{
                            .text = " ",
                            .style = style,
                        });
                    }
                }
                context.char_offset += spaces;
                i += 1;
            } else {
                const start = i;
                while (i < text.len and text[i] != '\t') : (i += 1) {}
                const part = text[start..i];
                
                try current_line.append(.{
                    .text = part,
                    .style = style,
                });
                context.char_offset += part.len;
            }
        }
    }
    
    /// Create vaxis Style from segment and colors
    fn createStyle(self: *VaxisRenderer, segment: highlighter.HighlightedSegment, colors: *const themes.VaxisColors, context: *RenderContext, options: Options) vaxis.Style {
        var style = vaxis.Style{};
        
        // Set text color based on token type
        const color = colors.tokenToColor(@typeName(segment.token_type));
        style.foreground = color;
        
        // Apply background for current line highlighting
        if (options.highlight_current_line and context.line_number == options.current_line) {
            style.background = .{ .index = 237 }; // Slightly darker background
        }
        
        // Apply bold for certain token types
        if (segment.token_type == .keyword or 
            segment.token_type == .function or 
            segment.token_type == .type) {
            style.bold = true;
        }
        
        // Apply italic for comments
        if (segment.token_type == .comment) {
            style.italic = true;
        }
        
        // Apply underline for errors
        if (segment.token_type == .error) {
            style.underline = .single;
        }
        
        return style;
    }
    
    /// Format line number with proper styling
    fn formatLineNumber(self: *VaxisRenderer, line_num: usize, options: Options) ![]vaxis.Segment {
        const segments = try self.allocator.alloc(vaxis.Segment, 2);
        
        // Line number
        const line_num_str = try std.fmt.allocPrint(self.allocator, "{d:>4}", .{line_num + 1});
        segments[0] = .{
            .text = line_num_str,
            .style = .{
                .foreground = .{ .index = 243 }, // Gray
                .bold = true,
            },
        };
        
        // Separator
        segments[1] = .{
            .text = " │ ",
            .style = .{
                .foreground = .{ .index = 240 }, // Dark gray
            },
        };
        
        return segments;
    }
    
    /// Render code from file with auto-detected language
    pub fn renderFile(self: *VaxisRenderer, file_path: []const u8, code: []const u8, options: Options) ![]vaxis.Text {
        const theme = self.theme;
        var highlighter_instance = try highlighter.SyntaxHighlighter.init(self.allocator);
        defer highlighter_instance.deinit();
        
        const highlighted_code = try highlighter_instance.highlightFile(file_path, code, theme);
        defer highlighted_code.deinit(self.allocator);
        
        return self.renderCode(&highlighted_code, options);
    }
    
    /// Render a simple code snippet without syntax highlighting
    pub fn renderPlainText(self: *VaxisRenderer, text: []const u8, options: Options) ![]vaxis.Text {
        var lines = std.ArrayList(vaxis.Text).init(self.allocator);
        errdefer {
            for (lines.items) |*text_line| {
                text_line.deinit();
            }
            lines.deinit();
        }
        
        var lines_iter = std.mem.splitSequence(u8, text, "\n");
        var line_num: usize = 0;
        
        while (lines_iter.next()) |line| {
            var segments = std.ArrayList(vaxis.Segment).init(self.allocator);
            defer segments.deinit();
            
            // Add line number if enabled
            if (options.line_numbers) {
                const line_num_text = try self.formatLineNumber(line_num, options);
                try segments.appendSlice(line_num_text);
                self.allocator.free(line_num_text);
            }
            
            // Add text content
            try segments.append(.{
                .text = line,
                .style = .{
                    .foreground = .{ .index = 252 }, // Default text color
                },
            });
            
            const line_text = vaxis.Text.init(self.allocator, segments.items);
            try lines.append(line_text);
            line_num += 1;
        }
        
        return lines.toOwnedSlice();
    }
    
    /// Clean up rendered text
    pub fn freeRenderedText(self: *VaxisRenderer, text_lines: []vaxis.Text) void {
        for (text_lines) |*text_line| {
            text_line.deinit();
        }
        self.allocator.free(text_lines);
    }
};

test "VaxisRenderer - basic functionality" {
    const allocator = std.testing.allocator;
    var theme = themes.darkOnePro(allocator);
    defer theme.deinit();
    
    var renderer = VaxisRenderer.init(allocator, &theme);
    
    // Test with plain text
    const options = VaxisRenderer.Options{
        .line_numbers = false,
        .max_width = 40,
    };
    
    const text_lines = try renderer.renderPlainText("Hello\nWorld", options);
    defer renderer.freeRenderedText(text_lines);
    
    try std.testing.expectEqual(@as(usize, 2), text_lines.len);
    try std.testing.expectEqualStrings("Hello", text_lines[0].toString());
    try std.testing.expectEqualStrings("World", text_lines[1].toString());
}

test "VaxisRenderer - line numbers" {
    const allocator = std.testing.allocator;
    var theme = themes.darkOnePro(allocator);
    defer theme.deinit();
    
    var renderer = VaxisRenderer.init(allocator, &theme);
    
    const options = VaxisRenderer.Options{
        .line_numbers = true,
        .max_width = 40,
    };
    
    const text_lines = try renderer.renderPlainText("Line 1\nLine 2\nLine 3", options);
    defer renderer.freeRenderedText(text_lines);
    
    try std.testing.expectEqual(@as(usize, 3), text_lines.len);
    
    // Check that line numbers are present
    const line1_text = text_lines[0].toString();
    try std.testing.expect(std.mem.indexOf(u8, line1_text, "1") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1_text, "│") != null);
}
