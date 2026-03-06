const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Io = std.Io;

const Cnf = @import("Cnf.zig");
const Bits = Cnf.Bits;

// ----------------------------------------------------------------------- MAIN

pub fn main(init: std.process.Init.Minimal) void {

    // Initialize process

    const gpa = std.heap.smp_allocator;

    var threaded: Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.ioBasic();

    // Print the usage of our program on error
    // Indicate error by exiting with status 1

    var process: []const u8 = "UNKNOWN";

    errdefer {
        std.debug.print(
            \\ USAGE: {s} [MODE] [CONFIG] [PATH]
            \\   MODE:
            \\     e --> Encodes CNF problem
            \\     d --> Decodes CNF problem
            \\   CONFIG:
            \\     * Path to valid .zon config
            \\     * Required by modes e and d
            \\   PATH:
            \\     * In mode e: path to output .cnf file
            \\     * In mode d: path to solution file
            \\     * Required by modes e and d
            \\
        , .{process});
        std.process.exit(1);
    }

    // Capture the CLI arguments

    const ArgsIterator = std.process.Args.Iterator;
    var args: ArgsIterator = try .initAllocator(init.args, gpa);
    defer args.deinit();

    process = args.next() orelse
        return error.LackingArgs;
    const mode_str = args.next() orelse
        return error.LackingArgs;
    const config_path = args.next() orelse
        return error.LackingArgs;
    const path = args.next() orelse
        return error.LackingArgs;

    // Read the configuation and parse into an options struct

    const cwd = std.Io.Dir.cwd();
    const config_text = try Io.Dir.readFileAllocOptions( //
        cwd, io, config_path, gpa, .unlimited, .@"1", 0);
    const config: Options = try .init(gpa, config_text);
    defer config.deinit(gpa);

    // Run the target program mode

    if (std.mem.eql(u8, mode_str, "e")) {
        return try encodeMain(io, gpa, &config, path);
    } else if (std.mem.eql(u8, mode_str, "d")) {
        return try decodeMain(io, gpa, &config, path);
    } else {
        return error.UnknownMode;
    }
}

// TODO:
// - Add something to config that allows people to block out positions
// - Add something to config that allows constraining of input/outputs
// - Add something to select either/or torches/dust for output types
// - Add something to select either/or dust/blocks for input types
// - Add option to allow inputs or outputs to always be negated

const Options = struct {
    // how many inputs there are to the circuit
    input_count: u64,
    // how many outputs there are to the circuit
    output_count: u64,
    // how many blocks [west to east] the circuit is
    width: u64,
    // how many blocks [north to south] the circuit is
    length: u64,
    // truth table that the circuit must satisfy
    truth: []const []const struct { []const u1, u1 },

    // allowed positions for inputs
    input_mask: ?[]const u1,
    // allowed positions for outputs
    output_mask: ?[]const u1,
    // allowed positions for torches
    torch_mask: ?[]const u1,
    // allowed positions for blocks
    block_mask: ?[]const u1,
    // allowed positions for dust
    dust_mask: ?[]const u1,

    // maximum number of redstone dusts
    max_dust: ?u64,
    // maximum number of redstone torches
    max_torch: ?u64,

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

    // enforce transitivity for inputs and outputs
    io_transitivity: bool,
    // prevent backfeeding of signal to the inputs
    input_isolation: bool,
    // whether to redirect input dust on the edges
    redirect_input_edge_dust: bool,
    // whether to redirect output dust on the edges
    redirect_output_edge_dust: bool,

    // enforce acyclic graph with a unary counter
    transition_bits: u64,
    // redstone dust max signal strength
    max_signal_strength: u64,

    fn init(gpa: Allocator, source: [:0]const u8) !@This() {
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

    fn deinit(self: *const @This(), gpa: Allocator) void {
        std.zon.parse.free(gpa, self.*);
    }

    fn area(self: *const @This()) u64 {
        return self.width * self.length;
    }

    fn states(self: *const @This()) u64 {
        return @as(u64, 1) << @intCast(self.input_count);
    }
};

const Variables = struct {
    // [position]
    dust: Bits, // position is dust
    torch: Bits, // position is torch
    block: Bits, // position is block
    input: Bits, // position is input
    output: Bits, // position is output

    // [cardinal_direction] * [position]
    facing_redirect: [4]Bits, // redirection source to the cardinal directions
    facing_connect: [4]Bits, // dust connected to the cardinal directions
    facing_torch: [4]Bits, // torch facing in a particular direction

    // [input_index] - [position]
    input_map: Bits, // selector for specific inputs

    // [output_index] - [position]
    output_map: Bits, // selector for specific outputs

    // [position] - [segment_bit_index]
    segment: Bits, // transitively enforce acyclicity

    // [state] - [position]
    torch_on: Bits, // torch is powered
    block_on: Bits, // block is powered
    override_on: Bits, // *override* something to be on
    constrain_on: Bits, // *constrain* something to be on
    constrain_off: Bits, // *constrain* something to be off

    // [cardinal_direction] - [state] - [position]
    connected_on: [4]Bits, // dust is powered and connected in some direction

    // [state] - [position] - [signal_strength_bit_index]
    strength: Bits,

    fn init(opt: *const Options, cnf: *Cnf) @This() {
        const area = opt.area();
        const states = opt.states();
        const seg_bits = opt.transition_bits;
        const power_bits = opt.max_signal_strength;

        return .{
            .dust = cnf.alloc(area),
            .torch = cnf.alloc(area),
            .block = cnf.alloc(area),
            .input = cnf.alloc(area),
            .output = cnf.alloc(area),

            .facing_redirect = .{
                cnf.alloc(area),
                cnf.alloc(area),
                cnf.alloc(area),
                cnf.alloc(area),
            },
            .facing_connect = .{
                cnf.alloc(area),
                cnf.alloc(area),
                cnf.alloc(area),
                cnf.alloc(area),
            },
            .facing_torch = .{
                cnf.alloc(area),
                cnf.alloc(area),
                cnf.alloc(area),
                cnf.alloc(area),
            },

            .input_map = cnf.alloc(opt.input_count * area),

            .output_map = cnf.alloc(opt.output_count * area),

            .segment = cnf.alloc(area * seg_bits),

            .torch_on = cnf.alloc(states * area),
            .block_on = cnf.alloc(states * area),
            .override_on = cnf.alloc(states * area),
            .constrain_on = cnf.alloc(states * area),
            .constrain_off = cnf.alloc(states * area),

            .connected_on = .{
                cnf.alloc(states * area),
                cnf.alloc(states * area),
                cnf.alloc(states * area),
                cnf.alloc(states * area),
            },

            .strength = cnf.alloc(states * area * power_bits),
        };
    }

    fn facingRedirectAt(self: *const @This(), dir: u64, pos: u64) u64 {
        assert(dir < 4);
        return self.facing_redirect[dir].at(pos);
    }

    fn facingConnectAt(self: *const @This(), dir: u64, pos: u64) u64 {
        assert(dir < 4);
        return self.facing_connect[dir].at(pos);
    }

    fn facingTorchAt(self: *const @This(), dir: u64, pos: u64) u64 {
        assert(dir < 4);
        return self.facing_torch[dir].at(pos);
    }

    fn inputMapAt(self: *const @This(), opt: *const Options, inp: u64, pos: u64) u64 {
        assert(inp < opt.input_count);
        return self.input_map.at(inp * opt.area() + pos);
    }

    fn outputMapAt(self: *const @This(), opt: *const Options, out: u64, pos: u64) u64 {
        assert(out < opt.output_count);
        return self.output_map.at(out * opt.area() + pos);
    }

    fn segmentAt(self: *const @This(), opt: *const Options, pos: u64) Bits {
        const index = self.segment.at(pos * opt.transition_bits);
        return .init(index, opt.transition_bits);
    }

    fn torchOnAt(self: *const @This(), opt: *const Options, state: u64, pos: u64) u64 {
        assert(state < opt.states());
        return self.torch_on.at(state * opt.area() + pos);
    }

    fn blockOnAt(self: *const @This(), opt: *const Options, state: u64, pos: u64) u64 {
        assert(state < opt.states());
        return self.block_on.at(state * opt.area() + pos);
    }

    fn overrideOnAt(self: *const @This(), opt: *const Options, state: u64, pos: u64) u64 {
        assert(state < opt.states());
        return self.override_on.at(state * opt.area() + pos);
    }

    fn constrainOnAt(self: *const @This(), opt: *const Options, state: u64, pos: u64) u64 {
        assert(state < opt.states());
        return self.constrain_on.at(state * opt.area() + pos);
    }

    fn constrainOffAt(self: *const @This(), opt: *const Options, state: u64, pos: u64) u64 {
        assert(state < opt.states());
        return self.constrain_off.at(state * opt.area() + pos);
    }

    fn connectedOnAt(self: *const @This(), opt: *const Options, dir: u64, state: u64, pos: u64) u64 {
        assert(dir < 4);
        assert(state < opt.states());
        return self.connected_on[dir].at(state * opt.area() + pos);
    }

    fn strengthAt(self: *const @This(), opt: *const Options, state: u64, pos: u64) Bits {
        assert(state < opt.states());
        const offset = (state * opt.area() + pos) * opt.max_signal_strength;
        return .init(self.strength.at(offset), opt.max_signal_strength);
    }
};

fn encodeMain(
    io: Io,
    _: Allocator,
    opt: *const Options,
    path: []const u8,
) !void {
    const cwd = Io.Dir.cwd();

    // Create a temporary file and writer to hold the CNF clauses

    var temp_closed: bool = false;
    const temp_path: []const u8 = "TEMP_CLAUSES.CNF";
    const temp_file = try cwd.createFile(io, temp_path, .{});
    errdefer if (!temp_closed) temp_file.close(io);
    var temp_buffer: [64]u8 = undefined;
    var temp_writer = temp_file.writer(io, &temp_buffer);
    const temp = &temp_writer.interface;

    // Run all of the functions that constrain the CNF

    var cnf: Cnf = .init(temp);
    defer cnf.deinit();

    const vars: Variables = .init(opt, &cnf);

    const function_name_list: []const []const u8 = &.{
        "blockMaps",
        "inputOverlap",
        "blockPowered",
        "torchPowered",
        "outputOverlap",
        "dustConnection",
        "inputBlockType",
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
        try @field(@This(), name)(&cnf, &vars, opt);
    }

    // Open "real_file" (real output) and create buffered writer "real"

    const real_file = try cwd.createFile(io, path, .{});
    defer real_file.close(io);
    var real_buffer: [64]u8 = undefined;
    var real_writer = real_file.writer(io, &real_buffer);
    const real = &real_writer.interface;

    // Flush completed CNF clauses, close the temp file, and write the header

    try cnf.flush();
    try cnf.header(real);
    temp_file.close(io);
    temp_closed = true;

    // Open the temp file for reading and stream it into the output file

    const read_file = try cwd.openFile(io, temp_path, .{});
    defer read_file.close(io);
    var read_buffer: [64]u8 = undefined;
    var temp_reader = temp_file.reader(io, &read_buffer);
    const reader = &temp_reader.interface;
    _ = try reader.streamRemaining(real);

    // Flush output sent to the real file and delete the temporary file

    try real.flush();
    try cwd.deleteFile(io, temp_path);
}

fn decodeMain(
    io: Io,
    gpa: Allocator,
    opt: *const Options,
    path: []const u8,
) !void {
    var failing: Io.Writer = .failing;
    var cnf: Cnf = .init(&failing);
    defer cnf.deinit();

    const vars: Variables = .init(opt, &cnf);
    const area = opt.area();

    var stdin_buffer: [64]u8 = undefined;
    const cwd = std.Io.Dir.cwd();

    const stdin_file = switch (std.mem.eql(u8, path, "-")) {
        false => try cwd.openFile(io, path, .{}),
        true => std.Io.File.stdin(),
    };

    defer stdin_file.close(io);
    var stdin_file_reader = stdin_file.reader(io, &stdin_buffer);
    const stdin = &stdin_file_reader.interface;

    var stdout_buffer: [64]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_file_writer = stdout_file.writer(io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var allocating: Io.Writer.Allocating = .init(gpa);
    defer allocating.deinit();
    const line_store = &allocating.writer;

    const is_dust: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_dust);
    const is_block: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_block);
    const is_n_connect: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_n_connect);
    const is_e_connect: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_e_connect);
    const is_s_connect: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_s_connect);
    const is_w_connect: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_w_connect);
    const is_n_torch: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_n_torch);
    const is_e_torch: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_e_torch);
    const is_s_torch: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_s_torch);
    const is_w_torch: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_w_torch);

    const is_input: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_input);
    const is_output: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_output);

    const is_dust_on: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_dust_on);
    const is_torch_on: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_torch_on);

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
                .{ is_dust, vars.dust },
                .{ is_block, vars.block },
                .{ is_n_connect, vars.facing_connect[0] },
                .{ is_e_connect, vars.facing_connect[1] },
                .{ is_s_connect, vars.facing_connect[2] },
                .{ is_w_connect, vars.facing_connect[3] },
                .{ is_n_torch, vars.facing_torch[0] },
                .{ is_e_torch, vars.facing_torch[1] },
                .{ is_s_torch, vars.facing_torch[2] },
                .{ is_w_torch, vars.facing_torch[3] },
                .{ is_input, vars.input },
                .{ is_output, vars.output },
            }) |list| {
                for (0..area) |pos| {
                    if (decoded == list[1].at(pos)) {
                        list[0][pos] = value;
                        continue :outer;
                    }
                }
            }

            for (0..area) |pos| {
                if (decoded == vars.strengthAt(opt, 0, pos).at(0)) {
                    is_dust_on[pos] = value;
                    continue :outer;
                }
            }

            for (0..area) |pos| {
                if (decoded == vars.torchOnAt(opt, 0, pos)) {
                    is_torch_on[pos] = value;
                    continue :outer;
                }
            }
        }
    }

    for (0..opt.length) |z| {
        for (0..3) |sub_row| {
            for (0..opt.width) |x| {
                const pos = x + z * opt.width;
                var display: [3][]const u8 = unknown_display;

                if (is_block[pos] == 1) {
                    display = block_display;
                    try stdout.writeAll(Color.code(.block));
                }

                inline for (&.{
                    .{ is_n_torch, n_torch_display },
                    .{ is_e_torch, e_torch_display },
                    .{ is_s_torch, s_torch_display },
                    .{ is_w_torch, w_torch_display },
                }) |list| if (list[0][pos] == 1) {
                    display = list[1];

                    if (is_torch_on[pos] == 1) {
                        try stdout.writeAll(Color.code(.powered_torch));
                    } else {
                        try stdout.writeAll(Color.code(.unpowered_torch));
                    }

                    break;
                };

                if (is_dust[pos] == 1) {
                    display = dustDisplay(
                        is_n_connect[pos],
                        is_e_connect[pos],
                        is_s_connect[pos],
                        is_w_connect[pos],
                    );

                    if (is_dust_on[pos] == 1) {
                        try stdout.writeAll(Color.code(.powered_dust));
                    } else {
                        try stdout.writeAll(Color.code(.unpowered_dust));
                    }
                }

                if (is_input[pos] == 1)
                    try stdout.writeAll(Color.code(.input));
                if (is_output[pos] == 1)
                    try stdout.writeAll(Color.code(.output));

                try stdout.writeAll(display[sub_row]);
                try stdout.writeAll(Color.reset);
            }
            try stdout.writeByte('\n');
        }
    }

    try stdout.flush();
}

const Color = enum {
    unpowered_dust, // dark red
    powered_dust, // light red
    unpowered_torch, // light brown
    powered_torch, // bright yellow
    output, // neon green
    input, // light blue
    block, // gray

    const reset: []const u8 = "\x1B[0m";
    fn code(self: @This()) []const u8 {
        return switch (self) {
            .unpowered_dust => "\x1B[38;5;52m",
            .powered_dust => "\x1B[38;5;196m",
            .unpowered_torch => "\x1B[38;5;94m",
            .powered_torch => "\x1B[38;5;226m",
            .output => "\x1B[38;5;46m",
            .input => "\x1B[38;5;51m",
            .block => "\x1B[38;5;240m",
        };
    }
};

fn dustDisplay(n: u4, e: u4, s: u4, w: u4) [3][]const u8 {
    return switch ((n << 3) | (e << 2) | (s << 1) | w) {
        0b0000 => .{ "      ", "  𜶉𜶉  ", "      " },
        0b0001 => .{ "      ", "𜶉𜶉𜶉𜶉  ", "      " },
        0b0010 => .{ "      ", "  𜶉𜶉  ", "  𜶉𜶉  " },
        0b0011 => .{ "      ", "𜶉𜶉𜶉𜶉  ", "  𜶉𜶉  " },
        0b0100 => .{ "      ", "  𜶉𜶉𜶉𜶉", "      " },
        0b0101 => .{ "      ", "𜶉𜶉𜶉𜶉𜶉𜶉", "      " },
        0b0110 => .{ "      ", "  𜶉𜶉𜶉𜶉", "  𜶉𜶉  " },
        0b0111 => .{ "      ", "𜶉𜶉𜶉𜶉𜶉𜶉", "  𜶉𜶉  " },
        0b1000 => .{ "  𜶉𜶉  ", "  𜶉𜶉  ", "      " },
        0b1001 => .{ "  𜶉𜶉  ", "𜶉𜶉𜶉𜶉  ", "      " },
        0b1010 => .{ "  𜶉𜶉  ", "  𜶉𜶉  ", "  𜶉𜶉  " },
        0b1011 => .{ "  𜶉𜶉  ", "𜶉𜶉𜶉𜶉  ", "  𜶉𜶉  " },
        0b1100 => .{ "  𜶉𜶉  ", "  𜶉𜶉𜶉𜶉", "      " },
        0b1101 => .{ "  𜶉𜶉  ", "𜶉𜶉𜶉𜶉𜶉𜶉", "      " },
        0b1110 => .{ "  𜶉𜶉  ", "  𜶉𜶉𜶉𜶉", "  𜶉𜶉  " },
        0b1111 => .{ "  𜶉𜶉  ", "𜶉𜶉𜶉𜶉𜶉𜶉", "  𜶉𜶉  " },
    };
}

const block_display = .{ "██████", "██🬤🬗██", "██████" };
const n_torch_display = .{ "      ", "  𜷂𜷖  ", "  ▐▌  " };
const e_torch_display = .{ "      ", "𜴳𜴳𜷂𜷖  ", "      " };
const s_torch_display = .{ "  ▐▌  ", "  𜷂𜷖  ", "      " };
const w_torch_display = .{ "      ", "  𜷂𜷖𜴳𜴳", "      " };
const unknown_display = .{ "? ? ? ", " ? ? ?", "? ? ? " };

/// Return a flat index representing an offset position, given an original
/// position, cardinal direction, and options - for the width of the circuit
fn cardinal(opt: *const Options, pos: u64, dir: u64) ?u64 {
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
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // Inputs are not to be placed where they aren't allowed
        if (opt.input_mask) |mask| if (mask[pos] != 1)
            try cnf.bitfalse(vars.input.at(pos));
        // Outputs are not to be placed where they aren't allowed
        if (opt.output_mask) |mask| if (mask[pos] != 1)
            try cnf.bitfalse(vars.output.at(pos));
        // Torches are not to be placed where they aren't allowed
        if (opt.torch_mask) |mask| if (mask[pos] != 1)
            try cnf.bitfalse(vars.torch.at(pos));
        // Blocks are not to be placed where they aren't allowed
        if (opt.block_mask) |mask| if (mask[pos] != 1)
            try cnf.bitfalse(vars.block.at(pos));
        // Dusts are not to be placed where they aren't allowed
        if (opt.dust_mask) |mask| if (mask[pos] != 1)
            try cnf.bitfalse(vars.dust.at(pos));
    }
}

// Prohibits air, dust, torch, and blocks from overlapping
fn blockSingularity(
    cnf: *Cnf,
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
        try cnf.clause(&.{ d, t, b }, &.{ 1, 1, 1 });

        // No two can be true at the same time
        try cnf.clause(&.{ d, t }, &.{ 0, 0 });
        try cnf.clause(&.{ t, b }, &.{ 0, 0 });
        try cnf.clause(&.{ b, d }, &.{ 0, 0 });
    }
}

// Prohibits torch variants from overlapping
fn torchDistinctness(
    cnf: *Cnf,
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
        try cnf.bitimp(n, t);
        try cnf.bitimp(e, t);
        try cnf.bitimp(s, t);
        try cnf.bitimp(w, t);

        // t implies n, e, s, OR w
        try cnf.clause(
            &.{ t, n, e, s, w },
            &.{ 0, 1, 1, 1, 1 },
        );

        // no two directions can coexist
        try cnf.clause(&.{ n, e }, &.{ 0, 0 });
        try cnf.clause(&.{ n, s }, &.{ 0, 0 });
        try cnf.clause(&.{ n, w }, &.{ 0, 0 });
        try cnf.clause(&.{ e, s }, &.{ 0, 0 });
        try cnf.clause(&.{ e, w }, &.{ 0, 0 });
        try cnf.clause(&.{ s, w }, &.{ 0, 0 });
    }
}

// Torches must have a block that will hold them up - this means that north
// facing torches have a block to the south, east facing torches have a block
// to the west, south facing torches have a block to the north, et cetera.
fn torchBlockSupports(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        for (0..4) |dir| {
            const torch = vars.facingTorchAt(dir, pos);
            if (cardinal(opt, pos, (dir + 2) % 4)) |card| {
                const block = vars.block.at(card);
                try cnf.bitimp(torch, block);
            } else {
                try cnf.bitfalse(torch);
            }
        }
    }
}

// make torches require cardinal dust
// OR act as an output
fn torchDustConnection(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // EITHER: there is no torch at this coordinate
        try cnf.part(vars.torch.at(pos), 0);

        // OR: the torch is set to be an output
        if (opt.allow_torch_output)
            try cnf.part(vars.output.at(pos), 1);

        // OR: There is a dust offset from the torch
        for (0..4) |dir|
            if (cardinal(opt, pos, dir)) |card|
                try cnf.part(vars.dust.at(card), 1);

        // Torches imply one connected dust to it's sides,
        // or it could be the case that it is an output.
        try cnf.end();
    }
}

// restrict the number of inputs
fn inputCardinality(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    switch (opt.input_count) {
        0 => assert(false), // checked in Options.init()
        1 => {
            // Exactly of the blocks is an input
            try cnf.cardinalityOne(vars.input, null);
        },
        else => {
            // Count the number bits and constrain to the input_count
            const cardinality = try cnf.unaryTotalize(vars.input);
            try cnf.unaryConstrainEQVal(cardinality, opt.input_count);
        },
    }
}

// restrict the number of outputs
fn outputCardinality(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    switch (opt.output_count) {
        0 => assert(false), // checked in Options.init()
        1 => {
            // Exactly of the blocks is an output
            try cnf.cardinalityOne(vars.output, null);
        },
        else => {
            // Count the number bits and constrain to the output_count
            const cardinality = try cnf.unaryTotalize(vars.output);
            try cnf.unaryConstrainEQVal(cardinality, opt.output_count);
        },
    }
}

// restrict the number of dusts
fn dustCardinality(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    // We don't need to handle unknown maximum
    const count = opt.max_dust orelse return;

    switch (count) {
        0 => {
            // Zero dust means that all are not dust
            for (0..opt.area()) |pos|
                try cnf.bitfalse(vars.dust.at(pos));
        },
        1 => {
            // At least one of the blocks is a dust
            for (0..opt.area()) |pos|
                try cnf.part(vars.dust.at(pos), 1);
            try cnf.end();

            // At most one of the blocks is a dust
            for (0..opt.area()) |lhs| {
                for (0..lhs) |rhs| {
                    const a = vars.dust.at(lhs);
                    const b = vars.dust.at(rhs);
                    try cnf.clause(&.{ a, b }, &.{ 0, 0 });
                }
            }
        },
        else => {
            // Count the number bits and constrain to the count
            const cardinality = try cnf.unaryTotalize(vars.dust);
            try cnf.unaryConstrainLEVal(cardinality, count);
        },
    }
}

// restrict the number of torches
fn torchCardinality(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    // We don't need to handle unknown maximum
    const count = opt.max_torch orelse return;

    switch (count) {
        0 => {
            // Zero torch means that all are not torch
            for (0..opt.area()) |pos|
                try cnf.bitfalse(vars.torch.at(pos));
        },
        1 => {
            // At least one of the blocks is a torch
            for (0..opt.area()) |pos|
                try cnf.part(vars.torch.at(pos), 1);
            try cnf.end();

            // At most one of the blocks is a torch
            for (0..opt.area()) |lhs| {
                for (0..lhs) |rhs| {
                    const a = vars.torch.at(lhs);
                    const b = vars.torch.at(rhs);
                    try cnf.clause(&.{ a, b }, &.{ 0, 0 });
                }
            }
        },
        else => {
            // Count the number bits and constrain to the count
            const cardinality = try cnf.unaryTotalize(vars.torch);
            try cnf.unaryConstrainLEVal(cardinality, count);
        },
    }
}

// constrain cardinal dust redirection sources
fn dustRedirectionSources(
    cnf: *Cnf,
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
                try cnf.bitor(t_off, d_off, redirect);
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
                    0b00 => try cnf.bitfalse(redirect),
                    // The dust redirects if it is an output
                    0b01 => try cnf.biteql(out, redirect),
                    // The dust redirects if it is an input
                    0b10 => try cnf.biteql(inp, redirect),
                    // The dust redirects if input or output
                    0b11 => try cnf.bitor(inp, out, redirect),
                }
            }
        }
    }
}

// constrain connections of dust blocks
fn dustConnection(
    cnf: *Cnf,
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

        try cnf.clause(&.{ d, n_c }, &.{ 1, 0 });
        try cnf.clause(&.{ d, e_c }, &.{ 1, 0 });
        try cnf.clause(&.{ d, s_c }, &.{ 1, 0 });
        try cnf.clause(&.{ d, w_c }, &.{ 1, 0 });

        // (d AND n) -> n_c
        // (d AND e) -> e_c
        // (d AND s) -> s_c
        // (d AND w) -> w_c

        try cnf.clause(&.{ d, n_r, n_c }, &.{ 0, 0, 1 });
        try cnf.clause(&.{ d, e_r, e_c }, &.{ 0, 0, 1 });
        try cnf.clause(&.{ d, s_r, s_c }, &.{ 0, 0, 1 });
        try cnf.clause(&.{ d, w_r, w_c }, &.{ 0, 0, 1 });

        // (e AND NOT n) -> (NOT n_c)
        // (n AND NOT e) -> (NOT e_c)
        // (w AND NOT s) -> (NOT s_c)
        // (s AND NOT w) -> (NOT w_c)

        try cnf.clause(&.{ e_r, n_r, n_c }, &.{ 0, 1, 0 });
        try cnf.clause(&.{ n_r, e_r, e_c }, &.{ 0, 1, 0 });
        try cnf.clause(&.{ w_r, s_r, s_c }, &.{ 0, 1, 0 });
        try cnf.clause(&.{ s_r, w_r, w_c }, &.{ 0, 1, 0 });

        // (w AND NOT n AND NOT e) -> (NOT n_c)
        // (s AND NOT n AND NOT e) -> (NOT e_c)
        // (e AND NOT s AND NOT w) -> (NOT s_c)
        // (n AND NOT s AND NOT w) -> (NOT w_c)

        try cnf.clause(&.{ w_r, n_r, e_r, n_c }, &.{ 0, 1, 1, 0 });
        try cnf.clause(&.{ s_r, n_r, e_r, e_c }, &.{ 0, 1, 1, 0 });
        try cnf.clause(&.{ e_r, s_r, w_r, s_c }, &.{ 0, 1, 1, 0 });
        try cnf.clause(&.{ n_r, s_r, w_r, w_c }, &.{ 0, 1, 1, 0 });

        // (d AND NOT n AND NOT e AND NOT w) -> n_c
        // (d AND NOT n AND NOT e AND NOT s) -> e_c
        // (d AND NOT e AND NOT s AND NOT w) -> s_c
        // (d AND NOT n AND NOT s AND NOT w) -> w_c

        try cnf.clause(&.{ d, n_r, e_r, w_r, n_c }, &.{ 0, 1, 1, 1, 1 });
        try cnf.clause(&.{ d, n_r, e_r, s_r, e_c }, &.{ 0, 1, 1, 1, 1 });
        try cnf.clause(&.{ d, e_r, s_r, w_r, s_c }, &.{ 0, 1, 1, 1, 1 });
        try cnf.clause(&.{ d, n_r, s_r, w_r, w_c }, &.{ 0, 1, 1, 1, 1 });
    }
}

// constrain matching positions of input/output and input_map/output_map
fn inputOutputMapPositionMatch(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // ------------------------------------------------ FORWARD IMPLICATION

        // No input mappings can exist without an input
        for (0..opt.input_count) |inp| {
            const inp_map = vars.inputMapAt(opt, inp, pos);
            try cnf.bitimp(inp_map, vars.input.at(pos));
        }

        // No output mappings can exist without an output
        for (0..opt.output_count) |out| {
            const out_map = vars.outputMapAt(opt, out, pos);
            try cnf.bitimp(out_map, vars.output.at(pos));
        }

        // ----------------------------------------------- BACKWARD IMPLICATION

        // EITHER: there is no input here
        try cnf.part(vars.input.at(pos), 0);
        // OR: there is a mapping here
        for (0..opt.input_count) |inp|
            try cnf.part(vars.inputMapAt(opt, inp, pos), 1);
        // No inputs can exist without a mapping
        try cnf.end();

        // EITHER: there is no output here
        try cnf.part(vars.output.at(pos), 0);
        // OR: there is a mapping here
        for (0..opt.output_count) |out|
            try cnf.part(vars.outputMapAt(opt, out, pos), 1);
        // No outputs can exist without a mapping
        try cnf.end();
    }
}

// constrain correct input block type
fn inputBlockType(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // Either this is not an input
        try cnf.part(vars.input.at(pos), 0);

        // Or this is a block
        if (opt.allow_block_input)
            try cnf.part(vars.block.at(pos), 1);

        // Or this is a dust
        if (opt.allow_dust_input)
            try cnf.part(vars.dust.at(pos), 1);

        try cnf.end();
    }
}

// constrain correct output block type
fn outputBlockType(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // Either this is not an output
        try cnf.part(vars.output.at(pos), 0);

        // Or this is a dust
        if (opt.allow_dust_output)
            try cnf.part(vars.dust.at(pos), 1);

        // Or this is a torch
        if (opt.allow_torch_output)
            try cnf.part(vars.torch.at(pos), 1);

        try cnf.end();
    }
}

// constrain cardinality of input_map
fn inputMapCardinality(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.input_count) |inp| {

        // At least one position is mapped for each input
        for (0..opt.area()) |pos|
            try cnf.part(vars.inputMapAt(opt, inp, pos), 1);
        try cnf.end();

        // At most one position is mapped for each input
        for (0..opt.area()) |rhs| {
            for (0..rhs) |lhs| {
                const a = vars.inputMapAt(opt, inp, lhs);
                const b = vars.inputMapAt(opt, inp, rhs);
                try cnf.clause(&.{ a, b }, &.{ 0, 0 });
            }
        }
    }
}

// constrain cardinality of output_map
fn outputMapCardinality(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.output_count) |out| {
        // At least one position is mapped for each output
        for (0..opt.area()) |pos|
            try cnf.part(vars.outputMapAt(opt, out, pos), 1);
        try cnf.end();

        // At most one position is mapped for each output
        for (0..opt.area()) |rhs| {
            for (0..rhs) |lhs| {
                const a = vars.outputMapAt(opt, out, lhs);
                const b = vars.outputMapAt(opt, out, rhs);
                try cnf.clause(&.{ a, b }, &.{ 0, 0 });
            }
        }
    }
}

// prevent overlapping inputs
fn inputOverlap(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.input_count) |lhs_idx| {
        for (0..lhs_idx) |rhs_idx| {
            for (0..opt.area()) |pos| {
                const lhs = vars.inputMapAt(opt, lhs_idx, pos);
                const rhs = vars.inputMapAt(opt, rhs_idx, pos);
                try cnf.clause(&.{ lhs, rhs }, &.{ 0, 0 });
            }
        }
    }
}

// prevent overlapping outputs
fn outputOverlap(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.output_count) |lhs_idx| {
        for (0..lhs_idx) |rhs_idx| {
            for (0..opt.area()) |pos| {
                const lhs = vars.outputMapAt(opt, lhs_idx, pos);
                const rhs = vars.outputMapAt(opt, rhs_idx, pos);
                try cnf.clause(&.{ lhs, rhs }, &.{ 0, 0 });
            }
        }
    }
}

// determine if a block is currently powered
fn blockPowered(
    cnf: *Cnf,
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
                try cnf.clause(&.{ b, c, s, p }, &.{ 0, 0, 0, 1 });
            };

            // If the current cell is a block and it was overridden to be
            // powered on (an input force it to be on), then it must be on.

            try cnf.clause(&.{ b, o, p }, &.{ 0, 0, 1 });

            // -------------------- BACKWARD IMPLICATION - block is powered off

            // If not a block, this can't be powered as a block
            try cnf.clause(&.{ b, p }, &.{ 1, 0 });

            // EITHER: the block is unpowered
            try cnf.part(p, 0);

            // OR: the block is overridden to be powered
            try cnf.part(o, 1);

            // OR: an adjacent dust is connected and powered
            for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                const rev = (dir + 2) % 4;
                try cnf.part(vars.connectedOnAt(opt, rev, state, card), 1);
            };

            try cnf.end();
        }
    }
}

// determine if a torch is currently powered
fn torchPowered(
    cnf: *Cnf,
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
                try cnf.clause(&.{ p, f_t, t_p }, &.{ 1, 0, 1 });

                // -------------------------------------- BACKWARDS IMPLICATION
                // EITHER: block unpowered, torch unpowered, or the right torch
                try cnf.clause(&.{ p, f_t, t_p }, &.{ 0, 0, 0 });
            };

            // If a torch is powered, it implies it is a torch
            const p = vars.torchOnAt(opt, state, pos);
            const t = vars.torch.at(pos);
            try cnf.clause(&.{ p, t }, &.{ 0, 1 });
        }
    }
}

// Given the current state and index of the input, return the input value
fn inputValue(state: u64, inp: u64) u1 {
    return @truncate(state >> @intCast(inp));
}

// Given the current state and index of the output, return the defined output
fn outputValue(opt: *const Options, state: u64, out: u64) ?u1 {
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
    cnf: *Cnf,
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
                    try cnf.bitimp(vars.inputMapAt(opt, inp, pos), o);

            // ----------------- BACKWARD IMPLICATION - not overridden to be on

            // The override is false if and only if every single input which is
            // true does not reside at the current cell. This is the same as
            // encoding a single CNF clause where either the override is FALSE,
            // or each input (if it is true in this state) is at this position.

            try cnf.part(o, 0);

            for (0..opt.input_count) |inp|
                if (inputValue(state, inp) == 1)
                    try cnf.part(vars.inputMapAt(opt, inp, pos), 1);

            try cnf.end();
        }
    }
}

// constrain constrain_off based on input_map & output_map & state
fn inputOutputConstrainOff(
    cnf: *Cnf,
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
                        try cnf.bitimp(vars.inputMapAt(opt, inp, pos), c);

            // For every single output, if the state of that output is supposed
            // to be FALSE, then if it is *that* output implies the constraint.

            for (0..opt.output_count) |out|
                if (outputValue(opt, state, out) == 0)
                    try cnf.bitimp(vars.outputMapAt(opt, out, pos), c);

            // --------------- BACKWARD IMPLICATION - not constrained to be off

            // EITHER: the cell is not constrained to be off
            try cnf.part(c, 0);

            // OR: there is an input and it is powered off
            if (opt.input_isolation)
                for (0..opt.input_count) |inp|
                    if (inputValue(state, inp) == 0)
                        try cnf.part(vars.inputMapAt(opt, inp, pos), 1);

            // OR: there is an output and it is powered off
            for (0..opt.output_count) |out|
                if (outputValue(opt, state, out) == 0)
                    try cnf.part(vars.outputMapAt(opt, out, pos), 1);

            try cnf.end();
        }
    }
}

// constrain constrain_on based on output_map & state
fn outputConstrainOn(
    cnf: *Cnf,
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
                    try cnf.bitimp(vars.outputMapAt(opt, out, pos), c);

            // ---------------- BACKWARD IMPLICATION - not constrained to be on

            // EITHER: the cell is not constrained to be on
            try cnf.part(c, 0);

            // OR: there is an output and it is powered on
            for (0..opt.output_count) |out|
                if (outputValue(opt, state, out) == 1)
                    try cnf.part(vars.outputMapAt(opt, out, pos), 1);

            try cnf.end();
        }
    }
}

// constrain all bitblasted numbers to be unary
fn unaryStrengthsAndSegments(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        try cnf.unaryConstrain(vars.segmentAt(opt, pos));
        for (0..opt.states()) |state| {
            try cnf.unaryConstrain(vars.strengthAt(opt, state, pos));
        }
    }
}

// constrain torches and blocks to be on with constrain_on
fn torchAndBlockOutput(
    cnf: *Cnf,
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
                try cnf.clause(&.{ constrain_on, t, t_on }, &.{ 0, 0, 1 });
                // (constrain_off AND torch) implies NOT torch_on
                try cnf.clause(&.{ constrain_off, t, t_on }, &.{ 0, 0, 0 });
            }
        }
    }
}

// determine if dust is cardinally connected AND on
fn connectedPoweredDust(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            for (0..4) |dir| {
                const c = vars.facingConnectAt(dir, pos);
                const p = vars.strengthAt(opt, state, pos).at(0);
                const c_p = vars.connectedOnAt(opt, dir, state, pos);
                try cnf.bitand(c, p, c_p);
            }
        }
    }
}

// constrain signal strength and power of dust
fn dustPowerStrengthPropagation(
    cnf: *Cnf,
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
            const maxxed = strength.at(opt.max_signal_strength - 1);
            // Whether the current block (at pos, for state) is powered
            const powered = strength.at(0);

            // -------------------------------------------- FORWARD IMPLICATION

            // Dust is fully powered by adjacent powered torches
            for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                const torch_on = vars.torchOnAt(opt, state, card);
                try cnf.clause(&.{ torch_on, dust, maxxed }, &.{ 0, 0, 1 });
            };

            // Dust is fully powered if overridden to be on (it is an input)
            const override_on = vars.overrideOnAt(opt, state, pos);
            try cnf.clause(&.{ override_on, dust, maxxed }, &.{ 0, 0, 1 });

            // Dust is powered if constrained to be on (it is an output)
            const constrain_on = vars.constrainOnAt(opt, state, pos);
            try cnf.clause(&.{ constrain_on, dust, powered }, &.{ 0, 0, 1 });

            // Dust strength is at least max(neighbors_strength) -| 1
            for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                const source = vars.strengthAt(opt, state, card);
                for (0..opt.max_signal_strength - 1) |bit| {
                    const src = source.at(bit + 1);
                    const dst = strength.at(bit);
                    try cnf.clause(&.{ dust, src, dst }, &.{ 0, 0, 1 });
                }
            };

            // ------------------------------------------- BACKWARD IMPLICATION

            // Any dust power level implies that this is dust
            try cnf.clause(&.{ powered, dust }, &.{ 0, 1 });

            // Dust is not powered if constrained to be off (input or output)
            const constrain_off = vars.constrainOffAt(opt, state, pos);
            try cnf.clause(&.{ constrain_off, powered }, &.{ 0, 0 });

            for (0..opt.max_signal_strength) |bit| {
                // EITHER: We are not at maximum signal strength
                try cnf.part(strength.at(bit), 0);

                // OR: The dust has been overridden to be maxxed
                try cnf.part(override_on, 1);

                // OR: An adjacent torch is currently powered on
                for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                    try cnf.part(vars.torchOnAt(opt, state, card), 1);
                };

                // OR: a cardinal strength bit at "bit + 1" is TRUE
                for (0..4) |dir| if (cardinal(opt, pos, dir)) |card| {
                    const source = vars.strengthAt(opt, state, card);
                    if (bit < opt.max_signal_strength - 1)
                        try cnf.part(source.at(bit + 1), 1);
                };

                try cnf.end();
            }
        }
    }
}

// constrain segment values to ensure acyclic graph

fn segmentTransitivity(
    cnf: *Cnf,
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
                try cnf.clause(&.{ p_dust, c_dust, b, a }, &.{ 0, 0, 0, 1 });
                // (dust HERE & dust THERE & bit HERE) -------------> bit THERE
                try cnf.clause(&.{ p_dust, c_dust, a, b }, &.{ 0, 0, 0, 1 });
            }

            // ------ Torches have less ID than the block they are connected to

            for (0..opt.transition_bits - 1) |bit| {
                // The current unary bit at <bit + 1> for segment
                const a = vars.segmentAt(opt, pos).at(bit + 1);
                // The cardinal unary bit at <bit> for segment
                const b = vars.segmentAt(opt, card).at(bit);
                // (torch THERE & lower bit THERE) -----------> higher bit HERE
                try cnf.clause(&.{ c_torch, b, a }, &.{ 0, 0, 1 });
            }
            // facing torch THERE -----------------------> first unary bit HERE
            try cnf.clause(&.{ c_torch, p_first }, &.{ 0, 1 });
            // facing torch THERE --------------------> NO last unary bit THERE
            try cnf.clause(&.{ c_torch, c_last }, &.{ 0, 0 });

            // -------- Blocks have less ID than the dust they are connected to

            for (0..opt.transition_bits - 1) |bit| {
                // The current unary bit at <bit + 1> for segment
                const a = vars.segmentAt(opt, pos).at(bit + 1);
                // The cardinal unary bit at <bit> for segment
                const b = vars.segmentAt(opt, card).at(bit);
                // (connected HERE & block THERE & bit THERE) -> lower bit HERE
                try cnf.clause(&.{ p_con, c_block, b, a }, &.{ 0, 0, 0, 1 });
            }
            // (connected HERE & block THERE) -----------> first unary bit HERE
            try cnf.clause(&.{ p_con, c_block, p_first }, &.{ 0, 0, 1 });
            // (connected HERE & block THERE) --------> NO last unary bit THERE
            try cnf.clause(&.{ p_con, c_block, c_last }, &.{ 0, 0, 0 });

            // ---- Redstone dust has less ID than cardinally connected torches

            for (0..opt.transition_bits - 1) |bit| {
                // The current unary bit at <bit + 1> for segment
                const a = vars.segmentAt(opt, pos).at(bit + 1);
                // The cardinal unary bit at <bit> for segment
                const b = vars.segmentAt(opt, card).at(bit);
                // (torch HERE & dust THERE & bit THERE) ------> lower bit HERE
                try cnf.clause(&.{ p_torch, c_dust, b, a }, &.{ 0, 0, 0, 1 });
            }
            // (torch HERE & dust THERE) ----------------> first unary bit HERE
            try cnf.clause(&.{ p_torch, c_dust, p_first }, &.{ 0, 0, 1 });
            // (torch HERE & dust THERE) -------------> NO last unary bit THERE
            try cnf.clause(&.{ p_torch, c_dust, c_last }, &.{ 0, 0, 0 });
        };
    }
}
