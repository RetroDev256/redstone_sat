# Truth Table -> Redstone SAT Compiler

This project implements a truth table to redstone CNF compiler. Given a truth table and various other descriptions of the required redstone circuit, this program generates a boolean equation representing the simulation of the redstone circuit satisfying this truth table. It supports redstone dust, redstone torches, and opaque blocks for flat (one block high, any number of blocks wide and long) circuits.

## Instructions for Build and Use

Steps to build and/or run the software:

1. `zig build run [-Doptimize=ReleaseFast]`

Instructions for using the software:

1. Build the program with `zig build [-Doptimize=ReleaseFast]`
2. Modify `problem.zon` to suit the problem you want to solve.
3. Run the program in the same directory as `problem.zon`.

## Development Environment

To recreate the development environment, you need the following software:

* Zig 0.16.0-dev.2694+74f361a5c

## Useful Websites to Learn More

I found these websites useful in developing this software:

* [Wikipedia on CNF](https://en.wikipedia.org/wiki/Conjunctive_normal_form)
* [Redstone with SAT solvers](https://alloc.dev/2026/01/09/redstone_from_sat)
* [Wikipedia on SAT solvers](https://en.wikipedia.org/wiki/SAT_solver)
* [Kissat SAT solver](https://github.com/arminbiere/kissat)

## Future Work

The following items I plan to fix, improve, and/or add to this project in the future:

* [x] Integrate Kissat libraries directly into the program to simplify flow.
* [ ] Add optional configurable tree of operations to further constrain circuit.
* [ ] Simplify clause generation (totalizer network & segment ID constraints)

## Demonstration Image

As an example of what this program is capable of, here are two separate redstone circuits that will logically swap two wires without overlapping any physical wires. Both displayed circuits were generated with this project:

<img width="2560" height="1600" alt="image" src="https://github.com/user-attachments/assets/eeb2af5c-a909-4478-8885-265b4aae3951" />

Here are two more demonstration circuits - namely, full adders:

<img width="2560" height="1600" alt="image" src="https://github.com/user-attachments/assets/bdb27528-c063-4545-b3ae-54fc06a497de" />

