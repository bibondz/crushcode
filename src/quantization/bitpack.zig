const std = @import("std");
const math = std.math;

const Allocator = std.mem.Allocator;

/// Bit-packing utilities for TurboQuant KV cache compression
/// Supports 2-bit (4 values per byte) and 4-bit (2 values per byte) packing
pub const BitPacker = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) BitPacker {
        return BitPacker{
            .allocator = allocator,
        };
    }

    pub fn deinit(_: *BitPacker) void {}

    /// Pack 2-bit quantized values (4 values per byte)
    /// Input: array of uint8 values [0..3], length must be multiple of 4
    /// Output: packed bytes
    pub fn pack2Bit(self: *BitPacker, values: []const u8) ![]u8 {
        if (values.len % 4 != 0) {
            return error.InputLengthNotMultipleOf4;
        }

        const packed_len = values.len / 4;
        var packed_data = try self.allocator.alloc(u8, packed_len);

        for (0..packed_len) |i| {
            const base = i * 4;
            const v0 = values[base];
            const v1 = values[base + 1];
            const v2 = values[base + 2];
            const v3 = values[base + 3];

            // Validate values are in range [0..3]
            if (v0 > 3 or v1 > 3 or v2 > 3 or v3 > 3) {
                self.allocator.free(packed_data);
                return error.ValueOutOfRange;
            }

            // Pack: a | (b<<2) | (c<<4) | (d<<6)
            packed_data[i] = v0 | (v1 << 2) | (v2 << 4) | (v3 << 6);
        }

        return packed_data;
    }

    /// Unpack 2-bit packed bytes back to values
    pub fn unpack2Bit(self: *BitPacker, packed_data: []const u8) ![]u8 {
        const unpacked_len = packed_data.len * 4;
        var unpacked = try self.allocator.alloc(u8, unpacked_len);

        for (packed_data, 0..) |byte, i| {
            const base = i * 4;

            // Unpack: extract 2-bit values
            unpacked[base] = byte & 0x03; // bits 0-1
            unpacked[base + 1] = (byte >> 2) & 0x03; // bits 2-3
            unpacked[base + 2] = (byte >> 4) & 0x03; // bits 4-5
            unpacked[base + 3] = (byte >> 6) & 0x03; // bits 6-7
        }

        return unpacked;
    }

    /// Pack 4-bit quantized values (2 values per byte)
    /// Input: array of uint8 values [0..15], length must be multiple of 2
    /// Output: packed bytes
    pub fn pack4Bit(self: *BitPacker, values: []const u8) ![]u8 {
        if (values.len % 2 != 0) {
            return error.InputLengthNotMultipleOf2;
        }

        const packed_len = values.len / 2;
        var packed_data = try self.allocator.alloc(u8, packed_len);

        for (0..packed_len) |i| {
            const base = i * 2;
            const v0 = values[base];
            const v1 = values[base + 1];

            // Validate values are in range [0..15]
            if (v0 > 15 or v1 > 15) {
                self.allocator.free(packed_data);
                return error.ValueOutOfRange;
            }

            // Pack: a | (b<<4)
            packed_data[i] = v0 | (v1 << 4);
        }

        return packed_data;
    }

    /// Unpack 4-bit packed bytes back to values
    pub fn unpack4Bit(self: *BitPacker, packed_data: []const u8) ![]u8 {
        const unpacked_len = packed_data.len * 2;
        var unpacked = try self.allocator.alloc(u8, unpacked_len);

        for (packed_data, 0..) |byte, i| {
            const base = i * 2;

            // Unpack: extract 4-bit values
            unpacked[base] = byte & 0x0F; // bits 0-3
            unpacked[base + 1] = (byte >> 4) & 0x0F; // bits 4-7
        }

        return unpacked;
    }

    /// Auto-pack based on bit width (2 or 4 bits)
    pub fn packAuto(self: *BitPacker, values: []const u8, bits: u8) ![]u8 {
        return switch (bits) {
            2 => try self.pack2Bit(values),
            4 => try self.pack4Bit(values),
            else => error.UnsupportedBitWidth,
        };
    }

    /// Auto-unpack based on bit width (2 or 4 bits)
    pub fn unpackAuto(self: *BitPacker, packed_data: []const u8, bits: u8) ![]u8 {
        return switch (bits) {
            2 => try self.unpack2Bit(packed_data),
            4 => try self.unpack4Bit(packed_data),
            else => error.UnsupportedBitWidth,
        };
    }

    /// Calculate packed size for given input length and bits
    pub fn calculatePackedSize(input_len: usize, bits: u8) !usize {
        return switch (bits) {
            2 => if (input_len % 4 == 0) input_len / 4 else return error.InputLengthNotMultipleOf4,
            4 => if (input_len % 2 == 0) input_len / 2 else return error.InputLengthNotMultipleOf2,
            else => return error.UnsupportedBitWidth,
        };
    }

    /// Calculate unpacked size for given packed length and bits
    pub fn calculateUnpackedSize(packed_len: usize, bits: u8) !usize {
        return switch (bits) {
            2 => packed_len * 4,
            4 => packed_len * 2,
            else => return error.UnsupportedBitWidth,
        };
    }

    /// Test bit-packing utilities
    pub fn runTests(self: *BitPacker) !void {
        std.debug.print("Testing bit-packing utilities:\n", .{});

        // Test 2-bit packing
        const test_2bit = [_]u8{ 0, 1, 2, 3, 3, 2, 1, 0 };
        const packed_2bit = try self.pack2Bit(&test_2bit);
        defer self.allocator.free(packed_2bit);

        const unpacked_2bit = try self.unpack2Bit(packed_2bit);
        defer self.allocator.free(unpacked_2bit);

        for (test_2bit, unpacked_2bit) |expected, actual| {
            if (expected != actual) {
                return error.BitPackingFailed;
            }
        }
        std.debug.print("  ✓ 2-bit packing/unpacking\n", .{});

        // Test 4-bit packing
        const test_4bit = [_]u8{ 0, 15, 7, 8, 15, 0, 1, 14 };
        const packed_4bit = try self.pack4Bit(&test_4bit);
        defer self.allocator.free(packed_4bit);

        const unpacked_4bit = try self.unpack4Bit(packed_4bit);
        defer self.allocator.free(unpacked_4bit);

        for (test_4bit, unpacked_4bit) |expected, actual| {
            if (expected != actual) {
                return error.BitPackingFailed;
            }
        }
        std.debug.print("  ✓ 4-bit packing/unpacking\n", .{});

        // Test size calculations
        const packed_size_2bit = try calculatePackedSize(16, 2);
        if (packed_size_2bit != 4) return error.SizeCalculationFailed;

        const unpacked_size_2bit = try calculateUnpackedSize(4, 2);
        if (unpacked_size_2bit != 16) return error.SizeCalculationFailed;

        std.debug.print("  ✓ Size calculations\n", .{});

        std.debug.print("All bit-packing tests passed!\n", .{});
    }
};

/// Error types for bit-packing
pub const BitPackingError = error{
    InputLengthNotMultipleOf4,
    InputLengthNotMultipleOf2,
    ValueOutOfRange,
    UnsupportedBitWidth,
    BitPackingFailed,
    SizeCalculationFailed,
};

/// Export test function
pub const test_runner = struct {
    pub fn run() !void {
        const allocator = std.heap.page_allocator;
        var bitpacker = BitPacker.init(allocator);
        defer bitpacker.deinit();

        try bitpacker.runTests();
    }
};
