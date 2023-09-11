const std = @import("std");
const os  = std.os;

const Window = struct {
    tty              : std.fs.File,
    width            : u16,
    height           : u16,
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
            // The following flags are likely to have no effect on any modern terminal
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
            .tty     = tty,
            .height  = size.ws_row,
            .width   = size.ws_col,
            .original_termios = original_termios,
            .termios = termios
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
    var window = try Window.init();
    defer window.deinit() catch {};

    const writer = window.tty.writer();
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
