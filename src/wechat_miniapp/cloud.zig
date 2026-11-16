//! 云开发服务 —— 对应 Java `api.WxMaCloudService` +
//! `api.impl.WxMaCloudServiceImpl`。
//!
//! URL 对齐 `constant.WxMaApiUrlConstants.Cloud`(全部 /tcb/):
//! - 云函数:invokecloudfunction?env=&name=(原样拼接,Java String.format 口径)
//!   → 提取 `resp_data`;
//! - 数据库:databaseadd/databasedelete/databaseupdate/databasequery
//!   /databaseaggregate/databasecount/updateindex
//!   + databasecollectionadd/delete/get(集合管理);
//! - 迁移:databasemigrateimport/export/queryinfo;
//! - 文件:uploadfile/batchdownloadfile/batchdeletefile;
//! - 其它:getqcloudtoken、sendsmsv2。
//!
//! Java 每个方法都有「带 env」与「不带 env(取配置 cloudEnv)」两个重载;
//! 本模块的 ConfigStorage 无 cloud_env 字段,改为构造时注入 default_env,
//! 各方法 env 传 null 时用 default_env 兜底。
//! (Java 三参 invokeCloudFunction 实际用了配置 env 而忽略入参,是缺陷;
//! 此处以入参为准。)
//! db 查询串拼接格式与 Java 逐字符一致(空格位置敏感):
//! `.add({data: X})` / `.where(W).remove()` / `.update({data:U })` /
//! `.orderBy('k', 'v').skip(N).limit(M).get()` / `.count()`。
//! errcode≠0 已由基座折叠为 `.err`。
const std = @import("std");
const json_util = @import("common").json_util;
const result_mod = @import("common").result;
const error_mod = @import("common").error_util;
const mp_service = @import("wechat_mp").service;

pub const WxResult = result_mod.WxResult;
pub const Done = result_mod.Done;
const WxError = error_mod.WxError;

const INVOKE_CLOUD_FUNCTION_URL = "https://api.weixin.qq.com/tcb/invokecloudfunction";
const DATABASE_ADD_URL = "https://api.weixin.qq.com/tcb/databaseadd";
const DATABASE_DELETE_URL = "https://api.weixin.qq.com/tcb/databasedelete";
const DATABASE_UPDATE_URL = "https://api.weixin.qq.com/tcb/databaseupdate";
const DATABASE_QUERY_URL = "https://api.weixin.qq.com/tcb/databasequery";
const DATABASE_AGGREGATE_URL = "https://api.weixin.qq.com/tcb/databaseaggregate";
const DATABASE_COUNT_URL = "https://api.weixin.qq.com/tcb/databasecount";
const UPDATE_INDEX_URL = "https://api.weixin.qq.com/tcb/updateindex";
const DATABASE_MIGRATE_IMPORT_URL = "https://api.weixin.qq.com/tcb/databasemigrateimport";
const DATABASE_MIGRATE_EXPORT_URL = "https://api.weixin.qq.com/tcb/databasemigrateexport";
const DATABASE_MIGRATE_QUERY_INFO_URL = "https://api.weixin.qq.com/tcb/databasemigratequeryinfo";
const UPLOAD_FILE_URL = "https://api.weixin.qq.com/tcb/uploadfile";
const BATCH_DOWNLOAD_FILE_URL = "https://api.weixin.qq.com/tcb/batchdownloadfile";
const BATCH_DELETE_FILE_URL = "https://api.weixin.qq.com/tcb/batchdeletefile";
const GET_QCLOUD_TOKEN_URL = "https://api.weixin.qq.com/tcb/getqcloudtoken";
const DATABASE_COLLECTION_ADD_URL = "https://api.weixin.qq.com/tcb/databasecollectionadd";
const DATABASE_COLLECTION_DELETE_URL = "https://api.weixin.qq.com/tcb/databasecollectiondelete";
const DATABASE_COLLECTION_GET_URL = "https://api.weixin.qq.com/tcb/databasecollectionget";
const SEND_SMS_V2_URL = "https://api.weixin.qq.com/tcb/sendsmsv2";

fn js(w: *std.Io.Writer, s: []const u8) !void {
    var sj: std.json.Stringify = .{ .writer = w, .options = .{ .escape_unicode = false } };
    try sj.write(s);
}

// --- bean ---------------------------------------------------------------------

/// 对应 `WxCloudDatabaseUpdateResult`(matched/modified/id)。
pub const DatabaseUpdateResult = struct {
    gpa: std.mem.Allocator,
    matched: ?i64 = null,
    modified: ?i64 = null,
    id: ?[]const u8 = null,

    pub fn deinit(self: *DatabaseUpdateResult) void {
        if (self.id) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 分页信息(微信返回键首字母大写:Offset/Limit/Total;
/// Java bean @SerializedName 显式标注,两处 Pager 同构)。
pub const Pager = struct {
    offset: ?i64 = null,
    limit: ?i64 = null,
    total: ?i64 = null,
};

/// 对应 `WxCloudDatabaseQueryResult`(pager + data[]:
/// data 每项是一条记录的原始 JSON 文本,微信返回字符串数组)。
pub const DatabaseQueryResult = struct {
    gpa: std.mem.Allocator,
    pager: Pager = .{},
    data: [][]const u8 = &.{},

    pub fn deinit(self: *DatabaseQueryResult) void {
        for (self.data) |s| self.gpa.free(@constCast(s));
        if (self.data.len > 0) self.gpa.free(self.data);
        self.* = undefined;
    }
};

/// 对应 `WxCloudCloudDatabaseMigrateQueryInfoResult`。
pub const MigrateQueryInfo = struct {
    gpa: std.mem.Allocator,
    status: ?[]const u8 = null,
    record_success: ?i64 = null,
    record_fail: ?i64 = null,
    err_msg: ?[]const u8 = null,
    file_url: ?[]const u8 = null,

    pub fn deinit(self: *MigrateQueryInfo) void {
        if (self.status) |s| self.gpa.free(@constCast(s));
        if (self.err_msg) |s| self.gpa.free(@constCast(s));
        if (self.file_url) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxCloudUploadFileResult`(url/token/authorization/file_id/cos_file_id)。
pub const UploadFileResult = struct {
    gpa: std.mem.Allocator,
    url: ?[]const u8 = null,
    token: ?[]const u8 = null,
    authorization: ?[]const u8 = null,
    file_id: ?[]const u8 = null,
    cos_file_id: ?[]const u8 = null,

    pub fn deinit(self: *UploadFileResult) void {
        if (self.url) |s| self.gpa.free(@constCast(s));
        if (self.token) |s| self.gpa.free(@constCast(s));
        if (self.authorization) |s| self.gpa.free(@constCast(s));
        if (self.file_id) |s| self.gpa.free(@constCast(s));
        if (self.cos_file_id) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxCloudBatchDownloadFileResult.FileDownloadInfo`。
pub const FileDownloadInfo = struct {
    gpa: std.mem.Allocator,
    fileid: ?[]const u8 = null,
    download_url: ?[]const u8 = null,
    status: ?i64 = null,
    errmsg: ?[]const u8 = null,

    pub fn deinit(self: *FileDownloadInfo) void {
        if (self.fileid) |s| self.gpa.free(@constCast(s));
        if (self.download_url) |s| self.gpa.free(@constCast(s));
        if (self.errmsg) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxCloudBatchDownloadFileResult`(file_list[])。
pub const BatchDownloadFileResult = struct {
    gpa: std.mem.Allocator,
    file_list: []FileDownloadInfo = &.{},

    pub fn deinit(self: *BatchDownloadFileResult) void {
        for (self.file_list) |*f| f.deinit();
        if (self.file_list.len > 0) self.gpa.free(self.file_list);
        self.* = undefined;
    }
};

/// 对应 `WxCloudBatchDeleteFileResult`(delete_list[];其 FileDownloadInfo
/// 无 download_url 字段,复用同一 bean,缺省为 null)。
pub const BatchDeleteFileResult = struct {
    gpa: std.mem.Allocator,
    delete_list: []FileDownloadInfo = &.{},

    pub fn deinit(self: *BatchDeleteFileResult) void {
        for (self.delete_list) |*f| f.deinit();
        if (self.delete_list.len > 0) self.gpa.free(self.delete_list);
        self.* = undefined;
    }
};

/// 对应 `WxCloudGetQcloudTokenResult`。
pub const QcloudToken = struct {
    gpa: std.mem.Allocator,
    secretid: ?[]const u8 = null,
    secretkey: ?[]const u8 = null,
    token: ?[]const u8 = null,
    expired_time: ?i64 = null,

    pub fn deinit(self: *QcloudToken) void {
        if (self.secretid) |s| self.gpa.free(@constCast(s));
        if (self.secretkey) |s| self.gpa.free(@constCast(s));
        if (self.token) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxCloudDatabaseCollectionGetResult.CollectionInfo`。
pub const CollectionInfo = struct {
    gpa: std.mem.Allocator,
    name: ?[]const u8 = null,
    count: ?i64 = null,
    size: ?i64 = null,
    index_count: ?i64 = null,
    index_size: ?i64 = null,

    pub fn deinit(self: *CollectionInfo) void {
        if (self.name) |s| self.gpa.free(@constCast(s));
        self.* = undefined;
    }
};

/// 对应 `WxCloudDatabaseCollectionGetResult`(pager + collections[])。
pub const CollectionGetResult = struct {
    gpa: std.mem.Allocator,
    pager: Pager = .{},
    collections: []CollectionInfo = &.{},

    pub fn deinit(self: *CollectionGetResult) void {
        for (self.collections) |*c| c.deinit();
        if (self.collections.len > 0) self.gpa.free(self.collections);
        self.* = undefined;
    }
};

/// 对应 `bean.cloud.request.WxCloudSendSmsV2Request`(请求侧,借用视图;
/// env 为 null 时序列化前用 default_env 兜底,与 Java sendSmsV2 一致)。
pub const SendSmsV2Request = struct {
    env: ?[]const u8 = null,
    url_link: ?[]const u8 = null,
    template_id: ?[]const u8 = null,
    template_param_list: ?[]const []const u8 = null,
    phone_number_list: []const []const u8 = &.{},
    use_short_name: ?bool = null,
    resource_appid: ?[]const u8 = null,
};

/// 对应 `WxCloudSendSmsV2Result`(send_status_list[];该 bean 继承
/// WxMaBaseResponse,errcode/errmsg 由基座兜底,不重复建模)。
pub const SendSmsV2Result = struct {
    gpa: std.mem.Allocator,
    send_status_list: []SendStatus = &.{},

    pub const SendStatus = struct {
        gpa: std.mem.Allocator,
        serial_no: ?[]const u8 = null,
        phone_number: ?[]const u8 = null,
        code: ?[]const u8 = null,
        message: ?[]const u8 = null,
        iso_code: ?[]const u8 = null,

        pub fn deinit(self: *SendStatus) void {
            if (self.serial_no) |s| self.gpa.free(@constCast(s));
            if (self.phone_number) |s| self.gpa.free(@constCast(s));
            if (self.code) |s| self.gpa.free(@constCast(s));
            if (self.message) |s| self.gpa.free(@constCast(s));
            if (self.iso_code) |s| self.gpa.free(@constCast(s));
            self.* = undefined;
        }
    };

    pub fn deinit(self: *SendSmsV2Result) void {
        for (self.send_status_list) |*s| s.deinit();
        if (self.send_status_list.len > 0) self.gpa.free(self.send_status_list);
        self.* = undefined;
    }
};

/// 对应 `WxCloudDatabaseCreateIndexRequest`(请求侧,借用视图)。
pub const CreateIndexRequest = struct {
    name: []const u8,
    unique: bool,
    keys: []const IndexKey,

    pub const IndexKey = struct { name: []const u8, direction: []const u8 };
};

/// 排序子句的键值对(对应 Java `Map<String,String> orderBy`)。
pub const OrderBy = struct { key: []const u8, direction: []const u8 };

// --- service -------------------------------------------------------------------

pub const CloudService = struct {
    svc: *mp_service.Service,
    /// env=null 的方法用它兜底(对应 Java 从 WxMaConfig.getCloudEnv() 取)。
    default_env: []const u8,

    fn envOr(self: *CloudService, env: ?[]const u8) []const u8 {
        return env orelse self.default_env;
    }

    // -- 云函数 ---------------------------------------------------------------

    /// 对应 `invokeCloudFunction(env, name, body)`:POST
    /// invokecloudfunction?env=&name=(原样拼接,不转义,Java String.format 口径)
    /// → 提取 `resp_data`(gpa 拥有)。
    /// (Java 实现误用配置 env 忽略入参;此处以入参优先,null 走 default_env。)
    pub fn invokeCloudFunction(self: *CloudService, io: std.Io, env: ?[]const u8, name: []const u8, body: []const u8) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const uri = std.fmt.allocPrint(gpa, "{s}?env={s}&name={s}", .{ INVOKE_CLOUD_FUNCTION_URL, self.envOr(env), name }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(uri);
        const resp = switch (self.svc.post(io, uri, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "cloud function not json", .{}) };
        defer parsed.deinit();
        const data = json_util.getStr(parsed.value, "resp_data") orelse
            return .{ .err = WxError.transport(gpa, "cloud function missing `resp_data`", .{}) };
        return .{ .ok = gpa.dupe(u8, data) catch return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    // -- 数据库 CRUD ----------------------------------------------------------

    /// 对应 `add(collection, list)`:POST databaseadd
    /// `{env,query:"db.collection('C').add({data: [...]})"}` → id_list[](gpa 拥有)。
    /// data_json 为 JSON 数组文本(Java List<?> 序列化)。
    pub fn add(self: *CloudService, io: std.Io, env: ?[]const u8, collection: []const u8, data_json: []const u8) WxResult([][]const u8) {
        const gpa = self.svc.gpa;
        // 拼接:db.collection('C').add({data: <data>})  —— "data:" 后带空格
        const query_str = std.fmt.allocPrint(gpa, "db.collection('{s}').add({{data: {s}}})", .{ collection, data_json }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(query_str);
        return self.idListPost(io, DATABASE_ADD_URL, env, query_str);
    }

    /// 对应 `add(collection, obj)`:同 add,但 data_json 为单对象 JSON,
    /// 取 id_list 首个(gpa 拥有)。
    pub fn addOne(self: *CloudService, io: std.Io, env: ?[]const u8, collection: []const u8, data_json: []const u8) WxResult([]const u8) {
        const gpa = self.svc.gpa;
        const query_str = std.fmt.allocPrint(gpa, "db.collection('{s}').add({{data: {s}}})", .{ collection, data_json }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(query_str);
        const ids = switch (self.idListPost(io, DATABASE_ADD_URL, env, query_str)) {
            .ok => |v| v,
            .err => |e| return .{ .err = e },
        };
        defer {
            for (ids) |s| gpa.free(@constCast(s));
            gpa.free(ids);
        }
        if (ids.len == 0) return .{ .err = WxError.transport(gpa, "cloud add empty `id_list`", .{}) };
        return .{ .ok = gpa.dupe(u8, ids[0]) catch return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `databaseAdd(env, query)`:POST databaseadd {env,query} → id_list[]
    /// (query 原样透传,gpa 拥有)。
    pub fn databaseAdd(self: *CloudService, io: std.Io, env: ?[]const u8, query_str: []const u8) WxResult([][]const u8) {
        return self.idListPost(io, DATABASE_ADD_URL, env, query_str);
    }

    /// 对应 `delete(collection, whereJson)`:POST databasedelete
    /// `{env,query:"db.collection('C').where(W).remove()"}` → deleted 计数。
    pub fn delete(self: *CloudService, io: std.Io, env: ?[]const u8, collection: []const u8, where_json: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        const query_str = std.fmt.allocPrint(gpa, "db.collection('{s}').where({s}).remove()", .{ collection, where_json }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(query_str);
        return self.countPost(io, DATABASE_DELETE_URL, env, query_str, "deleted");
    }

    /// 对应 `databaseDelete(env, query)` → deleted 计数。
    pub fn databaseDelete(self: *CloudService, io: std.Io, env: ?[]const u8, query_str: []const u8) WxResult(i64) {
        return self.countPost(io, DATABASE_DELETE_URL, env, query_str, "deleted");
    }

    /// 对应 `update(collection, whereJson, updateJson)`:POST databaseupdate
    /// `{env,query:"db.collection('C').where(W).update({data:U })"}`
    /// (注意 `{data:` 后无空格、`})` 前有一空格,与 Java 拼接一致)
    /// → DatabaseUpdateResult(matched/modified/id)。
    pub fn update(self: *CloudService, io: std.Io, env: ?[]const u8, collection: []const u8, where_json: []const u8, update_json: []const u8) WxResult(DatabaseUpdateResult) {
        const gpa = self.svc.gpa;
        const query_str = std.fmt.allocPrint(gpa, "db.collection('{s}').where({s}).update({{data:{s} }})", .{ collection, where_json, update_json }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(query_str);
        return self.updatePost(io, env, query_str);
    }

    /// 对应 `databaseUpdate(env, query)`(query 原样透传)。
    pub fn databaseUpdate(self: *CloudService, io: std.Io, env: ?[]const u8, query_str: []const u8) WxResult(DatabaseUpdateResult) {
        return self.updatePost(io, env, query_str);
    }

    /// 对应 `query(collection, whereJson, orderBy, skip, limit)`:POST
    /// databasequery `{env,query:"db.collection('C').where(W).orderBy('k', 'v')
    /// .skip(N).limit(M).get()"}`;where 空串 → `{}`;limit null → 100,
    /// skip null → 0 → DatabaseQueryResult(pager/data[])。
    pub fn query(self: *CloudService, io: std.Io, env: ?[]const u8, collection: []const u8, where_json: []const u8, order_by: ?[]const OrderBy, skip: ?i64, limit: ?i64) WxResult(DatabaseQueryResult) {
        const gpa = self.svc.gpa;
        const where = if (where_json.len == 0) "{}" else where_json;
        const skip_v = skip orelse 0;
        const limit_v = limit orelse 100;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.print("db.collection('{s}').where({s})", .{ collection, where }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (order_by) |obs| {
            for (obs) |ob| {
                w.print(".orderBy('{s}', '{s}')", .{ ob.key, ob.direction }) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        w.print(".skip({d}).limit({d}).get()", .{ skip_v, limit_v }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const query_str = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(query_str);
        return self.queryPost(io, env, query_str);
    }

    /// 对应 `databaseQuery(env, query)`(query 原样透传)。
    pub fn databaseQuery(self: *CloudService, io: std.Io, env: ?[]const u8, query_str: []const u8) WxResult(DatabaseQueryResult) {
        return self.queryPost(io, env, query_str);
    }

    /// 对应 `databaseAggregate(env, query)`:POST databaseaggregate
    /// {env,query} → data 数组(每项原始 JSON 文本,gpa 拥有)。
    pub fn databaseAggregate(self: *CloudService, io: std.Io, env: ?[]const u8, query_str: []const u8) WxResult([][]const u8) {
        const gpa = self.svc.gpa;
        const body = envQueryBody(gpa, self.envOr(env), query_str) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DATABASE_AGGREGATE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "cloud aggregate not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "data") orelse
            return .{ .err = WxError.transport(gpa, "cloud aggregate missing `data`", .{}) };
        return .{ .ok = stringArray(gpa, arr) catch return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    /// 对应 `count(collection, whereJson)`:POST databasecount
    /// `{env,query:"db.collection('C').where(W).count()"}` → count 计数。
    pub fn count(self: *CloudService, io: std.Io, env: ?[]const u8, collection: []const u8, where_json: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        const query_str = std.fmt.allocPrint(gpa, "db.collection('{s}').where({s}).count()", .{ collection, where_json }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(query_str);
        return self.countPost(io, DATABASE_COUNT_URL, env, query_str, "count");
    }

    /// 对应 `databaseCount(env, query)` → count 计数。
    pub fn databaseCount(self: *CloudService, io: std.Io, env: ?[]const u8, query_str: []const u8) WxResult(i64) {
        return self.countPost(io, DATABASE_COUNT_URL, env, query_str, "count");
    }

    // -- 索引 ----------------------------------------------------------------

    /// 对应 `updateIndex(env, collectionName, createIndexes, dropIndexNames)`:
    /// POST updateindex {env,collection_name,create_indexes:[{name,unique,
    /// keys:[{name,direction}]}],drop_indexes:[{name}]}。
    pub fn updateIndex(self: *CloudService, io: std.Io, env: ?[]const u8, collection_name: []const u8, create_indexes: []const CreateIndexRequest, drop_index_names: ?[]const []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"collection_name\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, collection_name) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        // create_indexes
        w.writeAll(",\"create_indexes\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (create_indexes, 0..) |ci, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.writeAll("{\"name\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, ci.name) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.print(",\"unique\":{},\"keys\":[", .{ci.unique}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            for (ci.keys, 0..) |k, j| {
                if (j > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                w.writeAll("{\"name\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                js(w, k.name) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                w.writeAll(",\"direction\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                js(w, k.direction) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
            w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        // drop_indexes
        w.writeAll("],\"drop_indexes\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (drop_index_names) |names| {
            for (names, 0..) |n, i| {
                if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                w.writeAll("{\"name\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                js(w, n) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, UPDATE_INDEX_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    // -- 迁移 ----------------------------------------------------------------

    /// 对应 `databaseMigrateImport(env, collectionName, filePath, fileType,
    /// stopOnError, conflictMode)`:POST databasemigrateimport
    /// {env,collection_name,file_path,file_type,stop_on_error,conflict_mode}
    /// → job_id。
    pub fn databaseMigrateImport(self: *CloudService, io: std.Io, env: ?[]const u8, collection_name: []const u8, file_path: []const u8, file_type: i64, stop_on_error: bool, conflict_mode: i64) WxResult(i64) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"collection_name\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, collection_name) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"file_path\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, file_path) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.print(",\"file_type\":{d},\"stop_on_error\":{},\"conflict_mode\":{d}}}", .{ file_type, stop_on_error, conflict_mode }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.jobIdPost(io, DATABASE_MIGRATE_IMPORT_URL, body);
    }

    /// 对应 `databaseMigrateExport(env, filePath, fileType, query)`:POST
    /// databasemigrateexport {env,file_path,file_type,query} → job_id。
    pub fn databaseMigrateExport(self: *CloudService, io: std.Io, env: ?[]const u8, file_path: []const u8, file_type: i64, query_str: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"file_path\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, file_path) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.print(",\"file_type\":{d},\"query\":", .{file_type}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, query_str) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        return self.jobIdPost(io, DATABASE_MIGRATE_EXPORT_URL, body);
    }

    /// 对应 `databaseMigrateQueryInfo(env, jobId)`:POST databasemigratequeryinfo
    /// {env,job_id} → MigrateQueryInfo(status/record_success/record_fail/
    /// err_msg/file_url)。
    pub fn databaseMigrateQueryInfo(self: *CloudService, io: std.Io, env: ?[]const u8, job_id: i64) WxResult(MigrateQueryInfo) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"env\":\"{s}\",\"job_id\":{d}}}", .{ self.envOr(env), job_id }) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DATABASE_MIGRATE_QUERY_INFO_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "migrate info not json", .{}) };
        defer parsed.deinit();
        var out = MigrateQueryInfo{
            .gpa = gpa,
            .record_success = json_util.getInt(parsed.value, "record_success"),
            .record_fail = json_util.getInt(parsed.value, "record_fail"),
            .status = null,
            .err_msg = null,
            .file_url = null,
        };
        if (json_util.getStr(parsed.value, "status")) |s| out.status = gpa.dupe(u8, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(parsed.value, "err_msg")) |s| out.err_msg = gpa.dupe(u8, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(parsed.value, "file_url")) |s| out.file_url = gpa.dupe(u8, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    // -- 文件 ----------------------------------------------------------------

    /// 对应 `uploadFile(env, path)`:POST uploadfile {env,path}
    /// → UploadFileResult(url/token/authorization/file_id/cos_file_id)。
    pub fn uploadFile(self: *CloudService, io: std.Io, env: ?[]const u8, path: []const u8) WxResult(UploadFileResult) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"path\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, path) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, UPLOAD_FILE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "upload file not json", .{}) };
        defer parsed.deinit();
        var out2 = UploadFileResult{ .gpa = gpa };
        if (json_util.getStr(parsed.value, "url")) |s| out2.url = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(parsed.value, "token")) |s| out2.token = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(parsed.value, "authorization")) |s| out2.authorization = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(parsed.value, "file_id")) |s| out2.file_id = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(parsed.value, "cos_file_id")) |s| out2.cos_file_id = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out2 };
    }

    /// 对应 `batchDownloadFile(env, fileIds, maxAges)`:POST batchdownloadfile
    /// {env,file_list:[{fileid,max_age}]} → BatchDownloadFileResult(file_list[])。
    pub fn batchDownloadFile(self: *CloudService, io: std.Io, env: ?[]const u8, file_ids: []const []const u8, max_ages: []const i64) WxResult(BatchDownloadFileResult) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"file_list\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (file_ids, 0..) |fid, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            w.writeAll("{\"fileid\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, fid) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            // Java 按 fileIds 逐一取 maxAges[i++],越界会抛异常;此处取 0 兜底
            const age = if (i < max_ages.len) max_ages[i] else 0;
            w.print(",\"max_age\":{d}}}", .{age}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, BATCH_DOWNLOAD_FILE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "batch download not json", .{}) };
        defer parsed.deinit();
        var out2 = BatchDownloadFileResult{ .gpa = gpa, .file_list = &.{} };
        if (json_util.getArray(parsed.value, "file_list")) |arr| {
            out2.file_list = parseFileDownloadInfos(gpa, arr) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        return .{ .ok = out2 };
    }

    /// 对应 `batchDeleteFile(env, fileIds)`:POST batchdeletefile
    /// {env,fileid_list:[...]} → BatchDeleteFileResult(delete_list[])。
    pub fn batchDeleteFile(self: *CloudService, io: std.Io, env: ?[]const u8, file_ids: []const []const u8) WxResult(BatchDeleteFileResult) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"fileid_list\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (file_ids, 0..) |fid, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, fid) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, BATCH_DELETE_FILE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "batch delete not json", .{}) };
        defer parsed.deinit();
        var out2 = BatchDeleteFileResult{ .gpa = gpa, .delete_list = &.{} };
        if (json_util.getArray(parsed.value, "delete_list")) |arr| {
            out2.delete_list = parseFileDownloadInfos(gpa, arr) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        return .{ .ok = out2 };
    }

    /// 对应 `getQcloudToken(lifeSpan)`:POST getqcloudtoken {lifespan}
    /// → QcloudToken(secretid/secretkey/token/expired_time)。
    pub fn getQcloudToken(self: *CloudService, io: std.Io, lifespan: i64) WxResult(QcloudToken) {
        const gpa = self.svc.gpa;
        const body = std.fmt.allocPrint(gpa, "{{\"lifespan\":{d}}}", .{lifespan}) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, GET_QCLOUD_TOKEN_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "qcloud token not json", .{}) };
        defer parsed.deinit();
        var out = QcloudToken{
            .gpa = gpa,
            .expired_time = json_util.getInt(parsed.value, "expired_time"),
        };
        if (json_util.getStr(parsed.value, "secretid")) |s| out.secretid = gpa.dupe(u8, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(parsed.value, "secretkey")) |s| out.secretkey = gpa.dupe(u8, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (json_util.getStr(parsed.value, "token")) |s| out.token = gpa.dupe(u8, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    // -- 集合管理 --------------------------------------------------------------

    /// 对应 `databaseCollectionAdd(env, collectionName)`:POST
    /// databasecollectionadd {env,collection_name}。
    pub fn databaseCollectionAdd(self: *CloudService, io: std.Io, env: ?[]const u8, collection_name: []const u8) Done {
        return self.collectionPost(io, DATABASE_COLLECTION_ADD_URL, env, collection_name);
    }

    /// 对应 `databaseCollectionDelete(env, collectionName)`:POST
    /// databasecollectiondelete {env,collection_name}。
    pub fn databaseCollectionDelete(self: *CloudService, io: std.Io, env: ?[]const u8, collection_name: []const u8) Done {
        return self.collectionPost(io, DATABASE_COLLECTION_DELETE_URL, env, collection_name);
    }

    /// 对应 `databaseCollectionGet(env, limit, offset)`:POST
    /// databasecollectionget {env[,limit][,offset]}(null 省略)
    /// → CollectionGetResult(pager/collections[])。
    pub fn databaseCollectionGet(self: *CloudService, io: std.Io, env: ?[]const u8, limit: ?i64, offset: ?i64) WxResult(CollectionGetResult) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (limit) |v| w.print(",\"limit\":{d}", .{v}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (offset) |v| w.print(",\"offset\":{d}", .{v}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, DATABASE_COLLECTION_GET_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "collection get not json", .{}) };
        defer parsed.deinit();

        var out2 = CollectionGetResult{ .gpa = gpa, .collections = &.{} };
        errdefer out2.deinit();
        if (json_util.getObject(parsed.value, "pager")) |p| {
            out2.pager = .{
                .offset = json_util.getInt(p, "Offset"),
                .limit = json_util.getInt(p, "Limit"),
                .total = json_util.getInt(p, "Total"),
            };
        }
        if (json_util.getArray(parsed.value, "collections")) |arr| {
            const items = gpa.alloc(CollectionInfo, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |*c| c.deinit();
                gpa.free(items);
            }
            for (arr.items) |item| {
                var c = CollectionInfo{
                    .gpa = gpa,
                    .count = json_util.getInt(item, "count"),
                    .size = json_util.getInt(item, "size"),
                    .index_count = json_util.getInt(item, "index_count"),
                    .index_size = json_util.getInt(item, "index_size"),
                    .name = null,
                };
                if (json_util.getStr(item, "name")) |s| c.name = gpa.dupe(u8, s) catch
                    return .{ .err = WxError.internal(gpa, "oom", .{}) };
                items[filled] = c;
                filled += 1;
            }
            out2.collections = items;
        }
        return .{ .ok = out2 };
    }

    // -- 短信 ----------------------------------------------------------------

    /// 对应 `sendSmsV2(request)`:POST sendsmsv2(请求体为 bean 序列化,
    /// null 字段省略;env 为 null 时用 default_env 兜底)
    /// → SendSmsV2Result(send_status_list[])。
    pub fn sendSmsV2(self: *CloudService, io: std.Io, request: SendSmsV2Request) WxResult(SendSmsV2Result) {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(request.env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (request.url_link) |v| {
            w.writeAll(",\"url_link\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        if (request.template_id) |v| {
            w.writeAll(",\"template_id\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        if (request.template_param_list) |params| {
            w.writeAll(",\"template_param_list\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            for (params, 0..) |p, i| {
                if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                js(w, p) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            }
            w.writeAll("]") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll(",\"phone_number_list\":[") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        for (request.phone_number_list, 0..) |p, i| {
            if (i > 0) w.writeAll(",") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, p) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("]") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        if (request.use_short_name) |v| {
            w.print(",\"use_short_name\":{}", .{v}) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        if (request.resource_appid) |v| {
            w.writeAll(",\"resource_appid\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
            js(w, v) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);

        const resp = switch (self.svc.post(io, SEND_SMS_V2_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "send sms not json", .{}) };
        defer parsed.deinit();
        var out2 = SendSmsV2Result{ .gpa = gpa, .send_status_list = &.{} };
        if (json_util.getArray(parsed.value, "send_status_list")) |arr| {
            const items = gpa.alloc(SendSmsV2Result.SendStatus, arr.items.len) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
            var filled: usize = 0;
            errdefer {
                for (items[0..filled]) |*st| st.deinit();
                gpa.free(items);
            }
            for (arr.items) |item| {
                var st = SendSmsV2Result.SendStatus{ .gpa = gpa };
                if (json_util.getStr(item, "serial_no")) |s| st.serial_no = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "phone_number")) |s| st.phone_number = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "code")) |s| st.code = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "message")) |s| st.message = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                if (json_util.getStr(item, "iso_code")) |s| st.iso_code = gpa.dupe(u8, s) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
                items[filled] = st;
                filled += 1;
            }
            out2.send_status_list = items;
        }
        return .{ .ok = out2 };
    }

    // -- 内部共用 --------------------------------------------------------------

    // 内部:POST {env,query} → id_list[](字符串数组,gpa 拥有)。
    fn idListPost(self: *CloudService, io: std.Io, url: []const u8, env: ?[]const u8, query_str: []const u8) WxResult([][]const u8) {
        const gpa = self.svc.gpa;
        const body = envQueryBody(gpa, self.envOr(env), query_str) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "cloud response not json", .{}) };
        defer parsed.deinit();
        const arr = json_util.getArray(parsed.value, "id_list") orelse
            return .{ .err = WxError.transport(gpa, "cloud response missing `id_list`", .{}) };
        return .{ .ok = stringArray(gpa, arr) catch return .{ .err = WxError.internal(gpa, "oom", .{}) } };
    }

    // 内部:POST {env,query} → <count_key> 计数(deleted/count)。
    fn countPost(self: *CloudService, io: std.Io, url: []const u8, env: ?[]const u8, query_str: []const u8, comptime count_key: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        const body = envQueryBody(gpa, self.envOr(env), query_str) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "cloud response not json", .{}) };
        defer parsed.deinit();
        const n = json_util.getInt(parsed.value, count_key) orelse
            return .{ .err = WxError.transport(gpa, "cloud response missing `{s}`", .{count_key}) };
        return .{ .ok = n };
    }

    // 内部:POST {env,query} → DatabaseUpdateResult(databaseupdate)。
    fn updatePost(self: *CloudService, io: std.Io, env: ?[]const u8, query_str: []const u8) WxResult(DatabaseUpdateResult) {
        const gpa = self.svc.gpa;
        const body = envQueryBody(gpa, self.envOr(env), query_str) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DATABASE_UPDATE_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "cloud update not json", .{}) };
        defer parsed.deinit();
        var out = DatabaseUpdateResult{
            .gpa = gpa,
            .matched = json_util.getInt(parsed.value, "matched"),
            .modified = json_util.getInt(parsed.value, "modified"),
            .id = null,
        };
        if (json_util.getStr(parsed.value, "id")) |s| out.id = gpa.dupe(u8, s) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        return .{ .ok = out };
    }

    // 内部:POST {env,query} → DatabaseQueryResult(pager/data[])。
    fn queryPost(self: *CloudService, io: std.Io, env: ?[]const u8, query_str: []const u8) WxResult(DatabaseQueryResult) {
        const gpa = self.svc.gpa;
        const body = envQueryBody(gpa, self.envOr(env), query_str) catch
            return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, DATABASE_QUERY_URL, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "cloud query not json", .{}) };
        defer parsed.deinit();
        var out = DatabaseQueryResult{ .gpa = gpa, .data = &.{} };
        errdefer out.deinit();
        if (json_util.getObject(parsed.value, "pager")) |p| {
            out.pager = .{
                .offset = json_util.getInt(p, "Offset"),
                .limit = json_util.getInt(p, "Limit"),
                .total = json_util.getInt(p, "Total"),
            };
        }
        if (json_util.getArray(parsed.value, "data")) |arr| {
            out.data = stringArray(gpa, arr) catch
                return .{ .err = WxError.internal(gpa, "oom", .{}) };
        }
        return .{ .ok = out };
    }

    // 内部:POST {env,collection_name}(集合增删)。
    fn collectionPost(self: *CloudService, io: std.Io, url: []const u8, env: ?[]const u8, collection_name: []const u8) Done {
        const gpa = self.svc.gpa;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        w.writeAll("{\"env\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, self.envOr(env)) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll(",\"collection_name\":") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        js(w, collection_name) catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        w.writeAll("}") catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        const body = out.toOwnedSlice() catch return .{ .err = WxError.internal(gpa, "oom", .{}) };
        defer gpa.free(body);
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        gpa.free(resp);
        return .{ .ok = {} };
    }

    // 内部:POST 预构建 body → job_id(迁移任务)。
    fn jobIdPost(self: *CloudService, io: std.Io, url: []const u8, body: []const u8) WxResult(i64) {
        const gpa = self.svc.gpa;
        const resp = switch (self.svc.post(io, url, &.{}, body)) {
            .ok => |b| b,
            .err => |e| return .{ .err = e },
        };
        defer gpa.free(resp);
        const parsed = json_util.parse(gpa, resp) catch
            return .{ .err = WxError.transport(gpa, "cloud migrate not json", .{}) };
        defer parsed.deinit();
        const n = json_util.getInt(parsed.value, "job_id") orelse
            return .{ .err = WxError.transport(gpa, "cloud migrate missing `job_id`", .{}) };
        return .{ .ok = n };
    }
};

// --- 内部辅助 ----------------------------------------------------------------

// 内部:{env,query} 请求体(键序与 Java ImmutableMap/JsonObject 一致)。
fn envQueryBody(gpa: std.mem.Allocator, env: []const u8, query: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"env\":");
    try js(w, env);
    try w.writeAll(",\"query\":");
    try js(w, query);
    try w.writeAll("}");
    return out.toOwnedSlice();
}

// 内部:字符串数组 → gpa 拥有的 [][]const u8(非字符串元素按 JSON 序列化,
// 对应 Java getAsString() 的宽容口径)。
fn stringArray(gpa: std.mem.Allocator, arr: std.ArrayList(std.json.Value)) ![][]const u8 {
    const items = try gpa.alloc([]const u8, arr.items.len);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |s| gpa.free(@constCast(s));
        gpa.free(items);
    }
    for (arr.items) |item| {
        switch (item) {
            .string => |s| items[filled] = try gpa.dupe(u8, s),
            else => {
                // 数字/对象等:getAsString 语义 → 序列化原样文本
                const text = try json_util.stringify(gpa, item);
                items[filled] = text;
            },
        }
        filled += 1;
    }
    return items;
}

// 内部:解析文件下载/删除结果数组(fileid/download_url/status/errmsg)。
fn parseFileDownloadInfos(gpa: std.mem.Allocator, arr: std.ArrayList(std.json.Value)) ![]FileDownloadInfo {
    const items = try gpa.alloc(FileDownloadInfo, arr.items.len);
    var filled: usize = 0;
    errdefer {
        for (items[0..filled]) |*f| f.deinit();
        gpa.free(items);
    }
    for (arr.items) |item| {
        var f = FileDownloadInfo{
            .gpa = gpa,
            .status = json_util.getInt(item, "status"),
            .fileid = null,
            .download_url = null,
            .errmsg = null,
        };
        if (json_util.getStr(item, "fileid")) |s| f.fileid = try gpa.dupe(u8, s);
        if (json_util.getStr(item, "download_url")) |s| f.download_url = try gpa.dupe(u8, s);
        if (json_util.getStr(item, "errmsg")) |s| f.errmsg = try gpa.dupe(u8, s);
        items[filled] = f;
        filled += 1;
    }
    return items;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const mock_mod = @import("_mock.zig");

test "cloud invokeCloudFunction/add/delete/update/count" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "invokecloudfunction", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"resp_data\":\"{\\\"sum\\\":3}\"}" },
        .{ .match = "databaseadd", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"id_list\":[\"id1\",\"id2\"]}" },
        .{ .match = "databasedelete", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"deleted\":5}" },
        .{ .match = "databaseupdate", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"matched\":2,\"modified\":1,\"id\":\"newid\"}" },
        .{ .match = "databasecount", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"count\":42}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CloudService{ .svc = &base, .default_env = "env-1" };

    // invokeCloudFunction:URL 原样拼接 env/name → resp_data
    const resp_data = switch (s.invokeCloudFunction(io, null, "fn1", "{\"a\":1}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(@constCast(resp_data));
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "/tcb/invokecloudfunction?env=env-1&name=fn1") != null);
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "access_token=") != null); // 基座自动附加
    try std.testing.expectEqualStrings("{\"a\":1}", m.last_body);
    try std.testing.expectEqualStrings("{\"sum\":3}", resp_data);

    // 显式 env 覆盖 default_env
    const rd2 = s.invokeCloudFunction(io, "env-2", "fn1", "{}");
    try std.testing.expect(std.mem.indexOf(u8, m.last_uri, "env=env-2") != null);
    switch (rd2) {
        .ok => |v| gpa.free(@constCast(v)),
        .err => return error.Unexpected,
    }

    // add:{env,query} 查询串逐字符对齐 Java
    const ids = switch (s.add(io, null, "tasks", "[{\"title\":\"a\"},{\"title\":\"b\"}]")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        for (ids) |id| gpa.free(@constCast(id));
        gpa.free(ids);
    }
    const expect_q = "{\"env\":\"env-1\",\"query\":\"db.collection('tasks').add({data: [{\\\"title\\\":\\\"a\\\"},{\\\"title\\\":\\\"b\\\"}]})\"}";
    try std.testing.expectEqualStrings(expect_q, m.last_body);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("id1", ids[0]);

    // addOne:取 id_list 首个
    const one = switch (s.addOne(io, null, "tasks", "{\"title\":\"c\"}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer gpa.free(@constCast(one));
    try std.testing.expectEqualStrings("id1", one);
    const expect_q1 = "{\"env\":\"env-1\",\"query\":\"db.collection('tasks').add({data: {\\\"title\\\":\\\"c\\\"}})\"}";
    try std.testing.expectEqualStrings(expect_q1, m.last_body);

    // delete:{env,query:"db.collection('C').where(W).remove()"} → deleted
    const deleted = switch (s.delete(io, null, "tasks", "{\"done\":true}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(i64, 5), deleted);
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"query\":\"db.collection('tasks').where({\\\"done\\\":true}).remove()\"}", m.last_body);

    // update:注意 `{data:U }` 的空格口径
    const upd = switch (s.update(io, null, "tasks", "{\"done\":false}", "{\"done\":true}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var u = upd;
    defer u.deinit();
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"query\":\"db.collection('tasks').where({\\\"done\\\":false}).update({data:{\\\"done\\\":true} })\"}", m.last_body);
    try std.testing.expectEqual(@as(i64, 2), u.matched.?);
    try std.testing.expectEqual(@as(i64, 1), u.modified.?);
    try std.testing.expectEqualStrings("newid", u.id.?);

    // count:{env,query:"...count()"} → count
    const cnt = switch (s.count(io, null, "tasks", "{}")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(i64, 42), cnt);
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"query\":\"db.collection('tasks').where({}).count()\"}", m.last_body);
}

test "cloud query/aggregate/index" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "databasequery", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"pager\":{\"Offset\":0,\"Limit\":10,\"Total\":1},\"data\":[\"{\\\"_id\\\":\\\"x1\\\",\\\"n\\\":1}\"]}" },
        .{ .match = "databaseaggregate", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"data\":[\"{\\\"_id\\\":\\\"g1\\\",\\\"sum\\\":3}\"]}" },
        .{ .match = "updateindex", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CloudService{ .svc = &base, .default_env = "env-1" };

    // query:空 where→{},orderBy 逐条拼接,skip/limit 默认 0/100
    const q = switch (s.query(io, null, "tasks", "", &.{.{ .key = "n", .direction = "1" }}, null, null)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var qr = q;
    defer qr.deinit();
    try std.testing.expectEqualStrings(
        "{\"env\":\"env-1\",\"query\":\"db.collection('tasks').where({}).orderBy('n', '1').skip(0).limit(100).get()\"}",
        m.last_body,
    );
    try std.testing.expectEqual(@as(i64, 0), qr.pager.offset.?);
    try std.testing.expectEqual(@as(i64, 10), qr.pager.limit.?);
    try std.testing.expectEqual(@as(i64, 1), qr.pager.total.?);
    try std.testing.expectEqual(@as(usize, 1), qr.data.len);
    try std.testing.expectEqualStrings("{\"_id\":\"x1\",\"n\":1}", qr.data[0]);

    // query:显式 where/skip/limit
    const q2r = s.query(io, "env-2", "tasks", "{\"n\":{$gt:1}}", null, 20, 5);
    try std.testing.expectEqualStrings(
        "{\"env\":\"env-2\",\"query\":\"db.collection('tasks').where({\\\"n\\\":{$gt:1}}).skip(20).limit(5).get()\"}",
        m.last_body,
    );
    switch (q2r) {
        .ok => |v| {
            var v2 = v;
            v2.deinit();
        },
        .err => return error.Unexpected,
    }

    // databaseQuery:原样透传
    const dq = switch (s.databaseQuery(io, null, "db.collection('x').get()")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var dqv = dq;
    defer dqv.deinit();
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"query\":\"db.collection('x').get()\"}", m.last_body);

    // databaseAggregate:data 数组 → 原始 JSON 文本
    const agg = switch (s.databaseAggregate(io, null, "db.collection('x').aggregate()")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    defer {
        for (agg) |a| gpa.free(@constCast(a));
        gpa.free(agg);
    }
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"query\":\"db.collection('x').aggregate()\"}", m.last_body);
    try std.testing.expectEqual(@as(usize, 1), agg.len);
    try std.testing.expectEqualStrings("{\"_id\":\"g1\",\"sum\":3}", agg[0]);

    // updateIndex:{env,collection_name,create_indexes,drop_indexes}
    try std.testing.expect(!s.updateIndex(io, null, "tasks", &.{
        .{ .name = "idx1", .unique = true, .keys = &.{ .{ .name = "n", .direction = "1" }, .{ .name = "loc", .direction = "2dsphere" } } },
    }, &.{"idx0"}).failed());
    try std.testing.expectEqualStrings(
        "{\"env\":\"env-1\",\"collection_name\":\"tasks\",\"create_indexes\":[{\"name\":\"idx1\",\"unique\":true,\"keys\":[{\"name\":\"n\",\"direction\":\"1\"},{\"name\":\"loc\",\"direction\":\"2dsphere\"}]}],\"drop_indexes\":[{\"name\":\"idx0\"}]}",
        m.last_body,
    );

    // updateIndex:drop null → 空数组
    try std.testing.expect(!s.updateIndex(io, null, "tasks", &.{}, null).failed());
    try std.testing.expectEqualStrings(
        "{\"env\":\"env-1\",\"collection_name\":\"tasks\",\"create_indexes\":[],\"drop_indexes\":[]}",
        m.last_body,
    );
}

test "cloud migrate/file/token/collection/sms" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var m = mock_mod.MockExecutor.init(gpa, &.{
        .{ .match = "databasemigrateimport", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"job_id\":101}" },
        .{ .match = "databasemigrateexport", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"job_id\":102}" },
        .{ .match = "databasemigratequeryinfo", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"status\":\"finish\",\"record_success\":100,\"record_fail\":0,\"file_url\":\"https://f/1\"}" },
        .{ .match = "uploadfile", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"url\":\"https://up\",\"token\":\"tk\",\"authorization\":\"ak\",\"file_id\":\"fid\",\"cos_file_id\":\"cos1\"}" },
        .{ .match = "batchdownloadfile", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"file_list\":[{\"fileid\":\"fid\",\"download_url\":\"https://dl\",\"status\":0}]}" },
        .{ .match = "batchdeletefile", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"delete_list\":[{\"fileid\":\"fid\",\"status\":0}]}" },
        .{ .match = "getqcloudtoken", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"secretid\":\"sid\",\"secretkey\":\"skey\",\"token\":\"tk\",\"expired_time\":1700000000}" },
        .{ .match = "databasecollectionadd", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "databasecollectiondelete", .response = "{\"errcode\":0,\"errmsg\":\"ok\"}" },
        .{ .match = "databasecollectionget", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"pager\":{\"Offset\":0,\"Limit\":10,\"Total\":1},\"collections\":[{\"name\":\"tasks\",\"count\":5,\"size\":1024,\"index_count\":1,\"index_size\":128}]}" },
        .{ .match = "sendsmsv2", .response = "{\"errcode\":0,\"errmsg\":\"ok\",\"send_status_list\":[{\"serial_no\":\"sn1\",\"phone_number\":\"13800000000\",\"code\":\"0\",\"message\":\"ok\",\"iso_code\":\"86\"}]}" },
    });
    defer m.deinit();
    var cfg = try mock_mod.fakeTokenConfig(gpa);
    defer cfg.deinit();
    var base = mp_service.Service.init(gpa, cfg.config(), m.executor());
    var s = CloudService{ .svc = &base, .default_env = "env-1" };

    // databaseMigrateImport
    const j1 = switch (s.databaseMigrateImport(io, null, "tasks", "/f/import.csv", 1, true, 1)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(i64, 101), j1);
    try std.testing.expectEqualStrings(
        "{\"env\":\"env-1\",\"collection_name\":\"tasks\",\"file_path\":\"/f/import.csv\",\"file_type\":1,\"stop_on_error\":true,\"conflict_mode\":1}",
        m.last_body,
    );

    // databaseMigrateExport
    const j2 = switch (s.databaseMigrateExport(io, null, "/f/export.csv", 1, "db.collection('tasks').get()")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    try std.testing.expectEqual(@as(i64, 102), j2);
    try std.testing.expectEqualStrings(
        "{\"env\":\"env-1\",\"file_path\":\"/f/export.csv\",\"file_type\":1,\"query\":\"db.collection('tasks').get()\"}",
        m.last_body,
    );

    // databaseMigrateQueryInfo
    const qi = switch (s.databaseMigrateQueryInfo(io, null, 101)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var qiv = qi;
    defer qiv.deinit();
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"job_id\":101}", m.last_body);
    try std.testing.expectEqualStrings("finish", qiv.status.?);
    try std.testing.expectEqual(@as(i64, 100), qiv.record_success.?);
    try std.testing.expectEqualStrings("https://f/1", qiv.file_url.?);

    // uploadFile
    const up = switch (s.uploadFile(io, null, "a/b.png")) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var upv = up;
    defer upv.deinit();
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"path\":\"a/b.png\"}", m.last_body);
    try std.testing.expectEqualStrings("https://up", upv.url.?);
    try std.testing.expectEqualStrings("fid", upv.file_id.?);
    try std.testing.expectEqualStrings("cos1", upv.cos_file_id.?);

    // batchDownloadFile
    const dl = switch (s.batchDownloadFile(io, null, &.{ "fid", "fid2" }, &.{ 86400, 3600 })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var dlv = dl;
    defer dlv.deinit();
    try std.testing.expectEqualStrings(
        "{\"env\":\"env-1\",\"file_list\":[{\"fileid\":\"fid\",\"max_age\":86400},{\"fileid\":\"fid2\",\"max_age\":3600}]}",
        m.last_body,
    );
    try std.testing.expectEqual(@as(usize, 1), dlv.file_list.len);
    try std.testing.expectEqualStrings("https://dl", dlv.file_list[0].download_url.?);

    // batchDeleteFile
    const del = switch (s.batchDeleteFile(io, null, &.{"fid"})) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var delv = del;
    defer delv.deinit();
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"fileid_list\":[\"fid\"]}", m.last_body);
    try std.testing.expectEqual(@as(usize, 1), delv.delete_list.len);

    // getQcloudToken
    const tk = switch (s.getQcloudToken(io, 7200)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var tkv = tk;
    defer tkv.deinit();
    try std.testing.expectEqualStrings("{\"lifespan\":7200}", m.last_body);
    try std.testing.expectEqualStrings("sid", tkv.secretid.?);
    try std.testing.expectEqualStrings("skey", tkv.secretkey.?);
    try std.testing.expectEqual(@as(i64, 1700000000), tkv.expired_time.?);

    // databaseCollectionAdd/Delete
    try std.testing.expect(!s.databaseCollectionAdd(io, null, "tasks").failed());
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"collection_name\":\"tasks\"}", m.last_body);
    try std.testing.expect(!s.databaseCollectionDelete(io, null, "tasks").failed());
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"collection_name\":\"tasks\"}", m.last_body);

    // databaseCollectionGet:null 省略 / 显式
    const cg = switch (s.databaseCollectionGet(io, null, null, null)) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var cgv = cg;
    defer cgv.deinit();
    try std.testing.expectEqualStrings("{\"env\":\"env-1\"}", m.last_body);
    try std.testing.expectEqual(@as(i64, 1), cgv.pager.total.?);
    try std.testing.expectEqual(@as(usize, 1), cgv.collections.len);
    try std.testing.expectEqualStrings("tasks", cgv.collections[0].name.?);
    try std.testing.expectEqual(@as(i64, 5), cgv.collections[0].count.?);
    try std.testing.expectEqual(@as(i64, 128), cgv.collections[0].index_size.?);

    const cg2r = s.databaseCollectionGet(io, null, 10, 20);
    try std.testing.expectEqualStrings("{\"env\":\"env-1\",\"limit\":10,\"offset\":20}", m.last_body);
    switch (cg2r) {
        .ok => |v| {
            var v2 = v;
            v2.deinit();
        },
        .err => return error.Unexpected,
    }

    // sendSmsV2:env 兜底 + null 字段省略
    const sm = switch (s.sendSmsV2(io, .{
        .template_id = "TPL1",
        .template_param_list = &.{"1234"},
        .phone_number_list = &.{"13800000000"},
    })) {
        .ok => |v| v,
        .err => return error.Unexpected,
    };
    var smv = sm;
    defer smv.deinit();
    try std.testing.expectEqualStrings(
        "{\"env\":\"env-1\",\"template_id\":\"TPL1\",\"template_param_list\":[\"1234\"],\"phone_number_list\":[\"13800000000\"]}",
        m.last_body,
    );
    try std.testing.expectEqual(@as(usize, 1), smv.send_status_list.len);
    try std.testing.expectEqualStrings("sn1", smv.send_status_list[0].serial_no.?);
    try std.testing.expectEqualStrings("ok", smv.send_status_list[0].message.?);
}
