const std = @import("std");
const assert = std.debug.assert;
const Solver = @import("Solver.zig");

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
pub fn clause(
    solver: *Solver,
    index_list: []const usize,
    identity_list: []const u1,
) void {
    // Write out every part of the clause in a loop
    for (index_list, identity_list) |index, identity| {
        part(solver, index, identity);
    }

    // Write out the termination for the clause
    end(solver);
}

// Write a portion of one CNF clause with an index & identity
pub fn part(solver: *Solver, index: usize, identity: u1) void {
    // Record any returned error, but don't return it
    switch (identity) {
        1 => solver.add(@as(i32, @intCast(index))),
        0 => solver.add(-@as(i32, @intCast(index))),
    }
}

// End the current CNF clause (can be replaced with clause())
pub fn end(solver: *Solver) void {
    solver.add(0);
}

// --------------------------------------------------------- BITWISE IDENTITIES

// val IS set
pub fn bitval(solver: *Solver, val: usize, set: u1) void {
    clause(solver, &.{val}, &.{set});
}

// val IS TRUE
pub fn bittrue(solver: *Solver, val: usize) void {
    clause(solver, &.{val}, &.{1});
}

// val IS FALSE
pub fn bitfalse(solver: *Solver, val: usize) void {
    clause(solver, &.{val}, &.{0});
}

// -------------------------------------------------- SINGLE BITWISE OPERATIONS

/// lhs *LOGICALLY* IMPLIES rhs
pub fn bitimp(solver: *Solver, lhs: usize, rhs: usize) void {
    clause(solver, &.{ lhs, rhs }, &.{ 0, 1 });
}

/// lhs NOT EQUIVALENT TO rhs
pub fn bitnot(solver: *Solver, lhs: usize, rhs: usize) void {
    clause(solver, &.{ lhs, rhs }, &.{ 0, 0 });
    clause(solver, &.{ lhs, rhs }, &.{ 1, 1 });
}

/// lhs EQUIVALENT TO rhs
pub fn biteql(solver: *Solver, lhs: usize, rhs: usize) void {
    clause(solver, &.{ lhs, rhs }, &.{ 0, 1 });
    clause(solver, &.{ lhs, rhs }, &.{ 1, 0 });
}

pub fn bitop1(solver: *Solver, a: usize, b: usize, t: [2]u1) void {
    clause(solver, &.{ a, b }, &.{ 1, t[0] });
    clause(solver, &.{ a, b }, &.{ 0, t[1] });
}

// -------------------------------------------------- DOUBLE BITWISE OPERATIONS

/// result <- lhs NOR rhs
pub fn bitnor(solver: *Solver, lhs: usize, rhs: usize, result: usize) void {
    bitop2(solver, lhs, rhs, result, .{ 1, 0, 0, 0 });
}

/// result <- lhs AND rhs
pub fn bitand(solver: *Solver, lhs: usize, rhs: usize, result: usize) void {
    // If the lhs and rhs are true, the result must be true
    clause(solver, &.{ lhs, rhs, result }, &.{ 0, 0, 1 });
    // if the lhs is false, then the result must be false
    clause(solver, &.{ lhs, result }, &.{ 1, 0 });
    // If the rhs is false, then the result must be false
    clause(solver, &.{ rhs, result }, &.{ 1, 0 });
}

/// result <- lhs NAND rhs
pub fn bitnand(solver: *Solver, lhs: usize, rhs: usize, result: usize) void {
    bitop2(solver, lhs, rhs, result, .{ 1, 1, 1, 0 });
}

/// result <- lhs OR rhs
pub fn bitor(solver: *Solver, lhs: usize, rhs: usize, result: usize) void {
    // If the LHS is true, then the result MUST be true
    clause(solver, &.{ lhs, result }, &.{ 0, 1 });
    // If the RHS is true, then the result MUST be true
    clause(solver, &.{ rhs, result }, &.{ 0, 1 });
    // If the LHS and the RHS are false the result MUST be false
    clause(solver, &.{ lhs, rhs, result }, &.{ 1, 1, 0 });
}

/// result <- lhs XNOR rhs
pub fn bitxnor(solver: *Solver, lhs: usize, rhs: usize, result: usize) void {
    bitop2(solver, lhs, rhs, result, .{ 1, 0, 0, 1 });
}

/// result <- lhs XOR rhs
pub fn bitxor(solver: *Solver, lhs: usize, rhs: usize, result: usize) void {
    bitop2(solver, lhs, rhs, result, .{ 0, 1, 1, 0 });
}

pub fn bitop2(solver: *Solver, a: usize, b: usize, c: usize, t: [4]u1) void {
    clause(solver, &.{ a, b, c }, &.{ 1, 1, t[0] });
    clause(solver, &.{ a, b, c }, &.{ 1, 0, t[1] });
    clause(solver, &.{ a, b, c }, &.{ 0, 1, t[2] });
    clause(solver, &.{ a, b, c }, &.{ 0, 0, t[3] });
}

// -------------------------------------------------- TRIPLE BITWISE OPERATIONS

/// res <- cond ? lhs : rhs
pub fn bitsel(solver: *Solver, cond: usize, lhs: usize, rhs: usize, res: usize) void {
    bitop3(solver, cond, lhs, rhs, res, .{ 0, 1, 0, 1, 0, 0, 1, 1 });
}

/// result <- a ^ b ^ c
pub fn bit3xor(solver: *Solver, a: usize, b: usize, c: usize, result: usize) void {
    bitop3(solver, a, b, c, result, .{ 0, 1, 1, 0, 1, 0, 0, 1 });
}

pub fn bitop3(solver: *Solver, a: usize, b: usize, c: usize, d: usize, t: [8]u1) void {
    clause(solver, &.{ a, b, c, d }, &.{ 1, 1, 1, t[0] });
    clause(solver, &.{ a, b, c, d }, &.{ 1, 1, 0, t[1] });
    clause(solver, &.{ a, b, c, d }, &.{ 1, 0, 1, t[2] });
    clause(solver, &.{ a, b, c, d }, &.{ 1, 0, 0, t[3] });
    clause(solver, &.{ a, b, c, d }, &.{ 0, 1, 1, t[4] });
    clause(solver, &.{ a, b, c, d }, &.{ 0, 1, 0, t[5] });
    clause(solver, &.{ a, b, c, d }, &.{ 0, 0, 1, t[6] });
    clause(solver, &.{ a, b, c, d }, &.{ 0, 0, 0, t[7] });
}

// ----------------------------------------------------------------- ARITHMETIC

/// bitwise half adder, a + b = s + c * 2
pub fn halfadd(solver: *Solver, a: usize, b: usize, c: usize, s: usize) void {
    // a b | c s
    // ----+----
    // 0 0 | 0 0
    // 1 0 | 0 1
    // 0 1 | 0 1
    // 1 1 | 1 0

    clause(solver, &.{ a, c }, &.{ 1, 0 }); // 0 + x = carry x
    clause(solver, &.{ b, c }, &.{ 1, 0 }); // x + 0 = carry x
    clause(solver, &.{ a, b, c }, &.{ 0, 0, 1 }); // 1 + 1 = carry x

    clause(solver, &.{ c, s }, &.{ 0, 0 }); // carry 1 -> sum 0
    clause(solver, &.{ a, b, s }, &.{ 1, 1, 0 }); // 0 + 0 = sum 0
    clause(solver, &.{ a, b, s }, &.{ 1, 0, 1 }); // 0 + 1 = sum 1
    clause(solver, &.{ a, b, s }, &.{ 0, 1, 1 }); // 1 + 0 = sum 1

}

/// bitwise half subtractor, a - b = s - o * 2
pub fn halfsub(solver: *Solver, a: usize, b: usize, o: usize, s: usize) void {
    // a b | o s
    // ----+----
    // 0 0 | 0 0
    // 0 1 | 1 1
    // 1 0 | 0 1
    // 1 1 | 0 0

    clause(solver, &.{ a, o }, &.{ 0, 0 }); // 1-x -> borrow 0
    clause(solver, &.{ a, b, o }, &.{ 1, 1, 0 }); // 0-0 -> borrow 0
    clause(solver, &.{ a, b, o }, &.{ 1, 0, 1 }); // 0-1 -> borrow 1

    clause(solver, &.{ o, s }, &.{ 0, 1 }); // borrow 1 -> sum 1
    clause(solver, &.{ a, b, s }, &.{ 1, 1, 0 }); // 0-0 -> sum 0
    clause(solver, &.{ a, b, s }, &.{ 0, 1, 1 }); // 1-0 -> sum 1
    clause(solver, &.{ a, b, s }, &.{ 0, 0, 0 }); // 1-1 -> sum 0
}

/// bitwise full adder, a + b + i = s + c * 2
pub fn fulladd(solver: *Solver, a: usize, b: usize, i: usize, c: usize, s: usize) void {
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

    clause(solver, &.{ a, b, c }, &.{ 1, 1, 0 }); // 0+0+x -> carry 0
    clause(solver, &.{ a, i, c }, &.{ 1, 1, 0 }); // 0+x+0 -> carry 0
    clause(solver, &.{ b, i, c }, &.{ 1, 1, 0 }); // x+0+0 -> carry 0
    clause(solver, &.{ b, i, c }, &.{ 0, 0, 1 }); // x+1+1 -> carry 1
    clause(solver, &.{ a, i, c }, &.{ 0, 0, 1 }); // 1+x+1 -> carry 1
    clause(solver, &.{ a, b, c }, &.{ 0, 0, 1 }); // 1+1+x -> carry 1

    clause(solver, &.{ a, c, s }, &.{ 1, 0, 0 }); // 0+x+x & carry 1 -> sum 0
    clause(solver, &.{ b, c, s }, &.{ 1, 0, 0 }); // x+0+x & carry 1 -> sum 0
    clause(solver, &.{ i, c, s }, &.{ 1, 0, 0 }); // x+x+0 & carry 1 -> sum 0
    clause(solver, &.{ i, c, s }, &.{ 0, 1, 1 }); // x+x+1 & carry 0 -> sum 1
    clause(solver, &.{ b, c, s }, &.{ 0, 1, 1 }); // x+1+x & carry 0 -> sum 1
    clause(solver, &.{ a, c, s }, &.{ 0, 1, 1 }); // 1+x+x & carry 0 -> sum 1
    clause(solver, &.{ a, b, i, s }, &.{ 1, 1, 1, 0 }); // 0+0+0 -> sum 0
    clause(solver, &.{ a, b, i, s }, &.{ 0, 0, 0, 1 }); // 1+1+1 -> sum 1
}

/// bitwise full subtractor, a - b - i = s - o * 2
pub fn fullsub(solver: *Solver, a: usize, b: usize, i: usize, o: usize, s: usize) void {
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

    clause(solver, &.{ a, b, o }, &.{ 0, 1, 0 }); // 1-0-x -> borrow 0
    clause(solver, &.{ a, i, o }, &.{ 0, 1, 0 }); // 1-x-0 -> borrow 0
    clause(solver, &.{ b, i, o }, &.{ 1, 1, 0 }); // x-0-0 -> borrow 0
    clause(solver, &.{ b, i, o }, &.{ 0, 0, 1 }); // x-1-1 -> borrow 1
    clause(solver, &.{ a, i, o }, &.{ 1, 0, 1 }); // 0-x-1 -> borrow 1
    clause(solver, &.{ a, b, o }, &.{ 1, 0, 1 }); // 0-1-x -> borrow 1

    clause(solver, &.{ a, o, s }, &.{ 0, 0, 1 }); // 1-x-x & borrow 1 -> sum 1
    clause(solver, &.{ b, o, s }, &.{ 0, 1, 0 }); // x-1-x & borrow 0 -> sum 0
    clause(solver, &.{ i, o, s }, &.{ 0, 1, 0 }); // x-x-1 & borrow 0 -> sum 0
    clause(solver, &.{ i, o, s }, &.{ 1, 0, 1 }); // x-x-0 & borrow 1 -> sum 1
    clause(solver, &.{ b, o, s }, &.{ 1, 0, 1 }); // x-0-x & borrow 1 -> sum 1
    clause(solver, &.{ a, o, s }, &.{ 1, 1, 0 }); // 0-x-x & borrow 0 -> sum 0
    clause(solver, &.{ a, b, i, s }, &.{ 1, 0, 0, 0 }); // 0-1-1 -> sum 0
    clause(solver, &.{ a, b, i, s }, &.{ 0, 1, 1, 1 }); // 1-0-0 -> sum 1
}

// ---------------------------------------------------------------- CARDINALITY

// Constraint the cardinality of the input to be exactly one. If the "sat"
// argument is non-null, then the cardinality of input will NOT be constrained
// to be exactly one - instead, it will be constrained to be one if "sat" is
// one, and it will be constrained to NOT be one if "sat" is zero - this means
// that you can constrain sat to be zero or one to check for unsatisfiability
// in your problems where you are unsure of whether this is unsatisfiable, and
// you need that information to make informed decisions.

pub fn cardinalityOne(solver: *Solver, input: Bits, sat: ?usize) void {
    if (input.len == 0) {
        if (sat) |bit| {
            bitfalse(solver, bit);
        } else {
            assert(false); // NO.
        }
        return;
    }

    // If we are going to track whether the expression is
    // sat, we will keep track of <= 1 and >= 1 separately.
    const le_one = if (sat) |_| solver.alloc(1).idx else null;
    const ge_one = if (sat) |_| solver.alloc(1).idx else null;

    var bits: Bits = input;
    while (bits.len > 1) {
        // At most one bit is set in adjacent pairs
        for (0..bits.len / 2) |pair| {
            // --------------------------------- BACKWARD IMPLICATION OF le_one
            // EITHER: number of set bits is NOT <= 1
            if (le_one) |bit| part(solver, bit, 0);
            // OR: the left bit of the pair is FALSE
            part(solver, bits.at(pair * 2), 0);
            // OR: the right bit of the pair is FALSE
            part(solver, bits.at(pair * 2 + 1), 0);
            end(solver);
        }

        // Allocate bits for the next layer
        const next_count = (bits.len + 1) / 2;
        var next: Bits = solver.alloc(next_count);

        // Carry ORs of working bits to the next layer
        for (0..bits.len / 2) |pair| {
            const lhs = bits.at(pair * 2);
            const rhs = bits.at(pair * 2 + 1);
            bitor(solver, lhs, rhs, next.at(pair));
        }

        // Carry any extra bit to the next layer
        if (bits.len & 1 == 1) {
            const lhs = bits.at(bits.len - 1);
            const rhs = next.at(next.len - 1);
            biteql(solver, lhs, rhs);
        }

        // Swap the layers
        bits = next;
    }

    if (ge_one) |bit| {
        // -------------------------------------- FORWARD IMPLICATION OF ge_one
        // EITHER: number of bits set is >= 1
        part(solver, bit, 1);
        // OR: there are zero set bits
        part(solver, bits.at(0), 0);
        end(solver);
    }

    // ----------------------------------------- BACKWARD IMPLICATION OF ge_one
    // EITHER: number of set bits is NOT >= 1
    if (ge_one) |bit| part(solver, bit, 0);
    // OR: input cardinality is at least 1
    for (0..input.len) |off|
        part(solver, input.at(off), 1);
    end(solver);

    if (le_one) |bit| {
        for (0..input.len) |skip| {
            // ---------------------------------- FORWARD IMPLICATION OF le_one
            // EITHER: number of set bits is <= 1
            part(solver, bit, 1);
            // OR: at least one bit (except skip) is true
            for (0..input.len) |off| {
                if (off == skip) continue;
                part(solver, input.at(off), 1);
            }
            end(solver);
        }
    }

    if (sat) |bit| {
        // The solution is satisfied if and only if the number of bits set is
        // less than or equal to one, and also greater than or equal to one.
        const le = le_one orelse unreachable;
        const ge = ge_one orelse unreachable;
        bitand(solver, le, ge, bit);
    }
}

pub fn cardinalityAtMostOne(solver: *Solver, input: Bits, sat: ?usize) void {
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
            if (sat) |bit| part(solver, bit, 0);
            // OR: the left bit of the pair is FALSE
            part(solver, bits.at(pair * 2), 0);
            // OR: the right bit of the pair is FALSE
            part(solver, bits.at(pair * 2 + 1), 0);
            end(solver);
        }

        // Allocate bits for the next layer
        const next_count = (bits.len + 1) / 2;
        var next: Bits = solver.alloc(next_count);

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
            part(solver, bit, 1);
            // OR: at least one bit (except skip) is true
            for (0..input.len) |off| {
                if (off == skip) continue;
                part(solver, input.at(off), 1);
            }
            end(solver);
        }
    }
}

// ----------------------------------------------------------- UNARY OPERATIONS

/// Returns bits that are constrained to be the maximum
/// of some number of unary numbers. Assumes that these
/// input bits are indeed unary numbers. (ie. 11111100)
pub fn unaryMax(solver: *Solver, input: []const Bits, output: Bits) void {
    // Ensure all lengths are the same
    for (input) |bit_list|
        assert(bit_list.len == output.len);

    // One bit in the input implies the corresponding bit
    for (input) |bit_list|
        for (0..output.len) |off|
            bitimp(bit_list.at(off), output.at(off));

    for (0..output.len) |off| {
        for (input) |bit_list|
            // It could be the case the unary bit is true
            part(solver, bit_list.at(off), 1);
        // It could be the case the result bit is false
        part(solver, output.at(off), 0);
        // The output bit is false if every bit is false
        end(solver);
    }
}

/// Returns bits that are constrained to be the minimum
/// of some number of unary numbers. Assumes that these
/// input bits are indeed unary numbers. (ie. 11111100)
pub fn unaryMin(solver: *Solver, input: []const Bits, output: Bits) void {
    // Ensure all lengths are the same
    for (input) |bit_list|
        assert(bit_list.len == output.len);

    // False in the input implies the corresponding false
    for (input) |bit_list|
        for (0..output.len) |off|
            // NOT A IMPLIES NOT B === B IMPLIES A
            bitimp(output.at(off), bit_list.at(off));

    for (0..output.len) |off| {
        for (input) |bit_list|
            // It could be the case the unary bit is false
            part(solver, bit_list.at(off), 0);
        // It could be the case the result bit is true
        part(solver, output.at(off), 1);
        // The output bit is true if every bit is true
        end(solver);
    }
}

/// Saturating decrement of some unary number. Assumes that
/// the input bits are indeed a unary number. (ie. 1111100)
pub fn unarySatDec(solver: *Solver, input: Bits, output: Bits) void {
    // Ensure all lengths are the same
    assert(output.len == input.len);

    // Each output bit is equal to one shifted input bit
    for (0..output.len -| 1) |off|
        biteql(solver, output.at(off), input.at(off + 1));

    // The last bit is always false
    if (output.len >= 1)
        bitfalse(solver, output.at(output.len - 1));
}

/// Saturating increment of some unary number. Assumes that
/// the input bits are indeed a unary number. (ie. 1111000)
pub fn unarySatInc(solver: *Solver, input: Bits, output: Bits) void {
    // Ensure all lengths are the same
    assert(output.len == input.len);

    // Each output bit is equal to one shifted input bit
    for (0..output.len -| 1) |off|
        biteql(solver, output.at(off + 1), input.at(off));

    // The first bit is always true
    if (output.len >= 1)
        bittrue(solver, output.at(0));
}

/// Constrains one "less_equal" bit to be equivalent to the
/// lhs unary number being at most the value of the rhs unary.
/// Assumes the lhs and rhs are both valid unary. (ie. 1110)
pub fn unaryLE(solver: *Solver, lhs: Bits, rhs: Bits, le: usize) void {
    // Ensure all lengths are the same
    assert(lhs.len == rhs.len);

    // Pairwise comparison would forbid this:
    // A: 11111111111111111111110000000000000
    // B: 11111111000000000000000000000000000
    // le IMPLIES (rhs bits IMPLIES lhs bits)
    for (0..lhs.len) |off| clause(
        solver,
        &.{ le, lhs.at(off), rhs.at(off) },
        &.{ 0, 0, 1 },
    );
}

/// Constrain the lhs unary number to be less than or equal
/// to the rhs unary number. Assumes that the input for the
/// lhs and rhs are indeed valid unary. (ie. 1111111110000)
pub fn unaryConstrainLE(solver: *Solver, lhs: Bits, rhs: Bits) void {
    // Ensure all lengths are the same
    assert(lhs.len == rhs.len);

    // Pairwise comparison would forbid this:
    // A: 11111111111111111111110000000000000
    // B: 11111111000000000000000000000000000
    // rhs bits imply the equivalent lhs bits
    for (0..lhs.len) |off|
        bitimp(solver, rhs.at(off), lhs.at(off));
}

/// Constrains one "not_equal" bit to be equivalent to the
/// lhs unary number being not equal to the rhs unary number.
/// Assumes that the lhs and rhs are both valid unary (ie. 1110)
pub fn unaryNE(solver: *Solver, lhs: Bits, rhs: Bits, ne: usize) void {
    // Ensure all lengths are the same
    assert(lhs.len == rhs.len);

    // Allocate auxilliary bits to encode bit equality
    const xors: Bits = solver.alloc(lhs.len);

    // Constrain xors to be bitwise lhs XOR rhs
    for (0..lhs.len) |off|
        bitxor(solver, lhs.at(off), rhs.at(off), xors.at(off));

    // If an XOR is true, it implies that the numbers aren't equal
    for (0..lhs.len) |off|
        bitimp(solver, xors.at(off), ne);

    // At least one of the XORs must be true to be not equal
    for (0..lhs.len) |off|
        part(solver, solver, xors.at(off), 1);
    part(solver, solver, ne, 0);
    end(solver);
}

/// Constrain the lhs unary number to be different to the
/// rhs unary number. Assumes the input for the lhs unary
/// number and rhs number are valid unary. (ie. 11100000)
pub fn unaryConstrainNE(solver: *Solver, lhs: Bits, rhs: Bits) void {
    // Ensure all lengths are the same
    assert(lhs.len == rhs.len);

    // Allocate auxilliary bits to encode bit equality
    const xors: Bits = solver.alloc(lhs.len);

    // Constrain xors to be bitwise lhs XOR rhs
    for (0..lhs.len) |off|
        bitxor(lhs.at(off), rhs.at(off), xors.at(off));

    // Constrain at least one of the xors to be true
    for (0..lhs.len) |off|
        part(solver, xors.at(off), 1);
    end(solver);
}

/// Constrains one "less_than" bit to be equivalent to the
/// lhs unary number being strictly less than the rhs unary.
/// Assumes the lhs and rhs are both valid unary. (ie. 1110)
pub fn unaryLT(solver: *Solver, lhs: Bits, rhs: Bits, lt: usize) void {
    // Strictly "less than" is the same as saying "less than
    // or equal" combined with a "not equal" constraint.
    const le_bit = solver.alloc(1).idx;
    unaryLE(lhs, rhs, le_bit);
    const ne_bit = solver.alloc(1).idx;
    unaryNE(lhs, rhs, ne_bit);
    // Both LE AND NE are required for LT
    bitand(solver, le_bit, ne_bit, lt);
}

/// Constrain the lhs unary number to be strictly less than
/// the rhs unary number. Assumes both inputted lhs and rhs
/// numbers to be valid unary. (ie. 1111111111111110000000)
pub fn unaryConstrainLT(solver: *Solver, lhs: Bits, rhs: Bits) void {
    // Strictly "less than" is the same as saying "less than
    // or equal" combined with a "not equal" constraint.
    unaryConstrainLE(solver, lhs, rhs);
    unaryConstrainNE(solver, lhs, rhs);
}

/// Constrain a unary number to be greater than or
/// equal to some known constant. Assumes that the
/// input is valid unary (eg. 1111111111100000000)
pub fn unaryConstrainGEVal(solver: *Solver, bits: Bits, val: usize) void {
    assert(val <= bits.len); // not possible to exceed
    if (val == 0) return; // everything is at least zero
    bittrue(solver, bits.at(val - 1));
}

/// Constrain a unary number to be strictly less than
/// some known constant. Assumes that the input unary
/// number is valid unary. (eg. 11111111111100000000)
pub fn unaryConstrainLTVal(solver: *Solver, bits: Bits, val: usize) void {
    assert(val != 0); // not possible to be less than zero
    if (val >= bits.len) return; // always the case
    bitfalse(solver, bits.at(val - 1));
}

/// Constrain a unary number to be less than or equal
/// to some known constant. Assumes that the input unary
/// number is valid unary. (eg. 11111111111100000000)
pub fn unaryConstrainLEVal(solver: *Solver, bits: Bits, val: usize) void {
    if (val > bits.len) return; // always the case
    bitfalse(solver, bits.at(val));
}

/// Constrains a unary number to be equal in value
/// to some known constant. Assumes that the input
/// is indeed valid unary. (eg. 11111111111110000)
pub fn unaryConstrainEQVal(solver: *Solver, bits: Bits, val: usize) void {
    unaryConstrainGEVal(solver, bits, val); // X >= val
    unaryConstrainLEVal(solver, bits, val); // X <= val
}

/// Constrain some number of bits to be a valid
/// unary number; eg, 10, 110, 11111100... etc.
pub fn unaryConstrain(solver: *Solver, bits: Bits) void {
    for (0..bits.len - 1) |off| {
        const lo_bit = bits.at(off + 0);
        const hi_bit = bits.at(off + 1);
        bitimp(solver, hi_bit, lo_bit);
    }
}

/// Returns a unary number totalizing the number
/// of "1" bits set in the input bits list. This
/// list does not need to be some known pattern.
pub fn unaryTotalize(solver: *Solver, bits: Bits) Bits {
    // The total is the same for 0 or 1 bits
    if (bits.len <= 1) return bits;

    // Split the input problem into two subproblems
    const half = bits.len / 2;
    const lhs = bits.slice(0, half);
    const rhs = bits.slice(half, bits.len);

    // Recursively sort each half into unary numbers
    const sorted_lhs = unaryTotalize(solver, lhs);
    const sorted_rhs = unaryTotalize(solver, rhs);

    // Merge the two pairs into one sorted list
    return unaryAdd(solver, sorted_lhs, sorted_rhs);
}

/// Constrain some number of bits to be the summation
/// of the lhs unary number and the rhs unary number.
/// Assumes the inputs are valid unary. (eg. 1100000)
pub fn unaryAdd(solver: *Solver, lhs: Bits, rhs: Bits) Bits {
    // Create a new output list of bits
    const length = lhs.len + rhs.len;
    const out = solver.alloc(length);

    // Each lhs bit implies the corresponding out bit -
    // If we have 3 + 2, the output (5) is at least 3.
    for (0..lhs.len) |off|
        bitimp(solver, lhs.at(off), out.at(off));

    // Each rhs bit implies the corresponding out bit -
    // If we have 3 + 2, the output (5) is at least 2.
    for (0..rhs.len) |off|
        bitimp(solver, rhs.at(off), out.at(off));

    // Each false lhs bit implies the corresponding false out bit -
    // If we have 1110 + 1100, the output (11111000) is at most 7.
    for (0..lhs.len) |off| {
        const lhs_bit = lhs.at(off);
        const out_bit = out.at(rhs.len + off);
        bitimp(solver, out_bit, lhs_bit);
    }

    // Each false rhs bit implies the corresponding false out bit -
    // If we have 1110 + 1100, the output (11111000) is at most 6.
    for (0..rhs.len) |off| {
        const rhs_bit = rhs.at(off);
        const out_bit = out.at(lhs.len + off);
        bitimp(solver, out_bit, rhs_bit);
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
            clause(solver, &.{ l_bit, r_bit, lt_bit }, &.{ 1, 1, 0 });

            // If lhs has GE lhs_off bits and rhs has GE rhs_off bits,
            // then the total must have at least lhs_off + rhs_off bits.
            // LOGIC: (l_bit & r_bit) -> s_bit
            // CNF: !l_bit | !r_bit | s_bit
            // LOWER BOUND
            const ge_bit = out.at(l_off + r_off + 1);
            clause(solver, &.{ l_bit, r_bit, ge_bit }, &.{ 0, 0, 1 });
        }
    }

    return out;
}

// ------------------------------------------------------- MULTI-BIT OPERATIONS

// N-value bitwise OR; result <- bits[0] OR bits[1] OR bits[2] ...
pub fn multiBitOR(solver: *Solver, bits: Bits, result: usize) void {
    for (0..bits.len) |off|
        // If any bit is true, the result is true
        bitimp(solver, bits.at(off), result);

    for (0..bits.len) |off|
        // Either one of the bits is true
        part(solver, bits.at(off), 1);
    // Otherwise the result is false
    part(solver, result, 0);
    // The result is false if every bit is false
    end(solver);
}
