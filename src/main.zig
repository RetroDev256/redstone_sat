const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const Variables = @import("Variables.zig");
const Options = @import("Options.zig");
const Solver = @import("Solver.zig");
const cnf = @import("cnf.zig");
const Bits = cnf.Bits;

// ----------------------------------------------------------------------- MAIN

pub fn main(init: std.process.Init.Minimal) !void {

    // Initialize process

    const gpa = std.heap.smp_allocator;

    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();

    // Print the usage of our program on error
    // Indicate error by exiting with status 1

    var process: []const u8 = "UNKNOWN";

    errdefer {
        std.debug.print(
            \\ USAGE: {s} [CONFIG]
            \\   CONFIG:
            \\     * Path to valid .zon config
            \\
        , .{process});
    }

    // Capture the CLI arguments

    const ArgsIterator = std.process.Args.Iterator;
    var args: ArgsIterator = try .initAllocator(init.args, gpa);
    defer args.deinit();

    process = args.next() orelse
        return error.LackingArgs;
    const config_path = args.next() orelse
        return error.LackingArgs;

    // Read the configuation and parse into an options struct

    const cwd = std.Io.Dir.cwd();
    const config_text = try Io.Dir.readFileAllocOptions( //
        cwd, io, config_path, gpa, .unlimited, .@"1", 0);
    const config: Options = try .init(gpa, config_text);
    defer config.deinit(gpa);

    // Run the target program mode

    var solver: Solver = try .init();
    defer solver.deinit();

    const vars = try encodeMain(&solver, &config);
    switch (solver.solve()) {
        .interrupted => std.debug.print("Solver interrupted.\n", .{}),
        .unsat => std.debug.print("Problem is UNSATISFIABLE\n", .{}),
        .sat => try decodeMain(io, &solver, &vars, &config),
    }
}

fn encodeMain(solver: *Solver, opt: *const Options) !Variables {
    // Run all of the functions that constrain the CNF
    const vars: Variables = .init(opt, solver);

    const function_name_list: []const []const u8 = &.{
        "blockMaps",
        "blockForced",
        "inputOverlap",
        "blockPowered",
        "torchPowered",
        "outputOverlap",
        "dustConnection",
        "inputBlockType",
        "ioTransitivity",
        "inputOverrideOn",
        "dustCardinality",
        "outputBlockType",
        "torchCardinality",
        "blockSingularity",
        "inputCardinality",
        "torchDistinctness",
        "outputCardinality",
        "outputConstrainOn",
        "torchBlockSupports",
        "inputOutputSpacing",
        "segmentTransitivity",
        "torchDustConnection",
        "inputMapCardinality",
        "torchAndBlockOutput",
        "connectedPoweredDust",
        "outputMapCardinality",
        "dustRedirectionSources",
        "inputOutputConstrainOff",
        "unaryStrengthsAndSegments",
        "inputOutputMapPositionMatch",
        "dustPowerStrengthPropagation",
    };

    inline for (function_name_list, 0..) |name, idx| {
        const fmt_args = .{ idx + 1, function_name_list.len, name };
        std.debug.print("{} / {} - {s}...\n", fmt_args);
        try @field(@This(), name)(solver, &vars, opt);
    }

    return vars;
}

fn decodeMain(
    io: Io,
    solver: *const Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    // For preventing unnecessary rendering
    var old_color: []const u8 = &.{};

    var buffer: [4096]u8 = undefined;
    const stdout_file = Io.File.stdout();
    var file_writer = stdout_file.writer(io, &buffer);
    const stdout = &file_writer.interface;

    for (0..opt.length) |z| {
        for (0..3) |sub_row| {
            for (0..opt.width) |x| {
                const pos = x + z * opt.width;

                const new_color = blockColor(
                    solver.value(vars.input.at(pos)),
                    solver.value(vars.output.at(pos)),
                    solver.value(vars.block.at(pos)),
                    solver.value(vars.torch.at(pos)),
                    solver.value(vars.torch_on.at(pos)),
                    solver.value(vars.dust.at(pos)),
                    solver.value(vars.strengthAt(opt, 0, pos).at(0)),
                );

                if (new_color) |color| {
                    if (color.ptr != old_color.ptr) {
                        try stdout.writeAll(color);
                        old_color = color;
                    }
                }

                for (0..3) |sub_col| {
                    const row: u2 = @intCast(sub_row);
                    const col: u2 = @intCast(sub_col);

                    if (solver.value(vars.dust.at(pos))) {
                        const n = solver.value(vars.facingConnectAt(0, pos));
                        const e = solver.value(vars.facingConnectAt(1, pos));
                        const s = solver.value(vars.facingConnectAt(2, pos));
                        const w = solver.value(vars.facingConnectAt(3, pos));
                        const display = dustDisplay(row, col, n, e, s, w);
                        try stdout.writeAll(display);
                    } else if (solver.value(vars.facingTorchAt(0, pos))) {
                        try stdout.writeAll(torchDisplay(row, col, 0));
                    } else if (solver.value(vars.facingTorchAt(1, pos))) {
                        try stdout.writeAll(torchDisplay(row, col, 1));
                    } else if (solver.value(vars.facingTorchAt(2, pos))) {
                        try stdout.writeAll(torchDisplay(row, col, 2));
                    } else if (solver.value(vars.facingTorchAt(3, pos))) {
                        try stdout.writeAll(torchDisplay(row, col, 3));
                    } else if (solver.value(vars.block.at(pos))) {
                        try stdout.writeAll(blockDisplay(row, col));
                    } else {
                        try stdout.writeAll(unknownDisplay(row, col));
                    }
                }
            }
            try stdout.writeByte('\n');
        }
    }

    try stdout.writeAll("\x1B[0m"); // color reset
    try stdout.flush();
}

fn blockColor(
    input: bool,
    output: bool,
    block: bool,
    torch: bool,
    torch_on: bool,
    dust: bool,
    dust_on: bool,
) ?[]const u8 {
    if (input) return "\x1B[38;5;51m"; // light blue
    if (output) return "\x1B[38;5;46m"; // neon green
    if (block) return "\x1B[38;5;240m"; // gray
    if (torch_on) return "\x1B[38;5;226m"; // yellow
    if (torch) return "\x1B[38;5;94m"; // brown
    if (dust_on) return "\x1B[38;5;196m"; // light red
    if (dust) return "\x1B[38;5;52m"; // dark red
    return null;
}

fn dustDisplay(
    row: u2,
    col: u2,
    north: bool,
    east: bool,
    south: bool,
    west: bool,
) []const u8 {
    if (row == 0 and col == 1 and north) return "𜶉𜶉";
    if (row == 1 and col == 2 and east) return "𜶉𜶉";
    if (row == 2 and col == 1 and south) return "𜶉𜶉";
    if (row == 1 and col == 0 and west) return "𜶉𜶉";
    if (row == 1 and col == 1) return "𜶉𜶉";

    return "  ";
}

fn torchDisplay(row: u2, col: u2, dir: u2) []const u8 {
    if (row == 1 and col == 1) return "𜷂𜷖";
    if (row == 2 and col == 1 and dir == 0) return "▐▌";
    if (row == 1 and col == 0 and dir == 1) return "𜴳𜴳";
    if (row == 0 and col == 1 and dir == 2) return "▐▌";
    if (row == 1 and col == 2 and dir == 3) return "𜴳𜴳";
    return "  ";
}

fn blockDisplay(row: u2, col: u2) []const u8 {
    if (row == 1 and col == 1) {
        return "🬤🬗";
    } else {
        return "██";
    }
}

fn unknownDisplay(row: u2, col: u2) []const u8 {
    if (row == 1 and col == 1) {
        return "??";
    } else {
        return "  ";
    }
}

/// Return a flat index representing an offset position, given an original
/// position, cardinal direction, and options - for the width of the circuit
fn cardinal(opt: *const Options, pos: usize, dir: usize) ?usize {
    const x = pos % opt.width;
    const z = pos / opt.width;

    return switch (@as(u2, @intCast(dir))) {
        // We must be after the first row if we are offset north
        0 => if (z > 0) pos - opt.width else null,
        // We must be before the last column if we are offset east
        1 => if (x < opt.width - 1) pos + 1 else null,
        // We must be before the last row if we are offset south
        2 => if (z < opt.length - 1) pos + opt.width else null,
        // we must be after the first column if we are offset west
        3 => if (x > 0) pos - 1 else null,
    };
}

// Allowed positions for inputs, outputs, torches, blocks, and dust
fn blockMaps(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        const x = pos % opt.width;
        const z = pos / opt.width;

        // Inputs are not to be placed where they aren't allowed
        if (opt.input_mask) |mask| if (mask[z][x] != 1)
            cnf.bitfalse(solver, vars.input.at(pos));
        // Outputs are not to be placed where they aren't allowed
        if (opt.output_mask) |mask| if (mask[z][x] != 1)
            cnf.bitfalse(solver, vars.output.at(pos));
        // Torches are not to be placed where they aren't allowed
        if (opt.torch_mask) |mask| if (mask[z][x] != 1)
            cnf.bitfalse(solver, vars.torch.at(pos));
        // Blocks are not to be placed where they aren't allowed
        if (opt.block_mask) |mask| if (mask[z][x] != 1)
            cnf.bitfalse(solver, vars.block.at(pos));
        // Dusts are not to be placed where they aren't allowed
        if (opt.dust_mask) |mask| if (mask[z][x] != 1)
            cnf.bitfalse(solver, vars.dust.at(pos));
    }
}

// Enforced positions for inputs, outputs, torches, blocks, and dust
fn blockForced(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        const x = pos % opt.width;
        const z = pos / opt.width;

        // Inputs are to be placed where they are forced
        if (opt.input_forced) |forced| if (forced[z][x] == 1)
            cnf.bittrue(solver, vars.input.at(pos));
        // Outputs are to be placed where they are forced
        if (opt.output_forced) |forced| if (forced[z][x] == 1)
            cnf.bittrue(solver, vars.output.at(pos));
        // Torches are to be placed where they are forced
        if (opt.torch_forced) |forced| if (forced[z][x] == 1)
            cnf.bittrue(solver, vars.torch.at(pos));
        // Blocks are to be placed where they are forced
        if (opt.block_forced) |forced| if (forced[z][x] == 1)
            cnf.bittrue(solver, vars.block.at(pos));
        // Dusts are to be placed where they are forced
        if (opt.dust_forced) |forced| if (forced[z][x] == 1)
            cnf.bittrue(solver, vars.dust.at(pos));
    }
}

// Prohibits air, dust, torch, and blocks from overlapping
fn blockSingularity(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // Exactly one-of dust, torch, and block is true.
        // That means that at least one must be true, and no
        // pair of two of these can possibly be true.

        const d = vars.dust.at(pos);
        const t = vars.torch.at(pos);
        const b = vars.block.at(pos);

        // At least one of D, T, B is true
        cnf.clause(solver, &.{ d, t, b }, &.{ 1, 1, 1 });

        // No two can be true at the same time
        cnf.clause(solver, &.{ d, t }, &.{ 0, 0 });
        cnf.clause(solver, &.{ t, b }, &.{ 0, 0 });
        cnf.clause(solver, &.{ b, d }, &.{ 0, 0 });
    }
}

// Prohibits torch variants from overlapping
fn torchDistinctness(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        const t = vars.torch.at(pos);
        const n = vars.facingTorchAt(0, pos);
        const e = vars.facingTorchAt(1, pos);
        const s = vars.facingTorchAt(2, pos);
        const w = vars.facingTorchAt(3, pos);

        // n, e, s, w, imply t
        cnf.bitimp(solver, n, t);
        cnf.bitimp(solver, e, t);
        cnf.bitimp(solver, s, t);
        cnf.bitimp(solver, w, t);

        // t implies n, e, s, OR w
        cnf.clause(
            solver,
            &.{ t, n, e, s, w },
            &.{ 0, 1, 1, 1, 1 },
        );

        // no two directions can coexist
        cnf.clause(solver, &.{ n, e }, &.{ 0, 0 });
        cnf.clause(solver, &.{ n, s }, &.{ 0, 0 });
        cnf.clause(solver, &.{ n, w }, &.{ 0, 0 });
        cnf.clause(solver, &.{ e, s }, &.{ 0, 0 });
        cnf.clause(solver, &.{ e, w }, &.{ 0, 0 });
        cnf.clause(solver, &.{ s, w }, &.{ 0, 0 });
    }
}

// Torches must have a block that will hold them up - this means that north
// facing torches have a block to the south, east facing torches have a block
// to the west, south facing torches have a block to the north, et cetera.
fn torchBlockSupports(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        for (0..4) |dir| {
            const torch = vars.facingTorchAt(dir, pos);
            if (cardinal(opt, pos, (dir + 2) % 4)) |card| {
                const block = vars.block.at(card);
                cnf.bitimp(solver, torch, block);
            } else {
                cnf.bitfalse(solver, torch);
            }
        }
    }
}

// Prevent cardinal inputs and outputs from touching each other, depending
// on the configuration of input-input, output-output, or input-output
fn inputOutputSpacing(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // To prevent duplications of clauses, only deal with two
        // cardinal directions, encoding the bijective when necessary.
        for (0..2) |dir| if (cardinal(opt, pos, dir)) |card| {
            // prevent inputs from touching cardinal inputs
            if (opt.input_spacing) {
                cnf.part(solver, vars.input.at(pos), 0);
                cnf.part(solver, vars.input.at(card), 0);
                cnf.end(solver);
            }

            // prevent outputs from touching cardinal outputs
            if (opt.output_spacing) {
                cnf.part(solver, vars.output.at(pos), 0);
                cnf.part(solver, vars.output.at(card), 0);
                cnf.end(solver);
            }

            // prevent inputs from touching cardinal outputs
            if (opt.both_io_spacing) {
                // INPUT -> OUTPUT
                cnf.part(solver, vars.input.at(pos), 0);
                cnf.part(solver, vars.output.at(card), 0);
                cnf.end(solver);
                // OUTPUT -> INPUT
                cnf.part(solver, vars.output.at(pos), 0);
                cnf.part(solver, vars.input.at(card), 0);
                cnf.end(solver);
            }
        };
    }
}

// make torches require cardinal dust
// OR act as an output
fn torchDustConnection(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // EITHER: there is no torch at this coordinate
        cnf.part(solver, vars.torch.at(pos), 0);

        // OR: the torch is set to be an output
        if (opt.allow_torch_output)
            cnf.part(solver, vars.output.at(pos), 1);

        // OR: There is a dust offset from the torch
        for (0..4) |dir|
            if (cardinal(opt, pos, dir)) |card|
                cnf.part(solver, vars.dust.at(card), 1);

        // Torches imply one connected dust to it's sides,
        // or it could be the case that it is an output.
        cnf.end(solver);
    }
}

// restrict the number of inputs
fn inputCardinality(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    switch (opt.input_count) {
        0 => assert(false), // checked in Options.init()
        1 => {
            // Exactly of the blocks is an input
            cnf.cardinalityOne(solver, vars.input, null);
        },
        else => {
            // Count the number bits and constrain to the input_count
            const cardinality = cnf.unaryTotalize(solver, vars.input);
            cnf.unaryConstrainEQVal(solver, cardinality, opt.input_count);
        },
    }
}

// restrict the number of outputs
fn outputCardinality(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    switch (opt.output_count) {
        0 => assert(false), // checked in Options.init()
        1 => {
            // Exactly of the blocks is an output
            cnf.cardinalityOne(solver, vars.output, null);
        },
        else => {
            // Count the number bits and constrain to the output_count
            const cardinality = cnf.unaryTotalize(solver, vars.output);
            cnf.unaryConstrainEQVal(solver, cardinality, opt.output_count);
        },
    }
}

// restrict the number of dusts
fn dustCardinality(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    // We don't need to handle unknown maximum
    const count = opt.max_dust orelse return;

    switch (count) {
        0 => {
            // Zero dust means that all are not dust
            for (0..opt.area()) |pos|
                cnf.bitfalse(solver, vars.dust.at(pos));
        },
        1 => {
            // At least one of the blocks is a dust
            for (0..opt.area()) |pos|
                cnf.part(solver, vars.dust.at(pos), 1);
            cnf.end(solver);

            // At most one of the blocks is a dust
            for (0..opt.area()) |lhs| {
                for (0..lhs) |rhs| {
                    const a = vars.dust.at(lhs);
                    const b = vars.dust.at(rhs);
                    cnf.clause(solver, &.{ a, b }, &.{ 0, 0 });
                }
            }
        },
        else => {
            // Count the number bits and constrain to the count
            const cardinality = cnf.unaryTotalize(solver, vars.dust);
            cnf.unaryConstrainLEVal(solver, cardinality, count);
        },
    }
}

// restrict the number of torches
fn torchCardinality(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    // We don't need to handle unknown maximum
    const count = opt.max_torch orelse return;

    switch (count) {
        0 => {
            // Zero torch means that all are not torch
            for (0..opt.area()) |pos|
                cnf.bitfalse(solver, vars.torch.at(pos));
        },
        1 => {
            // At least one of the blocks is a torch
            for (0..opt.area()) |pos|
                cnf.part(solver, vars.torch.at(pos), 1);
            cnf.end(solver);

            // At most one of the blocks is a torch
            for (0..opt.area()) |lhs| {
                for (0..lhs) |rhs| {
                    const a = vars.torch.at(lhs);
                    const b = vars.torch.at(rhs);
                    cnf.clause(solver, &.{ a, b }, &.{ 0, 0 });
                }
            }
        },
        else => {
            // Count the number bits and constrain to the count
            const cardinality = cnf.unaryTotalize(solver, vars.torch);
            cnf.unaryConstrainLEVal(solver, cardinality, count);
        },
    }
}

// constrain cardinal dust redirection sources
fn dustRedirectionSources(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        for (0..4) |dir| {
            // The direction that we will be redirecting
            const redirect = vars.facingRedirectAt(dir, pos);

            if (cardinal(opt, pos, dir)) |card| {
                // The direction we are observing is in bounds, so it only will
                // matter if the block in this direction is a torch or dust.

                const t_off = vars.torch.at(card);
                const d_off = vars.dust.at(card);
                cnf.bitor(solver, t_off, d_off, redirect);
            } else {
                // The direction we are observing is out of bounds, so the dust
                // will only redirect if the dust is an input (and we allow
                // input dust to redirect), or if the dust is an output (and we
                // allow output dust to redirect).

                const out = vars.output.at(pos);
                const inp = vars.input.at(pos);

                const r_inp = @intFromBool(opt.redirect_input_edge_dust);
                const r_out = @intFromBool(opt.redirect_output_edge_dust);

                switch ((@as(u2, r_inp) << 1) | r_out) {
                    // The edge dust can't ever redirect
                    0b00 => cnf.bitfalse(solver, redirect),
                    // The dust redirects if it is an output
                    0b01 => cnf.biteql(solver, out, redirect),
                    // The dust redirects if it is an input
                    0b10 => cnf.biteql(solver, inp, redirect),
                    // The dust redirects if input or output
                    0b11 => cnf.bitor(solver, inp, out, redirect),
                }
            }
        }
    }
}

// constrain connections of dust blocks
fn dustConnection(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // d -> whether the current block is dust

        const d = vars.dust.at(pos);

        // n_r -> whether the north block can redirect
        // e_r -> whether the east block can redirect
        // s_r -> whether the south block can redirect
        // w_r -> whether the west block can redirect

        const n_r = vars.facingRedirectAt(0, pos);
        const e_r = vars.facingRedirectAt(1, pos);
        const s_r = vars.facingRedirectAt(2, pos);
        const w_r = vars.facingRedirectAt(3, pos);

        // n_c -> whether the dust connects north
        // e_c -> whether the dust connects east
        // s_c -> whether the dust connects south
        // w_c -> whether the dust connects west

        const n_c = vars.facingConnectAt(0, pos);
        const e_c = vars.facingConnectAt(1, pos);
        const s_c = vars.facingConnectAt(2, pos);
        const w_c = vars.facingConnectAt(3, pos);

        // (NOT d) -> (NOT n_c)
        // (NOT d) -> (NOT e_c)
        // (NOT d) -> (NOT s_c)
        // (NOT d) -> (NOT w_c)

        cnf.clause(solver, &.{ d, n_c }, &.{ 1, 0 });
        cnf.clause(solver, &.{ d, e_c }, &.{ 1, 0 });
        cnf.clause(solver, &.{ d, s_c }, &.{ 1, 0 });
        cnf.clause(solver, &.{ d, w_c }, &.{ 1, 0 });

        // (d AND n) -> n_c
        // (d AND e) -> e_c
        // (d AND s) -> s_c
        // (d AND w) -> w_c

        cnf.clause(solver, &.{ d, n_r, n_c }, &.{ 0, 0, 1 });
        cnf.clause(solver, &.{ d, e_r, e_c }, &.{ 0, 0, 1 });
        cnf.clause(solver, &.{ d, s_r, s_c }, &.{ 0, 0, 1 });
        cnf.clause(solver, &.{ d, w_r, w_c }, &.{ 0, 0, 1 });

        // (e AND NOT n) -> (NOT n_c)
        // (n AND NOT e) -> (NOT e_c)
        // (w AND NOT s) -> (NOT s_c)
        // (s AND NOT w) -> (NOT w_c)

        cnf.clause(solver, &.{ e_r, n_r, n_c }, &.{ 0, 1, 0 });
        cnf.clause(solver, &.{ n_r, e_r, e_c }, &.{ 0, 1, 0 });
        cnf.clause(solver, &.{ w_r, s_r, s_c }, &.{ 0, 1, 0 });
        cnf.clause(solver, &.{ s_r, w_r, w_c }, &.{ 0, 1, 0 });

        // (w AND NOT n AND NOT e) -> (NOT n_c)
        // (s AND NOT n AND NOT e) -> (NOT e_c)
        // (e AND NOT s AND NOT w) -> (NOT s_c)
        // (n AND NOT s AND NOT w) -> (NOT w_c)

        cnf.clause(solver, &.{ w_r, n_r, e_r, n_c }, &.{ 0, 1, 1, 0 });
        cnf.clause(solver, &.{ s_r, n_r, e_r, e_c }, &.{ 0, 1, 1, 0 });
        cnf.clause(solver, &.{ e_r, s_r, w_r, s_c }, &.{ 0, 1, 1, 0 });
        cnf.clause(solver, &.{ n_r, s_r, w_r, w_c }, &.{ 0, 1, 1, 0 });

        // (d AND NOT n AND NOT e AND NOT w) -> n_c
        // (d AND NOT n AND NOT e AND NOT s) -> e_c
        // (d AND NOT e AND NOT s AND NOT w) -> s_c
        // (d AND NOT n AND NOT s AND NOT w) -> w_c

        cnf.clause(solver, &.{ d, n_r, e_r, w_r, n_c }, &.{ 0, 1, 1, 1, 1 });
        cnf.clause(solver, &.{ d, n_r, e_r, s_r, e_c }, &.{ 0, 1, 1, 1, 1 });
        cnf.clause(solver, &.{ d, e_r, s_r, w_r, s_c }, &.{ 0, 1, 1, 1, 1 });
        cnf.clause(solver, &.{ d, n_r, s_r, w_r, w_c }, &.{ 0, 1, 1, 1, 1 });
    }
}

// constrain matching positions of input/output and input_map/output_map
fn inputOutputMapPositionMatch(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // ------------------------------------------------ FORWARD IMPLICATION

        // No input mappings can exist without an input
        for (0..opt.input_count) |inp| {
            const inp_map = vars.inputMapAt(opt, inp, pos);
            cnf.bitimp(solver, inp_map, vars.input.at(pos));
        }

        // No output mappings can exist without an output
        for (0..opt.output_count) |out| {
            const out_map = vars.outputMapAt(opt, out, pos);
            cnf.bitimp(solver, out_map, vars.output.at(pos));
        }

        // ----------------------------------------------- BACKWARD IMPLICATION

        // EITHER: there is no input here
        cnf.part(solver, vars.input.at(pos), 0);
        // OR: there is a mapping here
        for (0..opt.input_count) |inp|
            cnf.part(solver, vars.inputMapAt(opt, inp, pos), 1);
        // No inputs can exist without a mapping
        cnf.end(solver);

        // EITHER: there is no output here
        cnf.part(solver, vars.output.at(pos), 0);
        // OR: there is a mapping here
        for (0..opt.output_count) |out|
            cnf.part(solver, vars.outputMapAt(opt, out, pos), 1);
        // No outputs can exist without a mapping
        cnf.end(solver);
    }
}

// constrain correct input block type
fn inputBlockType(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // Either this is not an input
        cnf.part(solver, vars.input.at(pos), 0);

        // Or this is a block
        if (opt.allow_block_input)
            cnf.part(solver, vars.block.at(pos), 1);

        // Or this is a dust
        if (opt.allow_dust_input)
            cnf.part(solver, vars.dust.at(pos), 1);

        cnf.end(solver);
    }
}

// constrain correct output block type
fn outputBlockType(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // Either this is not an output
        cnf.part(solver, vars.output.at(pos), 0);

        // Or this is a dust
        if (opt.allow_dust_output)
            cnf.part(solver, vars.dust.at(pos), 1);

        // Or this is a torch
        if (opt.allow_torch_output)
            cnf.part(solver, vars.torch.at(pos), 1);

        cnf.end(solver);
    }
}

// constrain transitivity of inputs and outputs
fn ioTransitivity(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |p_hi| for (0..p_hi) |p_lo| {
        // greater inputs come before lesser inputs
        if (opt.input_transitivity) {
            for (0..opt.input_count) |i_gt| for (0..i_gt) |i_lt| {
                const a = vars.inputMapAt(opt, i_gt, p_hi);
                const b = vars.inputMapAt(opt, i_lt, p_lo);
                cnf.clause(solver, &.{ a, b }, &.{ 0, 0 });
            };
        }

        // greater outputs come before lesser outputs
        if (opt.output_transitivity) {
            for (0..opt.output_count) |o_gt| for (0..o_gt) |o_lt| {
                const a = vars.outputMapAt(opt, o_gt, p_hi);
                const b = vars.outputMapAt(opt, o_lt, p_lo);
                cnf.clause(solver, &.{ a, b }, &.{ 0, 0 });
            };
        }
    };
}

// constrain cardinality of input_map
fn inputMapCardinality(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.input_count) |inp| {

        // At least one position is mapped for each input
        for (0..opt.area()) |pos|
            cnf.part(solver, vars.inputMapAt(opt, inp, pos), 1);
        cnf.end(solver);

        // At most one position is mapped for each input
        for (0..opt.area()) |rhs| {
            for (0..rhs) |lhs| {
                const a = vars.inputMapAt(opt, inp, lhs);
                const b = vars.inputMapAt(opt, inp, rhs);
                cnf.clause(solver, &.{ a, b }, &.{ 0, 0 });
            }
        }
    }
}

// constrain cardinality of output_map
fn outputMapCardinality(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.output_count) |out| {
        // At least one position is mapped for each output
        for (0..opt.area()) |pos|
            cnf.part(solver, vars.outputMapAt(opt, out, pos), 1);
        cnf.end(solver);

        // At most one position is mapped for each output
        for (0..opt.area()) |rhs| {
            for (0..rhs) |lhs| {
                const a = vars.outputMapAt(opt, out, lhs);
                const b = vars.outputMapAt(opt, out, rhs);
                cnf.clause(solver, &.{ a, b }, &.{ 0, 0 });
            }
        }
    }
}

// prevent overlapping inputs
fn inputOverlap(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.input_count) |lhs_idx| {
        for (0..lhs_idx) |rhs_idx| {
            for (0..opt.area()) |pos| {
                const lhs = vars.inputMapAt(opt, lhs_idx, pos);
                const rhs = vars.inputMapAt(opt, rhs_idx, pos);
                cnf.clause(solver, &.{ lhs, rhs }, &.{ 0, 0 });
            }
        }
    }
}

// prevent overlapping outputs
fn outputOverlap(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.output_count) |lhs_idx| {
        for (0..lhs_idx) |rhs_idx| {
            for (0..opt.area()) |pos| {
                const lhs = vars.outputMapAt(opt, lhs_idx, pos);
                const rhs = vars.outputMapAt(opt, rhs_idx, pos);
                cnf.clause(solver, &.{ lhs, rhs }, &.{ 0, 0 });
            }
        }
    }
}

// determine if a block is currently powered
fn blockPowered(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            const b = vars.block.at(pos);
            const p = vars.blockOnAt(opt, state, pos);
            const o = vars.overrideOnAt(opt, state, pos);

            // ---------------------- FORWARD IMPLICATION - block is powered on

            // If adjacent blocks are connected back to this block, AND if they
            // are powered on, AND if the current cell is a block, then the
            // current cell must be powered on.

            for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                const s = vars.strengthAt(opt, state, card).at(0);
                const c = vars.facingConnectAt((dir + 2) % 4, card);
                cnf.clause(solver, &.{ b, c, s, p }, &.{ 0, 0, 0, 1 });
            };

            // If the current cell is a block and it was overridden to be
            // powered on (an input force it to be on), then it must be on.

            cnf.clause(solver, &.{ b, o, p }, &.{ 0, 0, 1 });

            // -------------------- BACKWARD IMPLICATION - block is powered off

            // If not a block, this can't be powered as a block
            cnf.clause(solver, &.{ b, p }, &.{ 1, 0 });

            // EITHER: the block is unpowered
            cnf.part(solver, p, 0);

            // OR: the block is overridden to be powered
            cnf.part(solver, o, 1);

            // OR: an adjacent dust is connected and powered
            for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                const rev = (dir + 2) % 4;
                cnf.part(solver, vars.connectedOnAt(opt, rev, state, card), 1);
            };

            cnf.end(solver);
        }
    }
}

// determine if a torch is currently powered
fn torchPowered(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                const p = vars.blockOnAt(opt, state, pos);
                const f_t = vars.facingTorchAt(dir, card);
                const t_p = vars.torchOnAt(opt, state, card);

                // --------------------------------------- FORWARDS IMPLICATION
                // EITHER: block powered, torch powered, or not the right torch
                cnf.clause(solver, &.{ p, f_t, t_p }, &.{ 1, 0, 1 });

                // -------------------------------------- BACKWARDS IMPLICATION
                // EITHER: block unpowered, torch unpowered, or the right torch
                cnf.clause(solver, &.{ p, f_t, t_p }, &.{ 0, 0, 0 });
            };

            // If a torch is powered, it implies it is a torch
            const p = vars.torchOnAt(opt, state, pos);
            const t = vars.torch.at(pos);
            cnf.clause(solver, &.{ p, t }, &.{ 0, 1 });
        }
    }
}

// Given the current state and index of the input, return the input value
fn inputValue(state: usize, inp: usize) u1 {
    return @truncate(state >> @intCast(inp));
}

// Given the current state and index of the output, return the defined output
fn outputValue(opt: *const Options, state: usize, out: usize) ?u1 {
    outer: for (opt.truth[out]) |row| {
        for (row[0], 0..) |bit, off| {
            // Ensure that this row matches - if it does not, this row is not
            // the one the current state is referring to, so skip it.
            if (bit != (state >> @intCast(off)) & 1) continue :outer;
        }

        // The row signifies the current state, so the output for
        // this input state is the second value of the tuple.
        return row[1];
    }

    // No rows in the output truth table matched this state, so this output for
    // this state is left undefined and should be constrained explicitly.
    return null;
}

// constrain override_on based on input_map & state
fn inputOverrideOn(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            const o = vars.overrideOnAt(opt, state, pos);

            // ---------------------- FORWARD IMPLICATION - overridden to be on

            // For every single input, if the state of that input is supposed
            // to be TRUE, then whether the current cell is that input's
            // position will imply that the override is TRUE.

            for (0..opt.input_count) |inp|
                if (inputValue(state, inp) == 1)
                    cnf.bitimp(solver, vars.inputMapAt(opt, inp, pos), o);

            // ----------------- BACKWARD IMPLICATION - not overridden to be on

            // The override is false if and only if every single input which is
            // true does not reside at the current cell. This is the same as
            // encoding a single CNF clause where either the override is FALSE,
            // or each input (if it is true in this state) is at this position.

            cnf.part(solver, o, 0);

            for (0..opt.input_count) |inp|
                if (inputValue(state, inp) == 1)
                    cnf.part(solver, vars.inputMapAt(opt, inp, pos), 1);

            cnf.end(solver);
        }
    }
}

// constrain constrain_off based on input_map & output_map & state
fn inputOutputConstrainOff(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            const c = vars.constrainOffAt(opt, state, pos);

            // -------------------- FORWARD IMPLICATION - constrained to be off

            // For every single input, if the state of that input is supposed
            // to be FALSE, then if it is *that* input implies the constraint.

            if (opt.input_isolation)
                for (0..opt.input_count) |inp|
                    if (inputValue(state, inp) == 0)
                        cnf.bitimp(solver, vars.inputMapAt(opt, inp, pos), c);

            // For every single output, if the state of that output is supposed
            // to be FALSE, then if it is *that* output implies the constraint.

            for (0..opt.output_count) |out|
                if (outputValue(opt, state, out) == 0)
                    cnf.bitimp(solver, vars.outputMapAt(opt, out, pos), c);

            // --------------- BACKWARD IMPLICATION - not constrained to be off

            // EITHER: the cell is not constrained to be off
            cnf.part(solver, c, 0);

            // OR: there is an input and it is powered off
            if (opt.input_isolation)
                for (0..opt.input_count) |inp|
                    if (inputValue(state, inp) == 0)
                        cnf.part(solver, vars.inputMapAt(opt, inp, pos), 1);

            // OR: there is an output and it is powered off
            for (0..opt.output_count) |out|
                if (outputValue(opt, state, out) == 0)
                    cnf.part(solver, vars.outputMapAt(opt, out, pos), 1);

            cnf.end(solver);
        }
    }
}

// constrain constrain_on based on output_map & state
fn outputConstrainOn(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            const c = vars.constrainOnAt(opt, state, pos);

            // --------------------- FORWARD IMPLICATION - constrained to be on

            // For every single output, if the state of that output is supposed
            // to be TRUE, then the power is implied by if that cell is output.

            for (0..opt.output_count) |out|
                if (outputValue(opt, state, out) == 1)
                    cnf.bitimp(solver, vars.outputMapAt(opt, out, pos), c);

            // ---------------- BACKWARD IMPLICATION - not constrained to be on

            // EITHER: the cell is not constrained to be on
            cnf.part(solver, c, 0);

            // OR: there is an output and it is powered on
            for (0..opt.output_count) |out|
                if (outputValue(opt, state, out) == 1)
                    cnf.part(solver, vars.outputMapAt(opt, out, pos), 1);

            cnf.end(solver);
        }
    }
}

// constrain all bitblasted numbers to be unary
fn unaryStrengthsAndSegments(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        cnf.unaryConstrain(solver, vars.segmentAt(opt, pos));
        for (0..opt.states()) |state| {
            cnf.unaryConstrain(solver, vars.strengthAt(opt, state, pos));
        }
    }
}

// constrain torches and blocks to be on with constrain_on
fn torchAndBlockOutput(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            const constrain_on = vars.constrainOnAt(opt, state, pos);
            const constrain_off = vars.constrainOffAt(opt, state, pos);

            if (opt.allow_torch_output) {
                const t = vars.torch.at(pos);
                const t_on = vars.torchOnAt(opt, state, pos);
                // (constrain_on AND torch) implies torch_on
                cnf.clause(solver, &.{ constrain_on, t, t_on }, &.{ 0, 0, 1 });
                // (constrain_off AND torch) implies NOT torch_on
                cnf.clause(solver, &.{ constrain_off, t, t_on }, &.{ 0, 0, 0 });
            }
        }
    }
}

// determine if dust is cardinally connected AND on
fn connectedPoweredDust(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            for (0..4) |dir| {
                const c = vars.facingConnectAt(dir, pos);
                const p = vars.strengthAt(opt, state, pos).at(0);
                const c_p = vars.connectedOnAt(opt, dir, state, pos);
                cnf.bitand(solver, c, p, c_p);
            }
        }
    }
}

// constrain signal strength and power of dust
fn dustPowerStrengthPropagation(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {

            // Whether the current block (at pos) is dust
            const dust = vars.dust.at(pos);
            // The signal strength of the current block (at pos, for state)
            const strength = vars.strengthAt(opt, state, pos);
            // Whether the current block (at pos, for state) is fully powered
            const maxxed = strength.at(14);
            // Whether the current block (at pos, for state) is powered
            const powered = strength.at(0);

            // -------------------------------------------- FORWARD IMPLICATION

            // Dust is fully powered by adjacent powered torches
            for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                const torch_on = vars.torchOnAt(opt, state, card);
                cnf.clause(solver, &.{ torch_on, dust, maxxed }, &.{ 0, 0, 1 });
            };

            // Dust is fully powered if overridden to be on (it is an input)
            const override_on = vars.overrideOnAt(opt, state, pos);
            cnf.clause(solver, &.{ override_on, dust, maxxed }, &.{ 0, 0, 1 });

            // Dust is powered if constrained to be on (it is an output)
            const constrain_on = vars.constrainOnAt(opt, state, pos);
            cnf.clause(solver, &.{ constrain_on, dust, powered }, &.{ 0, 0, 1 });

            // Dust strength is at least max(neighbors_strength) -| 1
            for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                const source = vars.strengthAt(opt, state, card);
                for (0..14) |bit| {
                    const src = source.at(bit + 1);
                    const dst = strength.at(bit);
                    cnf.clause(solver, &.{ dust, src, dst }, &.{ 0, 0, 1 });
                }
            };

            // ------------------------------------------- BACKWARD IMPLICATION

            // Any dust power level implies that this is dust
            cnf.clause(solver, &.{ powered, dust }, &.{ 0, 1 });

            // Dust is not powered if constrained to be off (input or output)
            const constrain_off = vars.constrainOffAt(opt, state, pos);
            cnf.clause(solver, &.{ constrain_off, powered }, &.{ 0, 0 });

            for (0..15) |bit| {
                // EITHER: We are not at maximum signal strength
                cnf.part(solver, strength.at(bit), 0);

                // OR: The dust has been overridden to be maxxed
                cnf.part(solver, override_on, 1);

                // OR: An adjacent torch is currently powered on
                for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                    cnf.part(solver, vars.torchOnAt(opt, state, card), 1);
                };

                // OR: a cardinal strength bit at "bit + 1" is TRUE
                for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                    const source = vars.strengthAt(opt, state, card);
                    if (bit < 14)
                        cnf.part(solver, source.at(bit + 1), 1);
                };

                cnf.end(solver);
            }
        }
    }
}

// constrain segment values to ensure acyclic graph

fn segmentTransitivity(
    solver: *Solver,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {

            // Redstone dust has the same ID as it's cardinal redstone dust

            // The current block is dust:
            const p_dust = vars.dust.at(pos);
            // The current block is a torch
            const p_torch = vars.torch.at(pos);
            // The current block is dust, connected in dir:
            const p_con = vars.facingConnectAt(dir, pos);
            // The cardinal block is dust:
            const c_dust = vars.dust.at(card);
            // The cardinal block is block:
            const c_block = vars.block.at(card);
            // The cardinal block is a torch facing in <dir>
            const c_torch = vars.facingTorchAt(dir, card);
            // The first unary bit of the segment ID HERE
            const p_first = vars.segmentAt(opt, pos).at(0);
            // The last unary bit of the segment ID THERE
            const last = opt.transition_bits - 1;
            const c_last = vars.segmentAt(opt, card).at(last);

            // ---- Dust that connects to other dust shares the same segment ID

            for (0..opt.transition_bits) |bit| {
                // The current unary bit at <bit> for segment
                const a = vars.segmentAt(opt, pos).at(bit);
                // The cardinal unary bit at <bit> for segment
                const b = vars.segmentAt(opt, card).at(bit);
                // (dust HERE & dust THERE & bit THERE) -------------> bit HERE
                cnf.clause(solver, &.{ p_dust, c_dust, b, a }, &.{ 0, 0, 0, 1 });
                // (dust HERE & dust THERE & bit HERE) -------------> bit THERE
                cnf.clause(solver, &.{ p_dust, c_dust, a, b }, &.{ 0, 0, 0, 1 });
            }

            // ------ Torches have less ID than the block they are connected to

            for (0..opt.transition_bits - 1) |bit| {
                // The current unary bit at <bit + 1> for segment
                const a = vars.segmentAt(opt, pos).at(bit + 1);
                // The cardinal unary bit at <bit> for segment
                const b = vars.segmentAt(opt, card).at(bit);
                // (torch THERE & lower bit THERE) -----------> higher bit HERE
                cnf.clause(solver, &.{ c_torch, b, a }, &.{ 0, 0, 1 });
            }
            // facing torch THERE -----------------------> first unary bit HERE
            cnf.clause(solver, &.{ c_torch, p_first }, &.{ 0, 1 });
            // facing torch THERE --------------------> NO last unary bit THERE
            cnf.clause(solver, &.{ c_torch, c_last }, &.{ 0, 0 });

            // -------- Blocks have less ID than the dust they are connected to

            for (0..opt.transition_bits - 1) |bit| {
                // The current unary bit at <bit + 1> for segment
                const a = vars.segmentAt(opt, pos).at(bit + 1);
                // The cardinal unary bit at <bit> for segment
                const b = vars.segmentAt(opt, card).at(bit);
                // (connected HERE & block THERE & bit THERE) -> lower bit HERE
                cnf.clause(solver, &.{ p_con, c_block, b, a }, &.{ 0, 0, 0, 1 });
            }
            // (connected HERE & block THERE) -----------> first unary bit HERE
            cnf.clause(solver, &.{ p_con, c_block, p_first }, &.{ 0, 0, 1 });
            // (connected HERE & block THERE) --------> NO last unary bit THERE
            cnf.clause(solver, &.{ p_con, c_block, c_last }, &.{ 0, 0, 0 });

            // ---- Redstone dust has less ID than cardinally connected torches

            for (0..opt.transition_bits - 1) |bit| {
                // The current unary bit at <bit + 1> for segment
                const a = vars.segmentAt(opt, pos).at(bit + 1);
                // The cardinal unary bit at <bit> for segment
                const b = vars.segmentAt(opt, card).at(bit);
                // (torch HERE & dust THERE & bit THERE) ------> lower bit HERE
                cnf.clause(solver, &.{ p_torch, c_dust, b, a }, &.{ 0, 0, 0, 1 });
            }
            // (torch HERE & dust THERE) ----------------> first unary bit HERE
            cnf.clause(solver, &.{ p_torch, c_dust, p_first }, &.{ 0, 0, 1 });
            // (torch HERE & dust THERE) -------------> NO last unary bit THERE
            cnf.clause(solver, &.{ p_torch, c_dust, c_last }, &.{ 0, 0, 0 });
        };
    }
}
