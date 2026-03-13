const std = @import("std");
const assert = std.debug.assert;

const Options = @import("Options.zig");
const Solver = @import("Solver.zig");
const cnf = @import("cnf.zig");
const Bits = cnf.Bits;

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

pub fn init(opt: *const Options, solver: *Solver) @This() {
    const area = opt.area();
    const states = opt.states();
    const seg_bits = opt.transition_bits;

    return .{
        .dust = solver.alloc(area),
        .torch = solver.alloc(area),
        .block = solver.alloc(area),
        .input = solver.alloc(area),
        .output = solver.alloc(area),

        .facing_redirect = .{
            solver.alloc(area),
            solver.alloc(area),
            solver.alloc(area),
            solver.alloc(area),
        },
        .facing_connect = .{
            solver.alloc(area),
            solver.alloc(area),
            solver.alloc(area),
            solver.alloc(area),
        },
        .facing_torch = .{
            solver.alloc(area),
            solver.alloc(area),
            solver.alloc(area),
            solver.alloc(area),
        },

        .input_map = solver.alloc(opt.input_count * area),

        .output_map = solver.alloc(opt.output_count * area),

        .segment = solver.alloc(area * seg_bits),

        .torch_on = solver.alloc(states * area),
        .block_on = solver.alloc(states * area),
        .override_on = solver.alloc(states * area),
        .constrain_on = solver.alloc(states * area),
        .constrain_off = solver.alloc(states * area),

        .connected_on = .{
            solver.alloc(states * area),
            solver.alloc(states * area),
            solver.alloc(states * area),
            solver.alloc(states * area),
        },

        .strength = solver.alloc(states * area * 15),
    };
}

pub fn facingRedirectAt(self: *const @This(), dir: usize, pos: usize) usize {
    assert(dir < 4);
    return self.facing_redirect[dir].at(pos);
}

pub fn facingConnectAt(self: *const @This(), dir: usize, pos: usize) usize {
    assert(dir < 4);
    return self.facing_connect[dir].at(pos);
}

pub fn facingTorchAt(self: *const @This(), dir: usize, pos: usize) usize {
    assert(dir < 4);
    return self.facing_torch[dir].at(pos);
}

pub fn inputMapAt(self: *const @This(), opt: *const Options, inp: usize, pos: usize) usize {
    assert(inp < opt.input_count);
    return self.input_map.at(inp * opt.area() + pos);
}

pub fn outputMapAt(self: *const @This(), opt: *const Options, out: usize, pos: usize) usize {
    assert(out < opt.output_count);
    return self.output_map.at(out * opt.area() + pos);
}

pub fn segmentAt(self: *const @This(), opt: *const Options, pos: usize) Bits {
    const index = self.segment.at(pos * opt.transition_bits);
    return .init(index, opt.transition_bits);
}

pub fn torchOnAt(self: *const @This(), opt: *const Options, state: usize, pos: usize) usize {
    assert(state < opt.states());
    return self.torch_on.at(state * opt.area() + pos);
}

pub fn blockOnAt(self: *const @This(), opt: *const Options, state: usize, pos: usize) usize {
    assert(state < opt.states());
    return self.block_on.at(state * opt.area() + pos);
}

pub fn overrideOnAt(self: *const @This(), opt: *const Options, state: usize, pos: usize) usize {
    assert(state < opt.states());
    return self.override_on.at(state * opt.area() + pos);
}

pub fn constrainOnAt(self: *const @This(), opt: *const Options, state: usize, pos: usize) usize {
    assert(state < opt.states());
    return self.constrain_on.at(state * opt.area() + pos);
}

pub fn constrainOffAt(self: *const @This(), opt: *const Options, state: usize, pos: usize) usize {
    assert(state < opt.states());
    return self.constrain_off.at(state * opt.area() + pos);
}

pub fn connectedOnAt(self: *const @This(), opt: *const Options, dir: usize, state: usize, pos: usize) usize {
    assert(dir < 4);
    assert(state < opt.states());
    return self.connected_on[dir].at(state * opt.area() + pos);
}

pub fn strengthAt(self: *const @This(), opt: *const Options, state: usize, pos: usize) Bits {
    assert(state < opt.states());
    const offset = (state * opt.area() + pos) * 15;
    return .init(self.strength.at(offset), 15);
}
