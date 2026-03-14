const std = @import("std");
const assert = std.debug.assert;
const kissat = @import("kissat");

var_count: usize,
solver: *kissat.struct_kissat,

pub fn init() !@This() {
    if (kissat.kissat_init()) |solver| {
        return .{ .var_count = 0, .solver = solver };
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
/// Solves the clauses, returns interrupted, sat, or unsat
const Status = enum { interrupted, sat, unsat };
pub fn solve(sol: *const @This()) Status {
    switch (kissat.kissat_solve(sol.solver)) {
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
pub fn value(sol: *const @This(), variable: usize) bool {
    assert(variable != 0);
    const lit: i32 = @intCast(variable);
    const val = kissat.kissat_value(sol.solver, lit);
    assert(@abs(val) == @abs(variable));
    return val > 0;
}

// Allocate some number of unconstrained bits
pub fn alloc(sol: *@This(), count: usize) Bits {
    const start = sol.var_count;
    sol.var_count += @intCast(count);
    return .init(start + 1, count);
}

// ------------------------------------------------------- BIT LIST RECORD TYPE

pub const Bits = struct {
    idx: usize,
    len: usize,

    pub fn init(idx: usize, len: usize) @This() {
        return .{ .idx = idx, .len = len };
    }

    pub fn at(self: @This(), off: usize) usize {
        assert(off < self.len);
        return @intCast(self.idx + off);
    }

    pub fn slice(self: @This(), start: usize, limit: ?usize) @This() {
        const end_idx: usize = limit orelse self.len;
        assert(start <= self.len and end_idx <= self.len);
        return .init(self.idx + start, end_idx - start);
    }
};

// ------------------------------------------------------------ CLAUSE ENCODING

// Encode a complete CNF clause with slices
pub fn clause(sol: *@This(), index: []const usize, identity: []const u1) void {
    // Write out every part of the clause in a loop
    for (index, identity) |x, i| sol.part(x, i);
    // Write out the termination for the clause
    kissat.kissat_add(sol.solver, 0);
}

// Write a portion of one CNF clause with an index & identity
pub fn part(sol: *@This(), index: usize, identity: u1) void {
    const lit: i32 = @intCast(index);
    assert(index != 0); // prohibit end of clause

    switch (identity) {
        0 => kissat.kissat_add(sol.solver, -lit),
        1 => kissat.kissat_add(sol.solver, lit),
    }
}

// End the current CNF clause (can be replaced with clause())
pub fn end(sol: *@This()) void {
    kissat.kissat_add(sol.solver, 0);
}

// --------------------------------------------------------- BITWISE IDENTITIES

// val IS TRUE
pub fn bittrue(sol: *@This(), val: usize) void {
    clause(sol, &.{val}, &.{1});
}

// val IS FALSE
pub fn bitfalse(sol: *@This(), val: usize) void {
    clause(sol, &.{val}, &.{0});
}

// -------------------------------------------------- SINGLE BITWISE OPERATIONS

/// lhs EQUIVALENT TO rhs
pub fn biteql(sol: *@This(), lhs: usize, rhs: usize) void {
    clause(sol, &.{ lhs, rhs }, &.{ 0, 1 });
    clause(sol, &.{ lhs, rhs }, &.{ 1, 0 });
}

// -------------------------------------------------- DOUBLE BITWISE OPERATIONS

/// result <- lhs AND rhs
pub fn bitand(sol: *@This(), lhs: usize, rhs: usize, result: usize) void {
    // If the lhs and rhs are true, the result must be true
    clause(sol, &.{ lhs, rhs, result }, &.{ 0, 0, 1 });
    // if the lhs is false, then the result must be false
    clause(sol, &.{ lhs, result }, &.{ 1, 0 });
    // If the rhs is false, then the result must be false
    clause(sol, &.{ rhs, result }, &.{ 1, 0 });
}

/// result <- lhs OR rhs
pub fn bitor(sol: *@This(), lhs: usize, rhs: usize, result: usize) void {
    // If the LHS is true, then the result MUST be true
    clause(sol, &.{ lhs, result }, &.{ 0, 1 });
    // If the RHS is true, then the result MUST be true
    clause(sol, &.{ rhs, result }, &.{ 0, 1 });
    // If the LHS and the RHS are false the result MUST be false
    clause(sol, &.{ lhs, rhs, result }, &.{ 1, 1, 0 });
}
// ----------------------------------------------------------------- ARITHMETIC

/// bitwise half adder, a + b = s + c * 2
pub fn halfadd(sol: *@This(), a: usize, b: usize, c: usize, s: usize) void {
    // a b | c s
    // ----+----
    // 0 0 | 0 0
    // 1 0 | 0 1
    // 0 1 | 0 1
    // 1 1 | 1 0

    clause(sol, &.{ a, c }, &.{ 1, 0 }); // 0 + x = carry x
    clause(sol, &.{ b, c }, &.{ 1, 0 }); // x + 0 = carry x
    clause(sol, &.{ a, b, c }, &.{ 0, 0, 1 }); // 1 + 1 = carry x

    clause(sol, &.{ c, s }, &.{ 0, 0 }); // carry 1 -> sum 0
    clause(sol, &.{ a, b, s }, &.{ 1, 1, 0 }); // 0 + 0 = sum 0
    clause(sol, &.{ a, b, s }, &.{ 1, 0, 1 }); // 0 + 1 = sum 1
    clause(sol, &.{ a, b, s }, &.{ 0, 1, 1 }); // 1 + 0 = sum 1

}

/// bitwise half subtractor, a - b = s - o * 2
pub fn halfsub(sol: *@This(), a: usize, b: usize, o: usize, s: usize) void {
    // a b | o s
    // ----+----
    // 0 0 | 0 0
    // 0 1 | 1 1
    // 1 0 | 0 1
    // 1 1 | 0 0

    clause(sol, &.{ a, o }, &.{ 0, 0 }); // 1-x -> borrow 0
    clause(sol, &.{ a, b, o }, &.{ 1, 1, 0 }); // 0-0 -> borrow 0
    clause(sol, &.{ a, b, o }, &.{ 1, 0, 1 }); // 0-1 -> borrow 1

    clause(sol, &.{ o, s }, &.{ 0, 1 }); // borrow 1 -> sum 1
    clause(sol, &.{ a, b, s }, &.{ 1, 1, 0 }); // 0-0 -> sum 0
    clause(sol, &.{ a, b, s }, &.{ 0, 1, 1 }); // 1-0 -> sum 1
    clause(sol, &.{ a, b, s }, &.{ 0, 0, 0 }); // 1-1 -> sum 0
}

/// bitwise full adder, a + b + i = s + c * 2
pub fn fulladd(sol: *@This(), a: usize, b: usize, i: usize, c: usize, s: usize) void {
    // a b i | c s
    // ------+----
    // 0 0 0 | 0 0
    // 0 0 1 | 0 1
    // 0 1 0 | 0 1
    // 0 1 1 | 1 0
    // 1 0 0 | 0 1
    // 1 0 1 | 1 0
    // 1 1 0 | 1 0
    // 1 1 1 | 1 1

    clause(sol, &.{ a, b, c }, &.{ 1, 1, 0 }); // 0+0+x -> carry 0
    clause(sol, &.{ a, i, c }, &.{ 1, 1, 0 }); // 0+x+0 -> carry 0
    clause(sol, &.{ b, i, c }, &.{ 1, 1, 0 }); // x+0+0 -> carry 0
    clause(sol, &.{ b, i, c }, &.{ 0, 0, 1 }); // x+1+1 -> carry 1
    clause(sol, &.{ a, i, c }, &.{ 0, 0, 1 }); // 1+x+1 -> carry 1
    clause(sol, &.{ a, b, c }, &.{ 0, 0, 1 }); // 1+1+x -> carry 1

    clause(sol, &.{ a, c, s }, &.{ 1, 0, 0 }); // 0+x+x & carry 1 -> sum 0
    clause(sol, &.{ b, c, s }, &.{ 1, 0, 0 }); // x+0+x & carry 1 -> sum 0
    clause(sol, &.{ i, c, s }, &.{ 1, 0, 0 }); // x+x+0 & carry 1 -> sum 0
    clause(sol, &.{ i, c, s }, &.{ 0, 1, 1 }); // x+x+1 & carry 0 -> sum 1
    clause(sol, &.{ b, c, s }, &.{ 0, 1, 1 }); // x+1+x & carry 0 -> sum 1
    clause(sol, &.{ a, c, s }, &.{ 0, 1, 1 }); // 1+x+x & carry 0 -> sum 1
    clause(sol, &.{ a, b, i, s }, &.{ 1, 1, 1, 0 }); // 0+0+0 -> sum 0
    clause(sol, &.{ a, b, i, s }, &.{ 0, 0, 0, 1 }); // 1+1+1 -> sum 1
}

/// bitwise full subtractor, a - b - i = s - o * 2
pub fn fullsub(sol: *@This(), a: usize, b: usize, i: usize, o: usize, s: usize) void {
    // a b i | o s
    // ------+----
    // 0 0 0 | 0 0
    // 0 0 1 | 1 1
    // 0 1 0 | 1 1
    // 0 1 1 | 1 0
    // 1 0 0 | 0 1
    // 1 0 1 | 0 0
    // 1 1 0 | 0 0
    // 1 1 1 | 1 1

    clause(sol, &.{ a, b, o }, &.{ 0, 1, 0 }); // 1-0-x -> borrow 0
    clause(sol, &.{ a, i, o }, &.{ 0, 1, 0 }); // 1-x-0 -> borrow 0
    clause(sol, &.{ b, i, o }, &.{ 1, 1, 0 }); // x-0-0 -> borrow 0
    clause(sol, &.{ b, i, o }, &.{ 0, 0, 1 }); // x-1-1 -> borrow 1
    clause(sol, &.{ a, i, o }, &.{ 1, 0, 1 }); // 0-x-1 -> borrow 1
    clause(sol, &.{ a, b, o }, &.{ 1, 0, 1 }); // 0-1-x -> borrow 1

    clause(sol, &.{ a, o, s }, &.{ 0, 0, 1 }); // 1-x-x & borrow 1 -> sum 1
    clause(sol, &.{ b, o, s }, &.{ 0, 1, 0 }); // x-1-x & borrow 0 -> sum 0
    clause(sol, &.{ i, o, s }, &.{ 0, 1, 0 }); // x-x-1 & borrow 0 -> sum 0
    clause(sol, &.{ i, o, s }, &.{ 1, 0, 1 }); // x-x-0 & borrow 1 -> sum 1
    clause(sol, &.{ b, o, s }, &.{ 1, 0, 1 }); // x-0-x & borrow 1 -> sum 1
    clause(sol, &.{ a, o, s }, &.{ 1, 1, 0 }); // 0-x-x & borrow 0 -> sum 0
    clause(sol, &.{ a, b, i, s }, &.{ 1, 0, 0, 0 }); // 0-1-1 -> sum 0
    clause(sol, &.{ a, b, i, s }, &.{ 0, 1, 1, 1 }); // 1-0-0 -> sum 1
}

// ---------------------------------------------------------------- CARDINALITY

// Constraint the cardinality of the input to be exactly one. If the "sat"
// argument is non-null, then the cardinality of input will NOT be constrained
// to be exactly one - instead, it will be constrained to be one if "sat" is
// one, and it will be constrained to NOT be one if "sat" is zero - this means
// that you can constrain sat to be zero or one to check for unsatisfiability
// in your problems where you are unsure of whether this is unsatisfiable, and
// you need that information to make informed decisions.

pub fn cardinalityOne(sol: *@This(), input: Bits, sat: ?usize) void {
    if (input.len == 0) {
        if (sat) |bit| {
            bitfalse(sol, bit);
        } else {
            assert(false); // NO.
        }
        return;
    }

    // If we are going to track whether the expression is
    // sat, we will keep track of <= 1 and >= 1 separately.
    const le_one = if (sat) |_| sol.alloc(1).idx else null;
    const ge_one = if (sat) |_| sol.alloc(1).idx else null;

    var bits: Bits = input;
    while (bits.len > 1) {
        // At most one bit is set in adjacent pairs
        for (0..bits.len / 2) |pair| {
            // --------------------------------- BACKWARD IMPLICATION OF le_one
            // EITHER: number of set bits is NOT <= 1
            if (le_one) |bit| part(sol, bit, 0);
            // OR: the left bit of the pair is FALSE
            part(sol, bits.at(pair * 2), 0);
            // OR: the right bit of the pair is FALSE
            part(sol, bits.at(pair * 2 + 1), 0);
            end(sol);
        }

        // Allocate bits for the next layer
        const next_count = (bits.len + 1) / 2;
        var next: Bits = sol.alloc(next_count);

        // Carry ORs of working bits to the next layer
        for (0..bits.len / 2) |pair| {
            const lhs = bits.at(pair * 2);
            const rhs = bits.at(pair * 2 + 1);
            bitor(sol, lhs, rhs, next.at(pair));
        }

        // Carry any extra bit to the next layer
        if (bits.len & 1 == 1) {
            const lhs = bits.at(bits.len - 1);
            const rhs = next.at(next.len - 1);
            biteql(sol, lhs, rhs);
        }

        // Swap the layers
        bits = next;
    }

    if (ge_one) |bit| {
        // -------------------------------------- FORWARD IMPLICATION OF ge_one
        // EITHER: number of bits set is >= 1
        part(sol, bit, 1);
        // OR: there are zero set bits
        part(sol, bits.at(0), 0);
        end(sol);
    }

    // ----------------------------------------- BACKWARD IMPLICATION OF ge_one
    // EITHER: number of set bits is NOT >= 1
    if (ge_one) |bit| part(sol, bit, 0);
    // OR: input cardinality is at least 1
    for (0..input.len) |off|
        part(sol, input.at(off), 1);
    end(sol);

    if (le_one) |bit| {
        for (0..input.len) |skip| {
            // ---------------------------------- FORWARD IMPLICATION OF le_one
            // EITHER: number of set bits is <= 1
            part(sol, bit, 1);
            // OR: at least one bit (except skip) is true
            for (0..input.len) |off| {
                if (off == skip) continue;
                part(sol, input.at(off), 1);
            }
            end(sol);
        }
    }

    if (sat) |bit| {
        // The solution is satisfied if and only if the number of bits set is
        // less than or equal to one, and also greater than or equal to one.
        const le = le_one orelse unreachable;
        const ge = ge_one orelse unreachable;
        bitand(sol, le, ge, bit);
    }
}

pub fn cardinalityAtMostOne(sol: *@This(), input: Bits, sat: ?usize) void {
    if (input.len == 0) {
        if (sat) |bit|
            bittrue(bit);
        return;
    }

    var bits: Bits = input;
    while (bits.len > 1) {
        // At most one bit is set in adjacent pairs
        for (0..bits.len / 2) |pair| {
            // ------------------------------------ BACKWARD IMPLICATION OF sat
            // EITHER: number of set bits is NOT <= 1
            if (sat) |bit| part(sol, bit, 0);
            // OR: the left bit of the pair is FALSE
            part(sol, bits.at(pair * 2), 0);
            // OR: the right bit of the pair is FALSE
            part(sol, bits.at(pair * 2 + 1), 0);
            end(sol);
        }

        // Allocate bits for the next layer
        const next_count = (bits.len + 1) / 2;
        var next: Bits = sol.alloc(next_count);

        // Carry ORs of working bits to the next layer
        for (0..bits.len / 2) |pair| {
            const lhs = bits.at(pair * 2);
            const rhs = bits.at(pair * 2 + 1);
            bitor(lhs, rhs, next.at(pair));
        }

        // Carry any extra bit to the next layer
        if (bits.len & 1 == 1) {
            const lhs = bits.at(bits.len - 1);
            const rhs = next.at(next.len - 1);
            biteql(lhs, rhs);
        }

        // Swap the layers
        bits = next;
    }

    if (sat) |bit| {
        for (0..input.len) |skip| {
            // ------------------------------------- FORWARD IMPLICATION OF sat
            // EITHER: number of set bits is <= 1
            part(sol, bit, 1);
            // OR: at least one bit (except skip) is true
            for (0..input.len) |off| {
                if (off == skip) continue;
                part(sol, input.at(off), 1);
            }
            end(sol);
        }
    }
}

// ----------------------------------------------------------- UNARY OPERATIONS

// TODO: REWRITE THIS FUNCTION

/// Constrain a unary number to be greater than or
/// equal to some known constant. Assumes that the
/// input is valid unary (eg. 1111111111100000000)
pub fn unaryConstrainGEVal(sol: *@This(), bits: Bits, val: usize) void {
    assert(val <= bits.len); // not possible to exceed
    if (val == 0) return; // everything is at least zero
    bittrue(sol, bits.at(val - 1));
}

// TODO: REWRITE THIS FUNCTION

/// Constrain a unary number to be less than or equal
/// to some known constant. Assumes that the input unary
/// number is valid unary. (eg. 11111111111100000000)
pub fn unaryConstrainLEVal(sol: *@This(), bits: Bits, val: usize) void {
    if (val > bits.len) return; // always the case
    bitfalse(sol, bits.at(val));
}

// TODO: REWRITE THIS FUNCTION BELOW

/// Constrains a unary number to be equal in value
/// to some known constant. Assumes that the input
/// is indeed valid unary. (eg. 11111111111110000)
pub fn unaryConstrainEQVal(sol: *@This(), bits: Bits, val: usize) void {
    unaryConstrainGEVal(sol, bits, val); // X >= val
    unaryConstrainLEVal(sol, bits, val); // X <= val
}

/// Constrain some number of bits to be a valid
/// unary number; eg, 10, 110, 11111100... etc.
pub fn unaryConstrain(sol: *@This(), bits: Bits) void {
    for (0..bits.len - 1) |off| {
        const lo = bits.at(off + 0);
        const hi = bits.at(off + 1);
        sol.clause(&.{ hi, lo }, &.{ 0, 1 });
    }
}

/// Returns a unary number totalizing the number
/// of "1" bits set in the input bits list. This
/// list does not need to be some known pattern.
pub fn unaryTotalize(sol: *@This(), bits: Bits) Bits {
    // The total is the same for 0 or 1 bits
    if (bits.len <= 1) return bits;

    // Split the input problem into two subproblems
    const half = bits.len / 2;
    const lhs = bits.slice(0, half);
    const rhs = bits.slice(half, bits.len);

    // Recursively sort each half into unary numbers
    const sorted_lhs = unaryTotalize(sol, lhs);
    const sorted_rhs = unaryTotalize(sol, rhs);

    // Merge the two pairs into one sorted list
    return unaryAdd(sol, sorted_lhs, sorted_rhs);
}

/// Constrain some number of bits to be the summation
/// of the lhs unary number and the rhs unary number.
/// Assumes the inputs are valid unary. (eg. 1100000)
pub fn unaryAdd(sol: *@This(), lhs: Bits, rhs: Bits) Bits {
    // Create a new output list of bits
    const length = lhs.len + rhs.len;
    const out = sol.alloc(length);

    // Each lhs bit implies the corresponding out bit -
    // If we have 3 + 2, the output (5) is at least 3.
    for (0..lhs.len) |off|
        sol.clause(&.{ lhs.at(off), out.at(off) }, &.{ 0, 1 });

    // Each rhs bit implies the corresponding out bit -
    // If we have 3 + 2, the output (5) is at least 2.
    for (0..rhs.len) |off|
        sol.clause(&.{ rhs.at(off), out.at(off) }, &.{ 0, 1 });

    // Each false lhs bit implies the corresponding false out bit -
    // If we have 1110 + 1100, the output (11111000) is at most 7.
    for (0..lhs.len) |off| {
        const lhs_bit = lhs.at(off);
        const out_bit = out.at(rhs.len + off);
        sol.clause(&.{ out_bit, lhs_bit }, &.{ 0, 1 });
    }

    // Each false rhs bit implies the corresponding false out bit -
    // If we have 1110 + 1100, the output (11111000) is at most 6.
    for (0..rhs.len) |off| {
        const rhs_bit = rhs.at(off);
        const out_bit = out.at(lhs.len + off);
        sol.clause(&.{ out_bit, rhs_bit }, &.{ 0, 1 });
    }

    for (0..lhs.len) |l_off| {
        for (0..rhs.len) |r_off| {
            const l_bit = lhs.at(l_off);
            const r_bit = rhs.at(r_off);

            // If lhs has LT lhs_off bits and rhs has LT rhs_off bits,
            // the total must have no more than lhs_off + rhs_off bits.
            // LOGIC: (!l_bit & !r_bit) -> !s_bit
            // CNF: l_bit | r_bit | !s_bit
            // UPPER BOUND
            const lt_bit = out.at(l_off + r_off + 0);
            clause(sol, &.{ l_bit, r_bit, lt_bit }, &.{ 1, 1, 0 });

            // If lhs has GE lhs_off bits and rhs has GE rhs_off bits,
            // then the total must have at least lhs_off + rhs_off bits.
            // LOGIC: (l_bit & r_bit) -> s_bit
            // CNF: !l_bit | !r_bit | s_bit
            // LOWER BOUND
            const ge_bit = out.at(l_off + r_off + 1);
            clause(sol, &.{ l_bit, r_bit, ge_bit }, &.{ 0, 0, 1 });
        }
    }

    return out;
}
