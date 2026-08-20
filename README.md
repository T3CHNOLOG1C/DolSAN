# DolSAN

A sanitizer runtime for Gekko/Broadway (GameCube/Wii PowerPC) → x86_64/aarch64 native
recompilation projects, with a shadow-memory layout that doesn't collide with the fixed
low-memory address (`0x80000000`, GameCube "MEM1") these projects need to emulate at an
exact, non-relocatable host address.

**Status: planning only.** Nothing is implemented yet. Start with [PLANNING.md](PLANNING.md).

Motivating project: [OpenMelee](https://github.com/T3CHNOLOG1C/OpenMelee).
