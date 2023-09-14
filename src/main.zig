const std = @import("std");
const os  = std.os;

const Direction = enum {
    Up, Right, Down, Left,
    const Self = @This();

    inline fn getOpposite(self: Self) Self {
        return switch (self) {
            Self.Up    => Self.Down,
            Self.Right => Self.Left,
            Self.Down  => Self.Up,
            Self.Left  => Self.Right,
        };
    }
};

fn Vec2(comptime T: type) type {
    return struct {
        x: T, y: T,
        const Self = @This();

        inline fn stepBy(self: *const Self, direction: Direction, n_steps: u16) Self {
            return switch (direction) {
                Direction.Up    => Self { .x = self.x           , .y = self.y -| n_steps },
                Direction.Right => Self { .x = self.x +| n_steps, .y = self.y            },
                Direction.Down  => Self { .x = self.x           , .y = self.y +| n_steps },
                Direction.Left  => Self { .x = self.x -| n_steps, .y = self.y            },
            };
        }
    };
}

const Pannel = struct {
    /// Total dimensions of the Pannel (border included)
    dimensions : Vec2(u16),
    position   : Vec2(u16),
    padding    : Vec2(u16),

    fn new(writer: anytype, dimx: u16, dimy: u16, posx: u16, posy: u16, padx: u16, pady: u16) !@This() {
        const allocator = std.heap.page_allocator;

        const line = try allocator.alloc(u8, dimx - 2);
        defer allocator.free(line);
        for (0..line.len) |i| { line[i] = '-'; }

        try writer.print("\x1b[{};{}H+{s}+", .{ posy, posx, line });
        try writer.print("\x1b[{};{}H+{s}+", .{ posy + dimy, posx, line });

        for (1..dimy) |i| {
            try writer.print("\x1b[{};{}H|", .{ posy + i, posx });
            try writer.print("\x1b[{};{}H|", .{ posy + i, posx + dimx - 1 });
        }


        return Pannel {
            .dimensions = Vec2(u16) { .x = dimx, .y = dimy },
            .position   = Vec2(u16) { .x = posx, .y = posy },
            .padding    = Vec2(u16) { .x = padx, .y = pady },
        };
    }

    fn toAbsolutePosition(self: @This(), x: u16, y: u16) Vec2(u16) {
        return Vec2(u16) {
            // + 1 to account for the border
            .x = self.position.x + self.padding.x + 1 + x,
            .y = self.position.y + self.padding.y + 1 + y,
        };
    }

    fn setCursor(self: @This(), writer: anytype, x: u16, y: u16) !void {
        const new_cursor = self.toAbsolutePosition(x, y);
        try writer.print("\x1b[{};{}H", .{ new_cursor.y, new_cursor.x });
    }

    fn clear(self: *const @This(), writer: anytype) !void {
        const allocator = std.heap.page_allocator;
        const line = try allocator.alloc(u8, self.dimensions.x - 2);
        defer allocator.free(line);

        for (0..self.dimensions.x - 2) |i| {
            line[i] = ' ';
        }

        for (0..self.dimensions.y - 1) |i| {
            try self.setCursor(writer, 0, @intCast(i));
            try writer.writeAll(line);
        }
    }
};

const Window = struct {
    tty              : std.fs.File,
    dimensions       : Vec2(u16),
    original_termios : os.system.termios,
    termios          : os.system.termios,

    fn init() !@This() {
        // Get acces to the terminal window
        var tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });

        // Get terminal size, manually handle exit status because the api is weird
        var size = std.mem.zeroes(os.system.winsize);
        const status = os.system.ioctl(tty.handle, os.system.T.IOCGWINSZ, @intFromPtr(&size));
        if (os.errno(status) != .SUCCESS) {
            return os.unexpectedErrno(@enumFromInt(status));
        }

        // Get termios to "uncook" tty. Keep original to set tty to its original state later
        const original_termios = try os.tcgetattr(tty.handle);
        var termios = original_termios;

        // Uncook termios
        termios.lflag &= ~@as(os.system.tcflag_t,
            os.system.ECHO   |  // Stop the terminal from displaying pressed keys.
            os.system.ICANON |  // Allows reading inputs byte-wise instead of line-wise.
            os.system.ISIG   |  // Disable signals for Ctrl-C and Ctrl-Z.
            os.system.IEXTEN    // Disable input preprocessing to handle Ctrl-V.
        );

        termios.iflag &= ~@as(os.system.tcflag_t,
            os.system.IXON   |  // Disable software control flow for Ctrl-S and Ctrl-Q.
            os.system.ICRNL  |  // Disable carriage returns to handle Ctrl-J and Ctrl-M.
            // The following flags are likely to have no effect on any modern terminal
            os.system.BRKINT |  // Disable converting sending SIGINT on break conditions.
            os.system.INPCK  |  // Disable parity checking.
            os.system.ISTRIP    // Disable stripping the 8th bit of characters.
        );

        // Disable output processing.
        termios.oflag &= ~@as(os.system.tcflag_t, os.system.OPOST);

        // Set the character size to 8 bits per byte. Likely has no efffect on
        // anything remotely modern.
        termios.cflag |= os.system.CS8;

        // Syscall stuff, don’t really get it.
        termios.cc[os.system.V.TIME] = 0;
        termios.cc[os.system.V.MIN]  = 0;

        // Apply changes
        try os.tcsetattr(tty.handle, .FLUSH, termios);

        // Create Tui window
        try tty.writer().writeAll(
            "\x1B[?25l"   ++ // Hide the cursor.
            "\x1B[s"      ++ // Save cursor position.
            "\x1B[?47h"   ++ // Save screen.
            "\x1B[?1049h"    // Enable alternative buffer.
        );

        return @This() {
            .tty = tty,
            .dimensions = Vec2(u16) { .x = size.ws_col, .y = size.ws_row },
            .original_termios = original_termios,
            .termios = termios,
        };
    }

    fn deinit(self: *@This()) !void {
        // reset original termios
        try os.tcsetattr(self.*.tty.handle, .FLUSH, self.*.original_termios);
        // return to previous terminal view
        try self.*.tty.writer().writeAll(
            "\x1B[?25h"   ++ // Show the cursor.
            "\x1B[?1049l" ++ // Disable alternative buffer.
            "\x1B[?47l"   ++ // Restore screen.
            "\x1B[u"         // Restore cursor position.
        );
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

    fn iterOverNodes(self: *@This()) SnakeNodeIterator {
        return SnakeNodeIterator {
            .snake_arse   = self.nodes.first.?,
            .current_node = self.nodes.first,
        };
    }

    fn render(self: *@This(), writer: anytype, parent_pannel: Pannel) !void {
        var node_iter = self.iterOverNodes();
        while (node_iter.next()) |node| {
            try parent_pannel.setCursor(writer, node.data.x * 2, node.data.y);
            try writer.print("\x1b[7m  \x1b[0m", .{});
        }
    }

    fn step(self: *@This()) void {
        const new_mouth_pos = self.mouth_pos.stepBy(self.facing, 1);
        self.nodes.first.?.data = new_mouth_pos;
        self.nodes.first = self.nodes.first.?.next;
        self.mouth_pos = new_mouth_pos;
    }

    inline fn setDirection(self: *@This(), new_direction: Direction) void {
        if (self.facing.getOpposite() != new_direction) {
            self.facing = new_direction;
        }
    }
};

const SnakeNodeIterator = struct {
    snake_arse   :  *List.Node,
    current_node : ?*List.Node,

    const List = std.SinglyLinkedList(Vec2(u16));

    fn next(self: *@This()) ?*List.Node {
        const rv = self.current_node orelse return null;
        self.current_node = rv.next.?;
        if (self.current_node == self.snake_arse) {
            self.current_node = null;
        }
        return rv;
    }
};


pub fn main() !void {
    var window = try Window.init();
    defer window.deinit() catch {};

    const writer = window.tty.writer();
    const allocator = std.heap.page_allocator;

    const game_pannel_dimensions = Vec2(u16) { .x = 80, .y = 30 };
    const game_pannel_posision = Vec2(u16) {
        .x = (window.dimensions.x - game_pannel_dimensions.x) / 2,
        .y = (window.dimensions.y - game_pannel_dimensions.y) / 2,
    };

    const pannel = try Pannel.new(writer,
        game_pannel_dimensions.x, game_pannel_dimensions.y,
        game_pannel_posision.x, game_pannel_posision.y,
        0, 0
    );

    var snake = try Snake.init(5, Direction.Right, 10, 10, allocator);
    defer snake.deinit();

    game_loop: while (true) {
        // Handle keyboard input
        var buffer: [1]u8 = std.mem.zeroes([1]u8);
        _ = try window.tty.read(&buffer);
        switch (buffer[0]) {
            'q' => break :game_loop,
            'h' => snake.setDirection(Direction.Left),
            'j' => snake.setDirection(Direction.Down),
            'k' => snake.setDirection(Direction.Up),
            'l' => snake.setDirection(Direction.Right),
            else => {},
        }

        try pannel.clear(writer);
        snake.step();
        try snake.render(writer, pannel);
        std.time.sleep(100_000_000);
    }
}


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
