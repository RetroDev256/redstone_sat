zig build run -- e problem.zon problem.cnf &&
kissat problem.cnf --sat -v |
tee /dev/tty |
tee kissat.txt |
zig build run -- d problem.zon - |
tee result.txt
