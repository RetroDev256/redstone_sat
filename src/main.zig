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

// Constraint TODOs:
// - Dust which is also an input should be considered when finding out how it redirects
// - Find out how the heck I will encode redirection of dust

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
                if (row[0].len != self.input_count)
                    return error.MismatchingInputCount;
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
    false_bit: u64, // always false
    true_bit: u64, // always true

    // [position: opt.area()]
    air: Bits, // whether position is air
    dust: Bits, // whether position is dust
    torch: Bits, // whether position is torch
    block: Bits, // whether position is block

    // [position: opt.area()]
    n_redirect: Bits, // northern dust redirection (or edge I/O)
    e_redirect: Bits, // eastern dust redirection (or edge I/O)
    s_redirect: Bits, // southern dust redirection (or edge I/O)
    w_redirect: Bits, // western dust redirection (or edge I/O)

    // [position: opt.area()]
    n_connect: Bits, // dust connected to the north (looser redirection)
    e_connect: Bits, // dust connected to the east (looser redirection)
    s_connect: Bits, // dust connected to the south (looser redirection)
    w_connect: Bits, // dust connected to the west (looser redirection)

    // [position: opt.area()]
    n_torch: Bits, // whether position is north facing torch
    e_torch: Bits, // whether position is east facing torch
    s_torch: Bits, // whether position is south facing torch
    w_torch: Bits, // whether position is west facing torch

    // [position: opt.area()]
    input: Bits, // whether position is input
    output: Bits, // whether position is output

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
    torch_on: Bits, // whether a torch is powered or not
    block_on: Bits, // whether a block is powered or not
    dust_on: Bits, // whether a dust is powered or not
    connected_on: Bits, // whether adjacent dust is powered or not

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
            .false_bit = cnf.alloc(1).idx,
            .true_bit = cnf.alloc(1).idx,

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
            .connected_on = cnf.alloc(states * area),

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
        "falseAndTrueBit",
        "blockSingularity",
        "torchDistinctness",
        "torchBlockSupports",
        "blockTorchConnection",
        "torchDustConnection",
        "blockDustConnection",
        "inputCardinality",
        "outputCardinality",
        "dustRedirectionSources",
        "dustConnection",
        "inputBlockType",
        "outputBlockType",
        "inputMapCardinality",
        "outputMapCardinality",
        "inputOverlap",
        "outputOverlap",
        "cardinalConnectedOn",
        "blockPowered",
    };

    inline for (function_name_list, 0..) |name, idx| {
        const fmt_args = .{ idx + 1, function_name_list.len, name };
        std.debug.print("{} / {} - {s}...\n", fmt_args);
        try @field(@This(), name)(&cnf, &vars, opt);
    }

    try cnf.bittrue(vars.block.at(14));
    try cnf.bittrue(vars.block.at(20));
    try cnf.bittrue(vars.block.at(30));
    try cnf.bittrue(vars.block.at(40));

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
        0b0000 => .{ "      ", "  ██  ", "      " },
        0b0001 => .{ "      ", "████  ", "      " },
        0b0010 => .{ "      ", "  ██  ", "  ██  " },
        0b0011 => .{ "      ", "████  ", "  ██  " },
        0b0100 => .{ "      ", "  ████", "      " },
        0b0101 => .{ "      ", "██████", "      " },
        0b0110 => .{ "      ", "  ████", "  ██  " },
        0b0111 => .{ "      ", "██████", "  ██  " },
        0b1000 => .{ "  ██  ", "  ██  ", "      " },
        0b1001 => .{ "  ██  ", "████  ", "      " },
        0b1010 => .{ "  ██  ", "  ██  ", "  ██  " },
        0b1011 => .{ "  ██  ", "████  ", "  ██  " },
        0b1100 => .{ "  ██  ", "  ████", "      " },
        0b1101 => .{ "  ██  ", "██████", "      " },
        0b1110 => .{ "  ██  ", "  ████", "  ██  " },
        0b1111 => .{ "  ██  ", "██████", "  ██  " },
    } };
}

const air_display: Display = .{ .gray, .{ "      ", "  ..  ", "      " } };
const block_display: Display = .{ .white, .{ "██████", "██████", "██████" } };
const n_torch_display: Display = .{ .yellow, .{ "      ", "  𜷂𜷖  ", "  ▐▌  " } };
const e_torch_display: Display = .{ .yellow, .{ "      ", "🬋🬋𜷂𜷖  ", "      " } };
const s_torch_display: Display = .{ .yellow, .{ "  ▐▌  ", "  𜷂𜷖  ", "      " } };
const w_torch_display: Display = .{ .yellow, .{ "      ", "  𜷂𜷖🬋🬋", "      " } };
const unknown_display: Display = .{ .gray, .{ "? ? ? ", " ? ? ?", "? ? ? " } };

// Initialize the false and true bit
fn falseAndTrueBit(
    cnf: *Cnf,
    vars: *const Variables,
    _: *const Options,
) !void {
    try cnf.bitfalse(vars.false_bit);
    try cnf.bittrue(vars.true_bit);
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

// Make torches require supporting block
fn torchBlockSupports(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        const x = pos % opt.width;
        const z = pos / opt.width;

        const n_torch = vars.n_torch.at(pos);
        const e_torch = vars.e_torch.at(pos);
        const s_torch = vars.s_torch.at(pos);
        const w_torch = vars.w_torch.at(pos);

        if (z < opt.length - 1) { // north facing torches
            const block = vars.block.at(pos + opt.width);
            try cnf.bitimp(n_torch, block);
        } else {
            try cnf.bitfalse(n_torch);
        }

        if (x > 0) { // east facing torches
            const block = vars.block.at(pos - 1);
            try cnf.bitimp(e_torch, block);
        } else {
            try cnf.bitfalse(e_torch);
        }

        if (z > 0) { // south facing torches
            const block = vars.block.at(pos - opt.width);
            try cnf.bitimp(s_torch, block);
        } else {
            try cnf.bitfalse(s_torch);
        }

        if (x < opt.width - 1) { // west facing torches
            const block = vars.block.at(pos + 1);
            try cnf.bitimp(w_torch, block);
        } else {
            try cnf.bitfalse(w_torch);
        }
    }
}

// make blocks require cardinal connected torch
// OR act as output
fn blockTorchConnection(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        const x = pos % opt.width;
        const z = pos / opt.width;

        // There is either no block at this position
        try cnf.clausePart(vars.block.at(pos), 0);

        if (opt.allow_block_output) {
            // OR it could be that the block is an output
            try cnf.clausePart(vars.output.at(pos), 1);
        }

        // OR there is a north-facing torch here
        if (z > 0)
            try cnf.clausePart(vars.n_torch.at(pos - opt.width), 1);
        // OR there is a east-facing torch here
        if (x < opt.width - 1)
            try cnf.clausePart(vars.e_torch.at(pos + 1), 1);
        // OR there is a south-facing torch here
        if (z < opt.length - 1)
            try cnf.clausePart(vars.s_torch.at(pos + opt.width), 1);
        // OR there is a west-facing torch here
        if (x > 0)
            try cnf.clausePart(vars.w_torch.at(pos - 1), 1);

        // Blocks imply one connected torch to it's sides,
        // or it could be the case that it is an output.
        try cnf.clauseEnd();
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
        const x = pos % opt.width;
        const z = pos / opt.width;

        // There is either no torch at this position
        try cnf.clausePart(vars.torch.at(pos), 0);

        if (opt.allow_torch_output) {
            // OR it could be that the block is an output
            try cnf.clausePart(vars.output.at(pos), 1);
        }

        // OR there is a north-relative dust here
        if (z > 0)
            try cnf.clausePart(vars.dust.at(pos - opt.width), 1);
        // OR there is a east-relative dust here
        if (x < opt.width - 1)
            try cnf.clausePart(vars.dust.at(pos + 1), 1);
        // OR there is a south-relative dust here
        if (z < opt.length - 1)
            try cnf.clausePart(vars.dust.at(pos + opt.width), 1);
        // OR there is a west-relative dust here
        if (x > 0)
            try cnf.clausePart(vars.dust.at(pos - 1), 1);

        // Torches imply one connected dust to it's sides,
        // or it could be the case that it is an output.
        try cnf.clauseEnd();
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
        const x = pos % opt.width;
        const z = pos / opt.width;

        // There is either no block at this position
        try cnf.clausePart(vars.block.at(pos), 0);

        if (opt.allow_weak_powered_block_input)
            // OR it could be that the block is an input
            try cnf.clausePart(vars.input.at(pos), 1);

        // OR there is a north-relative connected dust here
        if (z > 0)
            try cnf.clausePart(vars.s_connect.at(pos - opt.width), 1);
        // OR there is a east-relative connected dust here
        if (x < opt.width - 1)
            try cnf.clausePart(vars.w_connect.at(pos + 1), 1);
        // OR there is a south-relative connected dust here
        if (z < opt.length - 1)
            try cnf.clausePart(vars.n_connect.at(pos + opt.width), 1);
        // OR there is a west-relative connected dust here
        if (x > 0)
            try cnf.clausePart(vars.e_connect.at(pos - 1), 1);

        // Blocks imply one connected dust to it's sides,
        // or it could be the case that it is an input.
        try cnf.clauseEnd();
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
                try cnf.clausePart(vars.input.at(pos), 1);
            try cnf.clauseEnd();

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
                try cnf.clausePart(vars.output.at(pos), 1);
            try cnf.clauseEnd();

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
        const x = pos % opt.width;
        const z = pos / opt.width;

        const d = vars.dust.at(pos);
        const i = vars.input.at(pos);
        const o = vars.output.at(pos);
        const n = vars.n_redirect.at(pos);
        const e = vars.e_redirect.at(pos);
        const s = vars.s_redirect.at(pos);
        const w = vars.w_redirect.at(pos);

        // (not dust) -> not redirected northward
        try cnf.clause(&.{ d, n }, &.{ 1, 0 });
        // (not dust) -> not redirected eastward
        try cnf.clause(&.{ d, e }, &.{ 1, 0 });
        // (not dust) -> not redirected southward
        try cnf.clause(&.{ d, s }, &.{ 1, 0 });
        // (not dust) -> not redirected westward
        try cnf.clause(&.{ d, w }, &.{ 1, 0 });

        if (z > 0) { // north redirections
            try centerRedirect(cnf, vars, d, pos - opt.width, n);
        } else {
            try edgeRedirect(cnf, opt, d, i, o, n);
        }

        if (x < opt.width - 1) { // east redirections
            try centerRedirect(cnf, vars, d, pos + 1, e);
        } else {
            try edgeRedirect(cnf, opt, d, i, o, e);
        }

        if (z < opt.length - 1) { // south redirections
            try centerRedirect(cnf, vars, d, pos + opt.width, s);
        } else {
            try edgeRedirect(cnf, opt, d, i, o, s);
        }

        if (x > 0) { // west redirections
            try centerRedirect(cnf, vars, d, pos - 1, w);
        } else {
            try edgeRedirect(cnf, opt, d, i, o, w);
        }
    }
}

fn centerRedirect(
    cnf: *Cnf,
    vars: *const Variables,
    d: u64, // whether this is dust
    c_pos: u64, // cardinal position
    r: u64, // whether this is redirected
) !void {
    // cardinal torch
    const c_t = vars.torch.at(c_pos);
    // cardinal dust
    const c_d = vars.dust.at(c_pos);

    // (not cardinal torch and not cardinal dust) -> not redirected
    try cnf.clause(&.{ c_t, c_d, r }, &.{ 1, 1, 0 });
    // (dust and cardinal torch) -> redirected
    try cnf.clause(&.{ d, c_t, r }, &.{ 0, 0, 1 });
    // (dust and cardinal dust) -> redirected
    try cnf.clause(&.{ d, c_d, r }, &.{ 0, 0, 1 });
}

fn edgeRedirect(
    cnf: *Cnf,
    opt: *const Options,
    d: u64, // whether this is dust
    i: u64, // whether this is an input
    o: u64, // whether this is an output
    r: u64, // whether this is redirected
) !void {
    const redirect_input = opt.redirect_input_edge_dust;
    const redirect_output = opt.redirect_output_edge_dust;
    const redirect_both = redirect_input and redirect_output;

    if (redirect_input) {
        // (dust and input) -> redirected
        try cnf.clause(&.{ d, i, r }, &.{ 0, 0, 1 });
    }

    if (redirect_output) {
        // (dust and output) -> redirected
        try cnf.clause(&.{ d, o, r }, &.{ 0, 0, 1 });
    }

    if (redirect_both) {
        // (not input and not output) -> not redirected
        try cnf.clause(&.{ i, o, r }, &.{ 1, 1, 0 });
    } else if (redirect_input) {
        // (not input) -> not redirected
        try cnf.clause(&.{ i, r }, &.{ 1, 0 });
    } else if (redirect_output) {
        // (not output) -> not redirected
        try cnf.clause(&.{ o, r }, &.{ 1, 0 });
    } else {
        // not redirected
        try cnf.bitfalse(r);
    }
}

// constrain connections of dust blocks
fn dustConnection(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.area()) |pos| {
        const d = vars.dust.at(pos);

        const n_r = vars.n_redirect.at(pos);
        const e_r = vars.e_redirect.at(pos);
        const s_r = vars.s_redirect.at(pos);
        const w_r = vars.w_redirect.at(pos);

        const n_c = vars.n_connect.at(pos);
        const e_c = vars.e_connect.at(pos);
        const s_c = vars.s_connect.at(pos);
        const w_c = vars.w_connect.at(pos);

        // (not d) -> not n_c
        try cnf.clause(&.{ d, n_c }, &.{ 1, 0 });
        // (not d) -> not e_c
        try cnf.clause(&.{ d, e_c }, &.{ 1, 0 });
        // (not d) -> not s_c
        try cnf.clause(&.{ d, s_c }, &.{ 1, 0 });
        // (not d) -> not w_c
        try cnf.clause(&.{ d, w_c }, &.{ 1, 0 });

        // (n_r) -> n_c
        try cnf.clause(&.{ n_r, n_c }, &.{ 0, 1 });
        // (e_r) -> e_c
        try cnf.clause(&.{ e_r, e_c }, &.{ 0, 1 });
        // (s_r) -> s_c
        try cnf.clause(&.{ s_r, s_c }, &.{ 0, 1 });
        // (w_r) -> w_c
        try cnf.clause(&.{ w_r, w_c }, &.{ 0, 1 });

        // (e_r and not n_r) -> not n_c
        try cnf.clause(&.{ e_r, n_r, n_c }, &.{ 0, 1, 0 });
        // (n_r and not e_r) -> not e_c
        try cnf.clause(&.{ n_r, e_r, e_c }, &.{ 0, 1, 0 });
        // (e_r and not s_r) -> not s_c
        try cnf.clause(&.{ e_r, s_r, s_c }, &.{ 0, 1, 0 });
        // (s_r and not w_r) -> not w_c
        try cnf.clause(&.{ s_r, w_r, w_c }, &.{ 0, 1, 0 });

        // (not n_r and not e_r and w_r) -> not n_c
        try cnf.clause(&.{ n_r, e_r, w_r, n_c }, &.{ 1, 1, 0, 0 });
        // (not n_r and not e_r and s_r) -> not e_c
        try cnf.clause(&.{ n_r, e_r, s_r, e_c }, &.{ 1, 1, 0, 0 });
        // (not e_r and not s_r and w_r) -> not s_c
        try cnf.clause(&.{ e_r, s_r, w_r, s_c }, &.{ 1, 1, 0, 0 });
        // (not s_r and not w_r and n_r) -> not w_c
        try cnf.clause(&.{ s_r, w_r, n_r, w_c }, &.{ 1, 1, 0, 0 });

        // (not n_r and not e_r and s_r and not w_r) -> n_c
        try cnf.clause(&.{ n_r, e_r, s_r, w_r, n_c }, &.{ 1, 1, 0, 1, 1 });
        // (not n_r and not e_r and not s_r and w_r) -> e_c
        try cnf.clause(&.{ n_r, e_r, s_r, w_r, e_c }, &.{ 1, 1, 1, 0, 1 });
        // (n_r and not e_r and not s_r and not w_r) -> s_c
        try cnf.clause(&.{ n_r, e_r, s_r, w_r, s_c }, &.{ 0, 1, 1, 1, 1 });
        // (not n_r and e_r and not s_r and not w_r) -> w_c
        try cnf.clause(&.{ n_r, e_r, s_r, w_r, w_c }, &.{ 1, 0, 1, 1, 1 });

        // This is the only place we need to depend on and include dust in the
        // equation, as this is the only place where we would be setting a
        // connection to true if none of the redirections are true - everything
        // else constrains to 0, or already depends on a redirection that is
        // true, which is impossible if dust is false.

        const none_ident = &.{ 0, 1, 1, 1, 1, 1 };
        // (d and not n_r and not e_r and not s_r and not w_r) -> n_c
        try cnf.clause(&.{ d, n_r, e_r, s_r, w_r, n_c }, none_ident);
        // (d and not n_r and not e_r and not s_r and not w_r) -> e_c
        try cnf.clause(&.{ d, n_r, e_r, s_r, w_r, e_c }, none_ident);
        // (d and not n_r and not e_r and not s_r and not w_r) -> w_c
        try cnf.clause(&.{ d, n_r, e_r, s_r, w_r, s_c }, none_ident);
        // (d and not n_r and not e_r and not s_r and not w_r) -> n_c
        try cnf.clause(&.{ d, n_r, e_r, s_r, w_r, w_c }, none_ident);
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
        try cnf.clausePart(vars.input.at(pos), 0);

        // Or this is a block
        if (opt.allow_weak_powered_block_input)
            try cnf.clausePart(vars.block.at(pos), 1);

        // Or this is a dust
        if (opt.allow_max_signal_dust_input)
            try cnf.clausePart(vars.dust.at(pos), 1);

        try cnf.clauseEnd();
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
        try cnf.clausePart(vars.output.at(pos), 0);

        // Or this is a block
        if (opt.allow_block_output)
            try cnf.clausePart(vars.block.at(pos), 1);

        // Or this is a dust
        if (opt.allow_dust_output)
            try cnf.clausePart(vars.dust.at(pos), 1);

        // Or this is a torch
        if (opt.allow_torch_output)
            try cnf.clausePart(vars.torch.at(pos), 1);

        try cnf.clauseEnd();
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
            try cnf.clausePart(input, 1);
        }
        try cnf.clauseEnd();

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
            try cnf.clausePart(output, 1);
        }
        try cnf.clauseEnd();

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
                const lhs = vars.input_map.at(pos + lhs_off);
                const rhs = vars.input_map.at(pos + rhs_off);
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

// constrain connected_on for connected powered dust
fn cardinalConnectedOn(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    for (0..opt.states()) |state| {
        for (0..opt.area()) |pos| {
            const offset = state * opt.area() + pos;

            const a = getDustOnRelative(opt, vars, state, pos, .n);
            const b = getDustOnRelative(opt, vars, state, pos, .e);
            const c = getDustOnRelative(opt, vars, state, pos, .s);
            const d = getDustOnRelative(opt, vars, state, pos, .w);

            const e = getConnectedRelative(opt, vars, pos, .n);
            const f = getConnectedRelative(opt, vars, pos, .e);
            const g = getConnectedRelative(opt, vars, pos, .s);
            const h = getConnectedRelative(opt, vars, pos, .w);

            const i = cnf.alloc(1).idx;
            try cnf.bitand(a, e, i);
            const j = cnf.alloc(1).idx;
            try cnf.bitand(b, f, j);
            const k = cnf.alloc(1).idx;
            try cnf.bitand(c, g, k);
            const l = cnf.alloc(1).idx;
            try cnf.bitand(d, h, l);

            const z = vars.connected_on.at(offset);

            // (i and m) -> z
            try cnf.clause(&.{ i, z }, &.{ 0, 1 });
            // (j and m) -> z
            try cnf.clause(&.{ j, z }, &.{ 0, 1 });
            // (k and m) -> z
            try cnf.clause(&.{ k, z }, &.{ 0, 1 });
            // (l and m) -> z
            try cnf.clause(&.{ l, z }, &.{ 0, 1 });

            // Either it is not connected to some powered dust
            try cnf.clausePart(z, 0);
            // Or it is connected to powered dust on the north
            try cnf.clausePart(i, 1);
            // Or it is connected to powered dust on the east
            try cnf.clausePart(j, 1);
            // Or it is connected to powered dust on the south
            try cnf.clausePart(k, 1);
            // Or it is connected to powered dust on the West
            try cnf.clausePart(l, 1);

            try cnf.clauseEnd();
        }
    }
}

fn getDustOnRelative(
    opt: *const Options,
    vars: *const Variables,
    state: u64,
    pos: u64,
    dir: enum { n, e, s, w },
) u64 {
    const x = pos % opt.width;
    const z = pos / opt.width;
    const offset = state * opt.area() + pos;

    switch (dir) {
        .n => if (z > 0)
            return vars.dust_on.at(offset - opt.width),
        .e => if (x < opt.width - 1)
            return vars.dust_on.at(offset + 1),
        .s => if (z < opt.length - 1)
            return vars.dust_on.at(offset + opt.width),
        .w => if (x > 0)
            return vars.dust_on.at(offset - 1),
    }

    return vars.false_bit;
}

fn getConnectedRelative(
    opt: *const Options,
    vars: *const Variables,
    pos: u64,
    dir: enum { n, e, s, w },
) u64 {
    const x = pos % opt.width;
    const z = pos / opt.width;

    switch (dir) {
        .n => if (z > 0)
            return vars.s_connect.at(pos - opt.width),
        .e => if (x < opt.width - 1)
            return vars.e_connect.at(pos + 1),
        .s => if (z < opt.length - 1)
            return vars.n_connect.at(pos + opt.width),
        .w => if (x > 0)
            return vars.e_connect.at(pos - 1),
    }

    return vars.false_bit;
}

// constrain block_on (based on connected_on, block, input, etc.)
fn blockPowered(
    cnf: *Cnf,
    vars: *const Variables,
    opt: *const Options,
) !void {
    _ = cnf;
    _ = vars;
    _ = opt;

    // a block is powered if:
    // - input_map at that position & input meant to be on
}
