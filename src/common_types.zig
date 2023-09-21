pub const Direction = enum {
    Up, Right, Down, Left,
    const Self = @This();

    pub inline fn getOpposite(self: Self) Self {
        return switch (self) {
            Self.Up    => Self.Down,
            Self.Right => Self.Left,
            Self.Down  => Self.Up,
            Self.Left  => Self.Right,
        };
    }
};

pub fn Vec2(comptime T: type) type {
    return struct {
        x: T, y: T,
        const Self = @This();
        const D = Direction;

        pub inline fn stepBy(self: *const Self, direction: D, n_steps: u16) Self {
            return switch (direction) {
                D.Up    => Self { .x = self.x           , .y = self.y -| n_steps },
                D.Right => Self { .x = self.x +| n_steps, .y = self.y            },
                D.Down  => Self { .x = self.x           , .y = self.y +| n_steps },
                D.Left  => Self { .x = self.x -| n_steps, .y = self.y            },
            };
        }
    };
}
