const std = @import("std");
const math = std.math;

const Allocator = std.mem.Allocator;

/// Quantized value representation with group scaling
/// Based on turboquant/kv_cache.py value quantization
pub const ValueQuantized = struct {
    /// Bit-packed quantized values
    data: []u8,
    /// Scale per group (f32)
    scales: []f32,
    /// Zero point per group (f32)
    zeros: []f32,
    /// Quantization bits (2 or 4)
    bits: u8,
    /// Number of elements per group
    group_size: usize,
    /// Original dimensions [..., seq_len, d]
    shape: []const usize,

    pub fn deinit(self: *ValueQuantized, allocator: Allocator) void {
        allocator.free(self.data);
        allocator.free(self.scales);
        allocator.free(self.zeros);
        allocator.free(self.shape);
    }
};

/// Value quantizer with group scaling
pub const ValueQuantizer = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) ValueQuantizer {
        return ValueQuantizer{
            .allocator = allocator,
        };
    }

    pub fn deinit(_: *ValueQuantizer) void {}

    /// Quantize value vectors with group scaling
    /// Input: f32 values with shape [..., seq_len, d]
    /// Returns: ValueQuantized structure
    pub fn quantize(self: *ValueQuantizer, values: []const f32, shape: []const usize, bits: u8, group_size: usize) !ValueQuantized {
        // Validate inputs
        if (bits != 2 and bits != 4) {
            return error.UnsupportedBitWidth;
        }

        if (group_size < 8 or group_size > 128) {
            return error.InvalidGroupSize;
        }

        const d = shape[shape.len - 1]; // Last dimension is head_dim
        if (d % group_size != 0) {
            return error.DimensionNotDivisibleByGroupSize;
        }

        const n_groups = d / group_size;
        const total_elements = values.len;
        const seq_len = total_elements / d;

        // Allocate quantized data storage
        const packed_len = try calculatePackedSize(d * seq_len, bits, group_size);
        var data = try self.allocator.alloc(u8, packed_len);
        errdefer self.allocator.free(data);

        var scales = try self.allocator.alloc(f32, seq_len * n_groups);
        errdefer self.allocator.free(scales);

        var zeros = try self.allocator.alloc(f32, seq_len * n_groups);
        errdefer self.allocator.free(zeros);

        var shape_copy = try self.allocator.alloc(usize, shape.len);
        errdefer self.allocator.free(shape_copy);
        @memcpy(shape_copy, shape);

        // Quantize each sequence position
        for (0..seq_len) |seq_idx| {
            const seq_offset = seq_idx * d;
            const group_offset = seq_idx * n_groups;

            for (0..n_groups) |group_idx| {
                const group_start = seq_offset + (group_idx * group_size);
                const group_end = group_start + group_size;

                // Find min and max in group
                var min_val: f32 = std.math.floatMax(f32);
                var max_val: f32 = std.math.floatMin(f32);

                for (group_start..group_end) |i| {
                    const val = values[i];
                    min_val = @min(min_val, val);
                    max_val = @max(max_val, val);
                }

                // Compute scale and zero
                const n_levels = @as(f32, @floatFromInt((1 << @as(u6, bits)) - 1));
                var scale = (max_val - min_val) / n_levels;
                scale = @max(scale, 1e-10); // Avoid division by zero
                const zero = min_val;

                scales[group_offset + group_idx] = scale;
                zeros[group_offset + group_idx] = zero;

                // Quantize group values
                var quantized_group = try self.allocator.alloc(u8, group_size);
                defer self.allocator.free(quantized_group);

                for (0..group_size) |j| {
                    const val = values[group_start + j];
                    var q = @as(i32, @intFromFloat(((val - zero) / scale) + 0.5));
                    q = @max(0, @min(q, @as(i32, @intCast(n_levels))));
                    quantized_group[j] = @as(u8, @intCast(q));
                }

                // Pack quantized values
                const packed_group = try self.packQuantized(quantized_group, bits);
                defer self.allocator.free(packed_group);

                // Store packed data
                const data_offset = (seq_idx * packed_len / seq_len) + (group_idx * packed_group.len);
                @memcpy(data[data_offset .. data_offset + packed_group.len], packed_group);
            }
        }

        return ValueQuantized{
            .data = data,
            .scales = scales,
            .zeros = zeros,
            .bits = bits,
            .group_size = group_size,
            .shape = shape_copy,
        };
    }

    /// Dequantize back to original values
    pub fn dequantize(self: *ValueQuantizer, vq: ValueQuantized) ![]f32 {
        const d = vq.shape[vq.shape.len - 1];
        const seq_len = vq.shape[vq.shape.len - 2];
        const n_groups = d / vq.group_size;
        const total_elements = seq_len * d;

        var values = try self.allocator.alloc(f32, total_elements);
        errdefer self.allocator.free(values);

        // Unpack data first
        const unpacked_len = try calculateUnpackedSize(vq.data.len, vq.bits, vq.group_size);
        var unpacked_data = try self.unpackQuantized(vq.data, vq.bits, unpacked_len);
        defer self.allocator.free(unpacked_data);

        // Dequantize each position
        for (0..seq_len) |seq_idx| {
            const seq_offset = seq_idx * d;
            const group_offset = seq_idx * n_groups;

            for (0..n_groups) |group_idx| {
                const group_start = seq_offset + (group_idx * vq.group_size);
                const scale = vq.scales[group_offset + group_idx];
                const zero = vq.zeros[group_offset + group_idx];

                for (0..vq.group_size) |j| {
                    const q_val = unpacked_data[group_start + j];
                    values[group_start + j] = zero + (scale * @as(f32, @floatFromInt(q_val)));
                }
            }
        }

        return values;
    }

    /// Pack quantized values (internal helper)
    fn packQuantized(self: *ValueQuantizer, values: []const u8, bits: u8) ![]u8 {
        if (bits == 2) {
            return self.pack2Bit(values);
        } else if (bits == 4) {
            return self.pack4Bit(values);
        } else {
            return error.UnsupportedBitWidth;
        }
    }

    /// Unpack quantized values (internal helper)
    fn unpackQuantized(self: *ValueQuantizer, packed_data: []const u8, bits: u8, expected_len: usize) ![]u8 {
        if (bits == 2) {
            const unpacked = try self.unpack2Bit(packed_data);
            if (unpacked.len != expected_len) {
                self.allocator.free(unpacked);
                return ValueQuantError.SizeMismatch;
            }
            return unpacked;
        } else if (bits == 4) {
            const unpacked = try self.unpack4Bit(packed_data);
            if (unpacked.len != expected_len) {
                self.allocator.free(unpacked);
                return ValueQuantError.SizeMismatch;
            }
            return unpacked;
        } else {
            return ValueQuantError.UnsupportedBitWidth;
        }
    }

    /// 2-bit packing (4 values per byte)
    fn pack2Bit(self: *ValueQuantizer, values: []const u8) ![]u8 {
        if (values.len % 4 != 0) return ValueQuantError.InputLengthNotMultipleOf4;

        const packed_len = values.len / 4;
        var packed_data = try self.allocator.alloc(u8, packed_len);

        for (0..packed_len) |i| {
            const base = i * 4;
            const v0 = values[base];
            const v1 = values[base + 1];
            const v2 = values[base + 2];
            const v3 = values[base + 3];

            if (v0 > 3 or v1 > 3 or v2 > 3 or v3 > 3) {
                self.allocator.free(packed_data);
                return ValueQuantError.ValueOutOfRange;
            }

            packed_data[i] = v0 | (v1 << 2) | (v2 << 4) | (v3 << 6);
        }

        return packed_data;
    }

    /// 4-bit packing (2 values per byte)
    fn pack4Bit(self: *ValueQuantizer, values: []const u8) ![]u8 {
        if (values.len % 2 != 0) return ValueQuantError.InputLengthNotMultipleOf2;

        const packed_len = values.len / 2;
        var packed_data = try self.allocator.alloc(u8, packed_len);

        for (0..packed_len) |i| {
            const base = i * 2;
            const v0 = values[base];
            const v1 = values[base + 1];

            if (v0 > 15 or v1 > 15) {
                self.allocator.free(packed_data);
                return ValueQuantError.ValueOutOfRange;
            }

            packed_data[i] = v0 | (v1 << 4);
        }

        return packed_data;
    }

    /// 2-bit unpacking
    fn unpack2Bit(self: *ValueQuantizer, packed_data: []const u8) ![]u8 {
        const unpacked_len = packed_data.len * 4;
        var unpacked = try self.allocator.alloc(u8, unpacked_len);

        for (packed_data, 0..) |byte, i| {
            const base = i * 4;
            unpacked[base] = byte & 0x03;
            unpacked[base + 1] = (byte >> 2) & 0x03;
            unpacked[base + 2] = (byte >> 4) & 0x03;
            unpacked[base + 3] = (byte >> 6) & 0x03;
        }

        return unpacked;
    }

    /// 4-bit unpacking
    fn unpack4Bit(self: *ValueQuantizer, packed_data: []const u8) ![]u8 {
        const unpacked_len = packed_data.len * 2;
        var unpacked = try self.allocator.alloc(u8, unpacked_len);

        for (packed_data, 0..) |byte, i| {
            const base = i * 2;
            unpacked[base] = byte & 0x0F;
            unpacked[base + 1] = (byte >> 4) & 0x0F;
        }

        return unpacked;
    }

    /// Test value quantization
    pub fn runTests(self: *ValueQuantizer) !void {
        std.debug.print("Testing value quantization:\n", .{});

        // Create test data: [2, 128] shape (2 sequences, 128 dimensions)
        const seq_len: usize = 2;
        const d: usize = 128;
        const group_size: usize = 32;
        const total_elements = seq_len * d;

        var test_values = try self.allocator.alloc(f32, total_elements);
        defer self.allocator.free(test_values);

        // Fill with random-ish values
        var prng = std.rand.DefaultPrng.init(42);
        const rand = prng.random();

        for (0..total_elements) |i| {
            test_values[i] = rand.float(f32) * 2.0 - 1.0; // Range [-1, 1]
        }

        const shape = [_]usize{ seq_len, d };

        // Test 2-bit quantization
        const vq_2bit = try self.quantize(test_values, &shape, 2, group_size);
        defer vq_2bit.deinit(self.allocator);

        const dequantized_2bit = try self.dequantize(vq_2bit);
        defer self.allocator.free(dequantized_2bit);

        // Check reconstruction error
        var error_2bit: f32 = 0;
        for (test_values, dequantized_2bit) |expected, actual| {
            error_2bit += math.abs(expected - actual);
        }
        error_2bit /= @as(f32, @floatFromInt(total_elements));

        std.debug.print("  ✓ 2-bit quantization (avg error={})\n", .{error_2bit});

        // Test 4-bit quantization
        const vq_4bit = try self.quantize(test_values, &shape, 4, group_size);
        defer vq_4bit.deinit(self.allocator);

        const dequantized_4bit = try self.dequantize(vq_4bit);
        defer self.allocator.free(dequantized_4bit);

        var error_4bit: f32 = 0;
        for (test_values, dequantized_4bit) |expected, actual| {
            error_4bit += math.abs(expected - actual);
        }
        error_4bit /= @as(f32, @floatFromInt(total_elements));

        std.debug.print("  ✓ 4-bit quantization (avg error={})\n", .{error_4bit});

        // Verify 4-bit has lower error than 2-bit
        if (error_4bit > error_2bit) {
            return error.QuantizationErrorUnexpected;
        }

        std.debug.print("All value quantization tests passed!\n", .{});
    }
};

/// Calculate packed size for given parameters
fn calculatePackedSize(total_elements: usize, bits: u8, group_size: usize) !usize {
    if (bits == 2) {
        return (total_elements + 3) / 4; // ceil(total_elements / 4)
    } else if (bits == 4) {
        return (total_elements + 1) / 2; // ceil(total_elements / 2)
    } else {
        return error.UnsupportedBitWidth;
    }
}

/// Calculate unpacked size for given parameters
fn calculateUnpackedSize(packed_len: usize, bits: u8, group_size: usize) !usize {
    if (bits == 2) {
        return packed_len * 4;
    } else if (bits == 4) {
        return packed_len * 2;
    } else {
        return error.UnsupportedBitWidth;
    }
}

/// Error types for value quantization
pub const ValueQuantError = error{
    UnsupportedBitWidth,
    InvalidGroupSize,
    DimensionNotDivisibleByGroupSize,
    InputLengthNotMultipleOf4,
    InputLengthNotMultipleOf2,
    ValueOutOfRange,
    SizeMismatch,
    QuantizationErrorUnexpected,
};

/// Export test function
pub const test_runner = struct {
    pub fn run() !void {
        const allocator = std.heap.page_allocator;
        var quantizer = ValueQuantizer.init(allocator);
        defer quantizer.deinit();

        try quantizer.runTests();
    }
};
