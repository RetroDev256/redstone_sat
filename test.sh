zig build run -- e &&
kissat problem.cnf --sat -v |
tee /dev/tty |
tee kissat.txt |
zig build run -- d |
tee result.txt