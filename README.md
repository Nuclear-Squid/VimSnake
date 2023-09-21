# VimSnake

VimSnake is a small TUI game based on the famous "snake game", but with a
twist : you control the snake using vim commands!

That means using `hjkl` to turn the snake around, but also `b}{w` to make the
snake leap forward 5 tiles at a time, and `^Gg$` for the snake to snap to the
borders.

## Roadmap

- [X] Functionnal game
- [ ] Score system
- [ ] Pretty main menu
- [ ] Different game modes ?

## Install

This game is written in [Zig 0.11.0](https://ziglang.org/download/).

Just install zig, clone the repo, run `zig build run` and you’re good to go !
