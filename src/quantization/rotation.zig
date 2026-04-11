const std = @import("std");
const math = std.math;
const random = std.crypto.random;

const Allocator = std.mem.Allocator;

/// Random rotation utilities for TurboQuant-style compression
/// Based on turboquant/rotation.py with QR decomposition approach
pub const RotationUtilities = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) RotationUtilities {
        return RotationUtilities{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RotationUtilities) void {
        _ = self;
    }

    /// Generate random orthogonal matrix Π ∈ R^{d×d} via QR decomposition
    /// This is the method described in Algorithm 1 of TurboQuant paper
    /// Returns: d×d matrix stored as [d][d]f32
    pub fn generateRotationMatrix(self: *RotationUtilities, d: usize, seed: u64) ![][]f32 {
        // Generate random Gaussian matrix G
        const G = try self.generateRandomGaussianMatrix(d, d, seed);
        defer self.freeMatrix(G);

        // Perform QR decomposition
        const Q = try self.qrDecomposition(G);

        // Ensure proper rotation (det = +1) by fixing signs
        var Q_mut = Q;
        self.fixRotationSigns(&Q_mut);

        return Q;
    }

    /// Generate random projection matrix S ∈ R^{d×d} for QJL (1-bit residual correction)
    /// S has i.i.d. N(0,1) entries
    pub fn generateQJLMatrix(self: *RotationUtilities, d: usize, seed: u64) ![][]f32 {
        return try self.generateRandomGaussianMatrix(d, d, seed + 12345);
    }

    /// Apply random rotation: y = x @ Pi^T
    pub fn rotateForward(self: *RotationUtilities, x: []const f32, Pi: [][]const f32) ![]f32 {
        const d = Pi.len;
        const n_vectors = x.len / d;

        var result = try self.allocator.alloc(f32, x.len);

        for (0..n_vectors) |i| {
            const vector_start = i * d;

            for (0..d) |j| {
                var sum: f32 = 0;
                for (0..d) |k| {
                    sum += x[vector_start + k] * Pi[j][k];
                }
                result[vector_start + j] = sum;
            }
        }

        return result;
    }

    /// Apply inverse rotation: x = y @ Pi
    pub fn rotateBackward(self: *RotationUtilities, y: []const f32, Pi: [][]const f32) ![]f32 {
        const d = Pi.len;
        const n_vectors = y.len / d;

        var result = try self.allocator.alloc(f32, y.len);

        for (0..n_vectors) |i| {
            const vector_start = i * d;

            for (0..d) |j| {
                var sum: f32 = 0;
                for (0..d) |k| {
                    sum += y[vector_start + k] * Pi[k][j];
                }
                result[vector_start + j] = sum;
            }
        }

        return result;
    }

    /// Generate random Gaussian matrix (normal distribution)
    fn generateRandomGaussianMatrix(self: *RotationUtilities, rows: usize, cols: usize, seed: u64) ![][]f32 {
        // Create deterministic random generator from seed
        var prng = std.rand.DefaultPrng.init(seed);
        const rand = prng.random();

        var matrix = try self.allocator.alloc([]f32, rows);
        for (0..rows) |i| {
            matrix[i] = try self.allocator.alloc(f32, cols);
            for (0..cols) |j| {
                // Generate normal distribution using Box-Muller transform
                const u1_val = rand.float(f32);
                const u2_val = rand.float(f32);
                const z0 = math.sqrt(-2 * math.log(u1_val)) * math.cos(2 * math.pi * u2_val);
                matrix[i][j] = z0;
            }
        }

        return matrix;
    }

    /// QR decomposition using Gram-Schmidt process
    fn qrDecomposition(self: *RotationUtilities, A: [][]const f32) ![][]f32 {
        const m = A.len;
        const n = A[0].len;

        var Q = try self.allocator.alloc([]f32, m);
        for (0..m) |i| {
            Q[i] = try self.allocator.alloc(f32, n);
            // Initialize to zero
            for (0..n) |j| {
                Q[i][j] = 0;
            }
        }

        var R = try self.allocator.alloc([]f32, n);
        for (0..n) |i| {
            R[i] = try self.allocator.alloc(f32, n);
            for (0..n) |j| {
                R[i][j] = 0;
            }
        }

        // Gram-Schmidt process
        for (0..n) |j| {
            // Copy column j of A to v
            var v = try self.allocator.alloc(f32, m);
            for (0..m) |i| {
                v[i] = A[i][j];
            }

            for (0..j) |k| {
                // Compute projection (dot product)
                var dot: f32 = 0;
                for (0..m) |i| {
                    dot += Q[i][k] * v[i];
                }

                R[k][j] = dot;

                // Subtract projection
                for (0..m) |i| {
                    v[i] -= dot * Q[i][k];
                }
            }

            // Normalize
            var norm: f32 = 0;
            for (0..m) |i| {
                norm += v[i] * v[i];
            }
            norm = math.sqrt(norm);

            if (norm > 0) {
                for (0..m) |i| {
                    Q[i][j] = v[i] / norm;
                }
                R[j][j] = norm;
            } else {
                // Handle zero norm (rare)
                for (0..m) |i| {
                    Q[i][j] = 0;
                }
                R[j][j] = 0;
            }

            self.allocator.free(v);
        }

        // Clean up R matrix
        for (0..n) |i| {
            self.allocator.free(R[i]);
        }
        self.allocator.free(R);

        return Q;
    }

    /// Fix rotation signs to ensure determinant = +1
    fn fixRotationSigns(_: *RotationUtilities, Q: *[][]f32) void {
        const n = Q.len;

        // Simplified sign fixing: ensure diagonal positive
        for (0..n) |i| {
            if (Q.*[i][i] < 0) {
                for (0..n) |j| {
                    Q.*[i][j] = -Q.*[i][j];
                }
            }
        }
    }

    /// Validate that matrix is orthogonal (within epsilon)
    pub fn validateOrthogonal(_: *RotationUtilities, matrix: [][]const f32, epsilon: f32) bool {
        const n = matrix.len;

        for (0..n) |i| {
            for (0..n) |j| {
                if (i == j) {
                    // Check column norm ≈ 1
                    var norm: f32 = 0;
                    for (0..n) |k| {
                        norm += matrix[k][i] * matrix[k][i];
                    }
                    if (math.abs(norm - 1) > epsilon) {
                        return false;
                    }
                } else {
                    // Check orthogonality
                    var dot: f32 = 0;
                    for (0..n) |k| {
                        dot += matrix[k][i] * matrix[k][j];
                    }
                    if (math.abs(dot) > epsilon) {
                        return false;
                    }
                }
            }
        }

        return true;
    }

    /// Clean up matrix memory
    pub fn freeMatrix(self: *RotationUtilities, matrix: [][]f32) void {
        for (matrix) |row| {
            self.allocator.free(row);
        }
        self.allocator.free(matrix);
    }

    /// Test rotation utilities
    pub fn runTests(self: *RotationUtilities) !void {
        const d: usize = 8; // Small dimension for testing

        std.debug.print("Testing rotation utilities:\n", .{});

        // Generate rotation matrix
        const Pi = try self.generateRotationMatrix(d, 42);
        defer self.freeMatrix(Pi);

        // Validate orthogonality
        const is_orthogonal = self.validateOrthogonal(Pi, 0.001);
        if (!is_orthogonal) {
            return error.RotationValidationFailed;
        }
        std.debug.print("  ✓ Rotation matrix is orthogonal\n", .{});

        // Generate QJL matrix
        const S = try self.generateQJLMatrix(d, 12345);
        defer self.freeMatrix(S);

        // Test rotation forward/backward
        var test_vector = try self.allocator.alloc(f32, d);
        defer self.allocator.free(test_vector);

        for (0..d) |i| {
            test_vector[i] = @as(f32, @floatFromInt(i)) / d;
        }

        const rotated = try self.rotateForward(test_vector, Pi);
        defer self.allocator.free(rotated);

        const restored = try self.rotateBackward(rotated, Pi);
        defer self.allocator.free(restored);

        // Check restoration accuracy
        var restoration_error: f32 = 0;
        for (0..d) |i| {
            restoration_error += math.abs(test_vector[i] - restored[i]);
        }

        if (restoration_error > 0.01) {
            return error.RotationAccuracyFailed;
        }
        std.debug.print("  ✓ Rotation forward/backward accurate (error={})\n", .{restoration_error});

        std.debug.print("All rotation tests passed!\n", .{});
    }
};

/// Export test function
pub const test_runner = struct {
    pub fn run() !void {
        const allocator = std.heap.page_allocator;
        var rotation = RotationUtilities.init(allocator);
        defer rotation.deinit();

        try rotation.runTests();
    }
};
