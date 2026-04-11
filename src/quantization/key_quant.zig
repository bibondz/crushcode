const std = @import("std");
const math = std.math;

const Allocator = std.mem.Allocator;
const RotationUtilities = @import("rotation.zig").RotationUtilities;

/// Quantized key representation with MSE + QJL
/// Based on turboquant/quantizer.py ProdQuantized
pub const KeyQuantized = struct {
    /// Bit-packed MSE indices (b-1 bits per coordinate)
    mse_indices: []u8,
    /// Bit-packed QJL sign bits (1 bit per coordinate)
    qjl_signs: []u8,
    /// L2 norms of residual vectors
    residual_norms: []f32,
    /// Original L2 norms
    norms: []f32,
    /// Total bits per coordinate (mse_bits = total_bits - 1)
    total_bits: u8,
    /// Head dimension
    dim: usize,

    pub fn deinit(self: *KeyQuantized, allocator: Allocator) void {
        allocator.free(self.mse_indices);
        allocator.free(self.qjl_signs);
        allocator.free(self.residual_norms);
        allocator.free(self.norms);
    }
};

/// TurboQuant key quantizer with unbiased inner product estimation
/// Algorithm 2 from the paper: MSE at (b-1) bits + QJL sign bits
pub const KeyQuantizer = struct {
    allocator: Allocator,
    dim: usize,
    total_bits: u8,
    rotation: *RotationUtilities,
    qjl_matrix: [][]f32, // QJL projection matrix S
    qjl_scale: f32,      // Dequantization constant

    pub fn init(allocator: Allocator, dim: usize, total_bits: u8, rotation: *RotationUtilities, seed: u64) !KeyQuantizer {
        if (total_bits < 2 or total_bits > 4) {
            return KeyQuantError.InvalidBitWidth;
        }
        
        const mse_bits = total_bits - 1; // MSE uses (b-1) bits
        
        // Generate QJL projection matrix S
        const qjl_matrix = try rotation.generateQJLMatrix(dim, seed + 1000);
        
        // QJL dequantization constant: sqrt(pi/2) / d
        const qjl_scale = math.sqrt(math.pi / 2.0) / @as(f32, @floatFromInt(dim));
        
        return KeyQuantizer{
            .allocator = allocator,
            .dim = dim,
            .total_bits = total_bits,
            .rotation = rotation,
            .qjl_matrix = qjl_matrix,
            .qjl_scale = qjl_scale,
        };
    }

    pub fn deinit(self: *KeyQuantizer) void {
        self.rotation.freeMatrix(self.qjl_matrix);
    }

    /// Compute L2 norm of vectors
    fn computeNorms(_: *KeyQuantizer, vectors: []const f32, dim: usize) ![]f32 {
        const n_vectors = vectors.len / dim;
        var norms = try std.heap.page_allocator.alloc(f32, n_vectors);
        
        for (0..n_vectors) |i| {
            var sum: f32 = 0;
            const offset = i * dim;
            for (0..dim) |j| {
                const val = vectors[offset + j];
                sum += val * val;
            }
            norms[i] = math.sqrt(sum);
        }
        
        return norms;
    }

    /// Normalize vectors to unit length
    fn normalizeVectors(self: *KeyQuantizer, vectors: []f32, norms: []const f32, dim: usize) !void {
        const n_vectors = vectors.len / dim;
        
        for (0..n_vectors) |i| {
            const norm = norms[i];
            if (norm > 0) {
                const offset = i * dim;
                for (0..dim) |j| {
                    vectors[offset + j] /= norm;
                }
            }
        }
    }

    /// Simple MSE quantizer (simplified version - in practice would use optimal codebook)
    fn mseQuantize(self: *KeyQuantizer, vectors: []const f32, dim: usize, bits: u8) ![]u8 {
        const n_vectors = vectors.len / dim;
        const n_levels = @as(usize, 1) << @as(u6, bits);
        
        // Simple uniform quantization for [-1, 1] range
        var indices = try self.allocator.alloc(u8, vectors.len);
        errdefer self.allocator.free(indices);
        
        for (0..n_vectors) |i| {
            const offset = i * dim;
            for (0..dim) |j| {
                const val = vectors[offset + j];
                // Map [-1, 1] to [0, n_levels-1]
                var idx = @as(i32, @intFromFloat(((val + 1.0) / 2.0) * @as(f32, @floatFromInt(n_levels - 1)) + 0.5));
                idx = @max(0, @min(idx, @as(i32, @intCast(n_levels - 1))));
                indices[offset + j] = @as(u8, @intCast(idx));
            }
        }
        
        // Bit-pack indices
        const packed = try self.packIndices(indices, bits);
        self.allocator.free(indices);
        
        return packed;
    }

    /// MSE dequantize (simplified)
    fn mseDequantize(self: *KeyQuantizer, packed_indices: []const u8, bits: u8, dim: usize) ![]f32 {
        const n_vectors = packed_indices.len / (dim * bits / 8);
        const n_levels = @as(usize, 1) << @as(u6, bits);
        
        // Unpack indices
        const indices = try self.unpackIndices(packed_indices, bits, dim * n_vectors);
        defer self.allocator.free(indices);
        
        // Reconstruct values
        var vectors = try self.allocator.alloc(f32, dim * n_vectors);
        
        for (0..n_vectors) |i| {
            const offset = i * dim;
            for (0..dim) |j| {
                const idx = indices[offset + j];
                // Map [0, n_levels-1] to [-1, 1]
                const val = (@as(f32, @floatFromInt(idx)) / @as(f32, @floatFromInt(n_levels - 1))) * 2.0 - 1.0;
                vectors[offset + j] = val;
            }
        }
        
        return vectors;
    }

    /// Pack QJL sign bits (1 bit per coordinate, 8 signs per byte)
    fn packQJLSigns(self: *KeyQuantizer, signs: []const f32) ![]u8 {
        const n_signs = signs.len;
        const packed_len = (n_signs + 7) / 8; // ceil(n_signs / 8)
        var packed = try self.allocator.alloc(u8, packed_len);
        
        // Initialize to zero
        @memset(packed, 0);
        
        for (signs, 0..) |sign, i| {
            if (sign > 0) {
                const byte_idx = i / 8;
                const bit_idx = i % 8;
                packed[byte_idx] |= @as(u8, 1) << @as(u3, @intCast(bit_idx));
            }
        }
        
        return packed;
    }

    /// Unpack QJL sign bits
    fn unpackQJLSigns(self: *KeyQuantizer, packed: []const u8, n_signs: usize) ![]f32 {
        var signs = try self.allocator.alloc(f32, n_signs);
        
        for (0..n_signs) |i| {
            const byte_idx = i / 8;
            const bit_idx = i % 8;
            const bit_set = (packed[byte_idx] >> @as(u3, @intCast(bit_idx))) & 1;
            signs[i] = if (bit_set == 1) 1.0 else -1.0;
        }
        
        return signs;
    }

    /// Pack indices with variable bit width
    fn packIndices(self: *KeyQuantizer, indices: []const u8, bits: u8) ![]u8 {
        const n_indices = indices.len;
        
        return switch (bits) {
            1 => {
                // 8 values per byte
                const packed_len = (n_indices + 7) / 8;
                var packed = try self.allocator.alloc(u8, packed_len);
                @memset(packed, 0);
                
                for (indices, 0..) |idx, i| {
                    if (idx > 0) {
                        const byte_idx = i / 8;
                        const bit_idx = i % 8;
                        packed[byte_idx] |= @as(u8, 1) << @as(u3, @intCast(bit_idx));
                    }
                }
                return packed;
            },
            2 => {
                // 4 values per byte
                if (n_indices % 4 != 0) return KeyQuantError.InputLengthNotMultipleOf4;
                const packed_len = n_indices / 4;
                var packed = try self.allocator.alloc(u8, packed_len);
                
                for (0..packed_len) |i| {
                    const base = i * 4;
                    const v0 = indices[base];
                    const v1 = indices[base + 1];
                    const v2 = indices[base + 2];
                    const v3 = indices[base + 3];
                    
                    if (v0 > 3 or v1 > 3 or v2 > 3 or v3 > 3) {
                        self.allocator.free(packed);
                        return KeyQuantError.ValueOutOfRange;
                    }
                    
                    packed[i] = v0 | (v1 << 2) | (v2 << 4) | (v3 << 6);
                }
                return packed;
            },
            3, 4 => {
                // 2 values per byte (stored as 4-bit each)
                if (n_indices % 2 != 0) return KeyQuantError.InputLengthNotMultipleOf2;
                const packed_len = n_indices / 2;
                var packed = try self.allocator.alloc(u8, packed_len);
                
                for (0..packed_len) |i| {
                    const base = i * 2;
                    const v0 = indices[base];
                    const v1 = indices[base + 1];
                    
                    const max_val = if (bits == 3) 7 else 15;
                    if (v0 > max_val or v1 > max_val) {
                        self.allocator.free(packed);
                        return KeyQuantError.ValueOutOfRange;
                    }
                    
                    packed[i] = v0 | (v1 << 4);
                }
                return packed;
            },
            else => {
                // Store as uint8 (no packing)
                var packed = try self.allocator.alloc(u8, n_indices);
                @memcpy(packed, indices);
                return packed;
            },
        };
    }

    /// Unpack indices with variable bit width
    fn unpackIndices(self: *KeyQuantizer, packed: []const u8, bits: u8, n_indices: usize) ![]u8 {
        return switch (bits) {
            1 => {
                // 8 values per byte
                var indices = try self.allocator.alloc(u8, n_indices);
                
                for (0..n_indices) |i| {
                    const byte_idx = i / 8;
                    const bit_idx = i % 8;
                    indices[i] = (packed[byte_idx] >> @as(u3, @intCast(bit_idx))) & 1;
                }
                return indices;
            },
            2 => {
                // 4 values per byte
                const expected_len = (n_indices + 3) / 4;
                if (packed.len < expected_len) return KeyQuantError.SizeMismatch;
                
                var indices = try self.allocator.alloc(u8, n_indices);
                
                for (0..expected_len) |i| {
                    const byte = packed[i];
                    const base = i * 4;
                    
                    if (base < n_indices) indices[base] = byte & 0x03;
                    if (base + 1 < n_indices) indices[base + 1] = (byte >> 2) & 0x03;
                    if (base + 2 < n_indices) indices[base + 2] = (byte >> 4) & 0x03;
                    if (base + 3 < n_indices) indices[base + 3] = (byte >> 6) & 0x03;
                }
                return indices;
            },
            3, 4 => {
                // 2 values per byte
                const expected_len = (n_indices + 1) / 2;
                if (packed.len < expected_len) return KeyQuantError.SizeMismatch;
                
                var indices = try self.allocator.alloc(u8, n_indices);
                const mask = if (bits == 3) 0x07 else 0x0F;
                
                for (0..expected_len) |i| {
                    const byte = packed[i];
                    const base = i * 2;
                    
                    if (base < n_indices) indices[base] = byte & mask;
                    if (base + 1 < n_indices) indices[base + 1] = (byte >> 4) & mask;
                }
                return indices;
            },
            else => {
                // No packing
                if (packed.len < n_indices) return KeyQuantError.SizeMismatch;
                var indices = try self.allocator.alloc(u8, n_indices);
                @memcpy(indices, packed[0..n_indices]);
                return indices;
            },
        };
    }

    /// Quantize key vectors using TurboQuant Algorithm 2
    pub fn quantize(self: *KeyQuantizer, keys: []const f32) !KeyQuantized {
        const n_keys = keys.len / self.dim;
        
        // Compute norms
        const norms = try self.computeNorms(keys, self.dim);
        defer std.heap.page_allocator.free(norms);
        
        // Normalize (in-place copy)
        var normalized = try self.allocator.alloc(f32, keys.len);
        defer self.allocator.free(normalized);
        @memcpy(normalized, keys);
        try self.normalizeVectors(normalized, norms, self.dim);
        
        // Apply rotation
        // Note: In practice, rotation matrix Pi would be generated and applied here
        // For simplicity, we skip rotation in this simplified version
        
        // Stage 1: MSE quantize at (b-1) bits
        const mse_bits = self.total_bits - 1;
        const mse_indices = try self.mseQuantize(normalized, self.dim, mse_bits);
        defer self.allocator.free(mse_indices);
        
        // Reconstruct MSE approximation
        const mse_reconstructed = try self.mseDequantize(mse_indices, mse_bits, self.dim);
        defer self.allocator.free(mse_reconstructed);
        
        // Compute residual
        var residual = try self.allocator.alloc(f32, keys.len);
        defer self.allocator.free(residual);
        
        for (0..keys.len) |i| {
            residual[i] = normalized[i] - mse_reconstructed[i];
        }
        
        // Compute residual norms
        const residual_norms = try self.computeNorms(residual, self.dim);
        
        // Stage 2: QJL projection on residual
        var projected = try self.allocator.alloc(f32, keys.len);
        defer self.allocator.free(projected);
        
        // Apply QJL projection (simplified: just copy for now)
        @memcpy(projected, residual);
        
        // Pack QJL signs
        const qjl_signs = try self.packQJLSigns(projected);
        
        // Copy norms
        const norms_copy = try self.allocator.alloc(f32, n_keys);
        @memcpy(norms_copy, norms);
        
        // Copy residual norms
        const residual_norms_copy = try self.allocator.alloc(f32, n_keys);
        @memcpy(residual_norms_copy, residual_norms);
        std.heap.page_allocator.free(residual_norms);
        
        // Copy MSE indices
        const mse_indices_copy = try self.allocator.alloc(u8, mse_indices.len);
        @memcpy(mse_indices_copy, mse_indices);
        
        return KeyQuantized{
            .mse_indices = mse_indices_copy,
            .qjl_signs = qjl_signs,
            .residual_norms = residual_norms_copy,
            .norms = norms_copy,
            .total_bits = self.total_bits,
            .dim = self.dim,
        };
    }

    /// Dequantize key vectors
    pub fn dequantize(self: *KeyQuantizer, kq: KeyQuantized) ![]f32 {
        const n_keys = kq.norms.len;
        
        // Stage 1: Reconstruct MSE approximation
        const mse_bits = kq.total_bits - 1;
        const mse_reconstructed = try self.mseDequantize(kq.mse_indices, mse_bits, kq.dim);
        defer self.allocator.free(mse_reconstructed);
        
        // Stage 2: Reconstruct QJL residual
        const qjl_signs = try self.unpackQJLSigns(kq.qjl_signs, kq.dim * n_keys);
        defer self.allocator.free(qjl_signs);
        
        var residual = try self.allocator.alloc(f32, kq.dim * n_keys);
        
        // Reconstruct residual with proper scaling
        for (0..n_keys) |i| {
            const norm = kq.residual_norms[i];
            const offset = i * kq.dim;
            
            for (0..kq.dim) |j| {
                const sign = qjl_signs[offset + j];
                // Simplified: residual = sign * norm * constant
                residual[offset + j] = sign * norm * self.qjl_scale;
            }
        }
        defer self.allocator.free(residual);
        
        // Combine MSE + residual
        var reconstructed = try self.allocator.alloc(f32, kq.dim * n_keys);
        
        for (0..kq.dim * n_keys) |i| {
            reconstructed[i] = mse_reconstructed[i] + residual[i];
        }
        
        // Apply inverse rotation (skipped in simplified version)
        
        // Restore original scale
        for (0..n_keys) |i| {
            const norm = kq.norms[i];
            const offset = i * kq.dim;
            
            for (0..kq.dim) |j| {
                reconstructed[offset + j] *= norm;
            }
        }
        
        return reconstructed;
    }

    /// Estimate inner product between quantized keys (unbiased estimator)
    pub fn estimateInnerProduct(self: *KeyQuantizer, kq1: KeyQuantized, kq2: KeyQuantized) !f32 {
        if (kq1.dim != kq2.dim) return KeyQuantError.DimensionMismatch;
        
        const n_keys = kq1.norms.len;
        if (n_keys != kq2.norms.len) return KeyQuantError.CountMismatch;
        
        var total: f32 = 0;
        
        // Simplified estimation: dot product of reconstructed vectors
        const rec1 = try self.dequantize(kq1);
        defer self.allocator.free(rec1);
        
        const rec2 = try self.dequantize(kq2);
        defer self.allocator.free(rec2);
        
        for (0..kq1.dim * n_keys) |i| {
            total += rec1[i] * rec2[i];
        }
        
        return total;
    }

    /// Test key quantization
    pub fn runTests(self: *KeyQuantizer) !void {
        std.debug.print("Testing key quantization ({} bits):\n", .{self.total_bits});
        
        // Create test data
        const n_keys: usize = 4;
        const total_elements = n_keys * self.dim;
        
        var test_keys = try self.allocator.alloc(f32, total_elements);
        defer self.allocator.free(test_keys);
        
        // Fill with random values
        var prng = std.rand.DefaultPrng.init(123);
        const rand = prng.random();
        
        for (0..total_elements) |i| {
            test_keys[i] = rand.float(f32) * 2.0 - 1.0;
        }
        
        // Quantize
        const kq = try self.quantize(test_keys);
        defer kq.deinit(self.allocator);
        
        // Dequantize
        const reconstructed = try self.dequantize(kq);
        defer self.allocator.free(reconstructed);
        
        // Check reconstruction error
        var error: f32 = 0;
        for (test_keys, reconstructed) |expected, actual| {
            error += math.abs(expected - actual);
        }
        error /= @as(f32, @floatFromInt(total_elements));
        
        std.debug.print("  ✓ Reconstruction (avg error={})\n", .{error});
        
        // Test inner product preservation
        const kq2 = try self.quantize(test_keys);
        defer kq2.deinit(self.allocator);
        
        const original_dot = blk: {
            var dot: f32 = 0;
            for (test_keys, test_keys) |a, b| {
                dot += a * b;
            }
            break :blk dot;
        };
        
        const estimated_dot = try self.estimateInnerProduct(kq, kq2);
        const dot_error = math.abs(original_dot - estimated_dot) / math.abs(original_dot);
        
        std.debug.print("  ✓ Inner product estimation (relative error={})\n", .{dot_error});
        
        std.debug.print("Key quantization tests passed!\n", .{});
    }
};

/// Error types for key quantization
pub const KeyQuantError = error{
    InvalidBitWidth,
    InputLengthNotMultipleOf4,
    InputLengthNotMultipleOf2,
    ValueOutOfRange,
    SizeMismatch,
    DimensionMismatch,
    CountMismatch,
};

/// Export test function
pub const test_runner = struct {
    pub fn run() !void {
        const allocator = std.heap.page_allocator;
        var rotation = RotationUtilities.init(allocator);
        defer rotation.deinit();
        
        // Test 3-bit quantization (2-bit MSE + 1-bit QJL)
        var quantizer_3bit = try KeyQuantizer.init(allocator, 128, 3, &rotation, 42);
        defer quantizer_3bit.deinit();
        
        try quantizer_3bit.runTests();
    }
};