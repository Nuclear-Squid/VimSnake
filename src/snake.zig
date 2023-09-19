const std = @import("std");

// Local libs
const tui = @import("tui");
const Vec2      = @import("common-types").Vec2;
const Direction = @import("common-types").Direction;

pub const Game = struct {
    const nb_fruits = 5;
    pannel : tui.Pannel,
    snake  : Snake,
    fruits : [nb_fruits]Vec2(u16),
    prng   : std.rand.DefaultPrng,

    const Self = @This();

    pub fn init(window: *const tui.Window, dim_x: u16, dim_y: u16) !Self {
        const position = Vec2(u16) {
            .x = (window.dimensions.x - dim_x) / 2,
            .y = (window.dimensions.y - dim_y) / 2,
        };

        var rv = Self {
            .fruits = [_]Vec2(u16) { Vec2(u16) { .x = 0, .y = 0} } ** nb_fruits,
            .prng   = std.rand.DefaultPrng.init(@intCast(std.time.timestamp())),
            .snake  = try Snake.init(5, Direction.Right, 10, 10, std.heap.page_allocator),
            .pannel = try window.newPannel(
                dim_x, dim_y,
                position.x, position.y,
                0, 0
            ),
        };
        for (0..nb_fruits) |i| { rv.moveFruit(i); }
        return rv;
    }

    pub fn deinit(self: *Self) void {
        self.snake.deinit();
    }

    pub fn play(self: *Self) !void {
        game_loop: while (true) {
            // Handle keyboard input
            var buffer: [1]u8 = std.mem.zeroes([1]u8);
            _ = try self.pannel.tty.read(&buffer);
            switch (buffer[0]) {
                'q'  => break :game_loop,
                'h'  => self.snake.setDirection(Direction.Left),
                'j'  => self.snake.setDirection(Direction.Down),
                'k'  => self.snake.setDirection(Direction.Up),
                'l'  => self.snake.setDirection(Direction.Right),
                else => {},
            }

            try self.pannel.clear();
            if (self.snake.step(&self.pannel, &self.fruits) catch break :game_loop) |fruit_eaten_index| {
                self.moveFruit(fruit_eaten_index);
                while (self.snake.onAFruit(&self.fruits)) |i| {
                    self.moveFruit(i);
                }
            }
            try self.render();
            std.time.sleep(400_000_000);
        }

        try self.pannel.setCursor(0, 0);
        _ = try self.pannel.tty.writer().write("Game Over.");
        std.time.sleep(1_000_000_000);
    }

    fn moveFruit(self: *Self, fruit_index: usize) void {
        try_position: while (true) {
            const max_x = (self.pannel.dimensions.x - (self.pannel.padding.x * 2) - 1) / 2;
            const max_y =  self.pannel.dimensions.y - (self.pannel.padding.y * 2) - 1;
            const rng = self.prng.random();
            const new_fruit_pos = Vec2(u16) {
                .x = rng.uintLessThan(u16, max_x),
                .y = rng.uintLessThan(u16, max_y)
            };
            for (self.fruits) |fruit_pos| {
                if (std.meta.eql(fruit_pos, new_fruit_pos)) {
                    continue :try_position;
                }
            }

            var iter = self.snake.iterOverNodes();
            while (iter.next()) |node| {
                if (std.meta.eql(node.data, new_fruit_pos)) {
                    continue :try_position;
                }
            }
            self.fruits[fruit_index] = new_fruit_pos;
            return;
        }
    }

    fn render(self: *const Self) !void {
        const writer = self.pannel.tty.writer();
        _ = try writer.write("\x1b[41m");
        for (self.fruits) |fruit| {
            try self.pannel.setCursor(fruit.x * 2, fruit.y);
            _ = try writer.write("  ");
        }
        _ = try writer.write("\x1b[0m");

        var node_iter = self.snake.iterOverNodes();
        while (node_iter.next()) |node| {
            try self.pannel.setCursor(node.data.x * 2, node.data.y);
            try writer.print("\x1b[7m  \x1b[0m", .{});
        }
    }
};

const Snake = struct {
    allocator : std.mem.Allocator,
    nodes     : List,
    mouth_pos : Vec2(u16),
    facing    : Direction,

    const List = std.SinglyLinkedList(Vec2(u16));

    fn init(comptime len: u8, direction: Direction, posx: u16, posy: u16, allocator: std.mem.Allocator) !@This() {
        comptime { std.debug.assert(len > 0); }

        const head_position = Vec2(u16) { .x = posx, .y = posy };
        var nodes: ?*List.Node = null;

        for (0..len) |i| {
            var new_node = try allocator.create(List.Node);
            new_node.* = List.Node {
                .next = nodes,
                .data = head_position.stepBy(direction.getOpposite(), @intCast(i)),
            };
            nodes = new_node;
        }

        const mouth = nodes.?.findLast();
        mouth.*.next = nodes;
        return @This() {
            .allocator = allocator,
            .nodes     = List { .first = nodes, },
            .facing    = direction,
            .mouth_pos = mouth.data,
        };
    }

    fn deinit(self: *@This()) void {
        var node_iter = self.iterOverNodes();
        while (node_iter.next()) |node| {
            self.allocator.destroy(node);
        }
        self.nodes.first = null;
    }

    fn iterOverNodes(self: *const @This()) SnakeNodeIterator {
        return SnakeNodeIterator {
            .snake_arse   = self.nodes.first.?,
            .current_node = self.nodes.first,
        };
    }

    const SnakeNodeIterator = struct {
        snake_arse   :  *List.Node,
        current_node : ?*List.Node,

        fn next(self: *@This()) ?*List.Node {
            const rv = self.current_node orelse return null;
            self.current_node = rv.next.?;
            if (self.current_node == self.snake_arse) {
                self.current_node = null;
            }
            return rv;
        }
    };

    const StepError = error { Crashed };

    /// Returns the index of the fruit that was eaten, if there was one.
    fn step(self: *@This(), parent_pannel: *const tui.Pannel, fruits: []Vec2(u16)) (std.mem.Allocator.Error || StepError)!?usize {
        const new_mouth_pos = self.mouth_pos.stepBy(self.facing, 1);

        // Check snake is still inbounds
        if (new_mouth_pos.x == 0 or new_mouth_pos.x == (parent_pannel.dimensions.x / 2) - 1 or
            new_mouth_pos.y == 0 or new_mouth_pos.y == parent_pannel.dimensions.y - 1)
        {
            return StepError.Crashed;
        }

        // Check if snake ate itself
        var iter = self.iterOverNodes();
        _ = iter.next();  // ignore the soon-to-be new head
        while (iter.next()) |node| {
            if (std.meta.eql(new_mouth_pos, node.data)) {
                return StepError.Crashed;
            }
        }

        const rv =
            for (fruits, 0..) |fruit_pos, i| {
                if (std.meta.eql(new_mouth_pos, fruit_pos)) {
                    // Eat the fruit, and grow in length.
                    var new_tail = try self.allocator.create(List.Node);
                    new_tail.* = self.nodes.first.?.*;
                    self.nodes.first.?.next = new_tail;
                    break i;
                }
            }
            else null;

        // step forward
        self.nodes.first.?.data = new_mouth_pos;
        self.nodes.first = self.nodes.first.?.next;
        self.mouth_pos = new_mouth_pos;

        return rv;
    }

    fn onAFruit(self: *const @This(), fruits: []Vec2(u16)) ?usize {
        var iter = self.iterOverNodes();
        while (iter.next()) |node| {
            for (fruits, 0..) |fruit_pos, i| {
                if (std.meta.eql(node.data, fruit_pos)) return i;
            }
        }
        return null;
    }

    inline fn setDirection(self: *@This(), new_direction: Direction) void {
        if (self.facing.getOpposite() != new_direction) {
            self.facing = new_direction;
        }
    }
};

test "snake_nodes_iter" {
    const snake_len = 5;
    var snake = try Snake.init(snake_len, Direction.Right, 10, 10, std.testing.allocator);
    defer snake.deinit();

    var nb_nodes_seen: u32 = 0;
    var nodes_iter = snake.iterOverNodes();
    while (nodes_iter.next()) |node| {
        nb_nodes_seen += 1;
        std.debug.print("position of node: ({}, {})\n", .{ node.data.x, node.data.y });
    }

    std.debug.print("expected: {}, seen: {}", .{ snake_len, nb_nodes_seen });
    try std.testing.expect(nb_nodes_seen == snake_len);
}
