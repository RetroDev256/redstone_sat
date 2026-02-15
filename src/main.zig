const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Cnf = @import("Cnf.zig");
const Bits = Cnf.Bits;

// ----------------------------------------------------------------------- MAIN

// OLD: 125.77 seconds, 61480960 bytes
// NEW:

pub fn main(init: std.process.Init.Minimal) !void {
    const gpa = std.heap.smp_allocator;

    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.ioBasic();

    var args = try std.process.Args.Iterator.initAllocator(init.args, gpa);
    defer args.deinit();

    const process_name = args.next().?;
    if (args.next()) |mode_str| {
        if (std.mem.eql(u8, mode_str, "e")) {
            return try encodeMain(io, gpa);
        } else if (std.mem.eql(u8, mode_str, "d")) {
            return try decodeMain(io, gpa);
        }
    }

    std.debug.print(
        \\ USAGE: {s} [MODE]
        \\   MODE:
        \\     e --> encodes CNF problem
        \\     d --> decodes CNF problem
        \\
    , .{process_name});
}

/// simulating every possible state in parallel
const states = 1 << in_pos.len;
/// length of the redstone build in number of blocks
const width = 10;
/// height of the redstone build in number of blocks
const height = 10;
/// complexity of the circuit (number of segment IDs)
const id_count = 64;
/// maximum power that a redstone line can have
const max_power = 15;
/// area of the redstone build in number of blocks
const area = width * height;

const in_pos: []const [2]usize = &.{
    .{ 0, 3 },
    .{ 0, 5 },
};

const out_pos: []const [2]usize = &.{
    .{ 9, 4 },
};

/// "air" is a lack of dust, torch, or block
var is_air: Bits = undefined; // area number of bits
/// "dust" is a lack of air, torch, or block
var is_dust: Bits = undefined; // area number of bits
/// "torch" is a lack of air, dust, or block
var is_torch: Bits = undefined; // area number of bits
/// "block" is a lack of air, dust, or torch
var is_block: Bits = undefined; // area number of bits

/// "inputs" are redstone dust
var is_input: Bits = undefined; // area number of bits
/// "outputs" are redstone dust
var is_output: Bits = undefined; // area number of bits

/// standing torches are connected to the block below them
var is_standing_torch: Bits = undefined; // area number of bits
/// left torches are connected to the block on their right
var is_left_torch: Bits = undefined; // area number of bits
/// right torches are connected to the block on their left
var is_right_torch: Bits = undefined; // area number of bits

/// segment IDs to prevent state cycles - preventing latches - unary
var segment_id: [area]Bits = undefined; // id_count number of bits

/// torch state, whether they are on or off
var is_torch_on: [states]Bits = undefined; // area number of bits
/// blocks that are powered by redstone dust
var is_weakly_powered: [states]Bits = undefined; // area number of bits
/// blocks that are powered by redstone torches
var is_strongly_powered: [states]Bits = undefined; // area number of bits
/// whether or not a block is powered in any way
var is_powered: [states]Bits = undefined; // area number of bits
/// whether the dust has a signal strength greater than zero
var is_dust_powered: [states]Bits = undefined; // area number of bits
/// whether signal strength can be calculated or propagated for this area
var can_propagate: [states]Bits = undefined; // area number of bits
/// whether the dust was directly powered by a block or torch
var is_directly_powered: [states]Bits = undefined; // area number of bits
/// whether the dust signal strength can decay from surrounding dust
var can_decay: [states]Bits = undefined; // area number of bits

/// Each block in each state can have up to max_power signal strength - unary
var signal_strength: [states][area]Bits = undefined; // max_power bits
/// The maximum signal strength of dust that connects to this - unary
var max_signal_strength: [states][area]Bits = undefined; // max_power bits
/// The supplyable signal strength from top left dust - unary
var supply_top_left: [states][area]Bits = undefined; // max_power bits
/// The supplyable signal strength from bottom left dust - unary
var supply_bottom_left: [states][area]Bits = undefined; // max_power bits
/// The supplyable signal strength from top right dust - unary
var supply_top_right: [states][area]Bits = undefined; // max_power bits
/// The supplyable signal strength from bottom right dust - unary
var supply_bottom_right: [states][area]Bits = undefined; // max_power bits
/// The signal strength of dust if it can be decayed - unary
var decay_strength: [states][area]Bits = undefined; // max_power bits

fn initializeGlobals(cnf: *Cnf) !void {
    is_air = cnf.alloc(area);
    is_dust = cnf.alloc(area);
    is_torch = cnf.alloc(area);
    is_block = cnf.alloc(area);

    is_input = cnf.alloc(area);
    is_output = cnf.alloc(area);

    is_standing_torch = cnf.alloc(area);
    is_left_torch = cnf.alloc(area);
    is_right_torch = cnf.alloc(area);

    for (0..area) |block| {
        segment_id[block] = cnf.alloc(id_count);
    }

    for (0..states) |state| {
        is_torch_on[state] = cnf.alloc(area);
        is_weakly_powered[state] = cnf.alloc(area);
        is_strongly_powered[state] = cnf.alloc(area);
        is_powered[state] = cnf.alloc(area);
        is_dust_powered[state] = cnf.alloc(area);
        can_propagate[state] = cnf.alloc(area);
        is_directly_powered[state] = cnf.alloc(area);
        can_decay[state] = cnf.alloc(area);

        for (0..area) |block| {
            signal_strength[state][block] = cnf.alloc(max_power);
            max_signal_strength[state][block] = cnf.alloc(max_power);
            supply_top_left[state][block] = cnf.alloc(max_power);
            supply_bottom_left[state][block] = cnf.alloc(max_power);
            supply_top_right[state][block] = cnf.alloc(max_power);
            supply_bottom_right[state][block] = cnf.alloc(max_power);
            decay_strength[state][block] = cnf.alloc(max_power);
        }
    }
}

fn decodeMain(io: Io, gpa: Allocator) !void {
    var failing: Io.Writer = .failing;
    var cnf: Cnf = .init(&failing);
    defer cnf.deinit();
    try initializeGlobals(&cnf);

    var stdin_buffer: [4096]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_file_reader = stdin_file.reader(io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    var stdout_buffer: [4096]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_file_writer = stdout_file.writer(io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var allocating: Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    const line_store = &allocating.writer;

    var block_is_air: [area]?u1 = @splat(null);
    var block_is_dust: [area]?u1 = @splat(null);
    var block_is_block: [area]?u1 = @splat(null);

    var block_is_input: [area]?u1 = @splat(null);
    var block_is_output: [area]?u1 = @splat(null);

    var block_is_left_torch: [area]?u1 = @splat(null);
    var block_is_right_torch: [area]?u1 = @splat(null);
    var block_is_standing_torch: [area]?u1 = @splat(null);

    var block_is_powered: [area]u3 = @splat(0);

    while (true) {
        allocating.clearRetainingCapacity();
        const stream = stdin.streamDelimiter(line_store, '\n');
        if (stdin.end != 0) stdin.toss(1);
        const byte_count = stream catch break;

        var stored = line_store.buffered();
        if (byte_count == 0 or stored[0] != 'v') continue;

        var toker = std.mem.tokenizeAny(u8, stored[2..], " \t\r\n");
        outer: while (toker.next()) |int_string| {
            const encoded = try std.fmt.parseInt(i64, int_string, 10);
            const value = @intFromBool(encoded >= 0);
            const decoded = @abs(encoded);

            inline for (&.{
                .{ &is_air, &block_is_air },
                .{ &is_dust, &block_is_dust },
                .{ &is_block, &block_is_block },
                .{ &is_input, &block_is_input },
                .{ &is_output, &block_is_output },
                .{ &is_left_torch, &block_is_left_torch },
                .{ &is_right_torch, &block_is_right_torch },
                .{ &is_standing_torch, &block_is_standing_torch },
            }) |list| {
                for (0..area) |pos| {
                    if (decoded == list[0].at(pos)) {
                        list[1][pos] = value;
                        continue :outer;
                    }
                }
            }

            // max_signal_strength[state][pos].at(0) // seems to be correct
            // decay_strength[state][pos].at(0) // seems to be correct
            // supply_top_right[state][pos].at(0) // seems to be correct
            // is_strongly_powered[state].at(pos) // seems to be correct
            // can_propagate[state].at(pos) // seems to be correct
            // is_directly_powered[state].at(pos) // seems to be correct
            // can_decay[state].at(pos) // seems to be correct
            // supply_bottom_left[state][pos].at(0) // seems to be correct

            // is_torch_on[state].at(pos) // either redstone doesn't power the block below,
            // or it is the case that redstone signals don't propagate, or it is the case that right
            // torches can simply choose to be on...

            // is_weakly_powered[state].at(pos) // propagating FROM the top left TO the bottom right
            // doesn't seem to work? Either that or dust doesn't need to weakly power blocks below them.

            // is_powered[state].at(pos) // still showing that some dust does not connect
            // (diagonal down right or diagnal up left)

            // is_dust_powered[state].at(pos) // perhaps the most interesting - it shows that
            // propagations to the left and right AND diagonal downard right don't work?

            // signal_strength[state][pos].at(0) // shows that signal strengths don't match up
            // across the diagonal up-left or down-right angles, as if signal is unconstrained

            // supply_top_left[state][pos].at(0) // shows that *some* signal is being supplied
            // from the top left... but it isn't nearly how much it should be.

            // supply_bottom_right[state][pos].at(0) // shows that *some* signal is being supplied
            // from the bottom right... but it isn't nearly how much it should be.

            for (0..states) |state| {
                for (0..area) |pos| {
                    if (decoded == is_dust_powered[state].at(pos)) {
                        block_is_powered[pos] += value;
                        continue :outer;
                    }
                }
            }
        }
    }

    for (0..height) |y| {
        for (0..3) |sub_row| {
            for (0..width) |x| {
                for (0..3) |sub_col| {
                    const pos = x + y * width;

                    var byte = unknown_display[sub_row][sub_col];

                    inline for (&.{
                        // Prioritize displaying inputs and outputs over dust
                        .{ &block_is_input, &input_display },
                        .{ &block_is_output, &output_display },
                        .{ &block_is_air, &air_display },
                        .{ &block_is_dust, &dust_display },
                        .{ &block_is_block, &block_display },
                        .{ &block_is_left_torch, &left_torch_display },
                        .{ &block_is_right_torch, &right_torch_display },
                        .{ &block_is_standing_torch, &standing_torch_display },
                    }) |list| {
                        if (list[0][pos] == 1) {
                            byte = list[1][sub_row][sub_col];
                            break;
                        }
                    }

                    // if (sub_row == 1 and sub_col == 1) {
                    //     byte = @as(u8, '0') + block_is_powered[pos];
                    // }

                    try stdout.writeByte(byte);
                }
                try stdout.writeAll("  ");
            }
            try stdout.writeByte('\n');
        }
        try stdout.writeByte('\n');
    }

    try stdout.writeByte('\n');
    try stdout.flush();
}

const air_display: [3][3]u8 = .{ "   ".*, " . ".*, "   ".* };
const block_display: [3][3]u8 = .{ "###".*, "###".*, "###".* };
const dust_display: [3][3]u8 = .{ "   ".*, "   ".*, "%%%".* };
const standing_torch_display: [3][3]u8 = .{ " o ".*, " | ".*, " | ".* };
const left_torch_display: [3][3]u8 = .{ "o  ".*, " \\ ".*, "  \\".* };
const right_torch_display: [3][3]u8 = .{ "  o".*, " / ".*, "/  ".* };
const input_display: [3][3]u8 = .{ "III".*, " I ".*, "III".* };
const output_display: [3][3]u8 = .{ "OOO".*, "O O".*, "OOO".* };
const unknown_display: [3][3]u8 = .{ "???".*, "???".*, "???".* };

fn isBlockOffset(x: u64, x_off: i64, y: u64, y_off: i64) ?u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return is_block.at(sum_x + sum_y * width);
}

fn isTorchOffset(x: u64, x_off: i64, y: u64, y_off: i64) ?u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return is_torch.at(sum_x + sum_y * width);
}

fn isDustOffset(x: u64, x_off: i64, y: u64, y_off: i64) ?u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return is_dust.at(sum_x + sum_y * width);
}

fn isDustPoweredOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) ?u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return is_dust_powered[state].at(sum_x + sum_y * width);
}

fn isTorchOnOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) ?u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return is_torch_on[state].at(sum_x + sum_y * width);
}

fn isWeaklyPoweredOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) ?u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return is_weakly_powered[state].at(sum_x + sum_y * width);
}

fn isStronglyPoweredOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) ?u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return is_strongly_powered[state].at(sum_x + sum_y * width);
}

fn isPoweredOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) ?u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return is_powered[state].at(sum_x + sum_y * width);
}

fn signalStrengthOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) ?Bits {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return signal_strength[state][sum_x + sum_y * width];
}

fn segmentIdOffset(x: u64, x_off: i64, y: u64, y_off: i64) ?Bits {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return null;
    return segment_id[sum_x + sum_y * width];
}

// Prohibits air, dust, torch, and blocks from overlapping
fn enforceSingleBlockType(cnf: *Cnf) !void {
    for (0..area) |pos| {
        // Exactly one-of air, dust, torch, and block is true.
        // That means that at least one must be true, and no
        // pair of two of these can possibly be true.

        const a = is_air.at(pos);
        const b = is_dust.at(pos);
        const c = is_torch.at(pos);
        const d = is_block.at(pos);

        // At least one of A, B, C, D is true
        try cnf.clause(&.{ a, b, c, d }, &.{ 1, 1, 1, 1 });

        // No two can be true at the same time
        try cnf.clause(&.{ a, b }, &.{ 0, 0 });
        try cnf.clause(&.{ a, c }, &.{ 0, 0 });
        try cnf.clause(&.{ a, d }, &.{ 0, 0 });
        try cnf.clause(&.{ b, c }, &.{ 0, 0 });
        try cnf.clause(&.{ b, d }, &.{ 0, 0 });
        try cnf.clause(&.{ c, d }, &.{ 0, 0 });
    }
}

// Prohibits torch variants from overlapping
fn enforceSingleTorchType(cnf: *Cnf) !void {
    for (0..area) |pos| {
        const a = is_torch.at(pos);
        const b = is_left_torch.at(pos);
        const c = is_right_torch.at(pos);
        const d = is_standing_torch.at(pos);

        // If A is false, none of B, C, D can be true
        try cnf.clause(&.{ a, b }, &.{ 1, 0 });
        try cnf.clause(&.{ a, c }, &.{ 1, 0 });
        try cnf.clause(&.{ a, d }, &.{ 1, 0 });

        // If A is true, one of B, C, D must be true
        try cnf.clause(&.{ a, b, c, d }, &.{ 0, 1, 1, 1 });

        // At most one of B, C, D is true
        try cnf.clause(&.{ b, c }, &.{ 0, 0 });
        try cnf.clause(&.{ b, d }, &.{ 0, 0 });
        try cnf.clause(&.{ c, d }, &.{ 0, 0 });
    }
}

// Prohibits dust from hanging in mid-air
fn enforceDustOnBlock(cnf: *Cnf) !void {
    for (0..area) |pos| {
        const x = pos % width;
        const y = pos / width;

        // Dust must have a supporting block, and
        // dust is not possible on the very bottom.
        if (isBlockOffset(x, 0, y, 1)) |block| {
            try cnf.bitimp(is_dust.at(pos), block);
        } else {
            try cnf.bitfalse(is_dust.at(pos));
        }
    }
}

// All input and output blocks are also redstone dust
fn enforceInputOutputDust(cnf: *Cnf) !void {
    for (0..area) |pos| {
        try cnf.bitimp(is_input.at(pos), is_dust.at(pos));
        try cnf.bitimp(is_output.at(pos), is_dust.at(pos));
    }
}

// Torches cannot be hanging mid-air
fn enforceTorchesOnBlocks(cnf: *Cnf) !void {
    for (0..area) |pos| {
        const x = pos % width;
        const y = pos / width;

        // Left torches must have a supporting block, except
        // for torches which would only be supported by out
        // of bounds blocks, which are blocked.
        if (isBlockOffset(x, 1, y, 0)) |block| {
            try cnf.bitimp(is_left_torch.at(pos), block);
        } else {
            try cnf.bitfalse(is_left_torch.at(pos));
        }

        // Right torches must have a supporting block, except
        // for torches which would only be supported by out
        // of bounds blocks, which are blocked.
        if (isBlockOffset(x, -1, y, 0)) |block| {
            try cnf.bitimp(is_right_torch.at(pos), block);
        } else {
            try cnf.bitfalse(is_right_torch.at(pos));
        }

        // Standing torches must have a supporting block, except
        // for torches which would only be supported by out
        // of bounds blocks, which are blocked.
        if (isBlockOffset(x, 0, y, 1)) |block| {
            try cnf.bitimp(is_standing_torch.at(pos), block);
        } else {
            try cnf.bitfalse(is_standing_torch.at(pos));
        }
    }
}

// Constrain inputs and outputs based on their position
fn enforceInputOutputPositions(cnf: *Cnf) !void {
    // Blocks aren't inputs if not in the input list
    for (0..height) |y| {
        inner: for (0..width) |x| {
            for (in_pos) |i|
                if (i[0] == x and i[1] == y)
                    continue :inner;
            const pos = x + y * width;
            try cnf.bitfalse(is_input.at(pos));
        }
    }

    // Blocks *are* inputs if in the input list
    for (in_pos) |i| {
        const pos = i[0] + i[1] * width;
        try cnf.bittrue(is_input.at(pos));
    }

    // Blocks aren't outputs if not in the output list
    for (0..height) |y| {
        inner: for (0..width) |x| {
            for (out_pos) |o|
                if (o[0] == x and o[1] == y)
                    continue :inner;
            const pos = x + y * width;
            try cnf.bitfalse(is_output.at(pos));
        }
    }

    // Blocks *are* outputs if in the output list
    for (out_pos) |o| {
        const pos = o[0] + o[1] * width;
        try cnf.bittrue(is_output.at(pos));
    }
}

// Blocks are weakly powered if adjacent to a powered dust block
fn enforceWeakPowering(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const x = pos % width;
            const y = pos / width;

            // Whether the right dust (if it exists) is powered
            const r = isDustPoweredOffset(state, x, 1, y, 0);
            // Whether the left dust (if it exists) is powered
            const l = isDustPoweredOffset(state, x, -1, y, 0);
            // Whether the top dust (if it exists) is powered
            const t = isDustPoweredOffset(state, x, 0, y, -1);
            // Whether or not the current block is weakly powered
            const p = is_weakly_powered[state].at(pos);
            // Whether or not the current block is indeed a block
            const b = is_block.at(pos);

            // right dust and block implies the block is powered
            if (r) |dust| try cnf.clause(&.{ dust, b, p }, &.{ 0, 0, 1 });
            // left dust and block implies the block is powered
            if (l) |dust| try cnf.clause(&.{ dust, b, p }, &.{ 0, 0, 1 });
            // top dust and block implies the block is powered
            if (t) |dust| try cnf.clause(&.{ dust, b, p }, &.{ 0, 0, 1 });

            // It is either the case that the block is not powered
            try cnf.clausePart(p, 0);
            // Or it is the case that the block is not a block
            try cnf.clausePart(b, 0);
            // Or it is the case that the right dust is powered
            if (r) |dust| try cnf.clausePart(dust, 1);
            // Or it is the case that the left dust is powered
            if (l) |dust| try cnf.clausePart(dust, 1);
            // Or it is the case that the top dust is powered
            if (t) |dust| try cnf.clausePart(dust, 1);
            // If all the dust is off, the block is not powered
            try cnf.clauseEnd();

            // If the block is powered, it must be a block
            try cnf.bitimp(p, b);
        }
    }
}

// Blocks are strongly powered if above a powered torch
fn enforceStrongPowering(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const x = pos % width;
            const y = pos / width;

            const p = is_strongly_powered[state].at(pos);
            const b = is_block.at(pos);

            if (isTorchOnOffset(state, x, 0, y, 1)) |t| {
                // Must be powered if both a block and torch below
                try cnf.bitand(b, t, p);
            } else {
                // Even if it's a block, it's not strongly powered
                try cnf.bitfalse(p);
            }
        }
    }
}

// dust is powered if and only if it's signal strength is not zero
fn enforceDustIsPowered(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const sig_strength = signal_strength[state][pos];
            const dust_powered = is_dust_powered[state].at(pos);
            const not_zero_sig = sig_strength.at(0); // unary :)
            // Power is equal to the lowest unary bit, sweet!
            try cnf.biteql(dust_powered, not_zero_sig);
        }
    }
}

// non-zero signal strengths only exist for dust
fn enforceDustSignalExistence(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const sig_strength = signal_strength[state][pos];
            const not_zero = sig_strength.at(0); // unary :)
            // It must be dust if it has non-zero signal strength
            try cnf.bitimp(not_zero, is_dust.at(pos));
        }
    }
}

// Blocks are powered in general if either weakly or strongly powered
fn enforceGeneralPower(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const w = is_weakly_powered[state].at(pos);
            const s = is_strongly_powered[state].at(pos);
            const p = is_powered[state].at(pos);
            // powered if either weak or strong
            try cnf.bitor(w, s, p);
        }
    }
}

// torches are on if and only if their supporting block is not powered
fn enforceTorchPower(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const x = pos % width;
            const y = pos / width;

            const r_pow_maybe = isPoweredOffset(state, x, 1, y, 0);
            const l_pow_maybe = isPoweredOffset(state, x, -1, y, 0);
            const b_pow_maybe = isPoweredOffset(state, x, 0, y, 1);

            const torch_on = is_torch_on[state].at(pos);
            const s_torch = is_standing_torch.at(pos);
            const r_torch = is_right_torch.at(pos);
            const l_torch = is_left_torch.at(pos);
            const torch = is_torch.at(pos);

            // b_pow l_pow r_pow s_torch r_torch l_torch torch torch_on
            //     .     .     .       .       .       .     0        0
            //     .     .     0       .       .       1     .        1
            //     .     .     1       .       .       1     .        0
            //     .     0     .       .       1       .     .        1
            //     .     1     .       .       1       .     .        0
            //     0     .     .       1       .       .     .        1
            //     1     .     .       1       .       .     .        0

            // If the torch is on, it must be a torch
            // OR: If not a torch, the torch is not on
            try cnf.bitimp(torch_on, torch);

            if (r_pow_maybe) |r_pow| {
                // (NOT r_pow AND l_torch) IMPLIES torch_on
                try cnf.clause(&.{ r_pow, l_torch, torch_on }, &.{ 1, 0, 1 });
                // (r_pow AND l_torch) IMPLIES NOT torch_on
                try cnf.clause(&.{ r_pow, l_torch, torch_on }, &.{ 0, 0, 0 });
            } else {
                // This case isn't possible because we can't have unsupported
                // torches, so we don't need to say l_torch implies torch_on.
            }

            if (l_pow_maybe) |l_pow| {
                // (NOT l_pow AND r_torch) IMPLIES torch_on
                try cnf.clause(&.{ l_pow, r_torch, torch_on }, &.{ 1, 0, 1 });
                // (l_pow and r_torch) IMPLIES NOT torch_on
                try cnf.clause(&.{ l_pow, r_torch, torch_on }, &.{ 0, 0, 0 });
            } else {
                // This case isn't possible because we can't have unsupported
                // torches, so we don't need to say r_torch implies torch_on.
            }

            if (b_pow_maybe) |b_pow| {
                // (NOT b_pow AND s_torch) IMPLIES torch_on
                try cnf.clause(&.{ b_pow, s_torch, torch_on }, &.{ 1, 0, 1 });
                // (b_pow AND s_torch) IMPLIES NOT torch_on
                try cnf.clause(&.{ b_pow, s_torch, torch_on }, &.{ 0, 0, 0 });
            } else {
                // This case isn't possible because we can't have unsupported
                // torches, so we don't need to say s_torch implies torch_on.
            }
        }
    }
}

// forces inputs and outputs to be certain values
fn enforceInputOutput(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (in_pos, 0..) |pos, idx| {
            const top = max_power - 1;
            const flat_pos = pos[0] + pos[1] * width;
            const signal = signal_strength[state][flat_pos];
            // The top unary bit of our input signal strength is
            // equal to the truth table input value for the state.
            // In other words, fully power the input state on '1'.
            switch (@as(u1, @truncate(state >> @intCast(idx)))) {
                // On an input of 0, the signal strength is zero
                0 => try cnf.clause(&.{signal.at(0)}, &.{0}),
                // On an input of 1, the signal strength is maximized
                1 => try cnf.clause(&.{signal.at(top)}, &.{1}),
            }
        }

        for (out_pos, 0..) |pos, idx| {
            const flat_pos = pos[0] + pos[1] * width;
            const pow = is_dust_powered[state].at(flat_pos);

            switch (idx) {
                0 => switch (state) {
                    // For each input state, the output
                    // is either powered or not powered.
                    0b00 => try cnf.clause(&.{pow}, &.{0}),
                    0b01 => try cnf.clause(&.{pow}, &.{1}),
                    0b10 => try cnf.clause(&.{pow}, &.{1}),
                    0b11 => try cnf.clause(&.{pow}, &.{0}),
                    else => unreachable,
                },
                // place other outputs down here
                else => unreachable,
            }
        }
    }
}

// Signal strength can only be propagated if the block is dust and not input
fn enforceCanPropagate(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const dust = is_dust.at(pos);
            const input = is_input.at(pos);
            const prop = can_propagate[state].at(pos);

            // propagation implies that it is dust
            try cnf.bitimp(prop, dust);
            // it can't propagate and also be an input
            try cnf.clause(&.{ prop, input }, &.{ 0, 0 });
            // if dust and not an input, it must be able to propagate
            try cnf.clause(&.{ prop, input, dust }, &.{ 1, 1, 0 });
        }
    }
}

// Signal strength can decay if not directly powered and if it can propagate
fn enforceCanDecay(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const direct = is_directly_powered[state].at(pos);
            const prop = can_propagate[state].at(pos);
            const decay = can_decay[state].at(pos);

            // decay implies that signal can be propagated
            try cnf.bitimp(decay, prop);
            // it can't decay and also be directly powered
            try cnf.clause(&.{ decay, direct }, &.{ 0, 0 });
            // if propagatable and not directly powered, it must decay
            try cnf.clause(&.{ prop, direct, decay }, &.{ 0, 1, 1 });
        }
    }
}

// SUP = SIG AND NOT BLOCK AND DUST

// SIG BLK DST SUP
//   0   0   0   0
//   0   0   1   0
//   0   1   0   0
//   0   1   1   0

//   1   1   0   0
//   1   1   1   0

//   1   0   0   0
//   1   0   1   1

// SIG IMPLIES NOT SUP
// BLK IMPLIES NOT SUP
// SUP IMPLIES DST
// (SIG AND NOT BLK AND DST) IMPLIES SUP

// Set the supplyable signal strengths of nearby blocks depending on the
// signal strength of nearby blocks, factoring in impediments like blocks.
fn constrainSupplyableSignal(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const x = pos % width;
            const y = pos / width;

            const t_block_maybe = isBlockOffset(x, 0, y, -1);
            const l_block_maybe = isBlockOffset(x, -1, y, 0);
            const r_block_maybe = isBlockOffset(x, 1, y, 0);

            const tl_sig_maybe = signalStrengthOffset(state, x, -1, y, -1);
            const bl_sig_maybe = signalStrengthOffset(state, x, -1, y, 1);
            const tr_sig_maybe = signalStrengthOffset(state, x, 1, y, -1);
            const br_sig_maybe = signalStrengthOffset(state, x, 1, y, 1);

            const tl_sup = supply_top_left[state][pos];
            const bl_sup = supply_bottom_left[state][pos];
            const tr_sup = supply_top_right[state][pos];
            const br_sup = supply_bottom_right[state][pos];

            for (0..max_power) |off| {
                if (tl_sig_maybe) |tl_sig| {
                    // SUP = SIG AND NOT BLOCK AND DUST
                    const sup = tl_sup.at(off);
                    const sig = tl_sig.at(off);
                    const block = t_block_maybe.?;
                    const dust = is_dust.at(pos);

                    const temp_a = cnf.alloc(1).idx; // NOT BLOCK
                    try cnf.bitnot(block, temp_a);
                    const temp_b = cnf.alloc(1).idx; // SIG AND NOT BLOCK
                    try cnf.bitand(sig, temp_a, temp_b);
                    try cnf.bitand(dust, temp_b, sup); // SIG AND NOT BLOCK AND DUST

                    // // If the supply bit is set, it implies dust
                    // try cnf.bitimp(sup, dust);
                    // // If the supply bit is set, it implies the signal bit
                    // try cnf.bitimp(sup, sig);
                    // // There is either no supply bit, or no block
                    // try cnf.clause(&.{ sup, block }, &.{ 0, 0 });
                    // // Supply requires dust, signal, and no block
                    // try cnf.clause(
                    //     &.{ sup, block, sig, dust },
                    //     &.{ 0, 0, 1, 1 },
                    // );
                } else {
                    // Supplyable signal strength from the top left is zero
                    try cnf.bitfalse(tl_sup.at(off));
                }

                if (bl_sig_maybe) |bl_sig| {
                    // SUP = SIG AND NOT BLOCK AND DUST
                    const sup = bl_sup.at(off);
                    const sig = bl_sig.at(off);
                    const block = l_block_maybe.?;
                    const dust = is_dust.at(pos);

                    // // If the supply bit is set, it implies dust
                    // try cnf.bitimp(sup, dust);
                    // // If the supply bit is set, it implies the signal bit
                    // try cnf.bitimp(sup, sig);
                    // // There is either no supply bit, or no block
                    // try cnf.clause(&.{ sup, block }, &.{ 0, 0 });
                    // // Supply requires dust, signal, and no block
                    // try cnf.clause(
                    //     &.{ sup, block, sig, dust },
                    //     &.{ 0, 0, 1, 1 },
                    // );

                    const temp_a = cnf.alloc(1).idx; // NOT BLOCK
                    try cnf.bitnot(block, temp_a);
                    const temp_b = cnf.alloc(1).idx; // SIG AND NOT BLOCK
                    try cnf.bitand(sig, temp_a, temp_b);
                    try cnf.bitand(dust, temp_b, sup); // SIG AND NOT BLOCK AND DUST
                } else {
                    // Supplyable signal strength from the bottom left is zero
                    try cnf.bitfalse(bl_sup.at(off));
                }

                if (tr_sig_maybe) |tr_sig| {
                    // SUP = SIG AND NOT BLOCK AND DUST
                    const sup = tr_sup.at(off);
                    const sig = tr_sig.at(off);
                    const block = t_block_maybe.?;
                    const dust = is_dust.at(pos);

                    // // If the supply bit is set, it implies dust
                    // try cnf.bitimp(sup, dust);
                    // // If the supply bit is set, it implies the signal bit
                    // try cnf.bitimp(sup, sig);
                    // // There is either no supply bit, or no block
                    // try cnf.clause(&.{ sup, block }, &.{ 0, 0 });
                    // // Supply requires dust, signal, and no block
                    // try cnf.clause(
                    //     &.{ sup, block, sig, dust },
                    //     &.{ 0, 0, 1, 1 },
                    // );

                    const temp_a = cnf.alloc(1).idx; // NOT BLOCK
                    try cnf.bitnot(block, temp_a);
                    const temp_b = cnf.alloc(1).idx; // SIG AND NOT BLOCK
                    try cnf.bitand(sig, temp_a, temp_b);
                    try cnf.bitand(dust, temp_b, sup); // SIG AND NOT BLOCK AND DUST
                } else {
                    // Supplyable signal strength from the top right is zero
                    try cnf.bitfalse(tr_sup.at(off));
                }

                if (br_sig_maybe) |br_sig| {
                    // SUP = SIG AND NOT BLOCK AND DUST
                    const sup = br_sup.at(off);
                    const sig = br_sig.at(off);
                    const block = r_block_maybe.?;
                    const dust = is_dust.at(pos);

                    // // If the supply bit is set, it implies dust
                    // try cnf.bitimp(sup, dust);
                    // // If the supply bit is set, it implies the signal bit
                    // try cnf.bitimp(sup, sig);
                    // // There is either no supply bit, or no block
                    // try cnf.clause(&.{ sup, block }, &.{ 0, 0 });
                    // // Supply requires dust, signal, and no block
                    // try cnf.clause(
                    //     &.{ sup, block, sig, dust },
                    //     &.{ 0, 0, 1, 1 },
                    // );

                    const temp_a = cnf.alloc(1).idx; // NOT BLOCK
                    try cnf.bitnot(block, temp_a);
                    const temp_b = cnf.alloc(1).idx; // SIG AND NOT BLOCK
                    try cnf.bitand(sig, temp_a, temp_b);
                    try cnf.bitand(dust, temp_b, sup); // SIG AND NOT BLOCK AND DUST
                } else {
                    // Supplyable signal strength from the bottom right is zero
                    try cnf.bitfalse(br_sup.at(off));
                }
            }
        }
    }
}

// Set the maximum neighboring signal strength depending on the signal strength
// of neighboring blocks, and whether the dust would connect (no impediments).
fn constrainMaxNeighborStrength(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const x = pos % width;
            const y = pos / width;

            const tl_sup = supply_top_left[state][pos];
            const bl_sup = supply_bottom_left[state][pos];
            const tr_sup = supply_top_right[state][pos];
            const br_sup = supply_bottom_right[state][pos];

            const l_sup_maybe = signalStrengthOffset(state, x, -1, y, 0);
            const r_sup_maybe = signalStrengthOffset(state, x, 1, y, 0);

            const max_signal = max_signal_strength[state][pos];

            for (0..max_power) |off| {
                const max = max_signal.at(off);

                // power from the top left implies at least this much power
                try cnf.bitimp(tl_sup.at(off), max);
                // power from the bottom left implies at least this much power
                try cnf.bitimp(bl_sup.at(off), max);
                // power from the top right implies at least this much power
                try cnf.bitimp(tr_sup.at(off), max);
                // power from the bottom right implies at least this much power
                try cnf.bitimp(br_sup.at(off), max);
                // power from the left implies at least this much power
                if (l_sup_maybe) |l_sup| try cnf.bitimp(l_sup.at(off), max);
                // power from the right implies at least this much power
                if (r_sup_maybe) |r_sup| try cnf.bitimp(r_sup.at(off), max);

                // Either the power is less than this level
                try cnf.clausePart(max, 0);
                // Or the top left has at least this much power
                try cnf.clausePart(tl_sup.at(off), 1);
                // Or the bottom left has at least this much power
                try cnf.clausePart(bl_sup.at(off), 1);
                // Or the top right has at least this much power
                try cnf.clausePart(tr_sup.at(off), 1);
                // Or the bottom right has at least this much power
                try cnf.clausePart(br_sup.at(off), 1);
                // Or the left has at least this much power
                if (l_sup_maybe) |l_sup| try cnf.clausePart(l_sup.at(off), 1);
                // Or the right has at least this much power
                if (r_sup_maybe) |r_sup| try cnf.clausePart(r_sup.at(off), 1);
                // The power is at most the power of the supply
                try cnf.clauseEnd();
            }
        }
    }
}

// Set dust signal strength to max & set "direct" power boolean depending
// on whether cardinal blocks and torches were directly powered themselves.
fn enforceDirectPowering(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const x = pos % width;
            const y = pos / width;

            const prop = can_propagate[state].at(pos);
            const direct = is_directly_powered[state].at(pos);

            const t_on_maybe = isTorchOnOffset(state, x, 0, y, -1);
            const l_on_maybe = isTorchOnOffset(state, x, -1, y, 0);
            const r_on_maybe = isTorchOnOffset(state, x, 1, y, 0);

            const b_pow_maybe = isStronglyPoweredOffset(state, x, 0, y, 1);
            const l_pow_maybe = isStronglyPoweredOffset(state, x, -1, y, 0);
            const r_pow_maybe = isStronglyPoweredOffset(state, x, 1, y, 0);

            if (t_on_maybe) |t_on|
                // Signal propagation AND t_on on IMPLIES direct powering
                try cnf.clause(&.{ prop, t_on, direct }, &.{ 0, 0, 1 });

            if (l_on_maybe) |l_on|
                // Signal propagation AND l_on on IMPLIES direct powering
                try cnf.clause(&.{ prop, l_on, direct }, &.{ 0, 0, 1 });

            if (r_on_maybe) |r_on|
                // Signal propagation AND r_on on IMPLIES direct powering
                try cnf.clause(&.{ prop, r_on, direct }, &.{ 0, 0, 1 });

            if (b_pow_maybe) |b_pow|
                // Signal propagation AND b_pow on IMPLIES direct powering
                try cnf.clause(&.{ prop, b_pow, direct }, &.{ 0, 0, 1 });

            if (l_pow_maybe) |l_pow|
                // Signal propagation AND l_pow on IMPLIES direct powering
                try cnf.clause(&.{ prop, l_pow, direct }, &.{ 0, 0, 1 });

            if (r_pow_maybe) |r_pow|
                // Signal propagation AND r_pow on IMPLIES direct powering
                try cnf.clause(&.{ prop, r_pow, direct }, &.{ 0, 0, 1 });

            // direct powering implies that the dust is at max signal strength
            const signal = signal_strength[state][pos];
            try cnf.bitimp(direct, signal.at(max_power - 1));

            // Either it's not directly powered:
            try cnf.clausePart(direct, 0);
            // Or it is powered from a torch above:
            if (t_on_maybe) |t_on| try cnf.clausePart(t_on, 1);
            // Or it is powered from a torch left:
            if (l_on_maybe) |l_on| try cnf.clausePart(l_on, 1);
            // Or it is powered from a torch right:
            if (r_on_maybe) |r_on| try cnf.clausePart(r_on, 1);
            // Or it is powered from a block below:
            if (b_pow_maybe) |b_pow| try cnf.clausePart(b_pow, 1);
            // Or it is powered from a block left:
            if (l_pow_maybe) |l_pow| try cnf.clausePart(l_pow, 1);
            // Or it is powered from a block right:
            if (r_pow_maybe) |r_pow| try cnf.clausePart(r_pow, 1);
            // Constrain the block to be directly powered:
            try cnf.clauseEnd();
        }
    }
}

// Constrain the decayable strength by decrementing the max supply strength
fn constrainDecayableStrength(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const max_supply = max_signal_strength[state][pos];
            const strength = decay_strength[state][pos];
            try cnf.unarySatDec(max_supply, strength);
        }
    }
}

// If signal can decay, it will be equal to the saturating decrement of the
// maximum signal of it's neighbors, depending on which ones are connected.
fn enforceSignalDecay(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            for (0..max_power) |off| {
                // Whether we can decay at this dust
                const decay = can_decay[state].at(pos);
                // The signal strength of this dust
                const signal = signal_strength[state][pos].at(off);
                // The decayed supply from surroundings
                const supply = decay_strength[state][pos].at(off);

                // decay IMPLIES (signal EQUALS supply)
                try cnf.clause(&.{ decay, signal, supply }, &.{ 0, 0, 1 });
                try cnf.clause(&.{ decay, signal, supply }, &.{ 0, 1, 0 });
            }
        }
    }
}

// Constrain all numbers we are working with to be unary
fn constrainUnaryNumbers(cnf: *Cnf) !void {
    for (0..area) |pos| {
        try cnf.unaryConstrain(segment_id[pos]);
    }

    for (0..states) |state| {
        for (0..area) |pos| {
            inline for (&.{
                signal_strength,  max_signal_strength,
                supply_top_left,  supply_bottom_left,
                supply_top_right, supply_bottom_right,
                decay_strength,
            }) |unary| {
                try cnf.unaryConstrain(unary[state][pos]);
            }
        }
    }
}

// torches have lesser ID than the block they are on
fn restrictTorchBlockId(cnf: *Cnf) !void {
    for (0..area) |pos| {
        const id_this = segment_id[pos];
        const x = pos % width;
        const y = pos / width;

        if (segmentIdOffset(x, -1, y, 0)) |id_block| {
            const block = isBlockOffset(x, -1, y, 0).?;
            const torch = is_right_torch.at(pos);

            const id_lt = cnf.alloc(1).idx;
            try cnf.unaryLT(id_this, id_block, id_lt);
            // (BLOCK AND TORCH) IMPLIES (id_this < id_block)
            try cnf.clause(&.{ block, torch, id_lt }, &.{ 0, 0, 1 });
        }

        if (segmentIdOffset(x, 1, y, 0)) |id_block| {
            const block = isBlockOffset(x, 1, y, 0).?;
            const torch = is_left_torch.at(pos);

            const id_lt = cnf.alloc(1).idx;
            try cnf.unaryLT(id_this, id_block, id_lt);
            // (BLOCK AND TORCH) IMPLIES (id_this < id_block)
            try cnf.clause(&.{ block, torch, id_lt }, &.{ 0, 0, 1 });
        }

        if (segmentIdOffset(x, 0, y, 1)) |id_block| {
            const block = isBlockOffset(x, 0, y, 1).?;
            const torch = is_standing_torch.at(pos);

            const id_lt = cnf.alloc(1).idx;
            try cnf.unaryLT(id_this, id_block, id_lt);
            // (BLOCK AND TORCH) IMPLIES (id_this < id_block)
            try cnf.clause(&.{ block, torch, id_lt }, &.{ 0, 0, 1 });
        }
    }
}

// blocks above torches have lesser ID than the torch they are above
fn restrictBlockTorchId(cnf: *Cnf) !void {
    for (0..area) |pos| {
        const id_this = segment_id[pos];
        const x = pos % width;
        const y = pos / width;

        if (segmentIdOffset(x, 0, y, 1)) |id_block| {
            const torch = isTorchOffset(x, 0, y, 1).?;
            const block = is_block.at(pos);

            const id_lt = cnf.alloc(1).idx;
            try cnf.unaryLT(id_this, id_block, id_lt);
            // (TORCH AND BLOCK) IMPLIES (id_this < id_block)
            try cnf.clause(&.{ torch, block, id_lt }, &.{ 0, 0, 1 });
        }
    }
}

// blocks have equal IDs to the dust next by or above them
fn restrictBlockDustId(cnf: *Cnf) !void {
    for (0..area) |pos| {
        const id_this = segment_id[pos];
        const x = pos % width;
        const y = pos / width;

        if (segmentIdOffset(x, -1, y, 0)) |id_block| {
            const dust = isDustOffset(x, -1, y, 0).?;
            const block = is_block.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (DUST AND BLOCK) IMPLIES (NOT ID_NE)
            try cnf.clause(&.{ dust, block, id_ne }, &.{ 0, 0, 0 });
        }

        if (segmentIdOffset(x, 1, y, 0)) |id_block| {
            const dust = isDustOffset(x, 1, y, 0).?;
            const block = is_block.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (DUST AND BLOCK) IMPLIES (NOT ID_NE)
            try cnf.clause(&.{ dust, block, id_ne }, &.{ 0, 0, 0 });
        }

        if (segmentIdOffset(x, 0, y, -1)) |id_block| {
            const dust = isDustOffset(x, 0, y, -1).?;
            const block = is_block.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (DUST AND BLOCK) IMPLIES (NOT ID_NE)
            try cnf.clause(&.{ dust, block, id_ne }, &.{ 0, 0, 0 });
        }
    }
}

// dust have lesser ID than the torch next to or above them
fn restrictDustTorchId(cnf: *Cnf) !void {
    for (0..area) |pos| {
        const id_this = segment_id[pos];
        const x = pos % width;
        const y = pos / width;

        if (segmentIdOffset(x, -1, y, 0)) |id_block| {
            const torch = isTorchOffset(x, -1, y, 0).?;
            const dust = is_dust.at(pos);

            const id_lt = cnf.alloc(1).idx;
            try cnf.unaryLT(id_this, id_block, id_lt);
            // (TORCH AND DUST) IMPLIES (id_this < id_block)
            try cnf.clause(&.{ torch, dust, id_lt }, &.{ 0, 0, 1 });
        }

        if (segmentIdOffset(x, 1, y, 0)) |id_block| {
            const torch = isTorchOffset(x, 1, y, 0).?;
            const dust = is_dust.at(pos);

            const id_lt = cnf.alloc(1).idx;
            try cnf.unaryLT(id_this, id_block, id_lt);
            // (TORCH AND DUST) IMPLIES (id_this < id_block)
            try cnf.clause(&.{ torch, dust, id_lt }, &.{ 0, 0, 1 });
        }

        if (segmentIdOffset(x, 0, y, -1)) |id_block| {
            const torch = isTorchOffset(x, 0, y, -1).?;
            const dust = is_dust.at(pos);

            const id_lt = cnf.alloc(1).idx;
            try cnf.unaryLT(id_this, id_block, id_lt);
            // (TORCH AND DUST) IMPLIES (id_this < id_block)
            try cnf.clause(&.{ torch, dust, id_lt }, &.{ 0, 0, 1 });
        }
    }
}

// connected dust have equal IDs
fn restrictDustGroupId(cnf: *Cnf) !void {
    for (0..area) |pos| {
        const id_this = segment_id[pos];
        const x = pos % width;
        const y = pos / width;

        const t_block_maybe = isBlockOffset(x, 0, y, -1);
        const l_block_maybe = isBlockOffset(x, -1, y, 0);
        const r_block_maybe = isBlockOffset(x, 1, y, 0);

        if (segmentIdOffset(x, -1, y, -1)) |id_block| {
            const other = isDustOffset(x, -1, y, -1).?;
            const block = t_block_maybe.?;
            const dust = is_dust.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (other AND NOT block AND dust) IMPLIES (NOT id_ne)
            try cnf.clause(&.{ other, block, dust, id_ne }, &.{ 0, 1, 0, 0 });
        }

        if (segmentIdOffset(x, -1, y, 1)) |id_block| {
            const other = isDustOffset(x, -1, y, 1).?;
            const block = l_block_maybe.?;
            const dust = is_dust.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (other AND NOT block AND dust) IMPLIES (NOT id_ne)
            try cnf.clause(&.{ other, block, dust, id_ne }, &.{ 0, 1, 0, 0 });
        }

        if (segmentIdOffset(x, 1, y, -1)) |id_block| {
            const other = isDustOffset(x, 1, y, -1).?;
            const block = t_block_maybe.?;
            const dust = is_dust.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (other AND NOT block AND dust) IMPLIES (NOT id_ne)
            try cnf.clause(&.{ other, block, dust, id_ne }, &.{ 0, 1, 0, 0 });
        }

        if (segmentIdOffset(x, 1, y, 1)) |id_block| {
            const other = isDustOffset(x, 1, y, 1).?;
            const block = r_block_maybe.?;
            const dust = is_dust.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (other AND NOT block AND dust) IMPLIES (NOT id_ne)
            try cnf.clause(&.{ other, block, dust, id_ne }, &.{ 0, 1, 0, 0 });
        }

        if (segmentIdOffset(x, -1, y, 0)) |id_block| {
            const other = isDustOffset(x, -1, y, 0).?;
            const dust = is_dust.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (other AND dust) IMPLIES (NOT id_ne)
            try cnf.clause(&.{ other, dust, id_ne }, &.{ 0, 0, 0 });
        }

        if (segmentIdOffset(x, 1, y, 0)) |id_block| {
            const other = isDustOffset(x, 1, y, 0).?;
            const dust = is_dust.at(pos);

            const id_ne = cnf.alloc(1).idx;
            try cnf.unaryNE(id_this, id_block, id_ne);
            // (other AND dust) IMPLIES (NOT id_ne)
            try cnf.clause(&.{ other, dust, id_ne }, &.{ 0, 0, 0 });
        }
    }
}

fn encodeMain(io: Io, _: Allocator) !void {
    const cwd = Io.Dir.cwd();

    // Create a temporary file and writer to hold the CNF clauses
    var temp_closed: bool = false;
    const temp_file = try cwd.createFile(io, "clauses.cnf", .{});
    errdefer if (!temp_closed) temp_file.close(io);
    var temp_buffer: [4096]u8 = undefined;
    var temp_writer = temp_file.writer(io, &temp_buffer);
    const temp = &temp_writer.interface;

    var cnf: Cnf = .init(temp);
    defer cnf.deinit();

    std.debug.print("initializeGlobals...\n", .{});
    try initializeGlobals(&cnf);
    std.debug.print("enforceCanDecay...\n", .{});
    try enforceCanDecay(&cnf);
    std.debug.print("enforceTorchPower...\n", .{});
    try enforceTorchPower(&cnf);
    std.debug.print("enforceSignalDecay...\n", .{});
    try enforceSignalDecay(&cnf);
    std.debug.print("enforceDustOnBlock...\n", .{});
    try enforceDustOnBlock(&cnf);
    std.debug.print("enforceInputOutput...\n", .{});
    try enforceInputOutput(&cnf);
    std.debug.print("enforceGeneralPower...\n", .{});
    try enforceGeneralPower(&cnf);
    std.debug.print("restrictBlockDustId...\n", .{});
    try restrictBlockDustId(&cnf);
    std.debug.print("enforceCanPropagate...\n", .{});
    try enforceCanPropagate(&cnf);
    std.debug.print("restrictDustGroupId...\n", .{});
    try restrictDustGroupId(&cnf);
    std.debug.print("enforceWeakPowering...\n", .{});
    try enforceWeakPowering(&cnf);
    std.debug.print("restrictDustTorchId...\n", .{});
    try restrictDustTorchId(&cnf);
    std.debug.print("restrictBlockTorchId...\n", .{});
    try restrictBlockTorchId(&cnf);
    std.debug.print("restrictTorchBlockId...\n", .{});
    try restrictTorchBlockId(&cnf);
    std.debug.print("enforceDustIsPowered...\n", .{});
    try enforceDustIsPowered(&cnf);
    std.debug.print("enforceDirectPowering...\n", .{});
    try enforceDirectPowering(&cnf);
    std.debug.print("enforceStrongPowering...\n", .{});
    try enforceStrongPowering(&cnf);
    std.debug.print("constrainUnaryNumbers...\n", .{});
    try constrainUnaryNumbers(&cnf);
    std.debug.print("enforceSingleTorchType...\n", .{});
    try enforceSingleTorchType(&cnf);
    std.debug.print("enforceSingleBlockType...\n", .{});
    try enforceSingleBlockType(&cnf);
    std.debug.print("enforceInputOutputDust...\n", .{});
    try enforceInputOutputDust(&cnf);
    std.debug.print("enforceTorchesOnBlocks...\n", .{});
    try enforceTorchesOnBlocks(&cnf);
    std.debug.print("constrainSupplyableSignal...\n", .{});
    try constrainSupplyableSignal(&cnf);
    std.debug.print("enforceDustSignalExistence...\n", .{});
    try enforceDustSignalExistence(&cnf);
    std.debug.print("constrainDecayableStrength...\n", .{});
    try constrainDecayableStrength(&cnf);
    std.debug.print("enforceInputOutputPositions...\n", .{});
    try enforceInputOutputPositions(&cnf);
    std.debug.print("constrainMaxNeighborStrength...\n", .{});
    try constrainMaxNeighborStrength(&cnf);
    std.debug.print("Saving...\n", .{});

    // Open "real_file" (real output) and create buffered writer "real"
    const real_file = try cwd.createFile(io, "problem.cnf", .{});
    defer real_file.close(io);
    var real_buffer: [4096]u8 = undefined;
    var real_writer = real_file.writer(io, &real_buffer);
    const real = &real_writer.interface;

    // Flush completed CNF clauses, close the temp file, and write the header
    try cnf.flush();
    try cnf.header(real);
    temp_file.close(io);
    temp_closed = true;

    // Open the temp file for reading and stream it into the output file
    const read_file = try cwd.openFile(io, "clauses.cnf", .{});
    defer read_file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var temp_reader = temp_file.reader(io, &read_buffer);
    const reader = &temp_reader.interface;
    _ = try reader.streamRemaining(real);

    // Flush output sent to the real file and delete the temporary file
    try real.flush();
    try cwd.deleteFile(io, "clauses.cnf");
}
