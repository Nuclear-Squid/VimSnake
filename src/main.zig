const std = @import("std");
const os  = std.os;

fn Vec2(comptime T: type) type {
    return struct {
        x: T,
        y: T,

        fn new(x: T, y: T) @This() {
            return @This() { .x = x, .y = y };
        }
    };
}

const Pannel = struct {
    /// Total dimensions of the Pannel (border included)
    dimensions    : Vec2(u16),
    position      : Vec2(u16),
    padding       : Vec2(u16),

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
            .dimensions = Vec2(u16).new(dimx, dimy),
            .position   = Vec2(u16).new(posx, posy),
            .padding    = Vec2(u16).new(padx, pady),
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
};

const Window = struct {
    tty              : std.fs.File,
    dimensions       : Vec2(u16),
    original_termios : os.system.termios,
    termios          : os.system.termios,
    pannels          : std.ArrayList(Pannel),

    fn init(allocator: std.mem.Allocator) !@This() {
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
        termios.cc[os.system.V.MIN]  = 1;

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
            .dimensions = Vec2(u16) { .x = size.ws_row, .y = size.ws_col },
            .original_termios = original_termios,
            .termios = termios,
            .pannels = std.ArrayList(Pannel).init(allocator),
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var window = try Window.init(allocator);
    defer window.deinit() catch {};

    const writer = window.tty.writer();
    const pannel = try Pannel.new(writer, 25, 5, 4, 2, 2, 0);
    try pannel.setCursor(writer, 0, 0);

    for ("Hello World!") |char| {
        std.time.sleep(100_000_000);  // Sleep takes nanoseconds
        try writer.writeByte(char);
    }

    while (true) {
        var buffer: [1]u8 = undefined;
        _ = try window.tty.read(&buffer);
        if (buffer[0] == 'q') {
            return;
        }
        try writer.writeAll(&buffer);
    }
}
