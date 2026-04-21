/// VSCode theme support for syntax highlighting
/// Provides theme definitions and color mappings for vaxis
const std = @import("std");
const vaxis = @import("vaxis");

/// VSCode theme token color
pub const TokenColor = struct {
    name: []const u8,
    scope: []const []const u8,
    settings: TokenSettings,
};

/// VSCode token settings
pub const TokenSettings = struct {
    foreground: ?[]const u8 = null,
    background: ?[]const u8 = null,
    fontStyle: ?[]const u8 = null,
    
    pub fn toVaxisColor(self: TokenSettings, default_fg: vaxis.Color) vaxis.Color {
        if (self.foreground) |fg| {
            if (std.mem.startsWith(u8, fg, "#")) {
                // Parse hex color
                const hex = fg[1..];
                if (hex.len == 6) {
                    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return default_fg;
                    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return default_fg;
                    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return default_fg;
                    return .{ .rgb = .{ r, g, b } };
                }
            }
        }
        return default_fg;
    }
};

/// Complete VSCode theme
pub const Theme = struct {
    name: []const u8,
    type: []const u8, // "dark" or "light"
    colors: std.StringHashMap([]const u8),
    tokenColors: []TokenColor,
    
    pub fn init(allocator: std.mem.Allocator, name: []const u8, theme_type: []const u8) Theme {
        return Theme{
            .name = name,
            .type = theme_type,
            .colors = std.StringHashMap([]const u8).init(allocator),
            .tokenColors = &[_]TokenColor{},
        };
    }
    
    pub fn deinit(self: *Theme) void {
        self.colors.deinit();
        // tokenColors are typically static, so we don't free them
    }
    
    /// Get color by name
    pub fn getColor(self: *Theme, name: []const u8) ?[]const u8 {
        return self.colors.get(name);
    }
    
    /// Get token color for a specific scope
    pub fn getTokenColor(self: *Theme, scope: []const u8) ?TokenColor {
        for (self.tokenColors) |token_color| {
            for (token_color.scope) |s| {
                if (std.mem.eql(u8, s, scope)) {
                    return token_color;
                }
            }
        }
        return null;
    }
    
    /// Convert theme to vaxis colors
    pub fn toVaxisColors(self: *Theme) VaxisColors {
        var colors = VaxisColors{};
        
        // Default colors
        colors.background = self.hexToVaxisColor(self.colors.get("editor.background") orelse "#1e1e1e");
        colors.foreground = self.hexToVaxisColor(self.colors.get("editor.foreground") orelse "#d4d4d4");
        
        // Syntax colors
        colors.keyword = self.hexToVaxisColor(self.colors.get("keyword") orelse "#569cd6");
        colors.string = self.hexToVaxisColor(self.colors.get("string") orelse "#ce9178");
        colors.comment = self.hexToVaxisColor(self.colors.get("comment") orelse "#6a9955");
        colors.number = self.hexToVaxisColor(self.colors.get("number") orelse "#b5cea8");
        colors.function = self.hexToVaxisColor(self.colors.get("function") orelse "#dcdcaa");
        colors.variable = self.hexToVaxisColor(self.colors.get("variable") orelse "#9cdcfe");
        colors.type = self.hexToVaxisColor(self.colors.get("type") orelse "#4ec9b0");
        colors.operator = self.hexToVaxisColor(self.colors.get("operator") orelse "#d4d4d4");
        colors.punctuation = self.hexToVaxisColor(self.colors.get("punctuation") orelse "#d4d4d4");
        colors.property = self.hexToVaxisColor(self.colors.get("property") orelse "#9cdcfe");
        
        return colors;
    }
    
    /// Convert hex color string to vaxis.Color
    fn hexToVaxisColor(self: *Theme, hex_str: []const u8) vaxis.Color {
        if (hex_str.len == 0) return .default;
        if (hex_str[0] == '#') {
            const hex = hex_str[1..];
            if (hex.len == 6) {
                const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return .default;
                const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return .default;
                const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return .default;
                return .{ .rgb = .{ r, g, b } };
            } else if (hex.len == 3) {
                // Shorthand hex (#rgb)
                const r = std.fmt.parseInt(u8, hex[0..1], 16) catch return .default;
                const g = std.fmt.parseInt(u8, hex[1..2], 16) catch return .default;
                const b = std.fmt.parseInt(u8, hex[2..3], 16) catch return .default;
                return .{ .rgb = .{ 
                    r, g, b 
                } };
            }
        }
        return .default;
    }
};

/// Vaxis color scheme derived from theme
pub const VaxisColors = struct {
    background: vaxis.Color = .{ .index = 236 },
    foreground: vaxis.Color = .{ .index = 252 },
    keyword: vaxis.Color = .{ .index = 13 },
    string: vaxis.Color = .{ .index = 10 },
    comment: vaxis.Color = .{ .index = 243 },
    number: vaxis.Color = .{ .index = 11 },
    function: vaxis.Color = .{ .index = 14 },
    variable: vaxis.Color = .{ .index = 12 },
    type: vaxis.Color = .{ .index = 6 },
    operator: vaxis.Color = .{ .index = 7 },
    punctuation: vaxis.Color = .{ .index = 8 },
    property: vaxis.Color = .{ .index = 9 },
    
    /// Convert token type to vaxis color
    pub fn tokenToColor(self: *const VaxisColors, token_type: []const u8) vaxis.Color {
        if (std.mem.eql(u8, token_type, "keyword")) return self.keyword;
        if (std.mem.eql(u8, token_type, "string")) return self.string;
        if (std.mem.eql(u8, token_type, "comment")) return self.comment;
        if (std.mem.eql(u8, token_type, "number")) return self.number;
        if (std.mem.eql(u8, token_type, "function")) return self.function;
        if (std.mem.eql(u8, token_type, "variable")) return self.variable;
        if (std.mem.eql(u8, token_type, "type")) return self.type;
        if (std.mem.eql(u8, token_type, "operator")) return self.operator;
        if (std.mem.eql(u8, token_type, "punctuation")) return self.punctuation;
        if (std.mem.eql(u8, token_type, "property")) return self.property;
        return self.foreground;
    }
};

// Built-in themes

/// Dark One Pro theme (VSCode default dark)
pub fn darkOnePro(allocator: std.mem.Allocator) Theme {
    var theme = Theme.init(allocator, "Dark One Pro", "dark");
    
    // Add basic colors
    theme.colors.put("editor.background", "#1e1e1e") catch {};
    theme.colors.put("editor.foreground", "#d4d4d4") catch {};
    theme.colors.put("activityBarBadge.background", "#007acc") catch {};
    theme.colors.put("sideBarTitle.foreground", "#cccccc") catch {};
    
    // Add syntax colors
    theme.colors.put("keyword", "#569cd6") catch {};
    theme.colors.put("string", "#ce9178") catch {};
    theme.colors.put("comment", "#6a9955") catch {};
    theme.colors.put("number", "#b5cea8") catch {};
    theme.colors.put("function", "#dcdcaa") catch {};
    theme.colors.put("variable", "#9cdcfe") catch {};
    theme.colors.put("type", "#4ec9b0") catch {};
    theme.colors.put("operator", "#d4d4d4") catch {};
    theme.colors.put("punctuation", "#d4d4d4") catch {};
    theme.colors.put("property", "#9cdcfe") catch {};
    
    return theme;
}

/// Light theme
pub fn lightTheme(allocator: std.mem.Allocator) Theme {
    var theme = Theme.init(allocator, "Light", "light");
    
    theme.colors.put("editor.background", "#ffffff") catch {};
    theme.colors.put("editor.foreground", "#000000") catch {};
    
    theme.colors.put("keyword", "#0000ff") catch {};
    theme.colors.put("string", "#a31515") catch {};
    theme.colors.put("comment", "#008000") catch {};
    theme.colors.put("number", "#098658") catch {};
    theme.colors.put("function", "#795e26") catch {};
    theme.colors.put("variable", "#001080") catch {};
    theme.colors.put("type", "#267f99") catch {};
    theme.colors.put("operator", "#000000") catch {};
    theme.colors.put("punctuation", "#000000") catch {};
    theme.colors.put("property", "#001080") catch {};
    
    return theme;
}

/// GitHub Dark theme
pub fn githubDark(allocator: std.mem.Allocator) Theme {
    var theme = Theme.init(allocator, "GitHub Dark", "dark");
    
    theme.colors.put("editor.background", "#0d1117") catch {};
    theme.colors.put("editor.foreground", "#c9d1d9") catch {};
    
    theme.colors.put("keyword", "#ff7b72") catch {};
    theme.colors.put("string", "#a5d6ff") catch {};
    theme.colors.put("comment", "#8b949e") catch {};
    theme.colors.put("number", "#79c0ff") catch {};
    theme.colors.put("function", "#d2a8ff") catch {};
    theme.colors.put("variable", "#ffa657") catch {};
    theme.colors.put("type", "#7ee787") catch {};
    theme.colors.put("operator", "#c9d1d9") catch {};
    theme.colors.put("punctuation", "#c9d1d9") catch {};
    theme.colors.put("property", "#ffa657") catch {};
    
    return theme;
}

/// Get default theme
pub fn defaultTheme(allocator: std.mem.Allocator) Theme {
    return darkOnePro(allocator);
}

/// Load theme from VSCode theme JSON file
pub fn loadThemeFromFile(allocator: std.mem.Allocator, file_path: []const u8) !Theme {
    const content = std.fs.cwd().readFileAlloc(allocator, file_path, 1024 * 1024) catch {
        return error.ThemeFileNotFound;
    };
    defer allocator.free(content);
    
    // Parse JSON theme
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return error.InvalidThemeFormat;
    };
    defer parsed.deinit();
    
    const theme_obj = parsed.value.object;
    
    const name = theme_obj.get("name").?.string;
    const theme_type = theme_obj.get("type").?.string;
    
    var theme = Theme.init(allocator, name, theme_type);
    
    // Load colors
    if (theme_obj.get("colors")) |colors_obj| {
        var color_it = colors_obj.object.iterator();
        while (color_it.next()) |entry| {
            const color_name = entry.key_ptr.*;
            const color_value = entry.value_ptr.*;
            theme.colors.put(color_name, color_value.string) catch {};
        }
    }
    
    // Load token colors (simplified for now)
    if (theme_obj.get("tokenColors")) |token_colors_obj| {
        // In a real implementation, we would parse the tokenColors array
        // For now, we'll skip this complexity
    }
    
    return theme;
}

/// Get theme by name
pub fn getTheme(allocator: std.mem.Allocator, name: []const u8) !Theme {
    if (std.mem.eql(u8, name, "dark")) {
        return darkOnePro(allocator);
    }
    if (std.mem.eql(u8, name, "light")) {
        return lightTheme(allocator);
    }
    if (std.mem.eql(u8, name, "github-dark")) {
        return githubDark(allocator);
    }
    
    return error.ThemeNotFound;
}

test "Theme - basic functionality" {
    const allocator = std.testing.allocator;
    var theme = darkOnePro(allocator);
    defer theme.deinit();
    
    try std.testing.expectEqualStrings("Dark One Pro", theme.name);
    try std.testing.expectEqualStrings("dark", theme.type);
    
    const bg_color = theme.getColor("editor.background");
    try std.testing.expect(bg_color != null);
    try std.testing.expectEqualStrings("#1e1e1e", bg_color.?);
    
    const vaxis_colors = theme.toVaxisColors();
    try std.testing.expect(vaxis_colors.background != .default);
    try std.testing.expect(vaxis_colors.foreground != .default);
}

test "Theme - token to color mapping" {
    const vaxis_colors = VaxisColors{};
    
    const keyword_color = vaxis_colors.tokenToColor("keyword");
    const string_color = vaxis_colors.tokenToColor("string");
    const comment_color = vaxis_colors.tokenToColor("comment");
    const unknown_color = vaxis_colors.tokenToColor("unknown");
    
    try std.testing.expect(!std.meta.eql(keyword_color, string_color));
    try std.testing.expect(!std.meta.eql(string_color, comment_color));
    try std.testing.expect(std.meta.eql(unknown_color, vaxis_colors.foreground));
}
