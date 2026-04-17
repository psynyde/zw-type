const std = @import("std");
const builtin = @import("builtin");
const wayland = @import("wayland");

const wl = wayland.client.wl;
const input = wayland.client.zwp;

const SeatInfo = struct {
    seat: *wl.Seat,
    name: []const u8,
};

const Client = struct {
    allocator: std.mem.Allocator,

    input_manager: ?*input.InputMethodManagerV2 = null,

    seats: std.ArrayList(SeatInfo),

    ime: ?*input.InputMethodV2 = null,
    ime_active: bool = false,
    ime_unavailable: bool = false,
    serial: u32 = 0,
};

const Options = struct {
    show_help: bool = false,
    list_seats: bool = false,
    seat_name: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

fn parseOptions(args: []const []const u8) !Options {
    var opts = Options{};
    var i: usize = 1; // skip argv[0]
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.show_help = true;
        } else if (std.mem.eql(u8, arg, "--list-seats")) {
            opts.list_seats = true;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--seat")) {
            i += 1;
            if (i >= args.len) return error.MissingSeatName;
            opts.seat_name = args[i];
        } else {
            opts.text = arg;
            break;
        }
    }
    return opts;
}

fn seatListener(
    seat: *wl.Seat,
    event: wl.Seat.Event,
    client: *Client,
) void {
    switch (event) {
        .name => |name| {
            const duped = client.allocator.dupe(
                u8,
                std.mem.span(name.name),
            ) catch return;

            client.seats.append(client.allocator, .{
                .name = duped,
                .seat = seat,
            }) catch {};
        },
        .capabilities => {},
    }
}

fn registryListener(
    registry: *wl.Registry,
    event: wl.Registry.Event,
    client: *Client,
) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, input.InputMethodManagerV2.interface.name) == .eq) {
                client.input_manager =
                    registry.bind(global.name, input.InputMethodManagerV2, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                const seat =
                    registry.bind(global.name, wl.Seat, 2) catch return;
                seat.setListener(*Client, seatListener, client);
            }
        },
        .global_remove => {},
    }
}

fn imeListener(
    _: *input.InputMethodV2,
    event: input.InputMethodV2.Event,
    client: *Client,
) void {
    switch (event) {
        .activate => client.ime_active = true,
        .deactivate => client.ime_active = false,
        .done => client.serial += 1,
        .unavailable => client.ime_unavailable = true,

        // required but unused
        .surrounding_text => {},
        .text_change_cause => {},
        .content_type => {},
    }
}

fn printSeats(stdout: *std.Io.Writer, seats: []const SeatInfo, default_seat: ?*wl.Seat) !void {
    if (seats.len == 0) {
        try stdout.print("No seats found\n", .{});
        try stdout.flush();
        return;
    }

    try stdout.print("Available seats:\n", .{});

    for (seats) |s| {
        const is_default = default_seat != null and s.seat == default_seat.?;
        try stdout.print(
            "  {s}{s}\n",
            .{ s.name, if (is_default) " (default)" else "" },
        );
    }
    try stdout.flush();
}

fn printHelp(stdout: *std.Io.Writer) !void {
    try stdout.print(
        \\Usage: zw-type [options] <text>
        \\
        \\Options:
        \\  -h, --help           Show this help message
        \\  -s, --seat <name>    Select seat by name
        \\      --list-seats     List available seats and exit
        \\
    , .{});
    try stdout.flush();
}

fn selectSeat(
    seats: []const SeatInfo,
    seat_name: ?[]const u8,
) !*wl.Seat {
    if (seats.len == 0)
        return error.NoSeat;

    if (seat_name == null)
        return seats[0].seat;

    for (seats) |s| {
        if (std.mem.eql(u8, s.name, seat_name.?))
            return s.seat;
    }

    return error.SeatNotFound;
}

fn readInput(allocator: std.mem.Allocator, io: std.Io, opts: Options) ![]u8 {
    if (opts.text) |text| {
        return allocator.dupe(u8, text);
    }

    if (!try std.Io.File.isTty(.stdin(), io)) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_file_reader: std.Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
        const stdin_reader = &stdin_file_reader.interface;

        const text = try stdin_reader.allocRemaining(allocator, .unlimited);
        if (text.len == 0)
            return error.EmptyInput;

        return text;
    }
    return error.NoInputProvided;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const args = try init.args.toSlice(allocator);
    const opts = try parseOptions(args);

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    const display = try wl.Display.connect(null);
    defer display.disconnect();

    const registry = try display.getRegistry();
    defer registry.destroy();

    var client = Client{
        .allocator = allocator,
        .seats = .empty,
    };

    registry.setListener(*Client, registryListener, &client);

    // First roundtrip: globals
    _ = display.roundtrip();
    // Second roundtrip: seat names
    _ = display.roundtrip();

    const default_seat =
        if (client.seats.items.len > 0) client.seats.items[0].seat else null;

    if (opts.show_help) {
        try printHelp(stdout);
        return;
    }

    if (opts.list_seats) {
        try printSeats(stdout, client.seats.items, default_seat);
        return;
    }

    const text = readInput(allocator, io, opts) catch |err| {
        switch (err) {
            error.NoInputProvided => {
                try printHelp(stdout);
                return;
            },
            else => return err,
        }
    };

    const seat = try selectSeat(client.seats.items, opts.seat_name);

    const input_manager = client.input_manager orelse
        return error.NoInputManager;

    const ime = try input_manager.getInputMethod(seat);
    client.ime = ime;

    ime.setListener(*Client, imeListener, &client);

    // Wait for activation
    while (!client.ime_active and !client.ime_unavailable) {
        // BUG: display.dispatch(); is hanging at first run
        // after login, on some specific configuration.
        if (display.dispatch() != .SUCCESS)
            return error.DispatchFailed;
    }

    if (client.ime_unavailable)
        return error.ImeUnavailable;

    const max_chunk_size = 4000;
    var offset: usize = 0;

    while (offset < text.len) {
        var end = @min(offset + max_chunk_size, text.len);

        // NOTE: Adjust 'end' to avoid splitting a UTF-8 multibyte character.
        // A continuation byte in UTF-8 starts with 10xxxxxx (0x80 to 0xBF).
        // (byte & 0xC0) == 0x80 checks for this exactly.

        if (end < text.len) {
            while (end > offset and (text[end] & 0xC0) == 0x80) {
                end -= 1;
            }
        }

        const chunk = text[offset..end];
        const c_chunk = try allocator.dupeSentinel(u8, chunk, 0);

        ime.commitString(c_chunk);
        ime.commit(client.serial);

        _ = display.roundtrip();

        offset = end;
    }

    ime.destroy();
    input_manager.destroy();
}
