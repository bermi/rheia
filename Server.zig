const std = @import("std");

const os = std.os;
const mem = std.mem;
const ip = std.x.net.ip;
const tcp = std.x.net.tcp;
const log = std.log.scoped(.server);

const binary = @import("binary.zig");

const assert = std.debug.assert;

const Lock = @import("Lock.zig");
const Loop = @import("Loop.zig");
const Packet = @import("Packet.zig");
const Worker = @import("Worker.zig");
const Runtime = @import("Runtime.zig");

const SinglyLinkedList = @import("intrusive.zig").SinglyLinkedList;

const Server = @This();

pub const Waiter = struct {
    next: ?*Waiter = null,
    worker_id: usize,
    task: Worker.Task,
};

pub const Connection = struct {
    worker_id: usize,
    client: tcp.Client,
    address: ip.Address,
    frame: @Frame(Server.serveConnection),

    done: bool,
    writer: ?*Worker.Task,
    queuer: ?*Worker.Task,

    queue: std.fifo.LinearFifo(u8, .Dynamic),
};

lock: Lock = .{},
connections: std.AutoArrayHashMapUnmanaged(*Server.Connection, void) = .{},

pending: struct {
    shutdown: SinglyLinkedList(Server.Waiter, .next) = .{},
} = .{},

pub fn init() Server {
    return .{};
}

pub fn deinit(self: *Server, gpa: *mem.Allocator) void {
    self.connections.deinit(gpa);
}

pub fn shutdown(self: *Server, runtime: *Runtime) void {
    self.lock.acquire();
    defer self.lock.release(runtime);

    var it = self.connections.iterator();
    while (it.next()) |entry| {
        entry.key_ptr.*.client.shutdown(.recv) catch {};
    }
}

pub fn waitForShutdown(self: *Server, runtime: *Runtime) callconv(.Async) void {
    self.lock.acquire();
    if (self.connections.count() > 0) {
        var waiter: Server.Waiter = .{
            .worker_id = Worker.getCurrent().id,
            .task = .{ .value = @frame() },
        };

        suspend {
            self.pending.shutdown.prepend(&waiter);
            self.lock.release(runtime);
        }
    } else {
        self.lock.release(runtime);
    }
}

pub fn serve(self: *Server, runtime: *Runtime, listener: tcp.Listener) !void {
    const address = try listener.getLocalAddress();

    log.info("listening for peers on {}", .{address});
    defer log.info("stopped listening for peers on {}", .{address});

    const loop = &Worker.getCurrent().loop;

    var next_worker_id: usize = 0;

    while (true) {
        const conn = loop.accept(listener.socket.fd, .{ .close_on_exec = true }) catch |err| switch (err) {
            error.SocketNotListening => return,
            else => return err,
        };
        errdefer conn.socket.deinit();

        const server_conn = try runtime.gpa.create(Server.Connection);
        errdefer runtime.gpa.destroy(server_conn);

        try self.register(runtime.gpa, runtime, server_conn);
        errdefer _ = self.deregister(runtime, server_conn);

        server_conn.worker_id = next_worker_id;
        defer next_worker_id = (next_worker_id + 1) % runtime.worker_count;

        server_conn.client = tcp.Client.from(conn.socket);
        server_conn.address = ip.Address.from(conn.address);

        server_conn.done = false;
        server_conn.writer = null;
        server_conn.queuer = null;

        server_conn.queue = std.fifo.LinearFifo(u8, .Dynamic).init(runtime.gpa);

        server_conn.frame = async self.serveConnection(runtime, server_conn);
    }
}

fn serveConnection(self: *Server, runtime: *Runtime, conn: *Server.Connection) !void {
    runtime.yield(conn.worker_id);

    defer {
        conn.queue.deinit();
        conn.client.deinit();

        var waiters = self.deregister(runtime, conn);
        suspend destroy(runtime, conn, waiters);
    }

    log.debug("new peer connected: {}", .{conn.address});
    defer log.debug("peer disconnected: {}", .{conn.address});

    try conn.client.setNoDelay(true);

    var writer_frame = async self.runWriteLoop(runtime, conn);
    var reader_frame = async self.runReadLoop(runtime, conn);

    await reader_frame catch {};
    await writer_frame catch {};
}

fn runReadLoop(_: *Server, runtime: *Runtime, conn: *Server.Connection) !void {
    defer {
        conn.done = true;
        if (conn.writer) |waiter| {
            conn.writer = null;
            runtime.schedule(waiter);
        }
    }

    const loop = &Worker.getCurrent().loop;

    var buffer = std.fifo.LinearFifo(u8, .Dynamic).init(runtime.gpa);
    defer buffer.deinit();

    var buf = std.ArrayList(u8).init(runtime.gpa);
    defer buf.deinit();

    while (true) {
        while (buffer.count < @sizeOf(u32)) {
            const num_bytes_read = try loop.recv(conn.client.socket.fd, try buffer.writableWithSize(65536), 0);
            if (num_bytes_read == 0) return error.EndOfFile;
            buffer.update(num_bytes_read);
        }

        var size: u32 = undefined;

        var size_pos: usize = 0;
        while (size_pos < @sizeOf(u32)) {
            size_pos += buffer.read(mem.asBytes(&size)[size_pos..]);
        }

        size = try binary.decode(u32, mem.asBytes(&size));
        if (size < @sizeOf(u32)) return error.MessageSizeTooSmall;
        if (size > 65536) return error.MessageSizeTooLarge;

        size -= @sizeOf(u32);

        while (buffer.count < size) {
            const num_bytes_read = try loop.recv(conn.client.socket.fd, try buffer.writableWithSize(65536), 0);
            if (num_bytes_read == 0) return error.EndOfFile;
            buffer.update(num_bytes_read);
        }

        const message = try runtime.gpa.alloc(u8, size);
        defer runtime.gpa.free(message); // make it errdefer after implementing message handling

        var message_pos: usize = 0;
        while (message_pos < size) {
            message_pos += buffer.read(message[message_pos..]);
        }

        const packet = try Packet.unmarshal(message);

        switch (packet.get(.type)) {
            .request => switch (packet.get(.tag)) {
                .ping => {
                    buf.clearRetainingCapacity();

                    var size_data = try binary.allocate(binary.Buffer.from(&buf), u32);
                    var body_data = try Packet.append(size_data.sliceFromEnd(), .{ .nonce = packet.get(.nonce), .@"type" = .response, .tag = .ping });
                    size_data = binary.writeAssumeCapacity(size_data.sliceFromStart(), @intCast(u32, size_data.len + body_data.len));

                    while (buf.items.len + conn.queue.count > 1 * 1024 * 1024) {
                        if (conn.done) return error.Closed;
                        var waiter: Worker.Task = .{ .value = @frame() };
                        suspend conn.queuer = &waiter;
                    }

                    try conn.queue.writer().writeAll(buf.items);

                    if (conn.writer) |waiter| {
                        conn.writer = null;
                        runtime.schedule(waiter);
                    }
                },
                else => {},
            },
            else => {},
        }
    }
}

fn runWriteLoop(_: *Server, runtime: *Runtime, conn: *Server.Connection) !void {
    defer {
        conn.done = true;
        if (conn.queuer) |queuer| {
            conn.queuer = null;
            runtime.schedule(queuer);
        }
    }

    const loop = &Worker.getCurrent().loop;

    var buffer: [65536]u8 = undefined;

    while (true) {
        if (conn.queue.count == 0) {
            if (conn.done) return error.Closed;
            var task: Worker.Task = .{ .value = @frame() };
            suspend conn.writer = &task;
            continue;
        }

        while (conn.queue.count > 0) {
            try writeAll(loop, conn.client, buffer[0..try conn.queue.reader().readAll(&buffer)]);
        }

        if (conn.queuer) |waiter| {
            conn.queuer = null;
            runtime.schedule(waiter);
        }
    }
}

fn writeAll(loop: *Loop, client: tcp.Client, buffer: []const u8) !void {
    var index: usize = 0;
    while (index < buffer.len) {
        index += try loop.send(client.socket.fd, buffer[index..], os.MSG_NOSIGNAL);
    }
}

fn register(self: *Server, gpa: *mem.Allocator, runtime: *Runtime, conn: *Server.Connection) !void {
    self.lock.acquire();
    defer self.lock.release(runtime);

    try self.connections.put(gpa, conn, {});
}

fn deregister(self: *Server, runtime: *Runtime, conn: *Server.Connection) SinglyLinkedList(Server.Waiter, .next) {
    self.lock.acquire();
    defer self.lock.release(runtime);

    assert(self.connections.swapRemove(conn));

    if (self.connections.count() > 0) {
        return .{};
    }

    const waiters = self.pending.shutdown;
    self.pending.shutdown = .{};

    return waiters;
}

fn destroy(runtime: *Runtime, conn: *Server.Connection, waiters: SinglyLinkedList(Server.Waiter, .next)) void {
    var it = waiters;

    runtime.gpa.destroy(conn);

    while (it.popFirst()) |waiter| {
        runtime.scheduleTo(waiter.worker_id, &waiter.task);
    }
}
