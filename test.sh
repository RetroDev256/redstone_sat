zig build run -- e
cadical out.cnf | tee out.txt
cat out.txt | zig build run -- d
