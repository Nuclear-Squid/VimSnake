const std = @import("std");

// Local modules
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
        try self.render();
        game_loop: while (true) {
            std.time.sleep(400_000_000);
            // Handle keyboard input
            var buffer: [1]u8 = std.mem.zeroes([1]u8);
            _ = try self.pannel.tty.read(&buffer);

            const command = Snake.Command {
                .direction = switch (buffer[0]) {
                    'q' => break :game_loop,
                    'h', 'b', '^' => Direction.Left,
                    'j', '}', 'G' => Direction.Down,
                    'k', '{', 'g' => Direction.Up,
                    'l', 'w', '$' => Direction.Right,
                    else => self.snake.facing,
                },
                .action = switch (buffer[0]) {
                    'h', 'j', 'k', 'l' => Snake.Action.step,
                    'b', '{', '}', 'w' => Snake.Action.leap,
                    '$', 'G', 'g', '^' => Snake.Action.go_to_edge,
                    else => Snake.Action.step,
                },
            };

            const new_head_position = self.snake
                    .getNewHeadPosition(command, self.pannel.getInnerDimensions())
                    catch break :game_loop;
            
            for (self.fruits, 0..) |fruit, fruit_pos| {
                if (std.meta.eql(new_head_position, fruit)) {
                    try self.snake.growWithNewHead(new_head_position);
                    self.moveFruit(fruit_pos);
                    break;
                }
            }
            else {
                self.snake.applyNewHead(new_head_position);
            }

            if (command.action == Snake.Action.go_to_edge) {
                self.snake.facing = command.direction.getOpposite();
            }
            else {
                self.snake.facing = command.direction;
            }

            try self.pannel.clear();
            try self.render();
        }

        try self.pannel.setCursor(0, 0);
        _ = try self.pannel.tty.writer().write("Game Over.");
        std.time.sleep(1_000_000_000);
    }

    fn moveFruit(self: *Self, fruit_index: usize) void {
        try_position: while (true) {
            const pannel_dim = self.pannel.getInnerDimensions();
            const rng = self.prng.random();

            const new_fruit_pos = Vec2(u16) {
                .x = rng.uintLessThan(u16, pannel_dim.x / 2),
                .y = rng.uintLessThan(u16, pannel_dim.y)
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

    const Self = @This();
    const List = std.SinglyLinkedList(Vec2(u16));

    fn init(comptime len: u8, direction: Direction, posx: u16, posy: u16, allocator: std.mem.Allocator) !Self {
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
        return Self {
            .allocator = allocator,
            .nodes     = List { .first = nodes, },
            .facing    = direction,
            .mouth_pos = mouth.data,
        };
    }

    fn deinit(self: *Self) void {
        var node_iter = self.iterOverNodes();
        while (node_iter.next()) |node| {
            self.allocator.destroy(node);
        }
        self.nodes.first = null;
    }

    fn iterOverNodes(self: *const Self) NodeIterator {
        return NodeIterator {
            .snake_arse   = self.nodes.first.?,
            .current_node = self.nodes.first,
        };
    }

    const NodeIterator = struct {
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

    const Action  = enum { step, leap, go_to_edge };
    const Command = struct {
        action   : Action,
        direction: Direction,
    };

    const StepError = error { crashed };

    fn getNewHeadPosition(self: *const Self, command: Command, pannel_dim: Vec2(u16)) StepError!Vec2(u16) {
        const new_head_position = switch (command.action) {
            Action.step => self.mouth_pos.stepBy(command.direction, 1),
            Action.leap => self.mouth_pos.stepBy(command.direction, 5),
            Action.go_to_edge => switch (command.direction) {
                Direction.Up    => Vec2(u16) { .x = self.mouth_pos.x, .y = 0 },
                Direction.Down  => Vec2(u16) { .x = self.mouth_pos.x, .y = pannel_dim.y },
                Direction.Left  => Vec2(u16) { .x = 0, .y = self.mouth_pos.y },
                Direction.Right => Vec2(u16) { .x = pannel_dim.x / 2 - 1, .y = self.mouth_pos.y },
            },
        };

        if (new_head_position.x > pannel_dim.x / 2 - 1 or
            new_head_position.y > pannel_dim.y)
        {
            return StepError.crashed;
        }

        var iter = self.iterOverNodes();
        while (iter.next()) |node| {
            if (std.meta.eql(node.data, new_head_position)) {
                return StepError.crashed;
            }
        }

        return new_head_position;
    }

    inline fn applyNewHead(self: *Self, new_mouth_pos: Vec2(u16)) void {
        self.nodes.first.?.data = new_mouth_pos;
        self.nodes.first = self.nodes.first.?.next;
        self.mouth_pos = new_mouth_pos;
    }

    inline fn growWithNewHead(self: *Self, new_mouth_pos: Vec2(u16)) std.mem.Allocator.Error!void {
        var new_tail = try self.allocator.create(List.Node);
        new_tail.* = self.nodes.first.?.*;
        self.nodes.first.?.next = new_tail;
        self.applyNewHead(new_mouth_pos);
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
