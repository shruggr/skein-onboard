//! onboard (shruggr/skein#90): the onboarding app, installed in the host
//! skein — the operator's own instance on a host. A page with a wallet asks
//! it for a skein of its own; it asks the host's instance manager, records
//! the child under its own name and answers the page.
//!
//!   an http row  {transport: "http", address: "/call", sender: "session", program: onboard, fn: "call"}
//!                (installed under /onboard/: POST /onboard/call; any BRC-104 session — the page's wallet)
//!
//!   POST /onboard/call  {fn: "onboard.create", args: {handle, image?}}   JSON (or dag-cbor as application/cbor)
//!     → 200 {fn, result: {handle, identity: <hex>, url}}
//!     → 4xx/5xx {fn, error: {code, message}}
//!
//! The route handler (fn "call", an in-VM call in the front door's step on
//! the request) checks the call, applies the policy (free, no gating yet),
//! records the request ({kind: "onboard-request", handle, owner, image?,
//! request}: the caller's key is the owner) and launches a thread of this
//! program on it, then answers {wait: true}: the client's connection is held
//! until that thread comes to rest (shruggr/skein#66). The thread's first step
//! emits `create {handle, owner, image?}` to the instance manager (the
//! address book's role `manager`: only the host skein's book has it) and
//! rests on its answer. The answer — a signed message, {replyTo, handle,
//! identity, url} or {replyTo, error} — steps it again: it points the head
//! `onboard/instances/<handle>` at the answer record (by reference: the
//! manager's own record, not a copy) and finishes with {handle, identity,
//! url}; a refusal (the handle taken, a bad owner key, an image the host does
//! not have) finishes with {error}. The handler is then called again with
//! `resolved` and answers the page.
//!
//! Error codes (the SDK's, `app.Code`, and one more): bad-request 400,
//! bad-args 400, not-admitted 403, unknown-fn 404, refused 409 (the instance
//! manager said no), failed 500 (the thread errored: no manager here, …).
const std = @import("std");
const cbor = @import("cbor");
const sk = @import("sk");
const app = @import("app");
const dagjson = @import("dagjson");

const Value = cbor.Value;
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const NAME = "onboard";
/// The one function: `<interface>.<function>` (skein-sdk `app`'s naming).
pub const CREATE = "onboard.create";
/// Where a created child is recorded: `onboard/instances/<handle>` → the manager's answer.
pub const INSTANCES = "onboard/instances/";

pub fn main() u8 {
    return sk.main(NAME, run);
}

fn run(a: Allocator) !void {
    const in = try sk.input(a);
    const kind = Value.str(in.get("kind")) orelse "";
    if (eql(u8, kind, "call")) {
        const func = Value.str(in.get("fn")) orelse "";
        if (!eql(u8, func, "call")) return sk.report("onboard answers fn \"call\" (its route)");
        const req = cbor.decode(a, Value.bytesOf(in.get("arg")) orelse "") catch return sk.report("the argument is not dag-cbor");
        return sk.answer(a, try route(a, req));
    }
    if (eql(u8, kind, "step")) return work(a, in);
    return sk.report("onboard is called (its route) or stepped (its create thread)");
}

// ---------------------------------------------------------------- the route

/// A failure as the route answers it.
pub const Fail = struct { status: u16, code: []const u8, message: []const u8 };

/// What a request body asks: {fn, args} checked down to the create's own args.
pub const Ask = struct { handle: []const u8, image: ?[]const u8 };

/// The body {fn: "onboard.create", args} → the create's args, checked against
/// the declared shape (`decl`: the manifest's declaration), or why not.
pub fn parseAsk(a: Allocator, body: Value, decl: ?Value) !union(enum) { ok: Ask, fail: Fail } {
    if (body != .map) return .{ .fail = .{ .status = 400, .code = "bad-request", .message = "the body is not {fn, args}" } };
    const name = Value.str(body.get("fn")) orelse return .{ .fail = .{ .status = 400, .code = "bad-request", .message = "fn is not text" } };
    if (!eql(u8, name, CREATE)) return .{ .fail = .{ .status = 404, .code = "unknown-fn", .message = try std.fmt.allocPrint(a, "{s}: not provided by onboard (it provides {s})", .{ name, CREATE }) } };
    const args: Value = switch (body.get("args") orelse Value.null) {
        .null => .{ .map = &.{} },
        else => |v| v,
    };
    if (decl) |d| if (try app.check(a, d.get("args") orelse Value{ .map = &.{} }, args, "args")) |why|
        return .{ .fail = .{ .status = 400, .code = "bad-args", .message = why } };
    const handle = Value.str(args.get("handle")) orelse return .{ .fail = .{ .status = 400, .code = "bad-args", .message = "args.handle: missing" } };
    return .{ .ok = .{ .handle = handle, .image = Value.str(args.get("image")) } };
}

/// The policy (shruggr/skein#90): who may have a skein, on what terms. Free
/// and ungated for now: every session may create one. Null: allowed.
pub fn policy(owner: []const u8, ask: Ask) ?Fail {
    _ = owner;
    _ = ask;
    return null;
}

fn route(a: Allocator, req: Value) !Value {
    if (req.get("resolved")) |r| return finish(a, r);
    if (!eql(u8, Value.str(req.get("method")) orelse "", "POST")) return failure(a, "", .{ .status = 400, .code = "bad-request", .message = "POST {fn: \"onboard.create\", args: {handle, image?}}" });
    const caller = Value.bytesOf(req.get("caller")) orelse return failure(a, "", .{ .status = 403, .code = "not-admitted", .message = "no session: create needs a BRC-104 session (its key owns the new skein)" });
    const raw = Value.bytesOf(req.get("body")) orelse "";
    const ct = Value.str(req.get("contentType")) orelse "";
    const body = (if (eql(u8, ct, "application/cbor")) cbor.decode(a, raw) else dagjson.decode(a, raw)) catch
        return failure(a, "", .{ .status = 400, .code = "bad-request", .message = "the body is not {fn, args} (JSON, or dag-cbor as application/cbor)" });
    const manifest = try app.manifestOf(a, NAME);
    const ask = switch (try parseAsk(a, body, try app.declOf(a, manifest, CREATE))) {
        .ok => |x| x,
        .fail => |f| return failure(a, Value.str(body.get("fn")) orelse "", f),
    };
    if (policy(caller, ask)) |f| return failure(a, CREATE, f);
    // The request, recorded: the create thread's arguments.
    var r = cbor.MapBuilder.init(a);
    try r.put("kind", cbor.string("onboard-request"));
    try r.put("handle", cbor.string(ask.handle));
    try r.put("owner", .{ .bytes = caller });
    try r.put("image", cbor.optStr(ask.image));
    try r.put("request", cbor.optCid(Value.cidOf(req.get("request"))));
    const match: Value = req.get("match") orelse .null;
    const self = Value.cidOf(match.get("program")) orelse return sk.report("the route's row names no program");
    _ = try sk.launch(a, self, try sk.put(a, r.value()));
    var w = cbor.MapBuilder.init(a);
    try w.put("wait", .{ .bool = true });
    return w.value();
}

/// Called again: the create thread came to rest. Its answer, on the connection.
fn finish(a: Allocator, resolved: Value) !Value {
    if (resolved != .array or resolved.array.len == 0) return sk.report("resolved: nothing");
    const r = resolved.array[0];
    if (!eql(u8, Value.str(r.get("state")) orelse "", "finished")) {
        const e: Value = r.get("error") orelse .null;
        return failure(a, CREATE, .{ .status = 500, .code = "failed", .message = Value.str(e.get("message")) orelse "the create thread failed" });
    }
    const res: Value = r.get("result") orelse .null;
    const out = cbor.decode(a, Value.bytesOf(res.get("stdout")) orelse "") catch return sk.report("the create thread's answer is not dag-cbor");
    return answerOf(a, out);
}

/// The create thread's answer ({handle, identity, url} | {error}) as the route's.
pub fn answerOf(a: Allocator, out: Value) !Value {
    if (Value.str(out.get("error"))) |e| return failure(a, CREATE, .{ .status = 409, .code = "refused", .message = e });
    var res = cbor.MapBuilder.init(a);
    try res.put("handle", out.get("handle"));
    try res.put("identity", cbor.string(try sk.hex(a, Value.bytesOf(out.get("identity")) orelse "")));
    try res.put("url", out.get("url"));
    var m = cbor.MapBuilder.init(a);
    try m.put("fn", cbor.string(CREATE));
    try m.put("result", res.value());
    return json(a, 200, m.value());
}

fn failure(a: Allocator, name: []const u8, f: Fail) !Value {
    var e = cbor.MapBuilder.init(a);
    try e.put("code", cbor.string(f.code));
    try e.put("message", cbor.string(f.message));
    var m = cbor.MapBuilder.init(a);
    try m.put("fn", cbor.string(name));
    try m.put("error", e.value());
    return json(a, f.status, m.value());
}

fn json(a: Allocator, status: u16, v: Value) !Value {
    var m = cbor.MapBuilder.init(a);
    try m.put("status", cbor.int(status));
    try m.put("type", cbor.string("application/json"));
    try m.put("body", .{ .bytes = try dagjson.encode(a, v) });
    return m.value();
}

// ---------------------------------------------------------------- the create thread

/// The head a child is recorded under.
pub fn instanceHead(a: Allocator, handle: []const u8) ![]u8 {
    return std.mem.concat(a, u8, &.{ INSTANCES, handle });
}

fn work(a: Allocator, in: Value) !void {
    const args: Value = in.get("args") orelse return sk.report("no args");
    if (!eql(u8, Value.str(args.get("kind")) orelse "", "onboard-request")) return sk.report("onboard is stepped only on its own create thread (an onboard-request)");
    const handle = Value.str(args.get("handle")) orelse return sk.report("the request names no handle");
    if (try sk.replyOf(a, in)) |r| {
        // The instance manager's answer: recorded by reference, then the page's answer.
        var m = cbor.MapBuilder.init(a);
        if (Value.str(r.body.get("error"))) |e| {
            try m.put("error", cbor.string(e));
            return sk.answer(a, m.value());
        }
        const rep: Value = in.get("reply") orelse .null;
        const body_cid = Value.cidOf(rep.get("body")) orelse return sk.report("reply: no body");
        if (!eql(u8, Value.str(r.body.get("handle")) orelse "", handle)) return sk.report("the instance manager answered for another handle");
        try sk.advance(try instanceHead(a, handle), body_cid);
        try m.put("handle", cbor.string(handle));
        try m.put("identity", r.body.get("identity"));
        try m.put("url", r.body.get("url"));
        return sk.answer(a, m.value());
    }
    const owner = Value.bytesOf(args.get("owner")) orelse return sk.report("the request names no owner");
    const manager = sk.provider(a, "manager") catch return sk.report("no instance manager in this skein's address book: the onboarding app runs in the host skein");
    var q = cbor.MapBuilder.init(a);
    try q.put("handle", cbor.string(handle));
    try q.put("owner", .{ .bytes = owner });
    try q.put("image", args.get("image"));
    const id = try sk.emit(a, manager, "create", q.value(), null);
    try sk.awaitRecord(id);
}

// ---------------------------------------------------------------- tests

const decl_json =
    \\{"writes":true,"args":{"handle":"string","image?":"string"},"answer":{"handle":"string","identity":"string","url":"string"}}
;

test "a create's body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decl = try dagjson.decode(a, decl_json);
    const ok = try parseAsk(a, try dagjson.decode(a, "{\"fn\":\"onboard.create\",\"args\":{\"handle\":\"alice\"}}"), decl);
    try std.testing.expectEqualStrings("alice", ok.ok.handle);
    try std.testing.expect(ok.ok.image == null);
    const img = try parseAsk(a, try dagjson.decode(a, "{\"fn\":\"onboard.create\",\"args\":{\"handle\":\"bob\",\"image\":\"default\"}}"), decl);
    try std.testing.expectEqualStrings("default", img.ok.image.?);
    const unk = try parseAsk(a, try dagjson.decode(a, "{\"fn\":\"create\",\"args\":{\"handle\":\"x\"}}"), decl);
    try std.testing.expectEqual(@as(u16, 404), unk.fail.status);
    const bad = try parseAsk(a, try dagjson.decode(a, "{\"fn\":\"onboard.create\",\"args\":{\"handle\":7}}"), decl);
    try std.testing.expectEqualStrings("bad-args", bad.fail.code);
    const extra = try parseAsk(a, try dagjson.decode(a, "{\"fn\":\"onboard.create\",\"args\":{\"handle\":\"x\",\"owner\":\"y\"}}"), decl);
    try std.testing.expectEqualStrings("args.owner: not in the shape", extra.fail.message);
    const none = try parseAsk(a, try dagjson.decode(a, "{\"fn\":\"onboard.create\"}"), decl);
    try std.testing.expectEqualStrings("args.handle: missing", none.fail.message);
    const notmap = try parseAsk(a, try dagjson.decode(a, "[1]"), decl);
    try std.testing.expectEqualStrings("bad-request", notmap.fail.code);
}

test "the policy is free" {
    try std.testing.expect(policy("k", .{ .handle = "alice", .image = null }) == null);
}

test "the answers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ok = cbor.MapBuilder.init(a);
    try ok.put("handle", cbor.string("alice"));
    try ok.put("identity", .{ .bytes = &[_]u8{ 2, 0xab } });
    try ok.put("url", cbor.string("http://alice.localhost:8100"));
    const r = try answerOf(a, ok.value());
    try std.testing.expectEqual(@as(i128, 200), Value.intOf(r.get("status")).?);
    try std.testing.expectEqualStrings("{\"fn\":\"onboard.create\",\"result\":{\"handle\":\"alice\",\"identity\":\"02ab\",\"url\":\"http://alice.localhost:8100\"}}", Value.bytesOf(r.get("body")).?);
    var no = cbor.MapBuilder.init(a);
    try no.put("error", cbor.string("handle alice is taken"));
    const n = try answerOf(a, no.value());
    try std.testing.expectEqual(@as(i128, 409), Value.intOf(n.get("status")).?);
    try std.testing.expectEqualStrings("{\"fn\":\"onboard.create\",\"error\":{\"code\":\"refused\",\"message\":\"handle alice is taken\"}}", Value.bytesOf(n.get("body")).?);
    try std.testing.expectEqualStrings("onboard/instances/alice", try instanceHead(a, "alice"));
}
