const std = @import("std");
const net = @import("net.zig");
const sync = @import("sync.zig");
const crypto = @import("crypto.zig");
const runtime = @import("runtime.zig");

const io = std.io;
const os = std.os;
const ip = std.x.net.ip;
const fmt = std.fmt;
const mem = std.mem;
const tcp = std.x.net.tcp;
const math = std.math;
const time = std.time;
const testing = std.testing;

const IPv4 = std.x.os.IPv4;
const Context = runtime.Context;
const Blake3 = std.crypto.hash.Blake3;
const Ed25519 = std.crypto.sign.Ed25519;
const HashMap = @import("hash_map.zig").HashMap;
const SinglyLinkedList = @import("intrusive.zig").SinglyLinkedList;

const assert = std.debug.assert;

pub const log_level = .debug;

pub fn main() !void {
    const log = std.log.scoped(.main);

    try runtime.init();
    defer runtime.deinit();

    var frame = async run();
    defer nosuspend await frame catch |err| log.crit("{}", .{err});

    try runtime.run();
}

pub fn run() !void {
    const log = std.log.scoped(.main);

    defer runtime.shutdown();

    log.info("press ctrl+c to commence graceful shutdown", .{});

    var ctx: Context = .{};
    defer ctx.cancel();

    var node: Node = undefined;
    try node.init(runtime.getAllocator());
    defer {
        var shutdown_ctx: Context = .{};
        defer shutdown_ctx.cancel();

        if (node.deinit(&shutdown_ctx, runtime.getAllocator())) |_| {
            log.info("node successfully shutdown", .{});
        } else |err| {
            log.warn("node reported an error while shutting down: {}", .{err});
        }
    }

    var node_frame = async node.run(&ctx, runtime.getAllocator());
    defer await node_frame catch |err| log.warn("node error: {}", .{err});

    var listener = try tcp.Listener.init(.ip, .{ .close_on_exec = true });
    defer listener.deinit();

    try listener.setReuseAddress(true);
    try listener.setReusePort(true);
    try listener.setFastOpen(true);

    try listener.bind(ip.Address.initIPv4(IPv4.unspecified, 9000));
    try listener.listen(128);

    var server = net.Server(Node).init(&node);
    defer {
        var shutdown_ctx: Context = .{};
        defer shutdown_ctx.cancel();

        if (server.deinit(&shutdown_ctx)) |_| {
            log.info("server successfully shutdown", .{});
        } else |err| {
            log.warn("server reported an error while shutting down: {}", .{err});
        }
    }

    var server_frame = async server.serve(&ctx, runtime.getAllocator(), listener);
    defer await server_frame catch |err| log.warn("server error: {}", .{err});

    var client = try net.Client.init(runtime.getAllocator(), ip.Address.initIPv4(IPv4.localhost, 9000));
    defer {
        var shutdown_ctx: Context = .{};
        defer shutdown_ctx.cancel();

        if (client.deinit(runtime.getAllocator(), &shutdown_ctx)) |_| {
            log.info("client successfully shutdown", .{});
        } else |err| {
            log.warn("client reported an error while shutting down: {}", .{err});
        }
    }

    var client_frame = async runBenchmark(&ctx, &client);
    defer await client_frame catch |err| log.warn("client error: {}", .{err});

    runtime.waitForSignal(&ctx, .{os.SIGINT}) catch {};
    log.info("gracefully shutting down...", .{});

    ctx.cancel();
}

pub fn runBenchmark(ctx: *Context, client: *net.Client) !void {
    const log = std.log.scoped(.main);

    var timer = try time.Timer.start();
    var count: usize = 0;
    var nonce: u64 = 0;

    const keys = try Ed25519.KeyPair.create(null);

    while (true) {
        const tx = try Transaction.create(runtime.getAllocator(), keys, .{
            .sender_nonce = nonce,
            .created_at = 0,
            .tag = .no_op,
            .data = "hello world",
        });
        defer tx.deinit(runtime.getAllocator());

        try sendTransactions(ctx, client, &[_]*Transaction{tx});
        count += 1;
        nonce += 1;

        if (timer.read() > 1 * time.ns_per_s) {
            log.info("{} requests/sec", .{count});
            count = 0;
            timer.reset();
        }
    }
}

pub fn sendTransactions(ctx: *Context, client: *net.Client, transactions: []*Transaction) !void {
    var len: u32 = 0;
    for (transactions) |tx| {
        len += tx.size();
    }

    const writer = try await async client.acquireWriter(ctx, runtime.getAllocator());
    defer client.releaseWriter(writer);

    try (net.Packet{
        .len = len,
        .nonce = 0,
        .op = .command,
        .tag = .push_transaction,
    }).write(writer);

    for (transactions) |tx| {
        try tx.write(writer);
    }
}

pub fn sendTestRequest(ctx: *Context, client: *net.Client) !void {
    var entry: RPC.Entry = .{};
    var nonce = try client.rpc.register(ctx, &entry);

    {
        const writer = try await async client.acquireWriter(ctx, runtime.getAllocator());
        defer client.releaseWriter(writer);

        try (net.Packet{
            .len = "hello world".len,
            .nonce = nonce,
            .op = .request,
            .tag = .ping,
        }).write(writer);

        try writer.writeAll("hello world");
    }

    const response = try await entry.response;
    defer response.deinit(runtime.getAllocator());
}

pub fn sendTestCommand(ctx: *Context, client: *net.Client) !void {
    const writer = try await async client.acquireWriter(ctx, runtime.getAllocator());
    defer client.releaseWriter(writer);

    try (net.Packet{
        .len = "hello world".len,
        .nonce = 0,
        .op = .command,
        .tag = .ping,
    }).write(writer);

    try writer.writeAll("hello world");
}

pub const Block = struct {
    pub const max_num_transaction_ids: u16 = math.maxInt(u16);

    pub const Params = struct {
        height: u64,
        merkle_root: [32]u8,
        transaction_ids: []const [32]u8,
    };

    id: [32]u8,
    refs: usize = 1,

    height: u64,
    merkle_root: [32]u8,
    num_transaction_ids: u16,
    transaction_ids: [*][32]u8,

    pub fn create(gpa: *mem.Allocator, params: Block.Params) !*Block {
        const bytes = try gpa.alignedAlloc(u8, @alignOf(Block), @sizeOf(Block) + params.transaction_ids.len * @sizeOf([32]u8));
        errdefer gpa.free(bytes);

        const block = @ptrCast(*Block, bytes.ptr);

        block.refs = 1;
        block.height = params.height;
        block.merkle_root = params.merkle_root;
        block.num_transaction_ids = @intCast(u16, params.transaction_ids.len);

        block.transaction_ids = @ptrCast([*][32]u8, bytes.ptr + @sizeOf(Block));
        mem.copy([32]u8, block.transaction_ids[0..block.num_transaction_ids], params.transaction_ids);

        // blake3 id

        var hash = crypto.HashWriter(Blake3).wrap(Blake3.init(.{}));
        try block.write(hash.writer());
        block.id = hash.digest(32);

        return block;
    }

    pub fn deinit(self: *Block, gpa: *mem.Allocator) void {
        self.refs -= 1;
        if (self.refs == 0) {
            gpa.free(@ptrCast([*]const u8, self)[0 .. @sizeOf(Block) + @as(usize, self.num_transaction_ids) * @sizeOf([32]u8)]);
        }
    }

    pub fn ref(self: *Block) *Block {
        assert(self.refs >= 1);
        self.refs += 1;
        return self;
    }

    pub fn write(self: Block, writer: anytype) !void {
        try writer.writeIntLittle(u64, self.height);
        try writer.writeAll(&self.merkle_root);
        try writer.writeIntLittle(u16, self.num_transaction_ids);
        try writer.writeAll(mem.sliceAsBytes(self.transaction_ids[0..self.num_transaction_ids]));
    }

    pub fn read(gpa: *mem.Allocator, reader: anytype) !*Block {
        var block = try gpa.create(Block);
        errdefer gpa.destroy(block);

        block.height = try reader.readIntLittle(u64);
        block.merkle_root = try reader.readBytesNoEof(32);
        block.num_transaction_ids = try reader.readIntLittle(u16);

        block = @ptrCast(*Block, try gpa.realloc(mem.span(mem.asBytes(block)), @sizeOf(Block) + @as(usize, block.num_transaction_ids) * @sizeOf([32]u8)));

        block.transaction_ids = @ptrCast([*][32]u8, @ptrCast([*]u8, block) + @sizeOf(Block));
        try reader.readNoEof(mem.sliceAsBytes(block.transaction_ids[0..block.num_transaction_ids]));

        var hash = crypto.HashWriter(Blake3).wrap(Blake3.init(.{}));
        try block.write(hash.writer());
        block.id = hash.digest(32);

        block.refs = 1;

        return block;
    }
};

pub const Transaction = struct {
    pub const header_size = @sizeOf([32]u8) + @sizeOf([64]u8) + @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u64) + @sizeOf(Transaction.Tag);

    pub const Tag = enum(u8) {
        no_op,
    };

    pub const Params = struct {
        sender_nonce: u64,
        created_at: u64,
        tag: Tag,
        data: []const u8,
    };

    id: [32]u8,
    refs: usize = 1,

    sender: [32]u8,
    signature: [64]u8,
    data_len: u32,

    sender_nonce: u64,
    created_at: u64,
    tag: Tag,
    data: [*]u8,

    pub fn create(gpa: *mem.Allocator, keys: Ed25519.KeyPair, params: Transaction.Params) !*Transaction {
        const bytes = try gpa.alignedAlloc(u8, @alignOf(Transaction), @sizeOf(Transaction) + params.data.len);
        errdefer gpa.free(bytes);

        const tx = @ptrCast(*Transaction, bytes.ptr);

        tx.refs = 1;
        tx.sender = keys.public_key;
        tx.data_len = @intCast(u32, params.data.len);

        tx.sender_nonce = params.sender_nonce;
        tx.created_at = params.created_at;
        tx.tag = params.tag;

        tx.data = bytes.ptr + @sizeOf(Transaction);
        mem.copy(u8, tx.data[0..tx.data_len], params.data);

        // ed25519 signature

        tx.signature = try crypto.sign(tx, keys);

        // blake3 id

        var hash = crypto.HashWriter(Blake3).wrap(Blake3.init(.{}));
        try tx.write(hash.writer());
        tx.id = hash.digest(32);

        return tx;
    }

    pub fn deinit(self: *Transaction, gpa: *mem.Allocator) void {
        self.refs -= 1;
        if (self.refs == 0) {
            gpa.free(@ptrCast([*]const u8, self)[0 .. @sizeOf(Transaction) + self.data_len]);
        }
    }

    pub fn ref(self: *Transaction) *Transaction {
        assert(self.refs >= 1);
        self.refs += 1;
        return self;
    }

    pub fn write(self: Transaction, writer: anytype) !void {
        try writer.writeAll(&self.sender);
        try writer.writeAll(&self.signature);
        try writer.writeIntLittle(u32, self.data_len);
        try self.writeSignaturePayload(writer);
    }

    pub fn writeSignaturePayload(self: Transaction, writer: anytype) !void {
        try writer.writeIntLittle(u64, self.sender_nonce);
        try writer.writeIntLittle(u64, self.created_at);
        try writer.writeIntLittle(u8, @enumToInt(self.tag));
        try writer.writeAll(self.data[0..self.data_len]);
    }

    pub fn size(self: Transaction) u32 {
        return Transaction.header_size + self.data_len;
    }

    pub fn read(gpa: *mem.Allocator, reader: anytype) !*Transaction {
        var tx = try gpa.create(Transaction);
        errdefer gpa.destroy(tx);

        tx.sender = try reader.readBytesNoEof(32);
        tx.signature = try reader.readBytesNoEof(64);
        tx.data_len = try reader.readIntLittle(u32);
        if (tx.data_len > 65536) return error.TransactionTooLarge;

        tx = @ptrCast(*Transaction, try gpa.realloc(mem.span(mem.asBytes(tx)), @sizeOf(Transaction) + tx.data_len));
        tx.sender_nonce = try reader.readIntLittle(u64);
        tx.created_at = try reader.readIntLittle(u64);
        tx.tag = try reader.readEnum(Transaction.Tag, .Little);

        tx.data = @ptrCast([*]u8, tx) + @sizeOf(Transaction);
        try reader.readNoEof(tx.data[0..tx.data_len]);

        var hash = crypto.HashWriter(Blake3).wrap(Blake3.init(.{}));
        try tx.write(hash.writer());
        tx.id = hash.digest(32);

        tx.refs = 1;

        return tx;
    }
};

test "block: create, serialize, and deserialize" {
    const expected = try Block.create(testing.allocator, .{
        .height = 123,
        .merkle_root = [_]u8{1} ** 32,
        .transaction_ids = &[_][32]u8{ [_]u8{2} ** 32, [_]u8{3} ** 32, [_]u8{4} ** 32 },
    });
    defer expected.deinit(testing.allocator);

    var data = std.ArrayList(u8).init(testing.allocator);
    defer data.deinit();

    try expected.write(data.writer());

    const actual = try Block.read(testing.allocator, io.fixedBufferStream(data.items).reader());
    defer actual.deinit(testing.allocator);

    try testing.expectEqual(expected.height, actual.height);
    try testing.expectEqual(expected.merkle_root, actual.merkle_root);
    try testing.expectEqual(expected.num_transaction_ids, actual.num_transaction_ids);
    try testing.expectEqualSlices([32]u8, expected.transaction_ids[0..expected.num_transaction_ids], actual.transaction_ids[0..actual.num_transaction_ids]);
}

test "transaction: create, serialize, and deserialize" {
    const keys = try Ed25519.KeyPair.create(null);

    const expected = try Transaction.create(testing.allocator, keys, .{
        .sender_nonce = 123,
        .created_at = 456,
        .tag = .no_op,
        .data = "hello world",
    });
    defer expected.deinit(testing.allocator);

    var data = std.ArrayList(u8).init(testing.allocator);
    defer data.deinit();

    try expected.write(data.writer());

    const actual = try Transaction.read(testing.allocator, io.fixedBufferStream(data.items).reader());
    defer actual.deinit(testing.allocator);

    try testing.expectEqualSlices(u8, &expected.id, &actual.id);
    try testing.expectEqualSlices(u8, &expected.sender, &actual.sender);
    try testing.expectEqual(expected.data_len, actual.data_len);
    try testing.expectEqual(expected.sender_nonce, actual.sender_nonce);
    try testing.expectEqual(expected.created_at, actual.created_at);
    try testing.expectEqual(expected.tag, actual.tag);
    try testing.expectEqualStrings(expected.data[0..expected.data_len], actual.data[0..expected.data_len]);
}

pub const Node = struct {
    const log = std.log.scoped(.node);

    chain: Chain,
    verifier: TransactionVerifier,

    pub fn init(self: *Node, gpa: *mem.Allocator) !void {
        self.chain = try Chain.init(gpa);
        errdefer self.chain.deinit(gpa);

        self.verifier = TransactionVerifier.init(&self.chain);
    }

    pub fn deinit(self: *Node, ctx: *Context, gpa: *mem.Allocator) !void {
        try self.verifier.deinit(ctx, gpa);
        self.chain.deinit(gpa);
    }

    pub fn run(self: *Node, ctx: *Context, gpa: *mem.Allocator) !void {
        var verifier_frame = async self.verifier.run(ctx, gpa);
        defer await verifier_frame catch |err| log.warn("transaction verifier error: {}", .{err});

        var chain_frame = async self.chain.run(ctx, gpa);
        defer await chain_frame catch |err| log.warn("chain error: {}", .{err});
    }

    pub fn handleServerPacket(
        self: *Node,
        ctx: *Context,
        gpa: *mem.Allocator,
        conn: *net.Server(Node).Connection,
        packet: net.Packet,
        frame: anytype,
    ) !void {
        switch (packet.op) {
            .request => {
                switch (packet.tag) {
                    .ping => {
                        try (net.Packet{
                            .len = "hello world".len,
                            .nonce = packet.nonce,
                            .op = .response,
                            .tag = .ping,
                        }).write(conn.buffer.writer());

                        try conn.buffer.writer().writeAll("hello world");

                        conn.writer_parker.notify({});
                    },
                    else => return error.UnexpectedTag,
                }
            },
            .command => {
                switch (packet.tag) {
                    .ping => {
                        try (net.Packet{
                            .len = "hello world".len,
                            .nonce = 0,
                            .op = .command,
                            .tag = .ping,
                        }).write(conn.buffer.writer());

                        try conn.buffer.writer().writeAll("hello world");

                        conn.writer_parker.notify({});
                    },
                    .push_transaction => {
                        var count: usize = 0;
                        while (true) : (count += 1) {
                            const tx = Transaction.read(gpa, frame.reader()) catch |err| switch (err) {
                                error.EndOfStream => break,
                                else => return err,
                            };
                            errdefer tx.deinit(gpa);

                            try self.verifier.push(ctx, gpa, tx);
                        }
                    },
                }
            },
            .response => return error.UnexpectedPacket,
        }
    }
};

pub const Chain = struct {
    const log = std.log.scoped(.chain);

    pub const propose_delay_min: i64 = 0 * time.ns_per_ms;
    pub const propose_delay_max: i64 = 500 * time.ns_per_ms;

    sampler: Sampler,
    pending: HashMap(*Transaction, 50),

    latest_block: ?*Block = null,
    last_propose_time: i64 = 0,

    pub fn init(gpa: *mem.Allocator) !Chain {
        var sampler = try Sampler.init(gpa);
        errdefer sampler.deinit(gpa);

        var pending = try HashMap(*Transaction, 50).init(gpa);
        errdefer pending.deinit(gpa);

        return Chain{ .sampler = sampler, .pending = pending };
    }

    pub fn deinit(self: *Chain, gpa: *mem.Allocator) void {
        for (self.pending.slice()) |entry| {
            if (!entry.isEmpty()) {
                entry.value.deinit(gpa);
            }
        }
        self.pending.deinit(gpa);
        if (self.latest_block) |latest_block| {
            latest_block.deinit(gpa);
        }
        self.sampler.deinit(gpa);
    }

    pub fn run(self: *Chain, ctx: *Context, gpa: *mem.Allocator) !void {
        var propose_delay: i64 = propose_delay_min;

        var transaction_ids: std.ArrayListUnmanaged([32]u8) = .{};
        defer transaction_ids.deinit(gpa);

        var votes: std.ArrayListUnmanaged(Sampler.Vote) = .{};
        defer votes.deinit(gpa);

        while (true) {
            const preferred_block = self.sampler.preferred orelse {
                try runtime.timeout(ctx, .{ .nanoseconds = propose_delay });

                if (self.pending.len == 0 or time.milliTimestamp() - self.last_propose_time < propose_delay_min / time.ns_per_ms) {
                    propose_delay = math.min(propose_delay_max, propose_delay + (propose_delay_max - propose_delay_min) / 10);
                    continue;
                }

                try transaction_ids.ensureTotalCapacity(gpa, math.min(Block.max_num_transaction_ids, self.pending.len));

                transaction_ids.clearRetainingCapacity();

                for (self.pending.slice()) |entry| {
                    if (!entry.isEmpty()) {
                        transaction_ids.appendAssumeCapacity(entry.value.id);
                        if (transaction_ids.items.len == Block.max_num_transaction_ids) {
                            break;
                        }
                    }
                }

                const block = try Block.create(gpa, .{
                    .height = (if (self.latest_block) |latest_block| latest_block.height else 0) + 1,
                    .merkle_root = [_]u8{0} ** 32,
                    .transaction_ids = transaction_ids.items,
                });
                defer block.deinit(gpa);

                self.sampler.prefer(gpa, block);
                propose_delay = propose_delay_min;

                log.info("proposed block {} (height {}, {} transaction(s))", .{
                    fmt.fmtSliceHexLower(&block.id),
                    block.height,
                    block.num_transaction_ids,
                });

                continue;
            };

            try votes.ensureTotalCapacity(gpa, 1);

            votes.clearRetainingCapacity();
            votes.appendAssumeCapacity(Sampler.Vote{ .block = preferred_block, .tally = 1.0 });

            const finalized_block = (try self.sampler.update(gpa, votes.items)) orelse continue;

            for (finalized_block.transaction_ids[0..finalized_block.num_transaction_ids]) |tx_id| {
                const tx = self.pending.delete(tx_id) orelse unreachable;
                tx.deinit(gpa);
            }

            if (self.latest_block) |latest_block| {
                latest_block.deinit(gpa);
            }
            self.latest_block = finalized_block.ref();

            self.sampler.reset(gpa);

            log.info("finalized block {} (height {}, {} transaction(s))", .{
                fmt.fmtSliceHexLower(&finalized_block.id),
                finalized_block.height,
                finalized_block.num_transaction_ids,
            });
        }
    }
};

pub const TransactionVerifier = struct {
    const log = std.log.scoped(.tx_verifier);

    pub const max_signature_batch_size = 64;
    pub const max_num_allowed_parallel_tasks = 256;

    pub const flush_delay_min: i64 = 100 * time.ns_per_ms;
    pub const flush_delay_max: i64 = 500 * time.ns_per_ms;

    pub const Task = extern struct {
        next: ?*TransactionVerifier.Task = null,
    };

    chain: *Chain,

    pool_wg: sync.WaitGroup = .{},
    pool_parker: sync.Parker(void) = .{},
    pool: SinglyLinkedList(TransactionVerifier.Task, .next) = .{},

    entries: std.ArrayListUnmanaged(*Transaction) = .{},
    last_flush_time: i64 = 0,

    pub fn init(chain: *Chain) TransactionVerifier {
        return TransactionVerifier{ .chain = chain };
    }

    pub fn deinit(self: *TransactionVerifier, ctx: *Context, gpa: *mem.Allocator) !void {
        try self.pool_wg.wait(ctx);

        for (self.entries.items) |tx| {
            tx.deinit(gpa);
        }
        self.entries.deinit(gpa);

        while (self.pool.popFirst()) |task| {
            gpa.free(@ptrCast([*]u8, task)[0 .. @sizeOf(TransactionVerifier.Task) + @frameSize(TransactionVerifier.runTask)]);
        }
    }

    pub fn push(self: *TransactionVerifier, ctx: *Context, gpa: *mem.Allocator, tx: *Transaction) !void {
        while (self.pool_wg.len == max_num_allowed_parallel_tasks) {
            try self.pool_parker.park(ctx);
        }

        try self.entries.append(gpa, tx);

        if (self.entries.items.len == max_signature_batch_size) {
            try self.flush(gpa);
        }
    }

    pub fn run(self: *TransactionVerifier, ctx: *Context, gpa: *mem.Allocator) !void {
        var flush_delay: i64 = flush_delay_min;

        while (true) {
            while (self.pool_wg.len == max_num_allowed_parallel_tasks) {
                try self.pool_parker.park(ctx);
            }

            try runtime.timeout(ctx, .{ .nanoseconds = flush_delay });

            if (self.entries.items.len == 0 or time.milliTimestamp() - self.last_flush_time < flush_delay_min / time.ns_per_ms) {
                flush_delay = math.min(flush_delay_max, flush_delay * 2);
                continue;
            }

            try self.flush(gpa);

            flush_delay = flush_delay_min;
        }
    }

    fn flush(self: *TransactionVerifier, gpa: *mem.Allocator) !void {
        const task = task: {
            if (self.pool.popFirst()) |task| {
                break :task task;
            }
            const task_align = @alignOf(@Frame(TransactionVerifier.runTask));
            const task_length = @sizeOf(TransactionVerifier.Task) + @frameSize(TransactionVerifier.runTask);
            const task_bytes = try gpa.alignedAlloc(u8, task_align, task_length);
            break :task @ptrCast(*TransactionVerifier.Task, task_bytes);
        };

        const task_frame = @ptrCast(*@Frame(TransactionVerifier.runTask), @ptrCast([*]u8, task) + @sizeOf(TransactionVerifier.Task));

        task.* = .{};
        task_frame.* = async self.runTask(task, gpa, self.entries.toOwnedSlice(gpa));

        self.last_flush_time = time.milliTimestamp();
    }

    fn runTask(self: *TransactionVerifier, task: *TransactionVerifier.Task, gpa: *mem.Allocator, entries: []*Transaction) !void {
        self.pool_wg.add(1);
        defer self.pool_wg.sub(1);

        defer {
            self.pool.prepend(task);
            self.pool_parker.notify({});
        }

        var index: usize = 0;

        {
            runtime.startCpuBoundOperation();
            defer runtime.endCpuBoundOperation();

            var num: usize = 0;
            while (entries.len - num >= max_signature_batch_size) : (num += max_signature_batch_size) {
                crypto.verifyBatch(entries[num..][0..max_signature_batch_size]) catch |batch_err| {
                    log.warn("bad transaction batch: {}", .{batch_err});

                    for (entries[num..][0..max_signature_batch_size]) |tx| {
                        crypto.verify(tx.signature, tx, tx.sender) catch |err| {
                            log.warn("bad transaction {}: {}", .{ fmt.fmtSliceHexLower(&tx.id), err });
                            tx.deinit(gpa);
                            continue;
                        };

                        entries[index] = tx;
                        index += 1;
                    }

                    continue;
                };

                mem.copy(*Transaction, entries[index..], entries[num..][0..max_signature_batch_size]);
                index += max_signature_batch_size;
            }

            for (entries[num..]) |tx| {
                crypto.verify(tx.signature, tx, tx.sender) catch |err| {
                    log.warn("bad transaction {}: {}", .{ fmt.fmtSliceHexLower(&tx.id), err });
                    tx.deinit(gpa);
                    continue;
                };

                entries[index] = tx;
                index += 1;
            }
        }

        defer gpa.free(entries);

        self.chain.pending.ensureUnusedCapacity(gpa, index) catch {
            for (entries[0..index]) |tx| {
                tx.deinit(gpa);
            }
            return;
        };

        for (entries[0..index]) |tx| {
            self.chain.pending.putAssumeCapacity(tx.id, tx);
        }
    }
};

pub const Sampler = struct {
    pub const default_alpha = 0.80;
    pub const default_beta = 150;

    pub const Vote = struct {
        block: ?*Block,
        tally: f64,
    };

    counts: HashMap(usize, 50),
    count: usize = 0,
    stalled: usize = 0,
    preferred: ?*Block = null,
    last: ?*Block = null,

    pub fn init(gpa: *mem.Allocator) !Sampler {
        var counts = try HashMap(usize, 50).init(gpa);
        errdefer counts.deinit(gpa);

        return Sampler{ .counts = counts };
    }

    pub fn deinit(self: *Sampler, gpa: *mem.Allocator) void {
        self.counts.deinit(gpa);
        if (self.preferred) |preferred| {
            preferred.deinit(gpa);
        }
        if (self.last) |last| {
            last.deinit(gpa);
        }
    }

    pub fn reset(self: *Sampler, gpa: *mem.Allocator) void {
        self.counts.clearRetainingCapacity();
        self.count = 0;
        self.stalled = 0;

        if (self.preferred) |preferred| {
            preferred.deinit(gpa);
        }
        self.preferred = null;

        if (self.last) |last| {
            last.deinit(gpa);
        }
        self.last = null;
    }

    pub fn prefer(self: *Sampler, gpa: *mem.Allocator, block: *Block) void {
        if (self.preferred) |preferred| {
            preferred.deinit(gpa);
        }
        self.preferred = block.ref();
    }

    pub fn update(self: *Sampler, gpa: *mem.Allocator, votes: []const Vote) !?*Block {
        try self.counts.ensureUnusedCapacity(gpa, 1);

        if (votes.len == 0) return null;

        var majority_vote = votes[0];
        for (votes[1..]) |vote| {
            if (vote.block == null) continue;
            if (majority_vote.tally >= vote.tally) continue;
            majority_vote = vote;
        }

        const majority_block = majority_vote.block orelse {
            self.count = 0;
            return null;
        };

        if (majority_vote.tally < default_alpha) {
            self.stalled += 1;
            if (self.stalled >= default_beta) {
                if (self.preferred) |preferred| {
                    preferred.deinit(gpa);
                }
                self.preferred = null;
                self.stalled = 0;
            }
            self.count = 0;
            return null;
        }

        // TODO: getEntry() can be added to allow for emplacement of value

        const count = (self.counts.get(majority_block.id) orelse 0) + 1;
        self.counts.putAssumeCapacity(majority_block.id, count);

        if (self.preferred) |preferred| {
            if (count > self.counts.get(preferred.id).?) {
                self.preferred = majority_block.ref();
                preferred.deinit(gpa);
            }
        } else {
            self.preferred = majority_block.ref();
        }

        if (self.last) |last| {
            if (!mem.eql(u8, &last.id, &majority_block.id)) {
                self.last = majority_block.ref();
                self.count = 1;
                last.deinit(gpa);
                return null;
            }
        } else {
            self.last = majority_block.ref();
            self.count = 1;
            return null;
        }

        self.count += 1;
        if (self.count > default_beta) {
            return self.preferred;
        }

        return null;
    }
};
