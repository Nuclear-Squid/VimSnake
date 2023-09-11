const std = @import("std");
const os  = std.os;

pub fn main() !void {
    var tty = try std.fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    const original_termios = try os.tcgetattr(tty.handle);
    try uncookTermios(&tty, original_termios);
    defer recookTermios(&tty, original_termios) catch {};

    try tty.writer().writeAll("Hello World!");

    while (true) {
        var buffer: [1]u8 = undefined;
        _ = try tty.read(&buffer);
        if (buffer[0] == 'q') {
            return;
        }
    }
}

fn recookTermios(tty: *std.fs.File, original_termios: os.termios) !void {
    try os.tcsetattr(tty.*.handle, .FLUSH, original_termios);
    var writer = tty.writer();
    try writer.writeAll("\x1B[?25h");   // Show the cursor.
    try writer.writeAll("\x1B[?1049l"); // Disable alternative buffer.
    try writer.writeAll("\x1B[?47l");   // Restore screen.
    try writer.writeAll("\x1B[u");      // Restore cursor position.
}

fn uncookTermios(tty: *std.fs.File, base_termios: os.termios) !void {
    var termios = base_termios;
    //   ECHO: Stop the terminal from displaying pressed keys.
    // ICANON: Disable canonical ("cooked") input mode. Allows us to read inputs
    //         byte-wise instead of line-wise.
    //   ISIG: Disable signals for Ctrl-C (SIGINT) and Ctrl-Z (SIGTSTP), so we
    //         can handle them as "normal" escape sequences.
    // IEXTEN: Disable input preprocessing. This allows us to handle Ctrl-V,
    //         which would otherwise be intercepted by some terminals.
    termios.lflag &= ~@as(
        os.system.tcflag_t,
        os.system.ECHO   | os.system.ICANON | os.system.ISIG   | os.system.IEXTEN
    );

    //   IXON: Disable software control flow. This allows us to handle Ctrl-S
    //         and Ctrl-Q.
    //  ICRNL: Disable converting carriage returns to newlines. Allows us to
    //         handle Ctrl-J and Ctrl-M.
    // BRKINT: Disable converting sending SIGINT on break conditions. Likely has
    //         no effect on anything remotely modern.
    //  INPCK: Disable parity checking. Likely has no effect on anything
    //         remotely modern.
    // ISTRIP: Disable stripping the 8th bit of characters. Likely has no effect
    //         on anything remotely modern.
    termios.iflag &= ~@as(
        os.system.tcflag_t,
        os.system.IXON   | os.system.ICRNL  | os.system.BRKINT | os.system.INPCK  | os.system.ISTRIP
    );

    // Disable output processing. Common output processing includes prefixing
    // newline with a carriage return.
    termios.oflag &= ~@as(os.system.tcflag_t, os.system.OPOST);

    // Set the character size to 8 bits per byte. Likely has no efffect on
    // anything remotely modern.
    termios.cflag |= os.system.CS8;

    termios.cc[os.system.V.TIME] = 0;
    termios.cc[os.system.V.MIN]  = 0;

    try os.tcsetattr(tty.*.handle, .FLUSH, termios);

    var writer = tty.writer();
    try writer.writeAll("\x1B[?25l");   // Hide the cursor.
    try writer.writeAll("\x1B[s");      // Save cursor position.
    try writer.writeAll("\x1B[?47h");   // Save screen.
    try writer.writeAll("\x1B[?1049h"); // Enable alternative buffer.
}
