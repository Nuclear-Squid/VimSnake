const std = @import("std");
const os  = std.os;

// Local libs
const Vec2      = @import("common-types").Vec2;
const Direction = @import("common-types").Direction;

pub const Pannel = struct {
    /// Total dimensions of the Pannel (border included)
    dimensions : Vec2(u16),
    position   : Vec2(u16),
    padding    : Vec2(u16),
    tty        : *const std.fs.File,

    const Self = @This();

    pub inline fn toAbsolutePosition(self: *const Self, x: u16, y: u16) Vec2(u16) {
        return Vec2(u16) { // + 1 to account for the border
            .x = self.position.x + self.padding.x + 1 + x,
            .y = self.position.y + self.padding.y + 1 + y,
        };
    }

    pub inline fn getInnerDimensions(self: *const Self) Vec2(u16) {
        return Vec2(u16) {
            .x = self.dimensions.x - (self.padding.x + 1) * 2,
            .y = self.dimensions.y - (self.padding.y + 1) * 2,
        };
    }

    pub fn setCursor(self: *const Self, x: u16, y: u16) !void {
        const new_cursor = self.toAbsolutePosition(x, y);
        try self.tty.writer().print("\x1b[{};{}H", .{ new_cursor.y, new_cursor.x });
    }

    pub fn clear(self: *const Self) !void {
        const allocator = std.heap.page_allocator;
        const line = try allocator.alloc(u8, self.dimensions.x - 2);
        defer allocator.free(line);

        for (0..self.dimensions.x - 2) |i| {
            line[i] = ' ';
        }

        for (0..self.dimensions.y - 1) |i| {
            try self.setCursor(0, @intCast(i));
            try self.tty.writer().writeAll(line);
        }
    }
};

pub const Window = struct {
    tty              : std.fs.File,
    dimensions       : Vec2(u16),
    original_termios : os.system.termios,
    termios          : os.system.termios,

    const Self = @This();

    pub fn init() !Self {
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

        return Self {
            .tty = tty,
            .dimensions = Vec2(u16) { .x = size.ws_col, .y = size.ws_row },
            .original_termios = original_termios,
            .termios = termios,
        };
    }

    pub fn deinit(self: *Self) !void {
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

    pub fn newPannel(
        self: *const Self,
		dimx: u16, dimy: u16,
		posx: u16, posy: u16,
		padx: u16, pady: u16
    ) !Pannel {
        const allocator = std.heap.page_allocator;
        const writer = self.tty.writer();

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
            .tty        = &self.tty,
        };
    }
};

