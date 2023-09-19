const std = @import("std");

const snake = @import("snake");
const tui   = @import("tui");

pub fn main() !void {
    var window = try tui.Window.init();
    defer window.deinit() catch {};

    var game = try snake.Game.init(&window, 80, 30);
    defer game.deinit();

    try game.play();
}
