const std = @import("std");
const builtin = @import("builtin");
const web = @import("web.zig");
const config = if (builtin.is_test) @import("test.zig").Config{} else @import("config");

pub const GITHUB_CLIENT_ID = config.github_client_id orelse {
    @compileError("Missing github_client_id from config");
};
const GITHUB_CLIENT_SECRET = config.github_client_secret orelse {
    @compileError("Missing github_client_secret from config");
};
const TOKEN_URL = "https://github.com/login/oauth/access_token";
const API_URL = "https://api.github.com";
const USER_URL = API_URL ++ "/user";

const logger = std.log.scoped(.github);

pub fn fetch_token(alloc: std.mem.Allocator, grant_type: web.GrantType, resource: []const u8) !web.Response {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const uri = try std.Uri.parse(TOKEN_URL);
    var header_buffer: [4096]u8 = undefined;
    var request = try client.open(.POST, uri, .{ .server_header_buffer = &header_buffer });
    defer request.deinit();

    // TODO: Replace allocPrint with bufPrint when known len?
    const body = switch (grant_type) {
        .AuthorizationCode => try std.fmt.allocPrint(
            alloc,
            "{{\"client_id\":\"" ++ GITHUB_CLIENT_ID ++ "\",\"client_secret\":\"" ++ GITHUB_CLIENT_SECRET ++ "\",\"code\":\"{s}\"}}",
            .{resource},
        ),
        .RefreshToken => try std.fmt.allocPrint(
            alloc,
            "{{\"client_id\":\"" ++ GITHUB_CLIENT_ID ++ "\",\"client_secret\":\"" ++ GITHUB_CLIENT_SECRET ++ "\",\"grant_type\":\"refresh_token\",\"refresh_token\": \"{s}\"}}",
            .{resource},
        ),
    };

    defer alloc.free(body);
    request.headers.connection = .omit;
    request.headers.content_type = .{
        .override = web.Mime.application_json.toString(),
    };
    request.extra_headers = &.{
        .{ .name = "Accept", .value = web.Mime.application_json.toString() },
    };
    request.transfer_encoding = .{ .content_length = body.len };

    try request.send();
    try request.writeAll(body);
    try request.finish();
    try request.wait();

    var response_body_buffer: [2048]u8 = undefined;
    const size = try request.readAll(&response_body_buffer);
    const response_body = response_body_buffer[0..size];

    const response = request.response;
    if (response.status.class() != .success) {
        logger.err("Failed to fetch token:\n{s}", .{response_body});
    }

    // return try std.json.parseFromSlice(Token, alloc, response_body, .{});
    return web.Response{
        .body = .{ .alloc = response_body },
        .content_type = web.Mime.application_json,
        .status = response.status,
    };
}

pub const User = struct {
    login: []const u8,
};

// This is used to validate the access token as well.
pub fn fetch_user(alloc: std.mem.Allocator, access_token: []const u8) !std.json.Parsed(User) {
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const uri = try std.Uri.parse(USER_URL);
    var header_buffer: [4096]u8 = undefined;
    var request = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    defer request.deinit();

    const auth_header = try std.fmt.allocPrint(alloc, "Bearer {s}", .{access_token});
    defer alloc.free(auth_header);
    request.headers.connection = .omit;
    // request.headers.content_type = .{
    //     .override = web.Mime.application_json.toString(),
    // };
    request.headers.authorization = .{ .override = auth_header };
    request.extra_headers = &.{
        .{ .name = "Accept", .value = web.Mime.application_json.toString() },
        .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
    };

    try request.send();
    try request.finish();
    try request.wait();

    var response_body_buffer: [4096]u8 = undefined;
    const size = try request.readAll(&response_body_buffer);
    const response_body = response_body_buffer[0..size];

    const response = request.response;

    if (response.status.class() != .success) {
        logger.warn("Failed to validate token:\n{s}", .{response_body});
        return error.InvalidToken;
    }

    const parsed_user = try std.json.parseFromSlice(
        User,
        alloc,
        response_body,
        .{ .ignore_unknown_fields = true },
    );

    return parsed_user;
}
