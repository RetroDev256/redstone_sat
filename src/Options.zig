const std = @import("std");
const Allocator = std.mem.Allocator;

// how many inputs there are to the circuit
input_count: u32,
// how many outputs there are to the circuit
output_count: u32,
// how many blocks [west to east] the circuit is
width: u32,
// how many blocks [north to south] the circuit is
length: u32,
// truth table that the circuit must satisfy
truth: []const []const struct { []const u1, u1 },

// allowed positions for inputs
input_mask: ?[]const []const u1,
// allowed positions for outputs
output_mask: ?[]const []const u1,
// allowed positions for torches
torch_mask: ?[]const []const u1,
// allowed positions for blocks
block_mask: ?[]const []const u1,
// allowed positions for dust
dust_mask: ?[]const []const u1,

// enforced positions for inputs
input_forced: ?[]const []const u1,
// enforced positions for outputs
output_forced: ?[]const []const u1,
// enforced positions for torches
torch_forced: ?[]const []const u1,
// enforced positions for blocks
block_forced: ?[]const []const u1,
// enforced positions for dust
dust_forced: ?[]const []const u1,

// maximum number of redstone dusts
max_dust: ?u32,
// maximum number of redstone torches
max_torch: ?u32,

// allow placement of north facing torches
allow_n_torch: bool,
// allow placement of east facing torches
allow_e_torch: bool,
// allow placement of south facing torches
allow_s_torch: bool,
// allow placement of west facing torches
allow_w_torch: bool,
// whether to allow a torch as an output
allow_torch_output: bool,
// whether to allow a dust as an output
allow_dust_output: bool,
// whether to allow a block as an input
allow_block_input: bool,
// Whether to allow a dust as an input
allow_dust_input: bool,

// enforce transitivity for inputs
input_transitivity: bool,
// enforce transitivity for outputs
output_transitivity: bool,
// prevent backfeeding of signal to the inputs
input_isolation: bool,
// prevent inputs from touching cardinal inputs
input_spacing: bool,
// prevent outputs from touching cardinal outputs
output_spacing: bool,
// prevent inputs from touching cardinal outputs
both_io_spacing: bool,
// whether to redirect input dust on the edges
redirect_input_edge_dust: bool,
// whether to redirect output dust on the edges
redirect_output_edge_dust: bool,

// enforce acyclic graph with some bits per cell
transition_bits: u32,

pub fn init(gpa: Allocator, source: [:0]const u8) !@This() {
    @setEvalBranchQuota(10_000); // for fromSliceAlloc
    const fromSliceAlloc = std.zon.parse.fromSliceAlloc;
    const self = try fromSliceAlloc(@This(), gpa, source, null, .{});

    if (self.output_count == 0)
        return error.ZeroOutputCount;
    if (self.input_count == 0)
        return error.ZeroInputCount;
    if (self.truth.len != self.output_count)
        return error.MismatchingOutputCount;

    for (self.truth) |out| {
        for (out) |row| {
            if (row[0].len != self.input_count) {
                return error.MismatchingInputCount;
            }
        }
    }

    return self;
}

pub fn deinit(self: *const @This(), gpa: Allocator) void {
    std.zon.parse.free(gpa, self.*);
}

pub fn area(self: *const @This()) u32 {
    return self.width * self.length;
}

pub fn states(self: *const @This()) u32 {
    return @as(u32, 1) << @intCast(self.input_count);
}
