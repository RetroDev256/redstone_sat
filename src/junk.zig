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
    for (0..height) |y| {
        const l_off = 0; // beginning of the row
        const dust_l = is_dust.at(l_off + y * width);
        try cnf.bitimp(is_input.at(y), dust_l);
        const r_off = width - 1; // end of the row
        const dust_r = is_dust.at(r_off + y * width);
        try cnf.bitimp(is_output.at(y), dust_r);
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

// forces specific inputs and outputs to be a general input or output
fn enforceInputOutputMapImplication(cnf: *Cnf) !void {
    // Specific inputs are a general input
    for (0..height) |y|
        for (input_map) |input|
            try cnf.bitimp(input.at(y), is_input.at(y));

    for (0..height) |y| {
        // Either the current block is not an input
        try cnf.clausePart(is_input.at(y), 0);
        for (input_map) |input|
            // Or there is a block that is a specific input
            try cnf.clausePart(input.at(y), 1);
        // general inputs require at least one specific input
        try cnf.clauseEnd();
    }

    // Specific outputs are a general output
    for (0..height) |y|
        for (output_map) |output|
            try cnf.bitimp(output.at(y), is_output.at(y));

    for (0..height) |y| {
        // Either the current block is not an output
        try cnf.clausePart(is_output.at(y), 0);
        for (output_map) |output|
            // Or there is a block that is a specific output
            try cnf.clausePart(output.at(y), 1);
        // general outputs require at least one specific output
        try cnf.clauseEnd();
    }
}

// Constrain the sides to only have input / output stuff
fn constrainInputOutputSideBlocks(cnf: *Cnf) !void {
    for (0..height) |y| {
        const pos = y * width;
        // If the block is dust, it must be an input
        try cnf.bitimp(is_dust.at(pos), is_input.at(y));
    }

    for (0..height) |y| {
        const pos = y * width + width - 1;
        // If the block is dust, it must be an output
        try cnf.bitimp(is_dust.at(pos), is_output.at(y));
    }

    // No block exists at the top left
    try cnf.bitfalse(is_block.at(0));
    // No block exists at the top right
    try cnf.bitfalse(is_block.at(width - 1));

    for (1..height) |y| {
        // Blocks must have dust above them on the input side
        const block_input = is_block.at(y * width);
        const dust_input = is_dust.at(y * width - width);
        try cnf.bitimp(block_input, dust_input);
        // Blocks must have dust above them on the output side
        const block_output = is_block.at(y * width + width - 1);
        const dust_output = is_dust.at(y * width - 1);
        try cnf.bitimp(block_output, dust_output);
    }

    // For every state, if there is a torch above an input redstone dust, the
    // torch must be on if the dust is on, otherwise the torch must be off.
    // This prevents the torch from incorrectly powering the input from above.

    for (0..states) |state| {
        for (1..height) |y| {
            const dust_pos = y * width;
            const torch_pos = (y - 1) * width;

            try cnf.clause(&.{
                // either there is **NOT** a torch above
                is_torch.at(torch_pos),
                // OR there is **NOT** an input below it
                is_input.at(y),
                // OR the torch **IS** powered on
                is_torch_on[state].at(torch_pos),
                // OR the dust is **NOT** powered on
                is_dust_powered[state].at(dust_pos),
            }, &.{ 0, 0, 1, 0 });

            try cnf.clause(&.{
                // either there is **NOT** a torch above
                is_torch.at(torch_pos),
                // OR there is **NOT** an input below it
                is_input.at(y),
                // OR the torch is **NOT** powered on
                is_torch_on[state].at(torch_pos),
                // OR the dust **IS** powered on
                is_dust_powered[state].at(dust_pos),
            }, &.{ 0, 0, 0, 1 });
        }
    }

    // For every state, if there is a torch two blocks below an input redstone
    // dust, the torch must be powered if the torch is powered, or off if off.
    // This prevents the torch from incorrectly powering the input from below.

    for (0..states) |state| {
        for (2..height) |y| {
            const torch_pos = y * width;
            const dust_pos = (y - 2) * width;

            try cnf.clause(&.{
                // either there is **NOT** a torch below
                is_torch.at(torch_pos),
                // OR there is **NOT** an input above it
                is_input.at(y - 2),
                // OR the torch **IS** powered on
                is_torch_on[state].at(torch_pos),
                // OR the dust is **NOT** powered on
                is_dust_powered[state].at(dust_pos),
            }, &.{ 0, 0, 1, 0 });

            try cnf.clause(&.{
                // either there is **NOT** a torch below
                is_torch.at(torch_pos),
                // OR there is **NOT** an input above it
                is_input.at(y - 2),
                // OR the torch is **NOT** powered on
                is_torch_on[state].at(torch_pos),
                // OR the dust **IS** powered on
                is_dust_powered[state].at(dust_pos),
            }, &.{ 0, 0, 0, 1 });
        }
    }
}

// Constrain the inputs and outputs to maintain truth table ordering
fn constrainInputOutputOrdering(cnf: *Cnf) !void {
    // greater inputs are above lesser inputs
    if (enforce_input_ordering) {
        for (0..height) |y_hi| for (0..y_hi) |y_lo| {
            for (0..inputs) |x_gt| for (0..x_gt) |x_lt| {
                const a = input_map[x_gt].at(y_hi);
                const b = input_map[x_lt].at(y_lo);
                try cnf.clause(&.{ a, b }, &.{ 0, 0 });
            };
        };
    }

    // greater outputs are above lesser outputs
    if (enforce_output_ordering) {
        for (0..height) |y_hi| for (0..y_hi) |y_lo| {
            for (0..outputs) |x_gt| for (0..x_gt) |x_lt| {
                const a = output_map[x_gt].at(y_hi);
                const b = output_map[x_lt].at(y_lo);
                try cnf.clause(&.{ a, b }, &.{ 0, 0 });
            };
        };
    }
}

// forces the number of inputs and outputs to be one
fn enforceInputOutputCardinality(cnf: *Cnf) !void {
    for (0..height) |lhs| {
        for (0..lhs) |rhs| {
            // No two blocks map to the same input
            for (input_map) |input| try cnf.clause(
                &.{ input.at(lhs), input.at(rhs) },
                &.{ 0, 0 },
            );

            // No two blocks map to the same output
            for (output_map) |output| try cnf.clause(
                &.{ output.at(lhs), output.at(rhs) },
                &.{ 0, 0 },
            );
        }
    }

    for (input_map) |input| {
        // At least one block is each input
        for (0..height) |y|
            try cnf.clausePart(input.at(y), 1);
        try cnf.clauseEnd();
    }

    for (output_map) |output| {
        // At least one block is each output
        for (0..height) |y|
            try cnf.clausePart(output.at(y), 1);
        try cnf.clauseEnd();
    }
}

// constrains the value of specific input blocks based on the state
fn constrainSpecificInputDustValue(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (input_map, 0..) |input, idx| {
            for (0..height) |y| {
                const inp = input.at(y);
                const top = max_power - 1;
                const sig = signal_strength[state][y * width];
                switch (@as(u1, @truncate(state >> @intCast(idx)))) {
                    // On specific 0, input IMPLIES zero signal strength
                    0 => try cnf.clause(&.{ inp, sig.at(0) }, &.{ 0, 0 }),
                    // On specific 1, input IMPLIES max signal strength
                    1 => try cnf.clause(&.{ inp, sig.at(top) }, &.{ 0, 1 }),
                }
            }
        }
    }
}

// constrains the value of specific output blocks based on the truth table
fn constrainSpecificOutputDustValue(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (output_map, 0..) |output, idx| {
            for (0..height) |y| {
                const out = output.at(y);
                const pos = y * width + width - 1;
                const pow = is_dust_powered[state].at(pos);
                for (truth[idx]) |row| {
                    // Compute which row we are on
                    var row_number: u64 = 0;
                    for (row[0], 0..) |bit, off| {
                        const shift: u6 = @intCast(inputs - 1 - off);
                        row_number |= @as(u64, bit) << shift;
                    }

                    // Constrain the output if we are on this row
                    if (state == row_number) switch (row[1]) {
                        // On specific 0, out IMPLIES unpowered
                        0 => try cnf.clause(&.{ out, pow }, &.{ 0, 0 }),
                        // On specific 1, out IMPLIES powered
                        1 => try cnf.clause(&.{ out, pow }, &.{ 0, 1 }),
                    };
                }
            }
        }
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

// Signal strength can only be propagated if the block is dust and not input
fn enforceCanPropagate(cnf: *Cnf) !void {
    for (0..states) |state| {
        for (0..area) |pos| {
            const dust = is_dust.at(pos);
            const prop = can_propagate[state].at(pos);

            if (isInputPosition(pos)) |input| {
                // propagation implies that it is dust
                try cnf.bitimp(prop, dust);
                // it can't propagate and also be an input
                try cnf.clause(&.{ prop, input }, &.{ 0, 0 });
                // if dust and not an input, it must be able to propagate
                try cnf.clause(&.{ prop, input, dust }, &.{ 1, 1, 0 });
            } else {
                // We know this position is not an input; prop = dust
                try cnf.biteql(prop, dust);
            }
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
                    const blk = t_block_maybe.?;
                    const dst = is_dust.at(pos);

                    // supply implies dust
                    try cnf.bitimp(sup, dst);
                    // supply implies signal strength
                    try cnf.bitimp(sup, sig);
                    // blocked connection implies no supply
                    try cnf.clause(&.{ blk, sup }, &.{ 0, 0 });
                    // signal and no block and dust imply supply
                    try cnf.clause(&.{ sig, blk, dst, sup }, &.{ 0, 1, 0, 1 });
                } else {
                    // Supplyable signal strength from the top left is zero
                    try cnf.bitfalse(tl_sup.at(off));
                }

                if (bl_sig_maybe) |bl_sig| {
                    // SUP = SIG AND NOT BLOCK AND DUST
                    const sup = bl_sup.at(off);
                    const sig = bl_sig.at(off);
                    const blk = l_block_maybe.?;
                    const dst = is_dust.at(pos);

                    // supply implies dust
                    try cnf.bitimp(sup, dst);
                    // supply implies signal strength
                    try cnf.bitimp(sup, sig);
                    // blocked connection implies no supply
                    try cnf.clause(&.{ blk, sup }, &.{ 0, 0 });
                    // signal and no block and dust imply supply
                    try cnf.clause(&.{ sig, blk, dst, sup }, &.{ 0, 1, 0, 1 });
                } else {
                    // Supplyable signal strength from the bottom left is zero
                    try cnf.bitfalse(bl_sup.at(off));
                }

                if (tr_sig_maybe) |tr_sig| {
                    // SUP = SIG AND NOT BLOCK AND DUST
                    const sup = tr_sup.at(off);
                    const sig = tr_sig.at(off);
                    const blk = t_block_maybe.?;
                    const dst = is_dust.at(pos);

                    // supply implies dust
                    try cnf.bitimp(sup, dst);
                    // supply implies signal strength
                    try cnf.bitimp(sup, sig);
                    // blocked connection implies no supply
                    try cnf.clause(&.{ blk, sup }, &.{ 0, 0 });
                    // signal and no block and dust imply supply
                    try cnf.clause(&.{ sig, blk, dst, sup }, &.{ 0, 1, 0, 1 });
                } else {
                    // Supplyable signal strength from the top right is zero
                    try cnf.bitfalse(tr_sup.at(off));
                }

                if (br_sig_maybe) |br_sig| {
                    // SUP = SIG AND NOT BLOCK AND DUST
                    const sup = br_sup.at(off);
                    const sig = br_sig.at(off);
                    const blk = r_block_maybe.?;
                    const dst = is_dust.at(pos);

                    // supply implies dust
                    try cnf.bitimp(sup, dst);
                    // supply implies signal strength
                    try cnf.bitimp(sup, sig);
                    // blocked connection implies no supply
                    try cnf.clause(&.{ blk, sup }, &.{ 0, 0 });
                    // signal and no block and dust imply supply
                    try cnf.clause(&.{ sig, blk, dst, sup }, &.{ 0, 1, 0, 1 });
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

            // direct power implies the dust is at max signal strength
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
    if (prevent_cycles) {
        for (0..area) |pos| {
            try cnf.unaryConstrain(segment_id[pos]);
        }
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

// constrain the number of torches
fn constrainTorchCount(cnf: *Cnf) !void {
    if (max_torch != null or min_torch != null) {
        const torch_card = try cnf.unaryTotalize(is_torch);

        if (max_torch) |count| {
            try cnf.unaryConstrainLEVal(torch_card, count);
        }

        if (min_torch) |count| {
            try cnf.unaryConstrainGEVal(torch_card, count);
        }
    }
}

// constrain torch type
fn constrainTorchType(cnf: *Cnf) !void {
    if (!allow_standing_torch) for (0..area) |pos|
        try cnf.bitfalse(is_standing_torch.at(pos));
    if (!allow_left_torch) for (0..area) |pos|
        try cnf.bitfalse(is_left_torch.at(pos));
    if (!allow_right_torch) for (0..area) |pos|
        try cnf.bitfalse(is_right_torch.at(pos));
}

// remove unchanging torches and dust
fn restrictUnchangingTorchesAndDust(cnf: *Cnf) !void {
    if (enforce_state_change) {
        for (0..area) |pos| {
            inline for (&.{
                &.{ is_torch_on, is_torch },
                &.{ is_dust_powered, is_dust },
            }) |stateful| {
                inline for (&.{ 0, 1 }) |power| {
                    for (0..states) |state|
                        try cnf.clausePart(stateful[0][state].at(pos), power);
                    try cnf.clausePart(stateful[1].at(pos), 0);
                    try cnf.clauseEnd();
                }
            }
        }
    }
}

// restrict redstone dust to not touch other redstone dust
fn restrictRedstoneDustConnectivity(cnf: *Cnf) !void {
    if (single_redstone_dust) {
        // Horizontal redstone dust
        for (0..width - 1) |x| {
            for (0..height) |y| {
                const pos = x + y * width;

                const l = is_dust.at(pos);
                const r = is_dust.at(pos + 1);

                // No dust can exist side-by-side with other dust
                try cnf.clause(&.{ l, r }, &.{ 0, 0 });
            }
        }

        // Diagonal redstone dust
        for (0..width - 1) |x| {
            for (0..height - 1) |y| {
                const pos = x + y * width;

                const tl = is_dust.at(pos);
                const tr = is_dust.at(pos + 1);
                const bl = is_dust.at(pos + width);
                const br = is_dust.at(pos + width + 1);

                // upper-right diagonal redstone dust implies top left block
                try cnf.clause(&.{ bl, tr, tl }, &.{ 0, 0, 1 });

                // downward-left diagonal redstone dust implies top right block
                try cnf.clause(&.{ tl, br, tr }, &.{ 0, 0, 1 });
            }
        }
    }
}

// restrict torches from obviously burning out instantly
fn restrictSimpleTorchCycles(cnf: *Cnf) !void {

    //        BLK
    //        BLK
    //  DST   BLK
    //
    //  BLK     o
    //  BLK    /
    //  BLK   /

    if (allow_right_torch) {
        for (0..width - 1) |x| {
            for (0..height - 1) |y| {
                const pos = x + y * width;
                const tl_d = is_dust.at(pos);
                const tr_b = is_block.at(pos + 1);
                const br_t = is_right_torch.at(pos + width + 1);
                try cnf.clause(&.{ tl_d, tr_b, br_t }, &.{ 0, 0, 0 });
            }
        }
    }

    //  BLK
    //  BLK
    //  BLK   DST
    //
    //  o     BLK
    //   \    BLK
    //    \   BLK

    if (allow_left_torch) {
        for (0..width - 1) |x| {
            for (0..height - 1) |y| {
                const pos = x + y * width;
                const tl_b = is_block.at(pos);
                const tr_d = is_dust.at(pos + 1);
                const bl_t = is_left_torch.at(pos + width);
                try cnf.clause(&.{ tl_b, tr_d, bl_t }, &.{ 0, 0, 0 });
            }
        }
    }
}

// block torches from appearing on the very bottom
fn restrictBottomTorches(cnf: *Cnf) !void {
    for (0..width) |x| {
        const y_off = (height - 1) * width;
        const torch = is_torch.at(x + y_off);
        try cnf.bitfalse(torch);
    }
}
