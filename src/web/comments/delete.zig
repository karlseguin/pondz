const std = @import("std");
const zul = @import("zul");
const httpz = @import("httpz");
const validate = @import("validate");
const comments = @import("_comments.zig");

const web = comments.web;
const aolium = web.aolium;

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const comment_id = try web.parseUUID("id", req.params.get("id").?, env);

	const user = env.user.?;
	const sql =
		\\ delete from comments
		\\ where id = ?1 and exists (
		\\   select 1 from posts where id = comments.post_id and user_id = ?2
		\\ )
	;

	const args = .{&comment_id.bin, user.id};
	const app = env.app;

	{
		// we want conn released ASAP
		const conn = app.getDataConn(user.shard_id);
		defer app.releaseDataConn(conn, user.shard_id);

		conn.exec(sql, args) catch |err| {
			return aolium.sqliteErr("comments.delete", err, conn, env.logger);
		};

		if (conn.changes() == 0) {
			return web.notFound(res, "the comment could not be found");
		}
	}
	res.status = 204;
}

const t = aolium.testing;
test "posts.delete: invalid id" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	tc.web.param("id", "nope");
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = validate.codes.TYPE_UUID, .field = "id"});
}

test "posts.delete: unknown id" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	tc.web.param("id", "4b0548fc-7127-438d-a87e-bc283f2d5981");
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
}

test "posts.delete: post belongs to a different user" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 1});
	const pid = tc.insert.post(.{.user_id = 4});
	const cid = tc.insert.comment(.{.post_id = pid});

	tc.web.param("id", cid);
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);

	const row = tc.getDataRow("select 1 from comments where id = ?1", .{(try zul.UUID.parse(cid)).bin});
	try t.expectEqual(true, row != null);
}

test "posts.delete: success" {
	var tc = t.context(.{});
	defer tc.deinit();

	tc.user(.{.id = 3});
	const pid = tc.insert.post(.{.user_id = 3});
	const cid = tc.insert.comment(.{.post_id = pid});

	tc.web.param("id", cid);
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(204);

	const row = tc.getDataRow("select 1 from comments where id = ?1", .{(try zul.UUID.parse(cid)).bin});
	try t.expectEqual(true, row == null);
}
