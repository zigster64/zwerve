const std = @import("std");

const Server = std.http.Server;
const net = std.net;
const expect = std.testing.expect;

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to {s}.\n", .{ "drift", "zwerve" });

    var server = Server.init(std.heap.page_allocator, .{ .reuse_address = true, .kernel_backlog = 4096 });
    defer server.deinit();

    try server.listen(try net.Address.parseIp("127.0.0.1", 8080));

    while (true) {
        // var buf: [8192]u8 = undefined;
        // _ = buf;
        std.log.info("Waiting for a new connection ...", .{});
        // const res = try server.accept(.{ .static = &buf }); // use a buffer for headers
        const res = try server.accept(.{ .dynamic = 8192 });

        // try handler(res);
        const thread = try std.Thread.spawn(.{}, handler, .{res});
        thread.detach();
    }
}

fn handler(res: *Server.Response) !void {
    std.log.info("New thread started ...", .{});
    try res.headers.append("server", "zwerve");
    while (true) { // because keepalive
        defer res.reset();

        res.wait() catch {
            std.log.info("Client disconnected ...", .{});
            break;
        };

        if (std.os.getenv("ZFIX") != null) {
            const req_connection = res.request.headers.getFirstValue("connection");
            const req_keepalive = req_connection != null and !std.ascii.eqlIgnoreCase("close", req_connection.?);
            if (req_keepalive) {
                res.connection.conn.closing = false;
            }
        }

        std.log.info("{s}: {}-> {s}", .{ getDate(), res.request.method, res.request.target });

        switch (res.request.method) {
            .GET => {
                if (res.request.target.len > 1) {
                    try sendfile(res, res.request.target[1..]);
                } else {
                    try sendfile(res, "index.html");
                }
            },
            else => {
                res.transfer_encoding = .{ .content_length = res.request.target.len };
                try res.do();
                try res.writer().writeAll(res.request.target);
                try res.finish();
            },
        }

        if (res.connection.conn.closing) break;
    }
    std.log.info("Thread ended ...", .{});
}

fn sendfile(res: *std.http.Server.Response, filename: []const u8) !void {
    var file = std.fs.cwd().openFile(filename, .{}) catch {
        res.status = .not_found;
        res.transfer_encoding = .{ .content_length = filename.len + 7 };
        try res.do();
        try res.writer().writeAll(filename);
        try res.writer().writeAll(": wuh?\n");
        try res.finish();
        return;
    };

    defer file.close();
    const file_len = try file.getEndPos();

    res.transfer_encoding = .{ .content_length = file_len };
    try res.do();

    const zero_iovec = &[0]std.os.iovec_const{};
    var send_total: usize = 0;

    while (true) {
        const send_len = std.os.sendfile(res.connection.conn.stream.handle, file.handle, send_total, file_len, zero_iovec, zero_iovec, 0) catch |err| {
            std.log.err("sendFile error {}", .{err});
            return err;
        };

        if (send_len == 0)
            break;

        send_total += send_len;
    }
}

fn getDate() []const u8 {
    // const res: [14:0]u8 = "20060102 10:00";
    const res = "20060102 10:00";
    const now = std.time.timestamp();
    // const enow = std.time.epoch.now();
    _ = now;

    return res[0..14];
}

test "test server copypasted from the std.http.server patches" {
    const allocator = std.testing.allocator;
    // const allocator = std.heap.page_allocator;

    const max_header_size = 8192;
    var server = std.http.Server.init(allocator, .{ .reuse_address = true });
    defer server.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 8080);
    try server.listen(address);
    const server_port = server.socket.listen_address.in.getPort();
    _ = server_port;

    const thread = try std.Thread.spawn(.{}, (struct {
        fn apply(s: *std.http.Server) !void {
            const res = try s.accept(.{ .dynamic = max_header_size });
            defer allocator.destroy(res);
            defer res.reset();
            try res.wait();

            const server_body: []const u8 = "message from server!\n";
            res.transfer_encoding = .{ .content_length = server_body.len };
            try res.headers.append("content-type", "text/plain");
            try res.headers.append("connection", "close");
            try res.do();
            defer res.headers.deinit();
            defer res.request.headers.deinit();

            var buf: [128]u8 = undefined;
            const n = try res.readAll(&buf);
            try expect(std.mem.eql(u8, buf[0..n], "Hello World"));
            std.debug.print("!!! after server expect\n", .{});
            _ = try res.writer().writeAll(server_body);
            try res.finish();
        }
    }).apply, .{&server});

    thread.join();
    std.debug.print("!!! test finished\n", .{});
}
