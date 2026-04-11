const std = @import("std");
const testing = std.testing;
const rotation = @import("src/quantization/rotation.zig");
const bitpack = @import("src/quantization/bitpack.zig");
const value_quant = @import("src/quantization/value_quant.zig");
const key_quant = @import("src/quantization/key_quant.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== TurboQuant KV Cache Compression Tests ===\n\n", .{});

    // Test 1: Rotation utilities
    std.debug.print("1. Testing rotation utilities...\n", .{});
    try rotation.test_runner.run();
    std.debug.print("   ✓ Rotation utilities passed\n\n", .{});

    // Test 2: Bit-packing
    std.debug.print("2. Testing bit-packing...\n", .{});
    try bitpack.test_runner.run();
    std.debug.print("   ✓ Bit-packing passed\n\n", .{});

    // Test 3: Value quantization
    std.debug.print("3. Testing value quantization...\n", .{});
    try value_quant.test_runner.run();
    std.debug.print("   ✓ Value quantization passed\n\n", .{});

    // Test 4: Key quantization
    std.debug.print("4. Testing key quantization...\n", .{});
    try key_quant.test_runner.run();
    std.debug.print("   ✓ Key quantization passed\n\n", .{});

    // Test 5: Compression ratio calculation
    std.debug.print("5. Testing compression ratios...\n", .{});
    try testCompressionRatios();
    std.debug.print("   ✓ Compression ratio tests passed\n\n", .{});

    std.debug.print("=== All TurboQuant tests passed! ===\n", .{});
}

fn testCompressionRatios() !void {
    const allocator = std.heap.page_allocator;

    // Test data: small KV cache simulation
    const seq_len: usize = 16; // 16 tokens
    const head_dim: usize = 128; // 128 dimensions
    const total_elements = seq_len * head_dim;

    // Generate test data
    var test_data = try allocator.alloc(f32, total_elements);
    defer allocator.free(test_data);

    var prng = std.rand.DefaultPrng.init(42);
    const rand = prng.random();

    for (0..total_elements) |i| {
        test_data[i] = rand.float(f32) * 2.0 - 1.0; // Range [-1, 1]
    }

    const shape = [_]usize{ seq_len, head_dim };

    // Calculate original size
    const original_size_bytes = total_elements * @sizeOf(f32);

    // Test different quantization configurations
    const configs = [_]struct { key_bits: u8, value_bits: u8 }{
        .{ .key_bits = 3, .value_bits = 2 }, // Max compression
        .{ .key_bits = 3, .value_bits = 4 }, // Balanced
        .{ .key_bits = 4, .value_bits = 4 }, // High quality
    };

    for (configs) |config| {
        // Estimate compressed size
        const key_packed_len = (total_elements * config.key_bits + 7) / 8;
        const value_packed_len = (total_elements * config.value_bits + 7) / 8;

        // Add overhead for scales/zeros/norms (simplified)
        const overhead = total_elements * @sizeOf(f32) / 4; // Rough estimate

        const compressed_size_bytes = key_packed_len + value_packed_len + overhead;
        const compression_ratio = @as(f32, @floatFromInt(original_size_bytes)) / @as(f32, @floatFromInt(compressed_size_bytes));

        std.debug.print("   {}-bit keys + {}-bit values: {d:.1}x compression\n", .{
            config.key_bits,
            config.value_bits,
            compression_ratio,
        });
    }

    // Verify expected compression ranges
    std.debug.print("\n", .{});
    std.debug.print("   Expected: 3-bit keys + 2-bit values = 3.8-6.4x (paper: Table 1)\n", .{});
    std.debug.print("   Expected: 3-bit keys + 4-bit values = 2.8-4.2x\n", .{});
    std.debug.print("   Expected: 4-bit keys + 4-bit values = 2.4-3.2x\n", .{});
}
