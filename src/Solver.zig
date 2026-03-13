const kissat = @import("kissat");
const assert = @import("std").debug.assert;
const Bits = @import("cnf.zig").Bits;

variable_count: u32,
solver: *kissat.struct_kissat,

pub fn init() !@This() {
    if (kissat.kissat_init()) |solver| {
        return .{
            .variable_count = 0,
            .solver = solver,
        };
    } else {
        return error.FailedToInitialize;
    }
}

/// May only be called after a successful init()
/// Frees all memory allocated by Kissat
pub fn deinit(self: *@This()) void {
    kissat.kissat_release(self.solver);
    self.* = undefined;
}

/// May only be called after a successful init()
/// THIS CAN be called after solve() is called, but the values
/// of variables will remain undefined until the next solve()
/// Adds 0 delimited sequences of variables -> ID & neg CNF
pub fn add(self: *const @This(), variable: i32) void {
    kissat.kissat_add(self.solver, variable);
}

/// May only be called after a successful init()
/// Solves the clauses, returns interrupted, sat, or unsat
const Status = enum { interrupted, sat, unsat };
pub fn solve(self: *const @This()) Status {
    switch (kissat.kissat_solve(self.solver)) {
        0 => return .interrupted,
        10 => return .sat,
        20 => return .unsat,
        else => unreachable,
    }
}

/// May only be called after solve() is called
/// Value is undefined if solve() did not return .sat
/// Value is undefined if called on newly added variables
/// Gets the boolean value of some variable (can be negative)
pub fn value(self: *const @This(), variable: usize) bool {
    assert(variable != 0);
    const val = kissat.kissat_value(self.solver, @intCast(variable));
    assert(@abs(val) == @abs(variable));
    return val > 0;
}

// Allocate some number of unconstrained bits
pub fn alloc(self: *@This(), count: usize) Bits {
    const start = self.variable_count;
    self.variable_count += @intCast(count);
    return .init(start + 1, count);
}
