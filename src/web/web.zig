const std = @import("std");
const zul = @import("zul");
const logz = @import("logz");
const httpz = @import("httpz");
const typed = @import("typed");
const validate = @import("validate");
pub const aolium = @import("../aolium.zig");

const App = aolium.App;
const Env = aolium.Env;
const Allocator = std.mem.Allocator;
const Dispatcher = @import("dispatcher.zig").Dispatcher;

// handlers
const auth = @import("auth/_auth.zig");
const misc = @import("misc/_misc.zig");
const posts = @import("posts/_posts.zig");
const comments = @import("comments/_comments.zig");

pub fn start(app: *App) !void {
	const config = app.config;
	const allocator = app.allocator;

	var server = try httpz.ServerCtx(*const Dispatcher, *Env).init(allocator, .{
		.cors = config.cors,
		.port = config.port,
		.address = config.address,
	}, undefined);
	server.notFound(routerNotFound);
	server.errorHandler(errorHandler);
	server.dispatcher(Dispatcher.dispatch);

	const router = server.router();
	{
		// publicly accessible API endpoints
		var routes = router.group("/api/1/", .{.ctx = &Dispatcher{
			.app = app,
			.requires_user = false,
			.log_http = config.log_http,
		}});

		routes.post("/auth/login", auth.login);
		routes.post("/auth/register", auth.register);
		routes.get("/posts", posts.index);
		routes.get("/posts/:id", posts.show);
		routes.post("/posts/:id/comments", comments.create);
		routes.get("/ping", misc.ping);
		routes.get("/comments/count", comments.count);
	}

	{
		// technically, logout should require a logged in user, but it's easier
		// for clients if we special-case is so that they don't have to deal with
		// a 401 on invalid or expired tokens.
		var routes = router.group("/api/1/", .{.ctx = &Dispatcher{
			.app = app,
			.load_user = false,
			.log_http = config.log_http,
		}});

		routes.get("/auth/logout", auth.logout);
	}

	{
		// routes that require a logged in user
		var routes = router.group("/api/1/", .{.ctx = &Dispatcher{
			.app = app,
			.requires_user = true,
			.log_http = config.log_http,
		}});
		routes.head("/auth/check", auth.check);
		routes.post("/posts", posts.create);
		routes.post("/posts/:id", posts.update);
		routes.post("/posts/:id", posts.update);
		routes.get("/comments/:id/delete", comments.delete);
		routes.get("/comments/:id/approve", comments.approve);
		routes.get("/comments", comments.index);
	}

	const http_address = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{config.address, config.port});
	logz.info().ctx("http").string("address", http_address).log();
	allocator.free(http_address);

	// blocks
	defer server.deinit();
	try server.listen();
}

// Since our dispatcher handles action errors, this should not happen unless
// the dispatcher itself, or the underlying http framework, fails.
fn errorHandler(_: *const Dispatcher, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
	const code = errors.ServerError.write(res);
	logz.err().err(err).ctx("errorHandler").string("path", req.url.raw).int("code", code).log();
}

// Not found specifically related to the method/path, this is passed to our
// http framework as a fallback.
fn routerNotFound(_: *const Dispatcher, _: *httpz.Request, res: *httpz.Response) !void {
	_ = errors.RouterNotFound.write(res);
}

// An application-level 404, e.g. a call to DELETE /blah/:id and the :id wasn't
// found. Always nice to include a brief description of exactly what wasn't found
// to help developers.
pub fn notFound(res: *httpz.Response, desc: []const u8) !void {
	res.status = 404;
	return res.json(.{
		.desc = desc,
		.err = "not found",
		.code = aolium.codes.NOT_FOUND,
	}, .{});
}

pub fn validateJson(req: *httpz.Request, v: *validate.Object(void), env: *Env) !typed.Map {
	const body = req.body() orelse return error.InvalidJson;
	var validator = try env.validator();
	const input = try v.validateJsonS(body, validator);
	if (!validator.isValid()) {
		return error.Validation;
	}
	return input;
}

// This isn't great, but we turn out querystring args into a typed.Map where every
// value is a typed.Value.string. Validators can be configured to parse strings.
pub fn validateQuery(req: *httpz.Request, v:  *validate.Object(void), env: *Env) !typed.Map {
	const q = try req.query();

	var map = typed.Map.init(req.arena);
	try map.ensureTotalCapacity(@intCast(q.len));

	for (q.keys[0..q.len], q.values[0..q.len]) |name, value| {
		try map.putAssumeCapacity(name, value);
	}

	var validator = try env.validator();
	const input = try v.validate(map, validator);
	if (!validator.isValid()) {
		return error.Validation;
	}
	return input orelse typed.Map.readonlyEmpty();
}

pub fn parseUUID(field: []const u8, raw: []const u8, env: *Env) !zul.UUID {
	return zul.UUID.parse(raw) catch {
		(try env.validator()).addInvalidField(.{
			.field = field,
			.err = "is not valid",
			.code = validate.codes.TYPE_UUID,
		});
		return error.Validation;
	};
}

pub fn getSessionId(req: *httpz.Request) ?[]const u8 {
	const header = req.header("authorization") orelse return null;
	if (header.len < 11 or std.mem.startsWith(u8, header, "aolium ") == false) return null;
	return header[7..];
}

// pre-generated error messages
pub const Error = struct {
	code: i32,
	status: u16,
	body: []const u8,

	fn init(status: u16, comptime code: i32, comptime message: []const u8) Error {
		const body = std.fmt.comptimePrint("{{\"code\": {d}, \"err\": \"{s}\"}}", .{code, message});
		return .{
			.code = code,
			.body = body,
			.status = status,
		};
	}

	pub fn write(self: Error, res: *httpz.Response) i32 {
		res.status = self.status;
		res.content_type = httpz.ContentType.JSON;
		res.body = self.body;
		return self.code;
	}
};

// bunch of static errors that we can serialize at comptime
pub const errors = struct {
	const codes = aolium.codes;
	pub const ServerError = Error.init(500, codes.INTERNAL_SERVER_ERROR_UNCAUGHT, "internal server error");
	pub const RouterNotFound = Error.init(404, codes.ROUTER_NOT_FOUND, "not found");
	pub const InvalidJson = Error.init(400, codes.INVALID_JSON, "invalid JSON");
	pub const AccessDenied = Error.init(401, codes.ACCESS_DENIED, "access denied");
};

pub const CachedResponse = struct {
	status: u16,
	body: []const u8,
	content_type: httpz.ContentType,

	pub fn removedFromCache(self: CachedResponse, allocator: Allocator) void {
		allocator.free(self.body);
	}

	pub fn write(self: CachedResponse, res: *httpz.Response) !void {
		res.status = self.status;
		res.content_type = self.content_type;
		res.body = self.body;

		// It's important that we explicitly write out the response, because our
		// cached entry is only guaranteed to be valid until it's released, which
		// happens before httpz gets back control.
		return res.write();
	}

	// used by cache library
	pub fn size(self: CachedResponse) u32 {
		return @intCast(self.body.len);
	}
};

const t = aolium.testing;
test "web: Error.write" {
	var tc = t.context(.{});
	defer tc.deinit();

	try t.expectEqual(0, errors.ServerError.write(tc.web.res));
	try tc.web.expectStatus(500);
	try tc.web.expectJson(.{.code = 0, .err = "internal server error"});
}

test "web: notFound" {
	var tc = t.context(.{});
	defer tc.deinit();

	try notFound(tc.web.res, "no spice");
	try tc.web.expectStatus(404);
	try tc.web.expectJson(.{.code = 3, .err = "not found", .desc = "no spice"});
}

test "web: getSessionID" {
	var tc = t.context(.{});
	defer tc.deinit();

	try t.expectEqual(null, getSessionId(tc.web.req));
}

test "web: CachedResponse.write" {
	var wt = t.web.init(.{});
	defer wt.deinit();

	const cr = CachedResponse{
		.status = 123,
		.content_type = .ICO,
		.body = "some content"
	};

	try cr.write(wt.res);
	try wt.expectStatus(123);
	try wt.expectBody("some content");
	try wt.expectHeader("Content-Type", "image/vnd.microsoft.icon");
}
