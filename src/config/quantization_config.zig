const std = @import("std");
const Allocator = std.mem.Allocator;

/// TurboQuant KV cache compression configuration
/// Based on turboquant architecture with rotation + quantization
pub const QuantizationConfig = struct {
    allocator: Allocator,

    /// Enable KV cache compression
    enabled: bool = false,

    /// Bits per coordinate for keys (2, 3, or 4 bits)
    key_bits: u8 = 3,

    /// Bits per coordinate for values (2 or 4 bits)
    value_bits: u8 = 2,

    /// Head dimension (d) for rotation matrix
    head_dim: usize = 128,

    /// Group size for value quantization (e.g., 32, 64)
    group_size: usize = 32,

    /// QJL projection enabled for residual correction
    qjl_enabled: bool = true,

    /// Seed for random rotation matrix generation
    rotation_seed: u64 = 42,

    /// Validate orthogonality during initialization
    validate_rotation: bool = true,

    /// Use optimal codebook (Lloyd-Max) vs uniform quantization
    use_optimal_codebook: bool = true,

    pub fn init(allocator: Allocator) QuantizationConfig {
        return QuantizationConfig{
            .allocator = allocator,
            .enabled = false,
            .key_bits = 3,
            .value_bits = 2,
            .head_dim = 128,
            .group_size = 32,
            .qjl_enabled = true,
            .rotation_seed = 42,
            .validate_rotation = true,
            .use_optimal_codebook = true,
        };
    }

    pub fn deinit(_: *QuantizationConfig) void {
        // No dynamic allocations to free
    }

    /// Load quantization config from TOML
    pub fn loadFromToml(self: *QuantizationConfig, content: []const u8) !void {
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Check if we're in [quantization] section
            if (std.mem.eql(u8, trimmed, "[quantization]")) {
                continue;
            }

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"");

                try self.parseKeyValue(key, value);
            }
        }
    }

    fn parseKeyValue(self: *QuantizationConfig, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "enabled")) {
            self.enabled = std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "key_bits")) {
            self.key_bits = try std.fmt.parseInt(u8, value, 10);
            // Validate bits
            if (!(self.key_bits == 2 or self.key_bits == 3 or self.key_bits == 4)) {
                return error.InvalidKeyBits;
            }
        } else if (std.mem.eql(u8, key, "value_bits")) {
            self.value_bits = try std.fmt.parseInt(u8, value, 10);
            // Validate bits
            if (!(self.value_bits == 2 or self.value_bits == 4)) {
                return error.InvalidValueBits;
            }
        } else if (std.mem.eql(u8, key, "head_dim")) {
            self.head_dim = try std.fmt.parseInt(usize, value, 10);
            // Common head dimensions: 64, 128, 256
            if (self.head_dim < 64 or self.head_dim > 512) {
                return error.InvalidHeadDim;
            }
        } else if (std.mem.eql(u8, key, "group_size")) {
            self.group_size = try std.fmt.parseInt(usize, value, 10);
            // Group size should be power of 2 for bit-packing
            if (self.group_size < 8 or self.group_size > 128) {
                return error.InvalidGroupSize;
            }
        } else if (std.mem.eql(u8, key, "qjl_enabled")) {
            self.qjl_enabled = std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "rotation_seed")) {
            self.rotation_seed = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, key, "validate_rotation")) {
            self.validate_rotation = std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "1");
        } else if (std.mem.eql(u8, key, "use_optimal_codebook")) {
            self.use_optimal_codebook = std.mem.eql(u8, value, "true") or
                std.mem.eql(u8, value, "1");
        }
    }

    /// Get compression ratio estimate
    pub fn getCompressionRatio(self: *const QuantizationConfig) f32 {
        if (!self.enabled) return 1.0;

        const original_bits = 32; // Original f32 bits
        const key_bits_used = if (self.key_bits == 3) @as(f32, 3.0) else @as(f32, @floatFromInt(self.key_bits));
        const value_bits_used = @as(f32, @floatFromInt(self.value_bits));

        // Average bits per coordinate (keys + values)
        const avg_bits_per_coord = (key_bits_used + value_bits_used) / 2;

        // Compression ratio: original bits / compressed bits
        const ratio = original_bits / avg_bits_per_coord;

        // Add overhead for rotation matrices (1/d effect)
        const overhead_factor = 1.0 + (1.0 / @as(f32, @floatFromInt(self.head_dim)));

        return ratio / overhead_factor;
    }

    /// Get memory savings percentage
    pub fn getMemorySavings(self: *const QuantizationConfig) f32 {
        const ratio = self.getCompressionRatio();
        return 1.0 - (1.0 / ratio);
    }

    /// Validate configuration
    pub fn validate(self: *const QuantizationConfig) !void {
        if (self.key_bits != 2 and self.key_bits != 3 and self.key_bits != 4) {
            return error.InvalidKeyBits;
        }
        if (self.value_bits != 2 and self.value_bits != 4) {
            return error.InvalidValueBits;
        }
        if (self.head_dim < 64 or self.head_dim > 512) {
            return error.InvalidHeadDim;
        }
        if (self.group_size < 8 or self.group_size > 128) {
            return error.InvalidGroupSize;
        }
        // Group size should be multiple of 8 for byte alignment
        if (self.group_size % 8 != 0) {
            return error.GroupSizeNotByteAligned;
        }
    }

    /// Create default config string for TOML
    pub fn defaultToml(_: *const QuantizationConfig) []const u8 {
        return 
        \\[quantization]
        \\# Enable TurboQuant KV cache compression
        \\enabled = false
        \\
        \\# Bits per coordinate for keys (2, 3, or 4 bits)
        \\# 3-bit keys provide near-lossless compression per paper
        \\key_bits = 3
        \\
        \\# Bits per coordinate for values (2 or 4 bits)
        \\# 2-bit values for max compression, 4-bit for quality
        \\value_bits = 2
        \\
        \\# Head dimension (d) for rotation matrix
        \\# Common values: 64, 128, 256
        \\head_dim = 128
        \\
        \\# Group size for value quantization
        \\# Must be multiple of 8 for byte alignment
        \\group_size = 32
        \\
        \\# Enable QJL projection for residual correction
        \\qjl_enabled = true
        \\
        \\# Seed for deterministic rotation matrices
        \\rotation_seed = 42
        \\
        \\# Validate rotation matrix orthogonality at startup
        \\validate_rotation = true
        \\
        \\# Use optimal Lloyd-Max codebook vs uniform quantization
        \\use_optimal_codebook = true
        ;
    }

    /// Print configuration summary
    pub fn printSummary(self: *const QuantizationConfig) void {
        std.debug.print("TurboQuant Configuration:\n", .{});
        std.debug.print("  Enabled: {}\n", .{self.enabled});
        if (self.enabled) {
            std.debug.print("  Key bits: {}\n", .{self.key_bits});
            std.debug.print("  Value bits: {}\n", .{self.value_bits});
            std.debug.print("  Head dimension: {}\n", .{self.head_dim});
            std.debug.print("  Group size: {}\n", .{self.group_size});
            std.debug.print("  QJL enabled: {}\n", .{self.qjl_enabled});
            std.debug.print("  Estimated compression: {d:.1}x\n", .{self.getCompressionRatio()});
            std.debug.print("  Memory savings: {d:.1}%\n", .{self.getMemorySavings() * 100});
        }
    }
};

/// Error types for quantization configuration
pub const QuantizationError = error{
    InvalidKeyBits,
    InvalidValueBits,
    InvalidHeadDim,
    InvalidGroupSize,
    GroupSizeNotByteAligned,
};
