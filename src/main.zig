const clap = @import("clap");
const std = @import("std");

const Result = struct {
    time: f64,
    failed: bool,
};

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_impl.allocator();
    defer _ = gpa_impl.deinit();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help                  Display this help and exit.
        \\-n, --number <u32>          Number of rounds to fire
        \\-c, --clients <u32>         Amount of clients per round
        \\<str>
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{ .diagnostic = &diag, .allocator = gpa }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }
    if (res.positionals.len != 1) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});
    }
    if (res.args.number == 0) {
        res.args.number = 1;
    }
    const rounds_number: u32 = res.args.number orelse 1;
    const clients_count: u32 = res.args.clients orelse 1;

    for (0..rounds_number) |_| {
        try sendRequests(clients_count, res.positionals[0]);
    }
}

fn sendRequests(count: u32, url: []const u8) !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa = gpa_impl.allocator();
    defer _ = gpa_impl.deinit();

    const threads = try gpa.alloc(std.Thread, count);
    defer gpa.free(threads);

    const location = std.http.Client.FetchOptions.Location{ .url = url };
    const options = std.http.Client.FetchOptions{ .method = std.http.Method.GET, .location = location };

    var client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const results = try gpa.alloc(Result, count);
    defer gpa.free(results);

    for (threads, 0..) |*thread, i| {
        thread.* = std.Thread.spawn(.{}, fetch, .{ &client, options, &results[i] }) catch unreachable;
    }

    var success_count: u8 = 0;
    var failure_count: u8 = 0;

    for (threads) |*thread| {
        defer {
            thread.join();
        }
    }

    var total_time_ms: f64 = 0;
    for (results) |r| {
        if (r.failed) {
            failure_count += 1;
        } else {
            success_count += 1;
            total_time_ms += r.time;
        }
    }

    const avg_time: f64 = if (success_count > 0) total_time_ms / @as(f64, @floatFromInt(success_count)) else 0.0;

    std.debug.print("Average response time: {d:.3} ms\n", .{avg_time});
    std.debug.print("Success: {}\n", .{success_count});
    std.debug.print("Failures: {}\n", .{failure_count});
}

fn fetch(client: *std.http.Client, options: std.http.Client.FetchOptions, r: *Result) !void {
    const start = try std.time.Instant.now();
    const result: std.http.Client.FetchResult = client.fetch(options) catch |err| {
        std.debug.print("{!}", .{err});
        r.failed = true;
        return;
    };
    const status = @intFromEnum(result.status);

    if (status >= 500) {
        r.failed = true;
    } else {
        r.failed = false;
        const end = try std.time.Instant.now();
        r.time = @as(f64, @floatFromInt(end.since(start))) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    }
}
