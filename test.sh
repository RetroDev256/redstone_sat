zig build run -- e &&
kissat problem.cnf --factor=false --sat -v |
tee /dev/tty |
tee kissat.txt |
zig build run -- d |
tee result.txt