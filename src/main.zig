const std = @import("std");
const Allocating = Writer.Allocating;
const assert = std.debug.assert;
const Writer = std.Io.Writer;
const Io = std.Io;

// Block types:

// ###
// ### <-- block
// ###
// - can be weakly powered
// - can be strongly powered

//  o
//  |  <-- upright torch
//  |
// - can be ON OR OFF
// - must have a block underneath itself
// - the torch is OFF if the block underneath is strongly powered
// - the torch is OFF if the block underneath is weakly powered
// - the torch is ON if the block underneath is NOT powered

//   o
//  /  <-- right facing torch
// /
// - can be ON OR OFF
// - must have a block to the left
// - the torch is OFF if the block to the left is strongly powered
// - the torch is OFF if the block to the left is weakly powered
// - the torch is ON if the block to the left is NOT powered

// o
//  \  <-- left facing torch
//   \
// - can be ON OR OFF
// - must have a block to the right
// - the torch is OFF if the block to the right is strongly powered
// - the torch is OFF if the block to the right is weakly powered
// - the torch is ON if the block to the right is NOT powered

//
//     <-- bottom redstone dust
// ===
// - can have signal strength [0, 16)
// - must have block underneath itself
// - if there is no block above itself:
//     - must not have redstone dust to the upper-left
//     - must not have redstone dust to the upper-right
// - if there is a left-facing torch to the right:
//     - the dust has signal strength 15 if it is ON
// - if there is a right-facing torch to the left:
//     - the dust has signal strength 15 if it is ON
// - if there is a left-facing OR right-facing torch above:
//     - the dust has signal strength 15 if it is ON
// - if there is bottom OR left dust to the left:
//     - if the signal strength of the other dust is higher:
//         - if the signal strength of the dust is greater than 1:
//             - the dust has a minimum signal strength of one less
//         - if the signal strength of the dust is between [0, 1]:
//             - the dust has a minimum signal strength of zero
// - if there is a bottom or right dust to the right:
//     - if the signal strength of the other dust is higher:
//         - if the signal strength of the dust is greater than 1:
//             - the dust has a minimum signal strength of one less
//         - if the signal strength of the dust is between [0, 1]:
//             - the dust has a minimum signal strength of zero
// - if there is a right or dipping redstone dust to the bottom-right:
//     - if the signal strength of the other dust is higher:
//         - if the signal strength of the dust is greater than 1:
//             - the dust has a minimum signal strength of one less
//         - if the signal strength of the dust is between [0, 1]:
//             - the dust has a minimum signal strength of zero
// - if there is a left or dipping redstone dust to the bottom-left:
//     - if the signal strength of the other dust is higher:
//         - if the signal strength of the dust is greater than 1:
//             - the dust has a minimum signal strength of one less
//         - if the signal strength of the dust is between [0, 1]:
//             - the dust has a minimum signal strength of zero

// =
// =   <-- left redstone dust
// ===
// - can have signal strength [0, 16)
// - must have block to the left and bottom
// - must not have block above itself
// - must have redstone dust to the upper-left
// - must not have redstone dust to the upper-right

//   =
//   = <-- right redstone dust
// ===
// - can have signal strength [0, 16)
// - must have block to the right and bottom
// - must not have block above itself
// - must not have redstone dust to the upper-left
// - must have redstone dust to the upper-right

// = =
// = = <-- dipping redstone dust
// ===
// - can have signal strength [0, 16)
// - must have block to the left, right, and bottom
// - must not have block above itself
// - must have redstone dust to the upper-left
// - must have redstone dust to the upper-right

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

// left dust is when a dust is joined to an upper-left dust
var is_left_dust: [width][height]u64 = undefined;
// right dust is when a dust is joined to an upper-right dust
var is_right_dust: [width][height]u64 = undefined;

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
            is_left_dust[w][h] = alloc();
            is_right_dust[w][h] = alloc();

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

    var block_is_left_dust: [width][height]bool = @splat(@splat(false));
    var block_is_right_dust: [width][height]bool = @splat(@splat(false));

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
                    } else if (decoded == is_left_dust[w][h]) {
                        block_is_left_dust[w][h] = true;
                        continue :outer;
                    } else if (decoded == is_right_dust[w][h]) {
                        block_is_right_dust[w][h] = true;
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
                        const left = block_is_left_dust[x][y];
                        const right = block_is_right_dust[x][y];

                        if (left and right) {
                            try stdout.writeByte(dip_dust_display[sub_row][sub_col]);
                        } else if (left) {
                            try stdout.writeByte(left_dust_display[sub_row][sub_col]);
                        } else if (right) {
                            try stdout.writeByte(right_dust_display[sub_row][sub_col]);
                        } else {
                            try stdout.writeByte(flat_dust_display[sub_row][sub_col]);
                        }
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
const flat_dust_display: [3][3]u8 = .{ "   ".*, "   ".*, "%%%".* };
const left_dust_display: [3][3]u8 = .{ "%  ".*, "%  ".*, "%%%".* };
const right_dust_display: [3][3]u8 = .{ "  %".*, "  %".*, "%%%".* };
const dip_dust_display: [3][3]u8 = .{ "% %".*, "% %".*, "%%%".* };
const standing_torch_display: [3][3]u8 = .{ " o ".*, " | ".*, " | ".* };
const left_torch_display: [3][3]u8 = .{ "o  ".*, " \\ ".*, "  \\".* };
const right_torch_display: [3][3]u8 = .{ "  o".*, " / ".*, "/  ".* };
const input_display: [3][3]u8 = .{ "III".*, " I ".*, "III".* };
const output_display: [3][3]u8 = .{ "OOO".*, "O O".*, "OOO".* };
const unknown_display: [3][3]u8 = .{ "? ?".*, " ? ".*, "? ?".* };

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

fn isDustOffset(x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_dust[sum_x][sum_y];
}

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

fn isTorchOffset(x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_torch[sum_x][sum_y];
}

fn isTorchOnOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_torch_on[state][sum_x][sum_y];
}

fn isStronglyPoweredOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return is_strongly_powered[state][sum_x][sum_y];
}

fn signalStrengthOffset(state: u64, x: u64, x_off: i64, y: u64, y_off: i64, bit: u2) u64 {
    const sum_x = x +% @as(u64, @bitCast(x_off));
    const sum_y = y +% @as(u64, @bitCast(y_off));
    if (sum_x >= width or sum_y >= height) return false_bit;
    return signal_strength[state][sum_x][sum_y][bit];
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

// dust is powered IFF it's signal strength is NOT zero
fn enforceDustIsPowered() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                const a = is_dust_powered[state][x][y];
                const b = signal_strength[state][x][y][0];
                const c = signal_strength[state][x][y][1];
                const d = signal_strength[state][x][y][2];
                const e = signal_strength[state][x][y][3];

                // either the dust is NOT powered, OR
                // one of the signal strength bits is ON
                try constrain(&.{ a, b, c, d, e }, &.{ 0, 1, 1, 1, 1 });

                // any signal strength bit implies the dust is powered
                try constrain(&.{ a, b }, &.{ 1, 0 });
                try constrain(&.{ a, c }, &.{ 1, 0 });
                try constrain(&.{ a, d }, &.{ 1, 0 });
                try constrain(&.{ a, e }, &.{ 1, 0 });
            }
        }
    }
}

// non-zero signal strengths only exist for dust
fn enforceDustSignalExistence() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                const a = is_dust[x][y];

                for (0..4) |bit_pos| {
                    const b = signal_strength[state][x][y][bit_pos];
                    try constrain(&.{ a, b }, &.{ 1, 0 });
                }
            }
        }
    }
}

// torches are on IFF their supporting block is not powered
fn enforceTorchPower() !void {
    for (0..states) |state| {
        for (0..width - 1) |x| {
            for (0..height) |y| {
                const a = is_left_torch[x][y];
                const b = is_weakly_powered[state][x + 1][y];
                const c = is_strongly_powered[state][x + 1][y];
                const d = is_torch_on[state][x][y];

                // 1. If the torch is ON, it must be a torch
                try constrain(&.{ d, a }, &.{ 0, 1 });

                // 2. If the torch is ON, the block must NOT be powered (Weakly AND Strongly)
                // This is two separate clauses: (d => !b) and (d => !c)
                try constrain(&.{ d, b }, &.{ 0, 0 });
                try constrain(&.{ d, c }, &.{ 0, 0 });

                // 3. If it is a torch AND the block is NOT powered, the torch MUST be ON
                // (!b AND !c AND a) => d  ---(rewritten for CNF)---> (b OR c OR !a OR d)
                try constrain(&.{ b, c, a, d }, &.{ 1, 1, 0, 1 });
            }
        }

        for (1..width) |x| {
            for (0..height) |y| {
                // No block to the left implies no right-facing torch
                const a = is_right_torch[x][y];
                const b = is_weakly_powered[state][x - 1][y];
                const c = is_strongly_powered[state][x - 1][y];
                const d = is_torch_on[state][x][y];

                // 1. If the torch is ON, it must be a torch
                try constrain(&.{ d, a }, &.{ 0, 1 });

                // 2. If the torch is ON, the block must NOT be powered (Weakly AND Strongly)
                // This is two separate clauses: (d => !b) and (d => !c)
                try constrain(&.{ d, b }, &.{ 0, 0 });
                try constrain(&.{ d, c }, &.{ 0, 0 });

                // 3. If it is a torch AND the block is NOT powered, the torch MUST be ON
                // (!b AND !c AND a) => d  ---(rewritten for CNF)---> (b OR c OR !a OR d)
                try constrain(&.{ b, c, a, d }, &.{ 1, 1, 0, 1 });
            }
        }

        for (0..width) |x| {
            for (0..height - 1) |y| {
                // No block below implies no torch above
                const a = is_standing_torch[x][y];
                const b = is_weakly_powered[state][x][y + 1];
                const c = is_strongly_powered[state][x][y + 1];
                const d = is_torch_on[state][x][y];

                // 1. If the torch is ON, it must be a torch
                try constrain(&.{ d, a }, &.{ 0, 1 });

                // 2. If the torch is ON, the block must NOT be powered (Weakly AND Strongly)
                // This is two separate clauses: (d => !b) and (d => !c)
                try constrain(&.{ d, b }, &.{ 0, 0 });
                try constrain(&.{ d, c }, &.{ 0, 0 });

                // 3. If it is a torch AND the block is NOT powered, the torch MUST be ON
                // (!b AND !c AND a) => d  ---(rewritten for CNF)---> (b OR c OR !a OR d)
                try constrain(&.{ b, c, a, d }, &.{ 1, 1, 0, 1 });
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
                    0b000 => try constrain(&.{a}, &.{0}),
                    0b001 => try constrain(&.{a}, &.{1}),
                    0b010 => try constrain(&.{a}, &.{1}),
                    0b011 => try constrain(&.{a}, &.{0}),
                    0b100 => try constrain(&.{a}, &.{1}),
                    0b101 => try constrain(&.{a}, &.{0}),
                    0b110 => try constrain(&.{a}, &.{0}),
                    0b111 => try constrain(&.{a}, &.{1}),
                    else => unreachable,
                },
                1 => switch (state) { // carry-out
                    0b000 => try constrain(&.{a}, &.{0}),
                    0b001 => try constrain(&.{a}, &.{0}),
                    0b010 => try constrain(&.{a}, &.{0}),
                    0b011 => try constrain(&.{a}, &.{1}),
                    0b100 => try constrain(&.{a}, &.{0}),
                    0b101 => try constrain(&.{a}, &.{1}),
                    0b110 => try constrain(&.{a}, &.{1}),
                    0b111 => try constrain(&.{a}, &.{1}),
                    else => unreachable,
                },
                else => unreachable,
            }
        }
    }
}

// If the block is an input block, ignore it.
// If there is a torch on the left, and it is ON, signal strength 15
// If there is a torch on the right, and it is ON, signal strength 15
// If there is a torch above the dust, and it is ON, signal strength 15
// If the block below is strongly powered, signal strength 15
// Find the maximum nearby power:
//     - this includes redstone dust to the left
//     - this includes redstone dust to the right
//     - If there is no block above,
//         - this includes redstone dust to the top left
//         - this includes redstone dust to the top right
// Now that the maximum nearby power has been found, if it is equal to zero:
//     - If so, the signal strength is equal to zero
// If The maximum nearby power is not equal to zero:
//     - The signal strength is one less than that value
fn enforceRedstoneSignalDecay() !void {
    for (0..states) |state| {
        for (0..width) |x| {
            for (0..height) |y| {
                // First, determine if it is directly powered:
                const direct_power = alloc();

                const tol = getIsTorchOn(state, @as(i64, @intCast(x)) - 1, y);
                const tor = getIsTorchOn(state, x + 1, y);
                const tou = getIsTorchOn(state, x, @as(i64, @intCast(y)) - 1);
                const bst = getIsStronglyPowered(state, x, y + 1);

                try constrain(&.{ direct_power, tol, tor, tou, bst }, &.{ 0, 1, 1, 1, 1 });
                try constrain(&.{ direct_power, tol }, &.{ 1, 0 });
                try constrain(&.{ direct_power, tor }, &.{ 1, 0 });
                try constrain(&.{ direct_power, tou }, &.{ 1, 0 });
                try constrain(&.{ direct_power, bst }, &.{ 1, 0 });

                // Second, determine if this is an input block:
                const is_input_block = is_input[x][y];

                const block_above = getIsBlock(x, @as(i64, @intCast(y)) - 1);

                const tl_power_0 = getSignalStrength(state, @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, 0);
                const tl_power_1 = getSignalStrength(state, @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, 1);
                const tl_power_2 = getSignalStrength(state, @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, 2);
                const tl_power_3 = getSignalStrength(state, @as(i64, @intCast(x)) - 1, @as(i64, @intCast(y)) - 1, 3);

                const tr_power_0 = getSignalStrength(state, x + 1, @as(i64, @intCast(y)) - 1, 0);
                const tr_power_1 = getSignalStrength(state, x + 1, @as(i64, @intCast(y)) - 1, 1);
                const tr_power_2 = getSignalStrength(state, x + 1, @as(i64, @intCast(y)) - 1, 2);
                const tr_power_3 = getSignalStrength(state, x + 1, @as(i64, @intCast(y)) - 1, 3);

                const l_supplied_0 = getSignalStrength(state, @as(i64, @intCast(x)) - 1, y, 0);
                const l_supplied_1 = getSignalStrength(state, @as(i64, @intCast(x)) - 1, y, 1);
                const l_supplied_2 = getSignalStrength(state, @as(i64, @intCast(x)) - 1, y, 2);
                const l_supplied_3 = getSignalStrength(state, @as(i64, @intCast(x)) - 1, y, 3);

                const r_supplied_0 = getSignalStrength(state, x + 1, y, 0);
                const r_supplied_1 = getSignalStrength(state, x + 1, y, 1);
                const r_supplied_2 = getSignalStrength(state, x + 1, y, 2);
                const r_supplied_3 = getSignalStrength(state, x + 1, y, 3);

                const tr_supplied_0 = alloc();
                const tr_supplied_1 = alloc();
                const tr_supplied_2 = alloc();
                const tr_supplied_3 = alloc();

                const tl_supplied_0 = alloc();
                const tl_supplied_1 = alloc();
                const tl_supplied_2 = alloc();
                const tl_supplied_3 = alloc();

                // depending on if a block is blocking us, don't allow the signal to come through

                try constrain(&.{ tl_supplied_0, block_above }, &.{ 0, 0 });
                try constrain(&.{ tl_supplied_1, block_above }, &.{ 0, 0 });
                try constrain(&.{ tl_supplied_2, block_above }, &.{ 0, 0 });
                try constrain(&.{ tl_supplied_3, block_above }, &.{ 0, 0 });

                try constrain(&.{ tr_supplied_0, block_above }, &.{ 0, 0 });
                try constrain(&.{ tr_supplied_1, block_above }, &.{ 0, 0 });
                try constrain(&.{ tr_supplied_2, block_above }, &.{ 0, 0 });
                try constrain(&.{ tr_supplied_3, block_above }, &.{ 0, 0 });

                try constrain(&.{ tl_supplied_0, tl_power_0 }, &.{ 0, 1 });
                try constrain(&.{ tl_supplied_1, tl_power_1 }, &.{ 0, 1 });
                try constrain(&.{ tl_supplied_2, tl_power_2 }, &.{ 0, 1 });
                try constrain(&.{ tl_supplied_3, tl_power_3 }, &.{ 0, 1 });

                try constrain(&.{ tr_supplied_0, tr_power_0 }, &.{ 0, 1 });
                try constrain(&.{ tr_supplied_1, tr_power_1 }, &.{ 0, 1 });
                try constrain(&.{ tr_supplied_2, tr_power_2 }, &.{ 0, 1 });
                try constrain(&.{ tr_supplied_3, tr_power_3 }, &.{ 0, 1 });

                try constrain(&.{ tl_supplied_0, block_above, tl_power_0 }, &.{ 1, 1, 0 });
                try constrain(&.{ tl_supplied_1, block_above, tl_power_1 }, &.{ 1, 1, 0 });
                try constrain(&.{ tl_supplied_2, block_above, tl_power_2 }, &.{ 1, 1, 0 });
                try constrain(&.{ tl_supplied_3, block_above, tl_power_3 }, &.{ 1, 1, 0 });

                try constrain(&.{ tr_supplied_0, block_above, tr_power_0 }, &.{ 1, 1, 0 });
                try constrain(&.{ tr_supplied_1, block_above, tr_power_1 }, &.{ 1, 1, 0 });
                try constrain(&.{ tr_supplied_2, block_above, tr_power_2 }, &.{ 1, 1, 0 });
                try constrain(&.{ tr_supplied_3, block_above, tr_power_3 }, &.{ 1, 1, 0 });

                // get the greater signal strength of all four signals:
                const max_supplied = try lexicalGreater(
                    try lexicalGreater(
                        .{ tl_supplied_0, tl_supplied_1, tl_supplied_2, tl_supplied_3 },
                        .{ l_supplied_0, l_supplied_1, l_supplied_2, l_supplied_3 },
                    ),
                    try lexicalGreater(
                        .{ tr_supplied_0, tr_supplied_1, tr_supplied_2, tr_supplied_3 },
                        .{ r_supplied_0, r_supplied_1, r_supplied_2, r_supplied_3 },
                    ),
                );

                // if is_input_block:
                //     (no constraint on signal)
                // else:
                //     if direct_power:
                //         signal = 15
                //     else if sup_not_zero:
                //         signal = supplied_dec
                //     else:
                //         signal = 0

                const sup_not_zero = alloc();
                // sup_not_zero is true if any bit is set
                try constrain(&.{ sup_not_zero, max_supplied[0], max_supplied[1], max_supplied[2], max_supplied[3] }, &.{ 1, 0, 0, 0, 0 });
                // if any bit is set, sup_not_zero must be true
                try constrain(&.{ sup_not_zero, max_supplied[0] }, &.{ 1, 0 });
                try constrain(&.{ sup_not_zero, max_supplied[1] }, &.{ 1, 0 });
                try constrain(&.{ sup_not_zero, max_supplied[2] }, &.{ 1, 0 });
                try constrain(&.{ sup_not_zero, max_supplied[3] }, &.{ 1, 0 });

                const supplied_dec = try decrement4(max_supplied);

                const signal_0 = signal_strength[state][x][y][0];
                const signal_1 = signal_strength[state][x][y][1];
                const signal_2 = signal_strength[state][x][y][2];
                const signal_3 = signal_strength[state][x][y][3];

                // if NOT input AND direct_power, then signal = 15
                try constrain(&.{ is_input_block, direct_power, signal_0 }, &.{ 1, 0, 1 });
                try constrain(&.{ is_input_block, direct_power, signal_1 }, &.{ 1, 0, 1 });
                try constrain(&.{ is_input_block, direct_power, signal_2 }, &.{ 1, 0, 1 });
                try constrain(&.{ is_input_block, direct_power, signal_3 }, &.{ 1, 0, 1 });

                // if NOT input AND NOT direct_power AND sup_not_zero, then signal = supplied_dec
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_0, supplied_dec[0] }, &.{ 1, 1, 0, 1, 0 });
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_0, supplied_dec[0] }, &.{ 1, 1, 0, 0, 1 });

                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_1, supplied_dec[1] }, &.{ 1, 1, 0, 1, 0 });
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_1, supplied_dec[1] }, &.{ 1, 1, 0, 0, 1 });

                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_2, supplied_dec[2] }, &.{ 1, 1, 0, 1, 0 });
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_2, supplied_dec[2] }, &.{ 1, 1, 0, 0, 1 });

                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_3, supplied_dec[3] }, &.{ 1, 1, 0, 1, 0 });
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_3, supplied_dec[3] }, &.{ 1, 1, 0, 0, 1 });

                // if NOT input AND NOT direct_power AND NOT sup_not_zero, then signal = 0
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_0 }, &.{ 1, 1, 1, 0 });
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_1 }, &.{ 1, 1, 1, 0 });
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_2 }, &.{ 1, 1, 1, 0 });
                try constrain(&.{ is_input_block, direct_power, sup_not_zero, signal_3 }, &.{ 1, 1, 1, 0 });
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
    try constrain(&.{ a, b }, &.{ 0, ~t[0] });
    try constrain(&.{ a, b }, &.{ 1, ~t[1] });
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
    try constrain(&.{ a, b, c }, &.{ 0, 0, ~t[0] });
    try constrain(&.{ a, b, c }, &.{ 0, 1, ~t[1] });
    try constrain(&.{ a, b, c }, &.{ 1, 0, ~t[2] });
    try constrain(&.{ a, b, c }, &.{ 1, 1, ~t[3] });
}

// -------------------------------------------------- TRIPLE BITWISE OPERATIONS

/// result <- condition ? lhs : rhs
fn bitsel(condition: u64, lhs: u64, rhs: u64, result: u64) !void {
    try bitop3(condition, lhs, rhs, result, .{ 0, 1, 0, 1, 0, 0, 1, 1 });
}

fn bitop3(a: u64, b: u64, c: u64, d: u64, t: [8]u1) !void {
    try constrain(&.{ a, b, c, d }, &.{ 0, 0, 0, ~t[0] });
    try constrain(&.{ a, b, c, d }, &.{ 0, 0, 1, ~t[1] });
    try constrain(&.{ a, b, c, d }, &.{ 0, 1, 0, ~t[2] });
    try constrain(&.{ a, b, c, d }, &.{ 0, 1, 1, ~t[3] });
    try constrain(&.{ a, b, c, d }, &.{ 1, 0, 0, ~t[4] });
    try constrain(&.{ a, b, c, d }, &.{ 1, 0, 1, ~t[5] });
    try constrain(&.{ a, b, c, d }, &.{ 1, 1, 0, ~t[6] });
    try constrain(&.{ a, b, c, d }, &.{ 1, 1, 1, ~t[7] });
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
