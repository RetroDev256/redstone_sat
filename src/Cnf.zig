const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

clause_writer: *Io.Writer,
variable_count: u64,
clause_count: u64,
part_count: u64,

// Create a new CNF encoder
pub fn init(clause_writer: *Io.Writer) @This() {
    return .{
        .clause_writer = clause_writer,
        .variable_count = 0,
        .clause_count = 0,
        .part_count = 0,
    };
}

// Flush out the written CNF clauses
pub fn flush(self: *const @This()) !void {
    // Must be done encoding any partial clauses
    assert(self.part_count == 0);
    try self.clause_writer.flush();
}

// Deinitialize the CNF encoder
pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

// Write out the CNF header for this instant
pub fn header(self: *const @This(), writer: *Io.Writer) !void {
    // Must be done encoding any partial clauses
    assert(self.part_count == 0);
    // The header contains variable and clause count
    try writer.print("p cnf {} {}\n", .{
        self.variable_count,
        self.clause_count,
    });
}

// ------------------------------------------------------- BIT LIST RECORD TYPE

pub const Bits = struct {
    idx: u64,
    len: u64,

    pub fn init(idx: u64, len: u64) @This() {
        return .{ .idx = idx, .len = len };
    }

    pub fn at(self: @This(), off: u64) u64 {
        assert(off < self.len);
        return self.idx + off;
    }

    pub fn slice(self: @This(), start: u64, limit: ?u64) @This() {
        const end_idx: u64 = limit orelse self.len;
        assert(start <= self.len and end_idx <= self.len);
        return .init(self.idx + start, end_idx - start);
    }
};

// Allocate some number of unconstrained bits
pub fn alloc(self: *@This(), count: u64) Bits {
    const start = self.variable_count;
    self.variable_count += count;
    return .init(start + 1, count);
}

// ------------------------------------------------------------ CLAUSE ENCODING

// Encode a complete CNF clause with slices
pub fn clause(
    self: *@This(),
    index_list: []const u64,
    identity_list: []const u1,
) !void {
    // Write out every part of the clause in a loop
    for (index_list, identity_list) |index, identity| {
        try self.part(index, identity);
    }

    // Write out the termination for the clause
    try self.end();
}

// Write a portion of one CNF clause with an index & identity
pub fn part(self: *@This(), index: u64, identity: u1) !void {
    // Record any returned error, but don't return it
    switch (identity) {
        1 => try self.clause_writer.print("{} ", .{index}),
        0 => try self.clause_writer.print("-{} ", .{index}),
    }

    // Record that we wrote one more part of the clause
    self.part_count += 1;
}

// End the current CNF clause (can be replaced with clause())
pub fn end(self: *@This()) !void {
    // Verify that we have at least one clause term
    assert(self.part_count != 0);
    // Write out the end of this clause in CNF
    try self.clause_writer.writeAll("0\n");
    // Update the number of clauses in the total CNF
    self.clause_count += 1;
    // We are completed with this multi-part clause
    self.part_count = 0;
}

// --------------------------------------------------------- BITWISE IDENTITIES

// val IS set
pub fn bitval(self: *@This(), val: u64, set: u1) !void {
    try self.clause(&.{val}, &.{set});
}

// val IS TRUE
pub fn bittrue(self: *@This(), val: u64) !void {
    try self.clause(&.{val}, &.{1});
}

// val IS FALSE
pub fn bitfalse(self: *@This(), val: u64) !void {
    try self.clause(&.{val}, &.{0});
}

// -------------------------------------------------- SINGLE BITWISE OPERATIONS

/// lhs *LOGICALLY* IMPLIES rhs
pub fn bitimp(self: *@This(), lhs: u64, rhs: u64) !void {
    try self.clause(&.{ lhs, rhs }, &.{ 0, 1 });
}

/// lhs NOT EQUIVALENT TO rhs
pub fn bitnot(self: *@This(), lhs: u64, rhs: u64) !void {
    try self.clause(&.{ lhs, rhs }, &.{ 0, 0 });
    try self.clause(&.{ lhs, rhs }, &.{ 1, 1 });
}

/// lhs EQUIVALENT TO rhs
pub fn biteql(self: *@This(), lhs: u64, rhs: u64) !void {
    try self.clause(&.{ lhs, rhs }, &.{ 0, 1 });
    try self.clause(&.{ lhs, rhs }, &.{ 1, 0 });
}

pub fn bitop1(self: *@This(), a: u64, b: u64, t: [2]u1) !void {
    try self.clause(&.{ a, b }, &.{ 1, t[0] });
    try self.clause(&.{ a, b }, &.{ 0, t[1] });
}

// -------------------------------------------------- DOUBLE BITWISE OPERATIONS

/// result <- lhs NOR rhs
pub fn bitnor(self: *@This(), lhs: u64, rhs: u64, result: u64) !void {
    try self.bitop2(lhs, rhs, result, .{ 1, 0, 0, 0 });
}

/// result <- lhs AND rhs
pub fn bitand(self: *@This(), lhs: u64, rhs: u64, result: u64) !void {
    // If the lhs and rhs are true, the result must be true
    try self.clause(&.{ lhs, rhs, result }, &.{ 0, 0, 1 });
    // if the lhs is false, then the result must be false
    try self.clause(&.{ lhs, result }, &.{ 1, 0 });
    // If the rhs is false, then the result must be false
    try self.clause(&.{ rhs, result }, &.{ 1, 0 });
}

/// result <- lhs NAND rhs
pub fn bitnand(self: *@This(), lhs: u64, rhs: u64, result: u64) !void {
    try self.bitop2(lhs, rhs, result, .{ 1, 1, 1, 0 });
}

/// result <- lhs OR rhs
pub fn bitor(self: *@This(), lhs: u64, rhs: u64, result: u64) !void {
    // If the LHS is true, then the result MUST be true
    try self.clause(&.{ lhs, result }, &.{ 0, 1 });
    // If the RHS is true, then the result MUST be true
    try self.clause(&.{ rhs, result }, &.{ 0, 1 });
    // If the LHS and the RHS are false the result MUST be false
    try self.clause(&.{ lhs, rhs, result }, &.{ 1, 1, 0 });
}

/// result <- lhs XNOR rhs
pub fn bitxnor(self: *@This(), lhs: u64, rhs: u64, result: u64) !void {
    try self.bitop2(lhs, rhs, result, .{ 1, 0, 0, 1 });
}

/// result <- lhs XOR rhs
pub fn bitxor(self: *@This(), lhs: u64, rhs: u64, result: u64) !void {
    try self.bitop2(lhs, rhs, result, .{ 0, 1, 1, 0 });
}

pub fn bitop2(self: *@This(), a: u64, b: u64, c: u64, t: [4]u1) !void {
    try self.clause(&.{ a, b, c }, &.{ 1, 1, t[0] });
    try self.clause(&.{ a, b, c }, &.{ 1, 0, t[1] });
    try self.clause(&.{ a, b, c }, &.{ 0, 1, t[2] });
    try self.clause(&.{ a, b, c }, &.{ 0, 0, t[3] });
}

// -------------------------------------------------- TRIPLE BITWISE OPERATIONS

/// res <- cond ? lhs : rhs
pub fn bitsel(self: *@This(), cond: u64, lhs: u64, rhs: u64, res: u64) !void {
    try self.bitop3(cond, lhs, rhs, res, .{ 0, 1, 0, 1, 0, 0, 1, 1 });
}

/// result <- a ^ b ^ c
pub fn bit3xor(self: *@This(), a: u64, b: u64, c: u64, result: u64) !void {
    try self.bitop3(a, b, c, result, .{ 0, 1, 1, 0, 1, 0, 0, 1 });
}

pub fn bitop3(self: *@This(), a: u64, b: u64, c: u64, d: u64, t: [8]u1) !void {
    try self.clause(&.{ a, b, c, d }, &.{ 1, 1, 1, t[0] });
    try self.clause(&.{ a, b, c, d }, &.{ 1, 1, 0, t[1] });
    try self.clause(&.{ a, b, c, d }, &.{ 1, 0, 1, t[2] });
    try self.clause(&.{ a, b, c, d }, &.{ 1, 0, 0, t[3] });
    try self.clause(&.{ a, b, c, d }, &.{ 0, 1, 1, t[4] });
    try self.clause(&.{ a, b, c, d }, &.{ 0, 1, 0, t[5] });
    try self.clause(&.{ a, b, c, d }, &.{ 0, 0, 1, t[6] });
    try self.clause(&.{ a, b, c, d }, &.{ 0, 0, 0, t[7] });
}

// ----------------------------------------------------------------- ARITHMETIC

/// bitwise half adder, a + b = s + c * 2
pub fn halfadd(self: *@This(), a: u64, b: u64, c: u64, s: u64) !void {
    // a b | c s
    // ----+----
    // 0 0 | 0 0
    // 1 0 | 0 1
    // 0 1 | 0 1
    // 1 1 | 1 0

    try self.clause(&.{ a, c }, &.{ 1, 0 }); // 0 + x = carry x
    try self.clause(&.{ b, c }, &.{ 1, 0 }); // x + 0 = carry x
    try self.clause(&.{ a, b, c }, &.{ 0, 0, 1 }); // 1 + 1 = carry x

    try self.clause(&.{ c, s }, &.{ 0, 0 }); // carry 1 -> sum 0
    try self.clause(&.{ a, b, s }, &.{ 1, 1, 0 }); // 0 + 0 = sum 0
    try self.clause(&.{ a, b, s }, &.{ 1, 0, 1 }); // 0 + 1 = sum 1
    try self.clause(&.{ a, b, s }, &.{ 0, 1, 1 }); // 1 + 0 = sum 1

}

/// bitwise half subtractor, a - b = s - o * 2
pub fn halfsub(self: *@This(), a: u64, b: u64, o: u64, s: u64) !void {
    // a b | o s
    // ----+----
    // 0 0 | 0 0
    // 0 1 | 1 1
    // 1 0 | 0 1
    // 1 1 | 0 0

    try self.clause(&.{ a, o }, &.{ 0, 0 }); // 1-x -> borrow 0
    try self.clause(&.{ a, b, o }, &.{ 1, 1, 0 }); // 0-0 -> borrow 0
    try self.clause(&.{ a, b, o }, &.{ 1, 0, 1 }); // 0-1 -> borrow 1

    try self.clause(&.{ o, s }, &.{ 0, 1 }); // borrow 1 -> sum 1
    try self.clause(&.{ a, b, s }, &.{ 1, 1, 0 }); // 0-0 -> sum 0
    try self.clause(&.{ a, b, s }, &.{ 0, 1, 1 }); // 1-0 -> sum 1
    try self.clause(&.{ a, b, s }, &.{ 0, 0, 0 }); // 1-1 -> sum 0
}

/// bitwise full adder, a + b + i = s + c * 2
pub fn fulladd(self: *@This(), a: u64, b: u64, i: u64, c: u64, s: u64) !void {
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

    try self.clause(&.{ a, b, c }, &.{ 1, 1, 0 }); // 0+0+x -> carry 0
    try self.clause(&.{ a, i, c }, &.{ 1, 1, 0 }); // 0+x+0 -> carry 0
    try self.clause(&.{ b, i, c }, &.{ 1, 1, 0 }); // x+0+0 -> carry 0
    try self.clause(&.{ b, i, c }, &.{ 0, 0, 1 }); // x+1+1 -> carry 1
    try self.clause(&.{ a, i, c }, &.{ 0, 0, 1 }); // 1+x+1 -> carry 1
    try self.clause(&.{ a, b, c }, &.{ 0, 0, 1 }); // 1+1+x -> carry 1

    try self.clause(&.{ a, c, s }, &.{ 1, 0, 0 }); // 0+x+x & carry 1 -> sum 0
    try self.clause(&.{ b, c, s }, &.{ 1, 0, 0 }); // x+0+x & carry 1 -> sum 0
    try self.clause(&.{ i, c, s }, &.{ 1, 0, 0 }); // x+x+0 & carry 1 -> sum 0
    try self.clause(&.{ i, c, s }, &.{ 0, 1, 1 }); // x+x+1 & carry 0 -> sum 1
    try self.clause(&.{ b, c, s }, &.{ 0, 1, 1 }); // x+1+x & carry 0 -> sum 1
    try self.clause(&.{ a, c, s }, &.{ 0, 1, 1 }); // 1+x+x & carry 0 -> sum 1
    try self.clause(&.{ a, b, i, s }, &.{ 1, 1, 1, 0 }); // 0+0+0 -> sum 0
    try self.clause(&.{ a, b, i, s }, &.{ 0, 0, 0, 1 }); // 1+1+1 -> sum 1
}

/// bitwise full subtractor, a - b - i = s - o * 2
pub fn fullsub(self: *@This(), a: u64, b: u64, i: u64, o: u64, s: u64) !void {
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

    try self.clause(&.{ a, b, o }, &.{ 0, 1, 0 }); // 1-0-x -> borrow 0
    try self.clause(&.{ a, i, o }, &.{ 0, 1, 0 }); // 1-x-0 -> borrow 0
    try self.clause(&.{ b, i, o }, &.{ 1, 1, 0 }); // x-0-0 -> borrow 0
    try self.clause(&.{ b, i, o }, &.{ 0, 0, 1 }); // x-1-1 -> borrow 1
    try self.clause(&.{ a, i, o }, &.{ 1, 0, 1 }); // 0-x-1 -> borrow 1
    try self.clause(&.{ a, b, o }, &.{ 1, 0, 1 }); // 0-1-x -> borrow 1

    try self.clause(&.{ a, o, s }, &.{ 0, 0, 1 }); // 1-x-x & borrow 1 -> sum 1
    try self.clause(&.{ b, o, s }, &.{ 0, 1, 0 }); // x-1-x & borrow 0 -> sum 0
    try self.clause(&.{ i, o, s }, &.{ 0, 1, 0 }); // x-x-1 & borrow 0 -> sum 0
    try self.clause(&.{ i, o, s }, &.{ 1, 0, 1 }); // x-x-0 & borrow 1 -> sum 1
    try self.clause(&.{ b, o, s }, &.{ 1, 0, 1 }); // x-0-x & borrow 1 -> sum 1
    try self.clause(&.{ a, o, s }, &.{ 1, 1, 0 }); // 0-x-x & borrow 0 -> sum 0
    try self.clause(&.{ a, b, i, s }, &.{ 1, 0, 0, 0 }); // 0-1-1 -> sum 0
    try self.clause(&.{ a, b, i, s }, &.{ 0, 1, 1, 1 }); // 1-0-0 -> sum 1
}

// ---------------------------------------------------------------- CARDINALITY

// Constraint the cardinality of the input to be exactly one. If the "sat"
// argument is non-null, then the cardinality of input will NOT be constrained
// to be exactly one - instead, it will be constrained to be one if "sat" is
// one, and it will be constrained to NOT be one if "sat" is zero - this means
// that you can constrain sat to be zero or one to check for unsatisfiability
// in your problems where you are unsure of whether this is unsatisfiable, and
// you need that information to make informed decisions.

pub fn cardinalityOne(self: *@This(), input: Bits, sat: ?u64) !void {
    if (input.len == 0) {
        if (sat) |bit| {
            try self.bitfalse(bit);
        } else {
            assert(false); // NO.
        }
        return;
    }

    // If we are going to track whether the expression is
    // sat, we will keep track of <= 1 and >= 1 separately.
    const le_one = if (sat) |_| self.alloc(1).idx else null;
    const ge_one = if (sat) |_| self.alloc(1).idx else null;

    var bits: Bits = input;
    while (bits.len > 1) {
        // At most one bit is set in adjacent pairs
        for (0..bits.len / 2) |pair| {
            // --------------------------------- BACKWARD IMPLICATION OF le_one
            // EITHER: number of set bits is NOT <= 1
            if (le_one) |bit| try self.part(bit, 0);
            // OR: the left bit of the pair is FALSE
            try self.part(bits.at(pair * 2), 0);
            // OR: the right bit of the pair is FALSE
            try self.part(bits.at(pair * 2 + 1), 0);
            try self.end();
        }

        // Allocate bits for the next layer
        const next_count = (bits.len + 1) / 2;
        var next: Bits = self.alloc(next_count);

        // Carry ORs of working bits to the next layer
        for (0..bits.len / 2) |pair| {
            const lhs = bits.at(pair * 2);
            const rhs = bits.at(pair * 2 + 1);
            try self.bitor(lhs, rhs, next.at(pair));
        }

        // Carry any extra bit to the next layer
        if (bits.len & 1 == 1) {
            const lhs = bits.at(bits.len - 1);
            const rhs = next.at(next.len - 1);
            try self.biteql(lhs, rhs);
        }

        // Swap the layers
        bits = next;
    }

    if (ge_one) |bit| {
        // -------------------------------------- FORWARD IMPLICATION OF ge_one
        // EITHER: number of bits set is >= 1
        try self.part(bit, 1);
        // OR: there are zero set bits
        try self.part(bits.at(0), 0);
        try self.end();
    }

    // ----------------------------------------- BACKWARD IMPLICATION OF ge_one
    // EITHER: number of set bits is NOT >= 1
    if (ge_one) |bit| try self.part(bit, 0);
    // OR: input cardinality is at least 1
    for (0..input.len) |off|
        try self.part(input.at(off), 1);
    try self.end();

    if (le_one) |bit| {
        for (0..input.len) |skip| {
            // ---------------------------------- FORWARD IMPLICATION OF le_one
            // EITHER: number of set bits is <= 1
            try self.part(bit, 1);
            // OR: at least one bit (except skip) is true
            for (0..input.len) |off| {
                if (off == skip) continue;
                try self.part(input.at(off), 1);
            }
            try self.end();
        }
    }

    if (sat) |bit| {
        // The solution is satisfied if and only if the number of bits set is
        // less than or equal to one, and also greater than or equal to one.
        const le = le_one orelse unreachable;
        const ge = ge_one orelse unreachable;
        try self.bitand(le, ge, bit);
    }
}

pub fn cardinalityAtMostOne(self: *@This(), input: Bits, sat: ?u64) !void {
    if (input.len == 0) {
        if (sat) |bit|
            try self.bittrue(bit);
        return;
    }

    var bits: Bits = input;
    while (bits.len > 1) {
        // At most one bit is set in adjacent pairs
        for (0..bits.len / 2) |pair| {
            // ------------------------------------ BACKWARD IMPLICATION OF sat
            // EITHER: number of set bits is NOT <= 1
            if (sat) |bit| try self.part(bit, 0);
            // OR: the left bit of the pair is FALSE
            try self.part(bits.at(pair * 2), 0);
            // OR: the right bit of the pair is FALSE
            try self.part(bits.at(pair * 2 + 1), 0);
            try self.end();
        }

        // Allocate bits for the next layer
        const next_count = (bits.len + 1) / 2;
        var next: Bits = self.alloc(next_count);

        // Carry ORs of working bits to the next layer
        for (0..bits.len / 2) |pair| {
            const lhs = bits.at(pair * 2);
            const rhs = bits.at(pair * 2 + 1);
            try self.bitor(lhs, rhs, next.at(pair));
        }

        // Carry any extra bit to the next layer
        if (bits.len & 1 == 1) {
            const lhs = bits.at(bits.len - 1);
            const rhs = next.at(next.len - 1);
            try self.biteql(lhs, rhs);
        }

        // Swap the layers
        bits = next;
    }

    if (sat) |bit| {
        for (0..input.len) |skip| {
            // ------------------------------------- FORWARD IMPLICATION OF sat
            // EITHER: number of set bits is <= 1
            try self.part(bit, 1);
            // OR: at least one bit (except skip) is true
            for (0..input.len) |off| {
                if (off == skip) continue;
                try self.part(input.at(off), 1);
            }
            try self.end();
        }
    }
}

// ----------------------------------------------------------- UNARY OPERATIONS

/// Returns bits that are constrained to be the maximum
/// of some number of unary numbers. Assumes that these
/// input bits are indeed unary numbers. (ie. 11111100)
pub fn unaryMax(self: *@This(), input: []const Bits, output: Bits) !void {
    // Ensure all lengths are the same
    for (input) |bit_list|
        assert(bit_list.len == output.len);

    // One bit in the input implies the corresponding bit
    for (input) |bit_list|
        for (0..output.len) |off|
            try self.bitimp(bit_list.at(off), output.at(off));

    for (0..output.len) |off| {
        for (input) |bit_list|
            // It could be the case the unary bit is true
            try self.part(bit_list.at(off), 1);
        // It could be the case the result bit is false
        try self.part(output.at(off), 0);
        // The output bit is false if every bit is false
        try self.end();
    }
}

/// Returns bits that are constrained to be the minimum
/// of some number of unary numbers. Assumes that these
/// input bits are indeed unary numbers. (ie. 11111100)
pub fn unaryMin(self: *@This(), input: []const Bits, output: Bits) !void {
    // Ensure all lengths are the same
    for (input) |bit_list|
        assert(bit_list.len == output.len);

    // False in the input implies the corresponding false
    for (input) |bit_list|
        for (0..output.len) |off|
            // NOT A IMPLIES NOT B === B IMPLIES A
            try self.bitimp(output.at(off), bit_list.at(off));

    for (0..output.len) |off| {
        for (input) |bit_list|
            // It could be the case the unary bit is false
            try self.part(bit_list.at(off), 0);
        // It could be the case the result bit is true
        try self.part(output.at(off), 1);
        // The output bit is true if every bit is true
        try self.end();
    }
}

/// Saturating decrement of some unary number. Assumes that
/// the input bits are indeed a unary number. (ie. 1111100)
pub fn unarySatDec(self: *@This(), input: Bits, output: Bits) !void {
    // Ensure all lengths are the same
    assert(output.len == input.len);

    // Each output bit is equal to one shifted input bit
    for (0..output.len -| 1) |off|
        try self.biteql(output.at(off), input.at(off + 1));

    // The last bit is always false
    if (output.len >= 1)
        try self.bitfalse(output.at(output.len - 1));
}

/// Saturating increment of some unary number. Assumes that
/// the input bits are indeed a unary number. (ie. 1111000)
pub fn unarySatInc(self: *@This(), input: Bits, output: Bits) !void {
    // Ensure all lengths are the same
    assert(output.len == input.len);

    // Each output bit is equal to one shifted input bit
    for (0..output.len -| 1) |off|
        try self.biteql(output.at(off + 1), input.at(off));

    // The first bit is always true
    if (output.len >= 1)
        try self.bittrue(output.at(0));
}

/// Constrains one "less_equal" bit to be equivalent to the
/// lhs unary number being at most the value of the rhs unary.
/// Assumes the lhs and rhs are both valid unary. (ie. 1110)
pub fn unaryLE(self: *@This(), lhs: Bits, rhs: Bits, le: u64) !void {
    // Ensure all lengths are the same
    assert(lhs.len == rhs.len);

    // Pairwise comparison would forbid this:
    // A: 11111111111111111111110000000000000
    // B: 11111111000000000000000000000000000
    // le IMPLIES (rhs bits IMPLIES lhs bits)
    for (0..lhs.len) |off| try self.clause(
        &.{ le, lhs.at(off), rhs.at(off) },
        &.{ 0, 0, 1 },
    );
}

/// Constrain the lhs unary number to be less than or equal
/// to the rhs unary number. Assumes that the input for the
/// lhs and rhs are indeed valid unary. (ie. 1111111110000)
pub fn unaryConstrainLE(self: *@This(), lhs: Bits, rhs: Bits) !void {
    // Ensure all lengths are the same
    assert(lhs.len == rhs.len);

    // Pairwise comparison would forbid this:
    // A: 11111111111111111111110000000000000
    // B: 11111111000000000000000000000000000
    // rhs bits imply the equivalent lhs bits
    for (0..lhs.len) |off|
        try self.bitimp(rhs.at(off), lhs.at(off));
}

/// Constrains one "not_equal" bit to be equivalent to the
/// lhs unary number being not equal to the rhs unary number.
/// Assumes that the lhs and rhs are both valid unary (ie. 1110)
pub fn unaryNE(self: *@This(), lhs: Bits, rhs: Bits, ne: u64) !void {
    // Ensure all lengths are the same
    assert(lhs.len == rhs.len);

    // Allocate auxilliary bits to encode bit equality
    const xors: Bits = self.alloc(lhs.len);

    // Constrain xors to be bitwise lhs XOR rhs
    for (0..lhs.len) |off|
        try self.bitxor(lhs.at(off), rhs.at(off), xors.at(off));

    // If an XOR is true, it implies that the numbers aren't equal
    for (0..lhs.len) |off|
        try self.bitimp(xors.at(off), ne);

    // At least one of the XORs must be true to be not equal
    for (0..lhs.len) |off|
        try self.part(xors.at(off), 1);
    try self.part(ne, 0);
    try self.end();
}

/// Constrain the lhs unary number to be different to the
/// rhs unary number. Assumes the input for the lhs unary
/// number and rhs number are valid unary. (ie. 11100000)
pub fn unaryConstrainNE(self: *@This(), lhs: Bits, rhs: Bits) !void {
    // Ensure all lengths are the same
    assert(lhs.len == rhs.len);

    // Allocate auxilliary bits to encode bit equality
    const xors: Bits = self.alloc(lhs.len);

    // Constrain xors to be bitwise lhs XOR rhs
    for (0..lhs.len) |off|
        try self.bitxor(lhs.at(off), rhs.at(off), xors.at(off));

    // Constrain at least one of the xors to be true
    for (0..lhs.len) |off|
        try self.part(xors.at(off), 1);
    try self.end();
}

/// Constrains one "less_than" bit to be equivalent to the
/// lhs unary number being strictly less than the rhs unary.
/// Assumes the lhs and rhs are both valid unary. (ie. 1110)
pub fn unaryLT(self: *@This(), lhs: Bits, rhs: Bits, lt: u64) !void {
    // Strictly "less than" is the same as saying "less than
    // or equal" combined with a "not equal" constraint.
    const le_bit = self.alloc(1).idx;
    try self.unaryLE(lhs, rhs, le_bit);
    const ne_bit = self.alloc(1).idx;
    try self.unaryNE(lhs, rhs, ne_bit);
    // Both LE AND NE are required for LT
    try self.bitand(le_bit, ne_bit, lt);
}

/// Constrain the lhs unary number to be strictly less than
/// the rhs unary number. Assumes both inputted lhs and rhs
/// numbers to be valid unary. (ie. 1111111111111110000000)
pub fn unaryConstrainLT(self: *@This(), lhs: Bits, rhs: Bits) !void {
    // Strictly "less than" is the same as saying "less than
    // or equal" combined with a "not equal" constraint.
    try self.unaryConstrainLE(lhs, rhs);
    try self.unaryConstrainNE(lhs, rhs);
}

/// Constrain a unary number to be greater than or
/// equal to some known constant. Assumes that the
/// input is valid unary (eg. 1111111111100000000)
pub fn unaryConstrainGEVal(self: *@This(), bits: Bits, val: u64) !void {
    assert(val <= bits.len); // not possible to exceed
    if (val == 0) return; // everything is at least zero
    try self.bittrue(bits.at(val - 1));
}

/// Constrain a unary number to be strictly less than
/// some known constant. Assumes that the input unary
/// number is valid unary. (eg. 11111111111100000000)
pub fn unaryConstrainLTVal(self: *@This(), bits: Bits, val: u64) !void {
    assert(val != 0); // not possible to be less than zero
    if (val >= bits.len) return; // always the case
    try self.bitfalse(bits.at(val - 1));
}

/// Constrain a unary number to be less than or equal
/// to some known constant. Assumes that the input unary
/// number is valid unary. (eg. 11111111111100000000)
pub fn unaryConstrainLEVal(self: *@This(), bits: Bits, val: u64) !void {
    if (val > bits.len) return; // always the case
    try self.bitfalse(bits.at(val));
}

/// Constrains a unary number to be equal in value
/// to some known constant. Assumes that the input
/// is indeed valid unary. (eg. 11111111111110000)
pub fn unaryConstrainEQVal(self: *@This(), bits: Bits, val: u64) !void {
    try self.unaryConstrainGEVal(bits, val); // X >= val
    try self.unaryConstrainLEVal(bits, val); // X <= val
}

/// Constrain some number of bits to be a valid
/// unary number; eg, 10, 110, 11111100... etc.
pub fn unaryConstrain(self: *@This(), bits: Bits) !void {
    for (0..bits.len - 1) |off| {
        const lo_bit = bits.at(off + 0);
        const hi_bit = bits.at(off + 1);
        try self.bitimp(hi_bit, lo_bit);
    }
}

/// Returns a unary number totalizing the number
/// of "1" bits set in the input bits list. This
/// list does not need to be some known pattern.
pub fn unaryTotalize(self: *@This(), bits: Bits) !Bits {
    // The total is the same for 0 or 1 bits
    if (bits.len <= 1) return bits;

    // Split the input problem into two subproblems
    const half = bits.len / 2;
    const lhs = bits.slice(0, half);
    const rhs = bits.slice(half, bits.len);

    // Recursively sort each half into unary numbers
    const sorted_lhs = try self.unaryTotalize(lhs);
    const sorted_rhs = try self.unaryTotalize(rhs);

    // Merge the two pairs into one sorted list
    return try self.unaryAdd(sorted_lhs, sorted_rhs);
}

/// Constrain some number of bits to be the summation
/// of the lhs unary number and the rhs unary number.
/// Assumes the inputs are valid unary. (eg. 1100000)
pub fn unaryAdd(self: *@This(), lhs: Bits, rhs: Bits) !Bits {
    // Create a new output list of bits
    const length = lhs.len + rhs.len;
    const out = self.alloc(length);

    // Each lhs bit implies the corresponding out bit -
    // If we have 3 + 2, the output (5) is at least 3.
    for (0..lhs.len) |off|
        try self.bitimp(lhs.at(off), out.at(off));

    // Each rhs bit implies the corresponding out bit -
    // If we have 3 + 2, the output (5) is at least 2.
    for (0..rhs.len) |off|
        try self.bitimp(rhs.at(off), out.at(off));

    // Each false lhs bit implies the corresponding false out bit -
    // If we have 1110 + 1100, the output (11111000) is at most 7.
    for (0..lhs.len) |off| {
        const lhs_bit = lhs.at(off);
        const out_bit = out.at(rhs.len + off);
        try self.bitimp(out_bit, lhs_bit);
    }

    // Each false rhs bit implies the corresponding false out bit -
    // If we have 1110 + 1100, the output (11111000) is at most 6.
    for (0..rhs.len) |off| {
        const rhs_bit = rhs.at(off);
        const out_bit = out.at(lhs.len + off);
        try self.bitimp(out_bit, rhs_bit);
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
            try self.clause(&.{ l_bit, r_bit, lt_bit }, &.{ 1, 1, 0 });

            // If lhs has GE lhs_off bits and rhs has GE rhs_off bits,
            // then the total must have at least lhs_off + rhs_off bits.
            // LOGIC: (l_bit & r_bit) -> s_bit
            // CNF: !l_bit | !r_bit | s_bit
            // LOWER BOUND
            const ge_bit = out.at(l_off + r_off + 1);
            try self.clause(&.{ l_bit, r_bit, ge_bit }, &.{ 0, 0, 1 });
        }
    }

    return out;
}

// ------------------------------------------------------- MULTI-BIT OPERATIONS

// N-value bitwise OR; result <- bits[0] OR bits[1] OR bits[2] ...
pub fn multiBitOR(self: *@This(), bits: Bits, result: u64) !void {
    for (0..bits.len) |off|
        // If any bit is true, the result is true
        try self.bitimp(bits.at(off), result);

    for (0..bits.len) |off|
        // Either one of the bits is true
        try self.part(bits.at(off), 1);
    // Otherwise the result is false
    try self.part(result, 0);
    // The result is false if every bit is false
    try self.end();
}
