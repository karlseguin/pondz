const std = @import("std");
const zul = @import("zul");
const httpz = @import("httpz");
const zqlite = @import("zqlite");
const raw_json = @import("raw_json");
const validate = @import("validate");
const posts = @import("_posts.zig");

const web = posts.web;
const aolium = web.aolium;
const Allocator = std.mem.Allocator;

const DEFAULT_UPDATED_AT = zul.DateTime.parse("2023-07-23T00:00:00Z", .rfc3339) catch unreachable;

var index_validator: *validate.Object(void) = undefined;

pub fn init(builder: *validate.Builder(void)) void {
	index_validator = builder.object(&.{
		builder.field("username", builder.string(.{.required = true, .max = aolium.MAX_USERNAME_LEN, .trim = true})),
		builder.field("atom", builder.boolean(.{.parse = true})),
		builder.field("html", builder.boolean(.{.parse = true})),
		builder.field("full", builder.boolean(.{.parse = true})),
		builder.field("page", builder.int(u16, .{.parse = true, .min = 1})),
	}, .{});
}

pub fn handler(env: *aolium.Env, req: *httpz.Request, res: *httpz.Response) !void {
	const input = try web.validateQuery(req, index_validator, env);

	const app = env.app;
	const username = input.get("username").?.string;
	const user = try app.getUserFromUsername(username) orelse {
		return web.notFound(res, "username doesn't exist");
	};

	const atom = if (input.get("atom")) |i| i.bool else false;
	const html = if (input.get("html")) |i| i.bool else true;
	const full = if (input.get("full")) |i| i.bool else true;
	// only do first page for atom
	const page = if (atom) 1 else if (input.get("page")) |p| p.u16 else 1;

	const fetcher = PostsFetcher.init(req.arena, env, user, username, page, html, atom, full);

	const cached_response = (try app.http_cache.fetch(*const PostsFetcher, &fetcher.cache_key, PostsFetcher.getPosts, &fetcher, .{.ttl = 300})).?;
	defer cached_response.release();
	res.header("Cache-Control", "public,max-age=30");
	try cached_response.value.write(res);
}

const PostsFetcher = struct {
	atom: bool,
	html: bool,
	full: bool,
	page: u16,
	env: *aolium.Env,
	user: aolium.User,
	cache_key: [11]u8,
	username: []const u8,
	arena: std.mem.Allocator,

	fn init(arena: Allocator, env: *aolium.Env, user: aolium.User, username: []const u8, page: u16, html: bool, atom: bool, full: bool) PostsFetcher {
		// user_id + page + (html | atom | full)
		// 8       + 2    + 1
		var cache_key: [11]u8 = undefined;
		@memcpy(cache_key[0..8], std.mem.asBytes(&user.id));
		@memcpy(cache_key[8..10], std.mem.asBytes(&page));
		cache_key[10] = if (html) 1 else 0;
		cache_key[10] |= if (atom) 2 else 0;
		cache_key[10] |= if (full) 4 else 0;

		return .{
			.env = env,
			.user = user,
			.page = page,
			.html = html,
			.atom = atom,
			.full = full,
			.arena = arena,
			.username = username,
			.cache_key = cache_key,
		};
	}

	fn getPosts(self: *const PostsFetcher, _: []const u8) !?web.CachedResponse {
		const env = self.env;
		const atom = self.atom;
		const shard_id = self.user.shard_id;

		const app = env.app;
		var sb = try app.buffers.acquire();
		defer sb.release();

		{
			// this block exists so that conn is released ASAP, specifically avoiding
			// the sb.copy

			const conn = app.getDataConn(shard_id);
			defer app.releaseDataConn(conn, shard_id);

			if (atom) {
				try self.generateAtom(conn, sb);
			} else {
				try self.generateJSON(conn, sb);
			}
		}

		return .{
			.status = 200,
			.content_type = if (atom) .XML else .JSON,
			.body = try sb.copy(app.http_cache.allocator),
		};
	}

	fn generateJSON(self: *const PostsFetcher, conn: zqlite.Conn, buf: *zul.StringBuilder) !void {
		const html = self.html;
		const user = self.user;
		const username = self.username;

		const prefix = "{\"posts\":[\n";
		try buf.write(prefix);
		const writer = buf.writer();

		const offset = (self.page - 1) * 20;

		const sql =
			\\ select id, type, title, tags,
			\\   case
			\\     when ?3 or type != 'long' then text
			\\     else null
			\\   end as text,
			\\   comments, created, updated
			\\ from posts
			\\ where user_id = ?1
			\\ order by created desc, rowid
			\\ limit 21 offset ?2
		;
		var more = false;
		const args = .{user.id, offset, self.full};
		{
			var rows = conn.rows(sql, args) catch |err| {
				return aolium.sqliteErr("posts.select.json", err, conn, self.env.logger);
			};
			defer rows.deinit();

			// It would be simpler to loop through rows, collecting "Posts" into an arraylist
			// and then using json.stringify(.{.posts = posts}). But if we did that, we'd
			// need to dupe the text values so that they outlive a single iteration of the
			// loop. Instead, we serialize each post immediately and glue everything together.

			// TODO: can/should heavily optimzie this, namely by storing pre-generated
			// json and html blobs that we just glue together.
			var count: usize = 0;
			while (rows.next()) |row| {
				const tpe = row.text(1);

				const text_value = posts.maybeRenderHTML(html, tpe, row, 4);
				defer text_value.deinit();

				const id = try zul.UUID.binToHex(row.blob(0), .lower);
				var url_buf: [aolium.MAX_WEB_POST_URL]u8 = undefined;

				try std.json.stringify(.{
					.id = id,
					.type = tpe,
					.title = row.nullableText(2),
					.text = text_value.value(),
					.tags = raw_json.init(row.nullableText(3)),
					.comment_count = row.int(5),
					.created = row.int(6),
					.updated = row.int(7),
					.web_url = try std.fmt.bufPrint(&url_buf, "https://www.aolium.com/{s}/{s}", .{username, id}),
				}, .{.emit_null_optional_fields = false}, writer);

				try buf.write(",\n");
				count += 1;
				if (count == 20) {
					more = rows.next() != null;
					break;
				}
			}

			if (rows.err) |err| {
				return aolium.sqliteErr("posts.select.json.rows", err, conn, self.env.logger);
			}
		}

		// strip out the last comma and newline, if we wrote anything
		if (buf.len() > prefix.len) {
			buf.truncate(2);
		}
		try buf.write("],\n\"more\":");
		try buf.write(if (more) "true}" else "false}");
	}

	fn generateAtom(self: *const PostsFetcher, conn: zqlite.Conn , buf: *zul.StringBuilder) !void {
		const user = self.user;

		const sql =
			\\ select id, title, text, created, updated
			\\ from posts
			\\ where user_id = ?1
			\\ order by created desc
			\\ limit 20
		;
		const args = .{user.id};

		{
			var rows = conn.rows(sql, args) catch |err| {
				return aolium.sqliteErr("posts.select.xml", err, conn, self.env.logger);
			};
			defer rows.deinit();

			if (rows.err) |err| {
				return aolium.sqliteErr("posts.select.xml.rows", err, conn, self.env.logger);
			}

			// We need the latest created time to generate the atom envelop, so we're
			// gonna have to get the first row first
			{
				const row = rows.next() orelse {
					try self.atomEnvelop(buf, DEFAULT_UPDATED_AT);
					try buf.write("</feed>");
					return;
				};

				try self.atomEnvelop(buf, try zul.DateTime.fromUnix(row.int(4), .seconds));
				try self.atomEntry(buf, row);
			}

			while (rows.next()) |row| {
				try self.atomEntry(buf, row);
			}
		}

		try buf.write("</feed>");
	}

	fn atomEnvelop(self: *const PostsFetcher, buf: *zul.StringBuilder, updated: zul.DateTime) !void {
		const username = self.username;

		try std.fmt.format(buf.writer(),
			\\<?xml version="1.0" encoding="utf-8"?>
			\\<?xml-stylesheet href="/assets/feed.xsl" type="text/xsl"?>
			\\<feed xmlns="http://www.w3.org/2005/Atom">
			\\	<title>{s} - aolium</title>
			\\	<link href="https://www.aolium.com/{s}.xml" rel="self"/>
			\\	<link href="https://www.aolium.com/{s}"/>
			\\	<updated>{s}</updated>
			\\	<id>https://www.aolium.com/{s}</id>
			\\	<author><name>{s}</name></author>
			\\
		, .{username, username, username, updated, username, username});
	}

	fn atomEntry(self: *const PostsFetcher, buf: *zul.StringBuilder, row: zqlite.Row) !void {
		const html = self.html;

		const id = try zul.UUID.binToHex(row.blob(0), .lower);
		const created = try zul.DateTime.fromUnix(row.int(3), .seconds);
		const updated = try zul.DateTime.fromUnix(row.int(4), .seconds);

		const content_type = if (html) "html" else "text";
		try buf.write("\t<entry>\n\t\t<title>");

		const title = if (row.nullableText(1)) |tt| tt else row.text(2);
		if (title.len < 80) {
			try writeEscapeXML(buf, title, false);
		} else {
			try writeEscapeXML(buf, title[0..80], false);
			try buf.write(" ...");
		}

		try std.fmt.format(buf.writer(), \\</title>
		\\		<link rel="alternate" href="https://www.aolium.com/{s}/{s}"/>
		\\		<published>{s}</published>
		\\		<updated>{s}</updated>
		\\		<id>https://www.aolium.com/{s}/{s}</id>
		\\		<content type="{s}">
		, .{self.username, id, created, updated, self.username, id, content_type});

		// don't pass a type, we want to render html even for a link
		const content = posts.maybeRenderHTML(html, "", row, 2);
		defer content.deinit();
		const content_value = std.mem.trim(u8, content.value().?, &std.ascii.whitespace);

		try writeEscapeXML(buf, content_value, html);
		try buf.write("</content>\n\t</entry>\n");
	}
};

// our buffer likely has plenty of spare space, but we can't be sure. We'll use
// the ensureUnusedCapacity function which lets us write using XAssumeCapacity
// variants, which lets us avoid _a lot_of bound checking. But we aren't sure
// how much capacity to reserve. Worst case is html.len * 5, if the html is
// just a bunch of opening and closing tags. So we'll:
//    ensureUnusedCapacity(html.len * 5)
// but in small chunks of 1000.
// Note: when the we're writing from the output of cmark, & is alreay escaped
fn writeEscapeXML(buf: *zul.StringBuilder, content: []const u8, amp_escaped: bool) !void {
	var raw = content;
	while (raw.len > 0) {
		const chunk_size = if (raw.len > 1000) 1000 else raw.len;
		try buf.ensureUnusedCapacity(chunk_size * 4);
		for (raw[0..chunk_size]) |b| {
			switch (b) {
				'>' => buf.writeAssumeCapacity("&gt;"),
				'<' => buf.writeAssumeCapacity("&lt;"),
				'&' => if (amp_escaped) buf.writeByteAssumeCapacity(b) else buf.writeAssumeCapacity("&amp;"),
				else => buf.writeByteAssumeCapacity(b),
			}
		}
		raw = raw[chunk_size..];
	}
}

const t = aolium.testing;
test "posts.index: missing username" {
	var tc = t.context(.{});
	defer tc.deinit();
	try t.expectError(error.Validation, handler(tc.env(), tc.web.req, tc.web.res));
	try tc.expectInvalid(.{.code = validate.codes.REQUIRED, .field = "username"});
}

test "posts.index: unknown username" {
	var tc = t.context(.{});
	defer tc.deinit();
	tc.web.query("username", "unknown");
	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectStatus(404);
	try tc.web.expectJson(.{.desc = "username doesn't exist", .code = 3});
}

test "posts.index: no posts json" {
	var tc = t.context(.{});
	defer tc.deinit();

	_ = tc.insert.user(.{.username = "index_no_post"});
	tc.web.query("username", "index_no_post");

	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectJson(.{.posts = .{}});
}

test "posts.index: json list" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid = tc.insert.user(.{.username = "index_post_list"});
	const p1 = tc.insert.post(.{.user_id = uid, .created = 10, .type = "simple", .text = "the spice must flow"});
	const p2 = tc.insert.post(.{.user_id = uid, .created = 15, .type = "link", .title = "t2", .text = "https://www.aolium.com", .tags = &.{"t2", "t3"}, .comments = 3});
	const p3 = tc.insert.post(.{.user_id = uid, .created = 12, .type = "long", .title = "t1", .text = "### c1\n\nhi\n\n"});
	_ = tc.insert.post(.{.created = 10});

	// test the cache too
	for (0..2) |_| {
		{
			// raw output
			tc.reset();
			tc.web.query("html", "false");
			tc.web.query("username", "index_post_list");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{.posts = .{
				.{
					.id = p2,
					.type = "link",
					.title = "t2",
					.comment_count = 3,
					.tags = &.{"t2", "t3"},
					.text = "https://www.aolium.com",
				},
				.{
					.id = p3,
					.type = "long",
					.title = "t1",
					.tags = null,
					.comment_count = 0,
					.text = "### c1\n\nhi\n\n"
				},
				.{
					.id = p1,
					.type = "simple",
					.tags = null,
					.comment_count = 0,
					.text = "the spice must flow",
				}
			}});
		}

		{
			// html output
			tc.reset();
			tc.web.query("username", "index_post_list");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectJson(.{.posts = .{
				.{
					.id = p2,
					.type = "link",
					.title = "t2",
					.text = "https://www.aolium.com",
					.tags = &.{"t2", "t3"},
					.comment_count = 3,
					.web_url = try std.fmt.allocPrint(tc.arena, "https://www.aolium.com/index_post_list/{s}", .{p2}),
				},
				.{
					.id = p3,
					.type = "long",
					.title = "t1",
					.text = "<h3>c1</h3>\n<p>hi</p>\n",
					.tags = null,
					.comment_count = 0,
					.web_url = try std.fmt.allocPrint(tc.arena, "https://www.aolium.com/index_post_list/{s}", .{p3}),
				},
				.{
					.id = p1,
					.type = "simple",
					.tags = null,
					.comment_count = 0,
					.text = "<p>the spice must flow</p>\n",
					.web_url = try std.fmt.allocPrint(tc.arena, "https://www.aolium.com/index_post_list/{s}", .{p1}),
				}
			}});
		}
	}
}

test "posts.index: no posts atom" {
	var tc = t.context(.{});
	defer tc.deinit();

	_ = tc.insert.user(.{.username = "index_no_post"});
	tc.web.query("username", "index_no_post");
	tc.web.query("atom", "true");

	try handler(tc.env(), tc.web.req, tc.web.res);
	try tc.web.expectHeader("Content-Type", "application/xml");
	try tc.web.expectBody(
\\<?xml version="1.0" encoding="utf-8"?>
\\<?xml-stylesheet href="/assets/feed.xsl" type="text/xsl"?>
\\<feed xmlns="http://www.w3.org/2005/Atom">
\\	<title>index_no_post - aolium</title>
\\	<link href="https://www.aolium.com/index_no_post.xml" rel="self"/>
\\	<link href="https://www.aolium.com/index_no_post"/>
\\	<updated>2023-07-23T00:00:00Z</updated>
\\	<id>https://www.aolium.com/index_no_post</id>
\\	<author><name>index_no_post</name></author>
\\</feed>
	);
}

test "posts.index: atom list" {
	var tc = t.context(.{});
	defer tc.deinit();

	const uid = tc.insert.user(.{.username = "index_post_atom"});
	const p1 = tc.insert.post(.{.user_id = uid, .created = 1281323924, .updated = 1291323924, .type = "simple", .text = "the spice & must flow this is a really long text that won't fit as a title if it's large than 80 characters"});
	const p2 = tc.insert.post(.{.user_id = uid, .created = 1670081558, .updated = 1690081558, .type = "link", .title = "t2", .text = "https://www.aolium.com"});
	const p3 = tc.insert.post(.{.user_id = uid, .created = 1670081558, .updated = 1680081558, .type = "long", .title = "t1", .text = "### c1\n\nhi\n\n"});
	_ = tc.insert.post(.{.created = 1890081558, .updated = 1890081558});

	// test the cache too
	for (0..2) |_| {
		{
			// raw output
			tc.reset();
			tc.web.query("username", "index_post_atom");
			tc.web.query("html", "false");
			tc.web.query("atom", "1");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectHeader("Content-Type", "application/xml");
			try tc.web.expectBody(try std.fmt.allocPrint(tc.arena,
				\\<?xml version="1.0" encoding="utf-8"?>
				\\<?xml-stylesheet href="/assets/feed.xsl" type="text/xsl"?>
				\\<feed xmlns="http://www.w3.org/2005/Atom">
				\\	<title>index_post_atom - aolium</title>
				\\	<link href="https://www.aolium.com/index_post_atom.xml" rel="self"/>
				\\	<link href="https://www.aolium.com/index_post_atom"/>
				\\	<updated>2023-07-23T03:05:58Z</updated>
				\\	<id>https://www.aolium.com/index_post_atom</id>
				\\	<author><name>index_post_atom</name></author>
				\\	<entry>
				\\		<title>t2</title>
				\\		<link rel="alternate" href="https://www.aolium.com/index_post_atom/{s}"/>
				\\		<published>2022-12-03T15:32:38Z</published>
				\\		<updated>2023-07-23T03:05:58Z</updated>
				\\		<id>https://www.aolium.com/index_post_atom/{s}</id>
				\\		<content type="text">https://www.aolium.com</content>
				\\	</entry>
				\\	<entry>
				\\		<title>t1</title>
				\\		<link rel="alternate" href="https://www.aolium.com/index_post_atom/{s}"/>
				\\		<published>2022-12-03T15:32:38Z</published>
				\\		<updated>2023-03-29T09:19:18Z</updated>
				\\		<id>https://www.aolium.com/index_post_atom/{s}</id>
				\\		<content type="text">### c1
				\\
				\\hi</content>
				\\	</entry>
				\\	<entry>
				\\		<title>the spice &amp; must flow this is a really long text that won't fit as a title if it ...</title>
				\\		<link rel="alternate" href="https://www.aolium.com/index_post_atom/{s}"/>
				\\		<published>2010-08-09T03:18:44Z</published>
				\\		<updated>2010-12-02T21:05:24Z</updated>
				\\		<id>https://www.aolium.com/index_post_atom/{s}</id>
				\\		<content type="text">the spice &amp; must flow this is a really long text that won't fit as a title if it's large than 80 characters</content>
				\\	</entry>
				\\</feed>
			, .{p2, p2, p3, p3, p1, p1}));
		}

		{
			// html output
			tc.reset();
			tc.web.query("username", "index_post_atom");
			tc.web.query("atom", "True");

			try handler(tc.env(), tc.web.req, tc.web.res);
			try tc.web.expectBody(try std.fmt.allocPrint(tc.arena,
				\\<?xml version="1.0" encoding="utf-8"?>
				\\<?xml-stylesheet href="/assets/feed.xsl" type="text/xsl"?>
				\\<feed xmlns="http://www.w3.org/2005/Atom">
				\\	<title>index_post_atom - aolium</title>
				\\	<link href="https://www.aolium.com/index_post_atom.xml" rel="self"/>
				\\	<link href="https://www.aolium.com/index_post_atom"/>
				\\	<updated>2023-07-23T03:05:58Z</updated>
				\\	<id>https://www.aolium.com/index_post_atom</id>
				\\	<author><name>index_post_atom</name></author>
				\\	<entry>
				\\		<title>t2</title>
				\\		<link rel="alternate" href="https://www.aolium.com/index_post_atom/{s}"/>
				\\		<published>2022-12-03T15:32:38Z</published>
				\\		<updated>2023-07-23T03:05:58Z</updated>
				\\		<id>https://www.aolium.com/index_post_atom/{s}</id>
				\\		<content type="html">&lt;p&gt;&lt;a href="https://www.aolium.com"&gt;https://www.aolium.com&lt;/a&gt;&lt;/p&gt;</content>
				\\	</entry>
				\\	<entry>
				\\		<title>t1</title>
				\\		<link rel="alternate" href="https://www.aolium.com/index_post_atom/{s}"/>
				\\		<published>2022-12-03T15:32:38Z</published>
				\\		<updated>2023-03-29T09:19:18Z</updated>
				\\		<id>https://www.aolium.com/index_post_atom/{s}</id>
				\\		<content type="html">&lt;h3&gt;c1&lt;/h3&gt;
				\\&lt;p&gt;hi&lt;/p&gt;</content>
				\\	</entry>
				\\	<entry>
				\\		<title>the spice &amp; must flow this is a really long text that won't fit as a title if it ...</title>
				\\		<link rel="alternate" href="https://www.aolium.com/index_post_atom/{s}"/>
				\\		<published>2010-08-09T03:18:44Z</published>
				\\		<updated>2010-12-02T21:05:24Z</updated>
				\\		<id>https://www.aolium.com/index_post_atom/{s}</id>
				\\		<content type="html">&lt;p&gt;the spice &amp; must flow this is a really long text that won't fit as a title if it's large than 80 characters&lt;/p&gt;</content>
				\\	</entry>
				\\</feed>
			, .{p2, p2, p3, p3, p1, p1}));
		}
	}
}
