const std = @import("std");
const Allocating = Writer.Allocating;
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const Io = std.Io;

// ----------------------------------------------------------------------- MAIN

pub fn main() !void {
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.ioBasic();

    var args = try std.process.argsWithAllocator(gpa);
    defer args.deinit();

    const process_name = args.next().?;
    if (args.next()) |mode_str| {
        if (std.mem.eql(u8, mode_str, "e")) {
            return try encodeMain(io);
        } else if (std.mem.eql(u8, mode_str, "d")) {
            return try decodeMain(io);
        }
    }

    std.debug.print(
        \\ USAGE: {s} [MODE]
        \\   MODE:
        \\     e --> encodes CNF for finding half-adder in one-wide redstone
        \\     d --> reads solution CNF and produces ASCII diagram of redstone
        \\
    , .{process_name});
}

// simulating every possible state in parallel
const states = 1 << in_pos.len;
// length of the redstone build in number of blocks
const width = 40;
// height of the redstone build in number of blocks
const height = 20;

const in_pos: []const [2]usize = &.{
    .{ 0, height - 2 },
    .{ 0, height - 4 },
    .{ 0, height - 6 },
};

const out_pos: []const [2]usize = &.{
    .{ width - 1, height - 2 },
    .{ width - 1, height - 4 },
};

var false_bit: u64 = undefined;
var true_bit: u64 = undefined;

// "air" is a lack of dust, torch, or block
var is_air: [width][height]u64 = undefined;
// "dust" is a lack of air, torch, or block
var is_dust: [width][height]u64 = undefined;
// "torch" is a lack of air, dust, or block
var is_torch: [width][height]u64 = undefined;
// "block" is a lack of air, dust, or torch
var is_block: [width][height]u64 = undefined;

// "inputs" are redstone dust
var is_input: [width][height]u64 = undefined;
// "outputs" are redstone dust
var is_output: [width][height]u64 = undefined;

// standing torches are connected to the block below them
var is_standing_torch: [width][height]u64 = undefined;
// left torches are connected to the block on their right
var is_left_torch: [width][height]u64 = undefined;
// right torches are connected to the block on their left
var is_right_torch: [width][height]u64 = undefined;

// torch state, whether they are on or off
var is_torch_on: [states][width][height]u64 = undefined;
// blocks that are powered by redstone dust
var is_weakly_powered: [states][width][height]u64 = undefined;
// blocks that are powered by redstone torches
var is_strongly_powered: [states][width][height]u64 = undefined;
// whether the dust has a signal strength greater than zero
var is_dust_powered: [states][width][height]u64 = undefined;
// [4]u64 to represent a 4 bit integer (for power signals [0, 16))
var signal_strength: [states][width][height][4]u64 = undefined;

fn initializeGlobals() !void {
    false_bit = alloc();
    try constrain(&.{false_bit}, &.{0});
    true_bit = alloc();
    try constrain(&.{true_bit}, &.{1});

    for (0..width) |w| {
        for (0..height) |h| {
            is_air[w][h] = alloc();
            is_dust[w][h] = alloc();
            is_torch[w][h] = alloc();
            is_block[w][h] = alloc();
            is_input[w][h] = alloc();
            is_output[w][h] = alloc();
            is_standing_torch[w][h] = alloc();
            is_left_torch[w][h] = alloc();
            is_right_torch[w][h] = alloc();

            for (0..states) |s| {
                is_torch_on[s][w][h] = alloc();
                is_weakly_powered[s][w][h] = alloc();
                is_strongly_powered[s][w][h] = alloc();
                is_dust_powered[s][w][h] = alloc();

                for (0..4) |b| {
                    signal_strength[s][w][h][b] = alloc();
                }
            }
        }
    }
}

fn decodeMain(io: Io) !void {
    try initializeGlobals();

    var stdin_buffer: [64]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_file_reader = stdin_file.reader(io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    var stdout_buffer: [64]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_file_writer = stdout_file.writer(io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var allocating: Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    const line_store = &allocating.writer;

    var block_is_air: [width][height]bool = @splat(@splat(false));
    var block_is_block: [width][height]bool = @splat(@splat(false));
    var block_is_dust: [width][height]bool = @splat(@splat(false));
    var block_is_torch: [width][height]bool = @splat(@splat(false));

    var block_is_input: [width][height]bool = @splat(@splat(false));
    var block_is_output: [width][height]bool = @splat(@splat(false));

    var block_is_left_torch: [width][height]bool = @splat(@splat(false));
    var block_is_right_torch: [width][height]bool = @splat(@splat(false));
    var block_is_standing_torch: [width][height]bool = @splat(@splat(false));

    while (true) {
        allocating.clearRetainingCapacity();
        const stream = stdin.streamDelimiter(line_store, '\n');
        if (stdin.end != 0) stdin.toss(1);
        const count = stream catch break;

        var stored = line_store.buffered();
        if (count == 0 or stored[0] != 'v') continue;

        var toker = std.mem.tokenizeAny(u8, stored[2..], " \t\r\n");
        outer: while (toker.next()) |int_string| {
            const encoded = try std.fmt.parseInt(i64, int_string, 10);
            if (encoded < 0) continue;
            const decoded = @abs(encoded);

            for (0..width) |w| {
                for (0..height) |h| {
                    if (decoded == is_air[w][h]) {
                        block_is_air[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_dust[w][h]) {
                        block_is_dust[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_torch[w][h]) {
                        block_is_torch[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_block[w][h]) {
                        block_is_block[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_input[w][h]) {
                        block_is_input[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_output[w][h]) {
                        block_is_output[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_standing_torch[w][h]) {
                        block_is_standing_torch[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_left_torch[w][h]) {
                        block_is_left_torch[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_right_torch[w][h]) {
                        block_is_right_torch[w][h] = true;
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
                    if (block_is_input[x][y]) {
                        try stdout.writeByte(input_display[sub_row][sub_col]);
                    } else if (block_is_output[x][y]) {
                        try stdout.writeByte(output_display[sub_row][sub_col]);
                    } else if (block_is_air[x][y]) {
                        try stdout.writeByte(air_display[sub_row][sub_col]);
                    } else if (block_is_block[x][y]) {
                        try stdout.writeByte(block_display[sub_row][sub_col]);
                    } else if (block_is_dust[x][y]) {
                        try stdout.writeByte(dust_display[sub_row][sub_col]);
                    } else if (block_is_torch[x][y]) {
                        if (block_is_left_torch[x][y]) {
                            try stdout.writeByte(left_torch_display[sub_row][sub_col]);
                        } else if (block_is_right_torch[x][y]) {
                            try stdout.writeByte(right_torch_display[sub_row][sub_col]);
                        } else if (block_is_standing_torch[x][y]) {
                            try stdout.writeByte(standing_torch_display[sub_row][sub_col]);
                        } else {
                            try stdout.writeByte(unknown_display[sub_row][sub_col]);
                        }
                    } else {
                        try stdout.writeByte(unknown_display[sub_row][sub_col]);
                    }
                }
                try stdout.writeByte(' ');
                try stdout.writeByte(' ');
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

fn isBlockOffset(x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_block[sum_x][sum_y];
}

fn isDustPoweredOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_dust_powered[state][sum_x][sum_y];
}

fn isTorchOnOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_torch_on[state][sum_x][sum_y];
}

fn isWeaklyPoweredOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_weakly_powered[state][sum_x][sum_y];
}

fn isStronglyPoweredOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_strongly_powered[state][sum_x][sum_y];
}

fn signalStrengthOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) [4]u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return @splat(false_bit);
    return signal_strength[state][sum_x][sum_y];
}

// Prohibits air, dust, torch, and blocks from overlapping
fn enforceSingleBlockType() !void {
    for (0..width) |x| {
        for (0..height) |y| {
            // Exactly one-of air, dust, torch, and block is true.
            // That means that at least one must be true, and no
            // pair of two of these can possibly be true.

            const a = is_air[x][y];
            const b = is_dust[x][y];
            const c = is_torch[x][y];
            const d = is_block[x][y];

            // At least one of A, B, C, D is true
            try constrain(&.{ a, b, c, d }, &.{ 1, 1, 1, 1 });

            // No two can be true at the same time
            try constrain(&.{ a, b }, &.{ 0, 0 });
            try constrain(&.{ a, c }, &.{ 0, 0 });
            try constrain(&.{ a, d }, &.{ 0, 0 });
            try constrain(&.{ b, c }, &.{ 0, 0 });
            try constrain(&.{ b, d }, &.{ 0, 0 });
            try constrain(&.{ c, d }, &.{ 0, 0 });
        }
    }
}

// Prohibits torch variants from overlapping
fn enforceSingleTorchType() !void {
    for (0..width) |x| {
        for (0..height) |y| {
            const a = is_torch[x][y];
            const b = is_left_torch[x][y];
            const c = is_right_torch[x][y];
            const d = is_standing_torch[x][y];

            // If A is false, none of B, C, D can be true
            try constrain(&.{ a, b }, &.{ 1, 0 });
            try constrain(&.{ a, c }, &.{ 1, 0 });
            try constrain(&.{ a, d }, &.{ 1, 0 });

            // If A is true, one of B, C, D must be true
            try constrain(&.{ a, b, c, d }, &.{ 0, 1, 1, 1 });

            // At most one of B, C, D is true
            try constrain(&.{ b, c }, &.{ 0, 0 });
            try constrain(&.{ b, d }, &.{ 0, 0 });
            try constrain(&.{ c, d }, &.{ 0, 0 });
        }
    }
}

// Prohibits dust from hanging in mid-air
fn enforceDustOnBlock() !void {
    for (0..width) |x| {
        for (0..height) |y| {
            const b = isBlockOffset(x, 0, y, 1);
            try bitimp(is_dust[x][y], b);
        }
    }
}

// All input and output blocks are also redstone dust
fn enforceInputOutputDust() !void {
    for (0..width) |x| {
        for (0..height) |y| {
            try bitimp(is_input[x][y], is_dust[x][y]);
            try bitimp(is_output[x][y], is_dust[x][y]);
        }
    }
}

// Torches cannot be hanging mid-air
fn enforceTorchesOnBlocks() !void {
    for (0..width) |x| {
        for (0..height) |y| {
            try bitimp(is_left_torch[x][y], isBlockOffset(x, 1, y, 0));
            try bitimp(is_right_torch[x][y], isBlockOffset(x, -1, y, 0));
            try bitimp(is_standing_torch[x][y], isBlockOffset(x, 0, y, 1));
        }
    }
}

// Constrain inputs and outputs based on their position
fn enforceInputOutputPositions() !void {
    for (0..height) |y| {
        inner: for (0..width) |x| {
            for (in_pos) |i| {
                if (i[0] == x and i[1] == y) {
                    continue :inner;
                }
            }
            try bitfalse(is_input[x][y]);
        }
    }

    for (in_pos) |i| {
        try bittrue(is_input[i[0]][i[1]]);
    }

    for (0..height) |y| {
        inner: for (0..width) |x| {
            for (out_pos) |o| {
                if (o[0] == x and o[1] == y) {
                    continue :inner;
                }
            }
            try bitfalse(is_output[x][y]);
        }
    }

    for (out_pos) |o| {
        try bittrue(is_output[o[0]][o[1]]);
    }
}

// Blocks are weakly powered if adjacent to a powered dust block
fn enforceWeakPowering() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                const r = isDustPoweredOffset(state, x, 1, y, 0); // right dust ON
                const l = isDustPoweredOffset(state, x, -1, y, 0); // left dust ON
                const t = isDustPoweredOffset(state, x, 0, y, -1); // top dust ON
                const p = is_weakly_powered[state][x][y]; // block is powered

                const r_or_l = alloc();
                try bitor(r, l, r_or_l);
                const r_or_l_or_t = alloc();
                try bitor(r_or_l, t, r_or_l_or_t);
                try bitand(is_block[x][y], r_or_l_or_t, p);
            }
        }
    }
}

// Blocks are strongly powered if above a powered torch
fn enforceStrongPowering() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                const p = is_strongly_powered[state][x][y];
                const t = isTorchOnOffset(state, x, 0, y, 1);
                try bitand(is_block[x][y], t, p);
            }
        }
    }
}

// dust is powered iff it's signal strength is not zero
fn enforceDustIsPowered() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                const is_zero = alloc();
                try iszero4(signal_strength[state][x][y], is_zero);
                try bitnot(is_dust_powered[state][x][y], is_zero);
            }
        }
    }
}

// non-zero signal strengths only exist for dust
fn enforceDustSignalExistence() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                const not_dust = alloc();
                try bitnot(not_dust, is_dust[x][y]);
                const is_zero = alloc();
                try iszero4(signal_strength[state][x][y], is_zero);
                try bitimp(not_dust, is_zero);
            }
        }
    }
}

// torches are on iff their supporting block is not powered
fn enforceTorchPower() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                const b_powered = alloc(); // is the bottom block powered?
                const b_weak = isWeaklyPoweredOffset(state, x, 0, y, 1);
                const b_strong = isStronglyPoweredOffset(state, x, 0, y, 1);
                try bitor(b_weak, b_strong, b_powered);

                const l_powered = alloc(); // is the left block powered?
                const l_weak = isWeaklyPoweredOffset(state, x, -1, y, 0);
                const l_strong = isStronglyPoweredOffset(state, x, -1, y, 0);
                try bitor(l_weak, l_strong, l_powered);

                const r_powered = alloc(); // is the right block powered?
                const r_weak = isWeaklyPoweredOffset(state, x, 1, y, 0);
                const r_strong = isStronglyPoweredOffset(state, x, 1, y, 0);
                try bitor(r_weak, r_strong, r_powered);

                const is_powered_s = alloc(); // a powered standing torch?
                try bitand(is_standing_torch[x][y], b_powered, is_powered_s);
                const is_powered_r = alloc(); // a powered right torch?
                try bitand(is_right_torch[x][y], l_powered, is_powered_r);
                const is_powered_l = alloc(); // a powered left torch?
                try bitand(is_left_torch[x][y], r_powered, is_powered_l);

                const is_pow_sr = alloc();
                const torch_powered = alloc();
                const is_unpowered = alloc();
                try bitor(is_powered_s, is_powered_r, is_pow_sr);
                try bitor(is_powered_l, is_pow_sr, torch_powered);
                try bitnot(is_unpowered, torch_powered); // is this block a torch?
                try bitand(is_unpowered, is_torch[x][y], is_torch_on[state][x][y]);
            }
        }
    }
}

// forces inputs and outputs to be certain values
fn enforceInputOutput() !void {
    for (0..states) |state| {
        for (in_pos, 0..) |p, idx| {
            const a = signal_strength[state][p[0]][p[1]][0];
            const b = signal_strength[state][p[0]][p[1]][1];
            const c = signal_strength[state][p[0]][p[1]][2];
            const d = signal_strength[state][p[0]][p[1]][3];

            const in = (state >> @intCast(idx)) & 1;
            try constrain(&.{a}, &.{@intCast(in)});
            try constrain(&.{b}, &.{@intCast(in)});
            try constrain(&.{c}, &.{@intCast(in)});
            try constrain(&.{d}, &.{@intCast(in)});
        }

        for (out_pos, 0..) |p, idx| {
            const a = is_dust_powered[state][p[0]][p[1]];

            switch (idx) {
                0 => switch (state) { // output
                    0b000 => try constrain(&.{a}, &.{0}), // &.{0}),
                    0b001 => try constrain(&.{a}, &.{0}), // &.{1}),
                    0b010 => try constrain(&.{a}, &.{0}), // &.{1}),
                    0b011 => try constrain(&.{a}, &.{0}), // &.{0}),
                    0b100 => try constrain(&.{a}, &.{0}), // &.{1}),
                    0b101 => try constrain(&.{a}, &.{0}), // &.{0}),
                    0b110 => try constrain(&.{a}, &.{0}), // &.{0}),
                    0b111 => try constrain(&.{a}, &.{0}), // &.{1}),
                    else => unreachable,
                },
                1 => switch (state) { // carry-out
                    0b000 => try constrain(&.{a}, &.{0}), // &.{0}),
                    0b001 => try constrain(&.{a}, &.{0}), // &.{0}),
                    0b010 => try constrain(&.{a}, &.{0}), // &.{0}),
                    0b011 => try constrain(&.{a}, &.{0}), // &.{1}),
                    0b100 => try constrain(&.{a}, &.{0}), // &.{0}),
                    0b101 => try constrain(&.{a}, &.{0}), // &.{1}),
                    0b110 => try constrain(&.{a}, &.{0}), // &.{1}),
                    0b111 => try constrain(&.{a}, &.{0}), // &.{1}),
                    else => unreachable,
                },
                else => unreachable,
            }
        }
    }
}

// If the block is redstone dust:
//     If the block is NOT an input block:
//         If powered by a torch above: 15
//         If powered by a torch to the left: 15
//         If powered by a torch to the right: 15
//         If block below is strongly powered: 15
//         If left block is strongly powered: 15
//         If right block is strongly powered: 15
//         Else:
//             bl_power = AND(NOT left_block, bottom_left_signal)
//             br_power = AND(NOT right_block, bottom_right_signal)
//             tl_power = AND(NOT top_block, top_left_signal)
//             tr_power = AND(NOT top_block, top_right_signal)
//             cr_sig = MAX(tl_power, tr_power)
//             lr_sig = MAX(left_signal, right_signal)
//             max_signal = MAX(lr_sig, cr_sig)
//             signal_strength = sat_dec(max_signal)
//
fn enforceRedstoneSignalDecay() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                const not_top = alloc(); // is there NOT a block above
                try bitnot(not_top, isBlockOffset(x, 0, y, -1));

                const not_left = alloc(); // is there NOT a block left
                try bitnot(not_left, isBlockOffset(x, -1, y, 0));

                const not_right = alloc(); // is there NOT a block right
                try bitnot(not_right, isBlockOffset(x, 1, y, 0));

                // signal strength *supplied* from the bottom right
                const br_pow: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };

                // signal strength of the dust at the bottom right
                const br_sig = signalStrengthOffset(state, x, 1, y, 1);

                try bitand(br_sig[0], not_right, br_pow[0]);
                try bitand(br_sig[1], not_right, br_pow[1]);
                try bitand(br_sig[2], not_right, br_pow[2]);
                try bitand(br_sig[3], not_right, br_pow[3]);

                // signal strength *supplied* from the bottom left
                const bl_pow: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };

                // signal strength of the dust at the bottom left
                const bl_sig = signalStrengthOffset(state, x, -1, y, 1);

                try bitand(bl_sig[0], not_left, bl_pow[0]);
                try bitand(bl_sig[1], not_left, bl_pow[1]);
                try bitand(bl_sig[2], not_left, bl_pow[2]);
                try bitand(bl_sig[3], not_left, bl_pow[3]);

                // signal strength *supplied* from the top left
                const tl_pow: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };

                // signal strength of the dust at the top left
                const tl_sig = signalStrengthOffset(state, x, -1, y, -1);

                try bitand(tl_sig[0], not_top, tl_pow[0]);
                try bitand(tl_sig[1], not_top, tl_pow[1]);
                try bitand(tl_sig[2], not_top, tl_pow[2]);
                try bitand(tl_sig[3], not_top, tl_pow[3]);

                // signal strength *supplied* from the top right
                const tr_pow: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };

                // signal strength of the dust at the top right
                const tr_sig = signalStrengthOffset(state, x, 1, y, -1);

                try bitand(tr_sig[0], not_top, tr_pow[0]);
                try bitand(tr_sig[1], not_top, tr_pow[1]);
                try bitand(tr_sig[2], not_top, tr_pow[2]);
                try bitand(tr_sig[3], not_top, tr_pow[3]);

                // signal strength *supplied* from the left
                const l_pow = signalStrengthOffset(state, x, -1, y, 0);

                // signal strength *supplied* from the right
                const r_pow = signalStrengthOffset(state, x, 1, y, 0);

                // signal strength *supplied* from the top corners
                const tc_sig: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };
                try max4(tl_pow, tr_pow, tc_sig);

                // signal strength *supplied* from the bottom corners
                const bc_sig: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };
                try max4(bl_pow, br_pow, bc_sig);

                // signal strength *supplied* from the corners
                const cr_sig: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };
                try max4(tc_sig, bc_sig, cr_sig);

                // signal strength *supplied* from the sides
                const lr_sig: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };
                try max4(l_pow, r_pow, lr_sig);

                // signal strength *supplied* from all positions
                const su_sig: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };
                try max4(cr_sig, lr_sig, su_sig);

                // new signal strength if not overridden
                const or_sig: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };
                try satdec4(su_sig, or_sig);

                // powered by a torch above
                const torch_u = isTorchOnOffset(state, x, 0, y, -1);
                // powered by a torch to the left
                const torch_l = isTorchOnOffset(state, x, -1, y, 0);
                // powered by a torch to the right
                const torch_r = isTorchOnOffset(state, x, 1, y, 0);
                // strongly powered block to the left
                const strong_l = isStronglyPoweredOffset(state, x, -1, y, 0);
                // strongly powered block to the right
                const strong_r = isStronglyPoweredOffset(state, x, 1, y, 0);
                // strongly powered block below
                const strong_d = isStronglyPoweredOffset(state, x, 0, y, 1);

                // determine if the block is being directly powered
                const strong_merge_a = alloc();
                try bitor(torch_u, torch_l, strong_merge_a);
                const strong_merge_b = alloc();
                try bitor(torch_r, strong_l, strong_merge_b);
                const strong_merge_c = alloc();
                try bitor(strong_r, strong_d, strong_merge_c);
                const strong_merge_d = alloc();
                try bitor(strong_merge_a, strong_merge_b, strong_merge_d);
                const direct_power = alloc();
                try bitor(strong_merge_c, strong_merge_d, direct_power);

                // power assuming block is redstone dust and
                const power: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };
                try bitor(direct_power, or_sig[0], power[0]);
                try bitor(direct_power, or_sig[1], power[1]);
                try bitor(direct_power, or_sig[2], power[2]);
                try bitor(direct_power, or_sig[3], power[3]);

                // constrainment based on whether it is an input block or dust
                const not_input = alloc();
                const not_inp_and_dust = alloc();
                try bitnot(not_input, is_input[x][y]);
                try bitand(not_input, is_dust[x][y], not_inp_and_dust);

                // whether the signals are equal or not
                const equal: [4]u64 = .{ alloc(), alloc(), alloc(), alloc() };
                try bitimp(not_inp_and_dust, equal[0]);
                try bitimp(not_inp_and_dust, equal[1]);
                try bitimp(not_inp_and_dust, equal[2]);
                try bitimp(not_inp_and_dust, equal[3]);

                try bitxnor(signal_strength[state][x][y][0], power[0], equal[0]);
                try bitxnor(signal_strength[state][x][y][1], power[1], equal[1]);
                try bitxnor(signal_strength[state][x][y][2], power[2], equal[2]);
                try bitxnor(signal_strength[state][x][y][3], power[3], equal[3]);
            }
        }
    }
}

fn encodeMain(io: Io) !void {
    try initializeGlobals();
    try enforceTorchPower();
    try enforceDustOnBlock();
    try enforceInputOutput();
    try enforceWeakPowering();
    try enforceDustIsPowered();
    try enforceStrongPowering();
    try enforceSingleTorchType();
    try enforceSingleBlockType();
    try enforceInputOutputDust();
    try enforceTorchesOnBlocks();
    try enforceRedstoneSignalDecay();
    try enforceDustSignalExistence();
    try enforceInputOutputPositions();
    try writeCnfToFile(io, "out.cnf");
}

// ------------------------------------------------------- CNF ENCODING GLOBALS

const gpa = std.heap.smp_allocator;
var cnf_content: Allocating = .init(gpa);
var cnf_constraint_count: u64 = 0;
var cnf_variable_count: u64 = 0;

// ------------------------------------------------------------ ALLOCATING BITS

fn alloc() u64 {
    cnf_variable_count += 1;
    return cnf_variable_count;
}

// --------------------------------------------------------- BITWISE IDENTITIES

// val IS TRUE
fn bittrue(val: u64) !void {
    try constrain(&.{val}, &.{1});
}

// val IS FALSE
fn bitfalse(val: u64) !void {
    try constrain(&.{val}, &.{0});
}

// -------------------------------------------------- SINGLE BITWISE OPERATIONS

/// lhs *LOGICALLY* IMPLIES rhs
fn bitimp(lhs: u64, rhs: u64) !void {
    try constrain(&.{ lhs, rhs }, &.{ 0, 1 });
}

/// lhs NOT EQUIVALENT TO rhs
fn bitnot(lhs: u64, rhs: u64) !void {
    try bitop1(lhs, rhs, .{ 1, 0 });
}

/// lhs EQUIVALENT TO rhs
fn biteql(lhs: u64, rhs: u64) !void {
    try bitop1(lhs, rhs, .{ 0, 1 });
}

fn bitop1(a: u64, b: u64, t: [2]u1) !void {
    try constrain(&.{ a, b }, &.{ 1, t[0] });
    try constrain(&.{ a, b }, &.{ 0, t[1] });
}

// -------------------------------------------------- DOUBLE BITWISE OPERATIONS

/// result <- lhs NOR rhs
fn bitnor(lhs: u64, rhs: u64, result: u64) !void {
    try bitop2(lhs, rhs, result, .{ 1, 0, 0, 0 });
}

/// result <- lhs AND rhs
fn bitand(lhs: u64, rhs: u64, result: u64) !void {
    try bitop2(lhs, rhs, result, .{ 0, 0, 0, 1 });
}

/// result <- lhs NAND rhs
fn bitnand(lhs: u64, rhs: u64, result: u64) !void {
    try bitop2(lhs, rhs, result, .{ 1, 1, 1, 0 });
}

/// result <- lhs OR rhs
fn bitor(lhs: u64, rhs: u64, result: u64) !void {
    try bitop2(lhs, rhs, result, .{ 0, 1, 1, 1 });
}

/// result <- lhs XNOR rhs
fn bitxnor(lhs: u64, rhs: u64, result: u64) !void {
    try bitop2(lhs, rhs, result, .{ 1, 0, 0, 1 });
}

/// result <- lhs XOR rhs
fn bitxor(lhs: u64, rhs: u64, result: u64) !void {
    try bitop2(lhs, rhs, result, .{ 0, 1, 1, 0 });
}

fn bitop2(a: u64, b: u64, c: u64, t: [4]u1) !void {
    try constrain(&.{ a, b, c }, &.{ 1, 1, t[0] });
    try constrain(&.{ a, b, c }, &.{ 1, 0, t[1] });
    try constrain(&.{ a, b, c }, &.{ 0, 1, t[2] });
    try constrain(&.{ a, b, c }, &.{ 0, 0, t[3] });
}

// -------------------------------------------------- TRIPLE BITWISE OPERATIONS

/// result <- condition ? lhs : rhs
fn bitsel(condition: u64, lhs: u64, rhs: u64, result: u64) !void {
    try bitop3(condition, lhs, rhs, result, .{ 0, 1, 0, 1, 0, 0, 1, 1 });
}

fn bitop3(a: u64, b: u64, c: u64, d: u64, t: [8]u1) !void {
    try constrain(&.{ a, b, c, d }, &.{ 1, 1, 1, t[0] });
    try constrain(&.{ a, b, c, d }, &.{ 1, 1, 0, t[1] });
    try constrain(&.{ a, b, c, d }, &.{ 1, 0, 1, t[2] });
    try constrain(&.{ a, b, c, d }, &.{ 1, 0, 0, t[3] });
    try constrain(&.{ a, b, c, d }, &.{ 0, 1, 1, t[4] });
    try constrain(&.{ a, b, c, d }, &.{ 0, 1, 0, t[5] });
    try constrain(&.{ a, b, c, d }, &.{ 0, 0, 1, t[6] });
    try constrain(&.{ a, b, c, d }, &.{ 0, 0, 0, t[7] });
}

// ----------------------------------------------------------------- ARITHMETIC

/// bitwise half subtractor, a - b = s - o * 2
fn halfsub(a: u64, b: u64, s: u64, o: u64) !void {
    try bitop2(a, b, s, .{ 0, 1, 1, 0 });
    try bitop2(a, b, o, .{ 0, 0, 1, 0 });
}

/// bitwise full subtractor, a - b - i = s - o * 2
fn fullsub(a: u64, b: u64, i: u64, s: u64, o: u64) !void {
    try bitop3(a, b, i, s, .{ 0, 1, 1, 0, 1, 0, 0, 1 });
    try bitop3(a, b, i, o, .{ 0, 1, 1, 1, 0, 0, 1, 1 });
}

/// 4 bit less-than based on overflow from subtraction
fn lessthan4(lhs: [4]u64, rhs: [4]u64, lt: u64) !void {
    const borrow = .{ alloc(), alloc(), alloc() };

    try halfsub(lhs[0], rhs[0], alloc(), borrow[0]);
    try fullsub(lhs[1], rhs[1], borrow[0], alloc(), borrow[1]);
    try fullsub(lhs[2], rhs[2], borrow[1], alloc(), borrow[2]);
    try fullsub(lhs[3], rhs[3], borrow[2], alloc(), lt);
}

/// 4 bit saturating decrement
fn satdec4(val: [4]u64, result: [4]u64) !void {
    const wrap_dec = .{ alloc(), alloc(), alloc(), alloc() };
    const borrow = .{ alloc(), alloc(), alloc(), alloc() };

    // set wrap_dec to a wrapping subtraction of one
    try halfsub(val[0], true_bit, wrap_dec[0], borrow[0]);
    try halfsub(val[1], borrow[0], wrap_dec[1], borrow[1]);
    try halfsub(val[2], borrow[1], wrap_dec[2], borrow[2]);
    try halfsub(val[3], borrow[2], wrap_dec[3], borrow[3]);

    // If the decrement is still borrowing, set to zero
    try bitsel(borrow[3], false_bit, wrap_dec[0], result[0]);
    try bitsel(borrow[3], false_bit, wrap_dec[1], result[1]);
    try bitsel(borrow[3], false_bit, wrap_dec[2], result[2]);
    try bitsel(borrow[3], false_bit, wrap_dec[3], result[3]);
}

/// result <- lhs < rhs ? rhs : lhs
fn max4(lhs: [4]u64, rhs: [4]u64, result: [4]u64) !void {
    const lt = alloc();
    try lessthan4(lhs, rhs, lt);
    try bitsel(lt, rhs[0], lhs[0], result[0]);
    try bitsel(lt, rhs[1], lhs[1], result[1]);
    try bitsel(lt, rhs[2], lhs[2], result[2]);
    try bitsel(lt, rhs[3], lhs[3], result[3]);
}

/// check equivalence to zero for 4 bits
fn iszero4(num: [4]u64, is_zero: u64) !void {
    try constrain( // the number is zero, or a bit is true
        &.{ is_zero, num[0], num[1], num[2], num[3] },
        &.{ 1, 1, 1, 1, 1 },
    );

    // each bit is either false, or the number isn't zero
    try constrain(&.{ is_zero, num[0] }, &.{ 0, 0 });
    try constrain(&.{ is_zero, num[1] }, &.{ 0, 0 });
    try constrain(&.{ is_zero, num[2] }, &.{ 0, 0 });
    try constrain(&.{ is_zero, num[3] }, &.{ 0, 0 });
}

// ------------------------------------------------------- ENCODING CONSTRAINTS

/// serialize some number of CNF constraints to the constraints list
fn constrain(indexes: []const u64, identities: []const u1) !void {
    const writer = &cnf_content.writer;
    for (indexes, identities) |index, identity| switch (identity) {
        1 => try writer.print("{} ", .{index}),
        0 => try writer.print("-{} ", .{index}),
    };
    try writer.writeAll("0\n");
    cnf_constraint_count += 1;
}

/// serialize bitblaster state
fn writeCnf(writer: *Writer) !void {
    try writer.print("p cnf {} {}\n{s}", .{
        cnf_variable_count,
        cnf_constraint_count,
        cnf_content.written(),
    });
}

/// write the serialized CNF to a file path
fn writeCnfToFile(io: Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const out_cnf = try cwd.createFile(io, path, .{});
    defer out_cnf.close(io);

    var buffer: [4096]u8 = undefined;
    var file_writer = out_cnf.writer(io, &buffer);
    const writer = &file_writer.interface;
    try writeCnf(writer);
    try writer.flush();
}
