const std = @import("std");
const Allocator = std.mem.Allocator;
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
    const config_file = try cwd.openFile(io, config_path, .{});
    defer config_file.close(io);
    var config_buf: [64]u8 = undefined;
    var config_file_reader = config_file.reader(io, &config_buf);
    const config_reader = &config_file_reader.interface;
    var config_allocating: Io.Writer.Allocating = .init(gpa);
    defer config_allocating.deinit();
    const config_writer = &config_allocating.writer;
    _ = try config_reader.streamRemaining(config_writer);
    const config_text = try config_allocating.toOwnedSliceSentinel(0);
    const config: Options = try .init(gpa, @ptrCast(config_text));
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

    // maximum number of redstone dusts
    max_dust: ?u64,
    // maximum number of redstone torches
    max_torch: ?u64,

    // maximum number of north facing torches
    max_n_torch: ?u64,
    // maximum number of east facing torches
    max_e_torch: ?u64,
    // maximum number of south facing torches
    max_s_torch: ?u64,
    // maximum number of west facing torches
    max_w_torch: ?u64,

    // whether to allow a weakly powered block as an output
    allow_block_output: bool,
    // whether to allow a torch as an output
    allow_torch_output: bool,
    // whether to allow a dust as an output
    allow_dust_output: bool,
    // whether to redirect input dust on the edges
    redirect_input_edge_dust: bool,
    // whether to redirect output dust on the edges
    redirect_output_edge_dust: bool,

    // whether to allow a weakly powered block as an input
    allow_weak_powered_block_input: bool,
    // whether to allow dust (max signal strength) as an input
    allow_max_signal_dust_input: bool,

    // enforce acyclic graph with a unary counter
    transition_bits: u64,
    // redstone dust max signal strength
    max_signal_strength: ?u64,

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

        for (self.truth) |output| {
            for (output) |row| {
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
    // [position: opt.area()]
    air: Bits, // position is air
    dust: Bits, // position is dust
    torch: Bits, // position is torch
    block: Bits, // position is block
    n_redirect: Bits, // redirection source to the north
    e_redirect: Bits, // redirection source to the east
    s_redirect: Bits, // redirection source to the south
    w_redirect: Bits, // redirection source to the west
    n_connect: Bits, // dust connected to the north
    e_connect: Bits, // dust connected to the east
    s_connect: Bits, // dust connected to the south
    w_connect: Bits, // dust connected to the west
    n_torch: Bits, // position is north facing torch
    e_torch: Bits, // position is east facing torch
    s_torch: Bits, // position is south facing torch
    w_torch: Bits, // position is west facing torch
    input: Bits, // position is input
    output: Bits, // position is output

    // [input: opt.input_count]
    // * [position: opt.area()]
    input_map: Bits, // selector for specific inputs

    // [input: opt.output_count]
    // * [position: opt.area()]
    output_map: Bits, // selector for specific outputs

    // [position: opt.area()]
    // * [index: opt.transition_bits]
    segment: Bits, // transitively enforce acyclicity

    // [state: opt.states()]
    // * [position: opt.area()]
    torch_on: Bits, // torch is powered
    block_on: Bits, // block is powered
    dust_on: Bits, // dust is powered
    override_on: Bits, // *override* something to be on
    constrain_on: Bits, // *constrain* something to be on
    constrain_off: Bits, // *constrain* something to be off

    // [state: opt.states()]
    // * [position: opt.area()]
    // * [index: opt.max_signal_strength orelse 0]
    strength: Bits,

    fn init(opt: *const Options, cnf: *Cnf) @This() {
        const area = opt.area();
        const states = opt.states();
        const seg_bits = opt.transition_bits;
        const power_bits = opt.max_signal_strength orelse 0;

        return .{
            .air = cnf.alloc(area),
            .dust = cnf.alloc(area),
            .torch = cnf.alloc(area),
            .block = cnf.alloc(area),
            .n_redirect = cnf.alloc(area),
            .e_redirect = cnf.alloc(area),
            .s_redirect = cnf.alloc(area),
            .w_redirect = cnf.alloc(area),
            .n_connect = cnf.alloc(area),
            .e_connect = cnf.alloc(area),
            .s_connect = cnf.alloc(area),
            .w_connect = cnf.alloc(area),
            .n_torch = cnf.alloc(area),
            .e_torch = cnf.alloc(area),
            .s_torch = cnf.alloc(area),
            .w_torch = cnf.alloc(area),
            .input = cnf.alloc(area),
            .output = cnf.alloc(area),

            .input_map = cnf.alloc(opt.input_count * area),

            .output_map = cnf.alloc(opt.output_count * area),

            .segment = cnf.alloc(area * seg_bits),

            .torch_on = cnf.alloc(states * area),
            .block_on = cnf.alloc(states * area),
            .dust_on = cnf.alloc(states * area),
            .override_on = cnf.alloc(states * area),
            .constrain_on = cnf.alloc(states * area),
            .constrain_off = cnf.alloc(states * area),

            .strength = cnf.alloc(states * area * power_bits),
        };
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
        "inputOverlap",
        "blockPowered",
        "torchPowered",
        "outputOverlap",
        "dustConnection",
        "inputBlockType",
        "inputOverrideOn",
        "outputBlockType",
        "blockSingularity",
        "inputCardinality",
        "torchDistinctness",
        "outputCardinality",
        "outputConstrainOn",
        "torchBlockSupports",
        "torchDustConnection",
        "blockDustConnection",
        "inputMapCardinality",
        "blockTorchConnection",
        "outputMapCardinality",
        "dustRedirectionSources",
        "inputOutputConstrainOff",
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

    const is_air: []u1 = try gpa.alloc(u1, area);
    defer gpa.free(is_air);
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
                .{ is_air, vars.air },
                .{ is_dust, vars.dust },
                .{ is_block, vars.block },
                .{ is_n_connect, vars.n_connect },
                .{ is_e_connect, vars.e_connect },
                .{ is_s_connect, vars.s_connect },
                .{ is_w_connect, vars.w_connect },
                .{ is_n_torch, vars.n_torch },
                .{ is_e_torch, vars.e_torch },
                .{ is_s_torch, vars.s_torch },
                .{ is_w_torch, vars.w_torch },
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
        }
    }

    for (0..opt.length) |z| {
        for (0..3) |sub_row| {
            for (0..opt.width) |x| {
                const pos = x + z * opt.width;
                var row: Display = unknown_display;

                inline for (&.{
                    .{ is_air, air_display },
                    .{ is_block, block_display },
                    .{ is_n_torch, n_torch_display },
                    .{ is_e_torch, e_torch_display },
                    .{ is_s_torch, s_torch_display },
                    .{ is_w_torch, w_torch_display },
                }) |list| if (list[0][pos] == 1) {
                    row = list[1];
                    break;
                };

                if (is_dust[pos] == 1) {
                    const n = is_n_connect[pos];
                    const e = is_e_connect[pos];
                    const s = is_s_connect[pos];
                    const w = is_w_connect[pos];
                    row = dustDisplay(n, e, s, w);
                }

                if (is_input[pos] == 1) row[0] = .blue;
                if (is_output[pos] == 1) row[0] = .green;

                try writeDisplayRow(row, stdout, sub_row);
            }
            try stdout.writeByte('\n');
        }
    }

    try stdout.flush();
}

const Color = enum {
    red, // dust
    blue, // input
    green, // output
    yellow, // torch
    white, // block
    gray, // air

    const reset: []const u8 = "\x1B[0m";
    fn code(self: @This()) []const u8 {
        return switch (self) {
            .red => "\x1B[91m",
            .blue => "\x1B[94m",
            .green => "\x1B[92m",
            .yellow => "\x1B[93m",
            .white => "\x1B[37m",
            .gray => "\x1B[30m",
        };
    }
};

const Display = struct { Color, [3][]const u8 };
fn writeDisplayRow(self: Display, w: *Io.Writer, row: usize) !void {
    if (row >= 3) unreachable;
    try w.writeAll(self[0].code());
    try w.writeAll(self[1][row]);
    try w.writeAll(Color.reset);
}

fn dustDisplay(n: u4, e: u4, s: u4, w: u4) Display {
    const pos = (n << 3) | (e << 2) | (s << 1) | w;
    return .{ .red, switch (pos) {
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
    } };
}

const air_display: Display = .{ .gray, .{ "      ", "  🬗🬤  ", "      " } };
const block_display: Display = .{ .white, .{ "██████", "██  ██", "██████" } };
const n_torch_display: Display = .{ .yellow, .{ "      ", "  𜷂𜷖  ", "  ▐▌  " } };
const e_torch_display: Display = .{ .yellow, .{ "      ", "𜴳𜴳𜷂𜷖  ", "      " } };
const s_torch_display: Display = .{ .yellow, .{ "  ▐▌  ", "  𜷂𜷖  ", "      " } };
const w_torch_display: Display = .{ .yellow, .{ "      ", "  𜷂𜷖𜴳𜴳", "      " } };
const unknown_display: Display = .{ .gray, .{ "? ? ? ", " ? ? ?", "? ? ? " } };

// Cardinal directions for north, east, south, and west
const Dir = enum { n, e, s, w };

/// Given a cardinal direction, this function finds the opposite direction.
fn opposite(comptime dir: Dir) Dir {
    return switch (dir) {
        .n => .s,
        .e => .w,
        .s => .n,
        .w => .e,
    };
}

/// Return a flat index representing an offset position, given an original
/// position, cardinal direction, and options - for the width of the circuit
fn cardinal(opt: *const Options, pos: u64, comptime dir: Dir) ?u64 {
    const x = pos % opt.width;
    const z = pos / opt.width;

    return switch (dir) {
        // We must be after the first row if we are offset north
        .n => if (z > 0) pos - opt.width else null,
        // We must be before the last column if we are offset east
        .e => if (x < opt.width - 1) pos + 1 else null,
        // We must be before the last row if we are offset south
        .s => if (z < opt.length - 1) pos + opt.width else null,
        // we must be after the first column if we are offset west
        .w => if (x > 0) pos - 1 else null,
    };
}

/// Return a torch facing a certain cardinal direction, given the position of
/// the torch, the variables in the system, and a comptime-known direction
fn facingTorch(vars: *const Variables, pos: u64, comptime dir: Dir) u64 {
    return switch (dir) {
        .n => vars.n_torch.at(pos),
        .e => vars.e_torch.at(pos),
        .s => vars.s_torch.at(pos),
        .w => vars.w_torch.at(pos),
    };
}

/// Return a certain connection of a block of dust - that is, whether this dust
/// both exists, and is connected (powered by or can power) to that direction.
fn connectedDust(vars: *const Variables, pos: u64, comptime dir: Dir) u64 {
    return switch (dir) {
        .n => vars.n_connect.at(pos),
        .e => vars.e_connect.at(pos),
        .s => vars.s_connect.at(pos),
        .w => vars.w_connect.at(pos),
    };
}

/// Return whether a cardinal block will redirect dust in the current position.
/// This function takes the variables, position of the dust, and direction.
fn cardinalRedirect(vars: *const Variables, pos: u64, comptime dir: Dir) u64 {
    return switch (dir) {
        .n => vars.n_redirect.at(pos),
        .e => vars.e_redirect.at(pos),
        .s => vars.s_redirect.at(pos),
        .w => vars.w_redirect.at(pos),
    };
}

// Prohibits air, dust, torch, and blocks from overlapping
fn blockSingularity(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // Exactly one-of air, dust, torch, and block is true.
        // That means that at least one must be true, and no
        // pair of two of these can possibly be true.

        const a = vars.air.at(pos);
        const b = vars.dust.at(pos);
        const c = vars.torch.at(pos);
        const d = vars.block.at(pos);

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
fn torchDistinctness(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        const t = vars.torch.at(pos);
        const n = vars.n_torch.at(pos);
        const e = vars.e_torch.at(pos);
        const s = vars.s_torch.at(pos);
        const w = vars.w_torch.at(pos);

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
        inline for (.{ .n, .e, .w, .s }) |facing| {
            const backward = comptime opposite(facing);
            const torch = facingTorch(vars, pos, facing);
            if (cardinal(opt, pos, backward)) |north| {
                const block = vars.block.at(north);
                try cnf.bitimp(torch, block);
            } else {
                try cnf.bitfalse(torch);
            }
        }
    }
}

// make blocks require cardinal connected torch
// OR act as an output
fn blockTorchConnection(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // EITHER: there is no block at this coordinate
        try cnf.part(vars.block.at(pos), 0);

        // OR: the block is set to be an output
        if (opt.allow_block_output)
            try cnf.part(vars.output.at(pos), 1);

        // OR: there is a torch connected to the block
        inline for (.{ .n, .e, .s, .w }) |dir| {
            if (cardinal(opt, pos, dir)) |off| {
                try cnf.part(facingTorch(vars, off, dir), 1);
            }
        }

        // Blocks imply one connected torch to it's sides,
        // or it could be the case that it is an output.
        try cnf.end();
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
        inline for (.{ .n, .e, .s, .w }) |dir| {
            if (cardinal(opt, pos, dir)) |off| {
                try cnf.part(vars.dust.at(off), 1);
            }
        }

        // Torches imply one connected dust to it's sides,
        // or it could be the case that it is an output.
        try cnf.end();
    }
}

// make blocks require cardinal connected dust
// OR act as an input
fn blockDustConnection(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        // EITHER: there is no block at this coordinate
        try cnf.part(vars.block.at(pos), 0);

        // OR: the block is set to be an input
        if (opt.allow_weak_powered_block_input)
            try cnf.part(vars.input.at(pos), 1);

        // OR: there is a connected dust offset from the block
        inline for (.{ .n, .e, .s, .w }) |dir| {
            if (cardinal(opt, pos, opposite(dir))) |off| {
                try cnf.part(connectedDust(vars, off, dir), 1);
            }
        }

        // Blocks imply one connected dust to it's sides,
        // or it could be the case that it is an input.
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
        0 => unreachable, // checked in Options.init()
        1 => {
            // At least one of the blocks is an input
            for (0..opt.area()) |pos|
                try cnf.part(vars.input.at(pos), 1);
            try cnf.end();

            // At most one of the blocks is an input
            for (0..opt.area()) |lhs| {
                for (0..lhs) |rhs| {
                    const a = vars.input.at(lhs);
                    const b = vars.input.at(rhs);
                    try cnf.clause(&.{ a, b }, &.{ 0, 0 });
                }
            }
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
        0 => unreachable, // checked in Options.init()
        1 => {
            // At least one of the blocks is an output
            for (0..opt.area()) |pos|
                try cnf.part(vars.output.at(pos), 1);
            try cnf.end();

            // At most one of the blocks is an output
            for (0..opt.area()) |lhs| {
                for (0..lhs) |rhs| {
                    const a = vars.output.at(lhs);
                    const b = vars.output.at(rhs);
                    try cnf.clause(&.{ a, b }, &.{ 0, 0 });
                }
            }
        },
        else => {
            // Count the number bits and constrain to the output_count
            const cardinality = try cnf.unaryTotalize(vars.output);
            try cnf.unaryConstrainEQVal(cardinality, opt.output_count);
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
        inline for (.{ .n, .e, .s, .w }) |dir| {
            // The direction that we will be redirecting
            const redirect = cardinalRedirect(vars, pos, dir);

            if (cardinal(opt, pos, dir)) |off| {
                // The direction we are observing is in bounds, so it only will
                // matter if the block in this direction is a torch or dust.

                const t_off = vars.torch.at(off);
                const d_off = vars.dust.at(off);
                try cnf.bitor(t_off, d_off, redirect);
            } else {
                // The direction we are observing is out of bounds, so the dust
                // will only redirect if the dust is an input (and we allow
                // input dust to redirect), or if the dust is an output (and we
                // allow output dust to redirect).

                const output = vars.output.at(pos);
                const input = vars.input.at(pos);

                const r_inp = @intFromBool(opt.redirect_input_edge_dust);
                const r_out = @intFromBool(opt.redirect_output_edge_dust);

                switch ((@as(u2, r_inp) << 1) | r_out) {
                    // The edge dust can't ever redirect
                    0b00 => try cnf.bitfalse(redirect),
                    // The dust redirects if it is an output
                    0b01 => try cnf.biteql(output, redirect),
                    // The dust redirects if it is an input
                    0b10 => try cnf.biteql(input, redirect),
                    // The dust redirects if input or output
                    0b11 => try cnf.bitor(input, output, redirect),
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

        const n_r = vars.n_redirect.at(pos);
        const e_r = vars.e_redirect.at(pos);
        const s_r = vars.s_redirect.at(pos);
        const w_r = vars.w_redirect.at(pos);

        // n_c -> whether the dust connects north
        // e_c -> whether the dust connects east
        // s_c -> whether the dust connects south
        // w_c -> whether the dust connects west

        const n_c = vars.n_connect.at(pos);
        const e_c = vars.e_connect.at(pos);
        const s_c = vars.s_connect.at(pos);
        const w_c = vars.w_connect.at(pos);

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
        if (opt.allow_weak_powered_block_input)
            try cnf.part(vars.block.at(pos), 1);

        // Or this is a dust
        if (opt.allow_max_signal_dust_input)
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

        // Or this is a block
        if (opt.allow_block_output)
            try cnf.part(vars.block.at(pos), 1);

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
    for (0..opt.input_count) |input_idx| {
        const input_off = input_idx * opt.area();

        // At least one position is mapped for each input
        for (0..opt.area()) |pos| {
            const input = vars.input_map.at(pos + input_off);
            try cnf.part(input, 1);
        }
        try cnf.end();

        // At most one position is mapped for each input
        for (0..opt.area()) |rhs| {
            for (0..rhs) |lhs| {
                const a = vars.input_map.at(lhs + input_off);
                const b = vars.input_map.at(rhs + input_off);
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
    for (0..opt.output_count) |output_idx| {
        const output_off = output_idx * opt.area();

        // At least one position is mapped for each output
        for (0..opt.area()) |pos| {
            const output = vars.output_map.at(pos + output_off);
            try cnf.part(output, 1);
        }
        try cnf.end();

        // At most one position is mapped for each output
        for (0..opt.area()) |rhs| {
            for (0..rhs) |lhs| {
                const a = vars.output_map.at(lhs + output_off);
                const b = vars.output_map.at(rhs + output_off);
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
            const lhs_off = lhs_idx * opt.area();
            const rhs_off = rhs_idx * opt.area();

            for (0..opt.area()) |pos| {
                const lhs = vars.input_map.at(lhs_off + pos);
                const rhs = vars.input_map.at(rhs_off + pos);
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
            const lhs_off = lhs_idx * opt.area();
            const rhs_off = rhs_idx * opt.area();

            for (0..opt.area()) |pos| {
                const lhs = vars.output_map.at(pos + lhs_off);
                const rhs = vars.output_map.at(pos + rhs_off);
                try cnf.clause(&.{ lhs, rhs }, &.{ 0, 0 });
            }
        }
    }
}

// constrain dust power to signal strength
fn dustIsPowered(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    if (opt.max_signal_strength) |max_signal| {
        for (0..opt.states()) |state| {
            for (0..opt.area()) |pos| {
                const idx = pos + state * opt.area();
                const strength_idx = idx * max_signal;
                const a = vars.strength.at(strength_idx);
                const b = vars.dust_on.at(idx);
                try cnf.biteql(a, b);
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
            const offset = state * opt.area() + pos;

            const b = vars.block.at(pos);
            const p = vars.block_on.at(offset);
            const o = vars.override_on.at(offset);

            // ---------------------- forward implication - block is powered on

            // If adjacent blocks are connected back to this block, AND if they
            // are powered on, AND if the current cell is a block, then the
            // current cell must be powered on.

            inline for (.{ .n, .e, .s, .w }) |dir| {
                if (cardinal(opt, pos, dir)) |off| {
                    const backwards = comptime opposite(dir);
                    const c_off = state * opt.area() + off;
                    const d_on = vars.dust_on.at(c_off);
                    const d_con = connectedDust(vars, off, backwards);
                    try cnf.clause(&.{ b, d_on, d_con, p }, &.{ 0, 0, 0, 1 });
                }
            }

            // If the current cell is a block and it was overridden to be
            // powered on (an input force it to be on), then it must be on.

            try cnf.clause(&.{ b, o, p }, &.{ 0, 0, 1 });

            // -------------------- backward implication - block is powered off

            // If not a block, this can't be powered as a block
            try cnf.clause(&.{ b, p }, &.{ 1, 0 });

            inline for (0b0000..0b1111 + 1) |combos| {
                // EITHER: the block is unpowered
                try cnf.part(p, 0);
                // OR: the block is overridden to be powered
                try cnf.part(o, 1);
                // OR: the cell is not actually a block
                try cnf.part(b, 0);

                inline for (&.{ .n, .e, .s, .w }, 0..4) |dir, combo_bit| {
                    if (cardinal(opt, pos, dir)) |off| {
                        if (combos & (1 << combo_bit) != 0) {
                            // OR: cardinal dust is not connected
                            try cnf.part(connectedDust(vars, pos, dir), 0);
                            // OR: cardinal dust is powered on
                            const c_off = state * opt.area() + off;
                            try cnf.part(vars.dust_on.at(c_off), 1);
                        } else {
                            // OR: cardinal dust is connected
                            try cnf.part(connectedDust(vars, pos, dir), 1);
                        }
                    }
                }

                try cnf.end();
            }
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
            const offset = state * opt.area() + pos;

            const t = vars.torch.at(pos);
            const p = vars.torch_on.at(offset);

            // ************* forward implication - when the torch is powered on

            // Torches are on when their connected blocks are off

            inline for (.{ .n, .e, .s, .w }) |dir| {
                if (cardinal(opt, pos, dir)) |off| {
                    const block_on = vars.block_on.at(off);
                    const backwards = comptime opposite(dir);
                    const torch = facingTorch(vars, pos, backwards);
                    try cnf.clause(&.{ torch, block_on, p }, &.{ 0, 1, 1 });
                }
            }

            // *********** backward implication - when the torch is powered off

            // If not a torch, this can't be powered as a torch
            try cnf.clause(&.{ t, p }, &.{ 1, 0 });

            // Torches are off when their connected blocks are on

            inline for (.{ .n, .e, .s, .w }) |dir| {
                if (cardinal(opt, pos, dir)) |off| {
                    const block_on = vars.block_on.at(off);
                    const backwards = comptime opposite(dir);
                    const torch = facingTorch(vars, pos, backwards);
                    try cnf.clause(&.{ torch, block_on, p }, &.{ 0, 0, 1 });
                }
            }
        }
    }
}

// Given the current state and index of the input, return the input value
fn inputValue(state: u64, input: u64) u1 {
    return @truncate(state >> @intCast(input));
}

// Given the current state and index of the output, return the defined output
fn outputValue(opt: *const Options, state: u64, output: u64) ?u1 {
    outer: for (opt.truth[output]) |row| {
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
            const ovr_off = state * opt.area();
            const override = vars.override_on.at(ovr_off + pos);

            // ********************** forward implication - overridden to be on

            // For every single input, if the state of that input is supposed
            // to be TRUE, then whether the current cell is that input's
            // position will imply that the override is TRUE.

            for (0..opt.input_count) |inp| {
                const inp_off = inp * opt.area() + pos;
                const is_input = vars.input_map.at(inp_off);
                if (inputValue(state, inp) == 1) {
                    try cnf.bitimp(is_input, override);
                }
            }

            // ***************** backward implication - not overridden to be on

            // The override is false if and only if every single input which is
            // true does not reside at the current cell. This is the same as
            // encoding a single CNF clause where either the override is FALSE,
            // or each input (if it is true in this state) is at this position.

            try cnf.part(override, 0);

            for (0..opt.input_count) |inp| {
                const inp_off = inp * opt.area() + pos;
                const is_input = vars.input_map.at(inp_off);
                if (inputValue(state, inp) == 1) {
                    try cnf.part(is_input, 1);
                }
            }

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
            const c_off_offset = state * opt.area() + pos;
            const constrain = vars.constrain_off.at(c_off_offset);

            // ******************** forward implication - constrained to be off

            // For every single input, if the state of that input is supposed
            // to be FALSE, then if it is *that* input implies the constraint.

            for (0..opt.input_count) |inp| {
                const is_input = vars.input_map.at(pos + inp * opt.area());
                if (inputValue(state, inp) == 0) {
                    try cnf.bitimp(is_input, constrain);
                }
            }

            // For every single output, if the state of that output is supposed
            // to be FALSE, then if it is *that* output implies the constraint.

            for (0..opt.output_count) |out| {
                const is_output = vars.output_map.at(pos + out * opt.area());
                if (outputValue(opt, state, out) == 0) {
                    try cnf.bitimp(is_output, constrain);
                }
            }

            // *************** backward implication - not constrained to be off

            // EITHER: the cell is not constrained to be off
            try cnf.part(constrain, 0);

            // OR: there is an input and it is powered off
            for (0..opt.input_count) |inp| {
                const is_input = vars.input_map.at(pos + inp * opt.area());
                if (inputValue(state, inp) == 0) {
                    try cnf.part(is_input, 1);
                }
            }

            // OR: there is an output and it is powered off
            for (0..opt.output_count) |out| {
                const is_output = vars.output_map.at(pos + out * opt.area());
                if (outputValue(opt, state, out) == 0) {
                    try cnf.part(is_output, 1);
                }
            }

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
            const c_on_offset = state * opt.area() + pos;
            const constrain = vars.constrain_on.at(c_on_offset);

            // --------------------- forward implication - constrained to be on

            // For every single output, if the state of that output is supposed
            // to be TRUE, then the power is implied by if that cell is output.

            for (0..opt.output_count) |out| {
                const is_output = vars.output_map.at(pos + out * opt.area());
                if (outputValue(opt, state, out) == 1) {
                    try cnf.bitimp(is_output, constrain);
                }
            }

            // ---------------- backward implication - not constrained to be on

            // EITHER: the cell is not constrained to be on
            try cnf.part(constrain, 0);

            // OR: there is an output and it is powered on
            for (0..opt.output_count) |out| {
                const is_output = vars.output_map.at(pos + out * opt.area());
                if (outputValue(opt, state, out) == 1) {
                    try cnf.part(is_output, 1);
                }
            }

            try cnf.end();
        }
    }
}

// TODO: constrain signal strength and power of dust
fn dustPowerStrengthPropagation(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            const d_offset = state * opt.area() + pos;
            const d_on = vars.dust_on.at(d_offset);
            const d = vars.dust.at(pos);

            if (opt.max_signal_strength) |max_strength| {
                _ = max_strength;
                unreachable; // TODO: not yet implemented
            } else {
                // Dust power is equal to adjacent dust
                inline for (&.{ .n, .e, .s, .w }) |dir| {
                    if (cardinal(opt, pos, dir)) |off| {
                        const rhs_offset = state * opt.area() + off;
                        const c_on = vars.dust_on.at(rhs_offset);
                        const c_d = vars.dust.at(off);
                        try cnf.clause(&.{ d, c_d, c_on, d_on }, &.{ 0, 0, 0, 1 });
                        try cnf.clause(&.{ d, c_d, c_on, d_on }, &.{ 0, 0, 1, 0 });
                    }
                }

                // override_on and dust implies the dust is powered
                const o_on = vars.override_on.at(d_offset);
                try cnf.clause(&.{ o_on, d, d_on }, &.{ 0, 0, 1 });

                // constrain_on and dust implies the dust is powered
                const c_on = vars.constrain_on.at(d_offset);
                try cnf.clause(&.{ c_on, d, d_on }, &.{ 0, 0, 1 });

                // constrain_off implies the dust is not powered
                const c_off = vars.constrain_off.at(d_offset);
                try cnf.clause(&.{ c_off, d_on }, &.{ 0, 0 });
            }
        }
    }
}
