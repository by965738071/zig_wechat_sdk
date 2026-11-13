//! 微信公众号 API URL 常量表 —— 逐字镜像 Java 的
//! `weixin-java-tools/.../mp/enums/WxMpApiUrl.java`（1482 行 / 28 个嵌套枚举家族 / 276 个常量）。
//!
//! 本模块是 `wechat_mp` 全部服务 URL 路径的 **唯一数据源（single source of truth）**：
//! 取代两处旧机制 —— (1) `service.zig:33` 的 `ApiUrl` 枚举 + `asUri()`，
//! (2) 各 `services/*.zig` 里分散的 `Path` 结构体常量。旧机制由后续集成阶段迁移，
//! 本文件不做任何兼容/废弃标记。
//!
//! 组织方式：一个 `pub const Family = struct { ... };` 对应 Java 的一个嵌套 enum。
//! 28 个家族（顺序与 Java 一致）：
//!   Device, OAuth2, Other, Marketing, Menu, Qrcode, ShakeAround, SubscribeMsg,
//!   TemplateMsg, UserBlacklist, UserTag, Wifi, AiOpen, Ocr, Card, DataCube,
//!   Kefu, MassMessage, Material, MemberCard, Store, User, Comment, ImgProc,
//!   Invoice, Guide, Draft, FreePublish
//!
//! 命名规则：常量名 = Java enum 常量名整体转小写（UPPER_SNAKE -> snake_case），
//! 与 Java 一一对应；每个常量上方都有 `// Java: 原名` 注释，便于服务作者快速回查。
//!
//! 路径规则（Java -> Zig 差异）：Java `getUrl()` = `buildUrl(host, prefix, path)` 即
//! `prefix + path`；其默认 prefix 形如 `https://api.weixin.qq.com`（无尾斜杠），故 Java
//! 的 path 都带一个前导 `/`。Zig 侧 `api_host_url = "https://api.weixin.qq.com/"`
//! 自带尾斜杠，为避免 `//` 双斜杠，本模块常量统一 **去掉那一个前导 `/`**，其余字符
//! （查询串、`%s`/`%d` 占位、`#wechat_redirect` 片段、结尾的 `?`/`=`）全部逐字保留。
//! 拼接方式即 `api_host_url ++ Family.constant`。
//!
//! 主机差异：绝大多数常量走 API host；有 5 个常量在 Java 里用 MP/OPEN host，
//! 已在其注释标注 `[host: ...]`，拼接时改用 `Host.mp` / `Host.open`（见 `url`）。
//!
//! 纯数据模块：仅依赖 `std`（测试用），不依赖任何 wechat_mp 服务类型，不需要 allocator，
//! 无运行时失败路径；可被 `common` 反向 import。
const std = @import("std");

/// 对应 Java `WxMpHostConfig` 的三个默认主机。为与「无前导斜杠」的路径常量直接拼接
/// （host ++ path），这里统一带尾斜杠。
pub const Host = struct {
    pub const api = "https://api.weixin.qq.com/";
    pub const mp = "https://mp.weixin.qq.com/";
    pub const open = "https://open.weixin.qq.com/";
};

/// 对应 Java `WxMpHostConfig.buildUrl(hostConfig, prefix, path)` 的最简编译期形态。
/// 默认常量传 `Host.api`；标注了 `[host: MP_DEFAULT_HOST_URL]` /
/// `[host: OPEN_DEFAULT_HOST_URL]` 的常量请传 `Host.mp` / `Host.open`。
pub fn url(comptime host: []const u8, comptime path: []const u8) []const u8 {
    return host ++ path;
}

/// Java enum `Device` — 9 constants.
pub const Device = struct {
    // Java: DEVICE_GET_BIND_DEVICE
    pub const device_get_bind_device = "device/get_bind_device";
    // Java: DEVICE_GET_OPENID
    pub const device_get_openid = "device/get_openid";
    // Java: DEVICE_COMPEL_UNBIND  [literal template: keep verbatim]
    pub const device_compel_unbind = "device/compel_unbind?";
    // Java: DEVICE_UNBIND  [literal template: keep verbatim]
    pub const device_unbind = "device/unbind?";
    // Java: DEVICE_COMPEL_BIND
    pub const device_compel_bind = "device/compel_bind";
    // Java: DEVICE_BIND
    pub const device_bind = "device/bind";
    // Java: DEVICE_AUTHORIZE_DEVICE
    pub const device_authorize_device = "device/authorize_device";
    // Java: DEVICE_GETQRCODE
    pub const device_getqrcode = "device/getqrcode";
    // Java: DEVICE_TRANSMSG
    pub const device_transmsg = "device/transmsg";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [9][]const u8{
        device_get_bind_device,
        device_get_openid,
        device_compel_unbind,
        device_unbind,
        device_compel_bind,
        device_bind,
        device_authorize_device,
        device_getqrcode,
        device_transmsg,
    };
};

/// Java enum `OAuth2` — 5 constants.
pub const OAuth2 = struct {
    // Java: OAUTH2_ACCESS_TOKEN_URL  [literal template: keep verbatim]
    pub const oauth2_access_token_url = "sns/oauth2/access_token?appid=%s&secret=%s&code=%s&grant_type=authorization_code";
    // Java: OAUTH2_REFRESH_TOKEN_URL  [literal template: keep verbatim]
    pub const oauth2_refresh_token_url = "sns/oauth2/refresh_token?appid=%s&grant_type=refresh_token&refresh_token=%s";
    // Java: OAUTH2_USERINFO_URL  [literal template: keep verbatim]
    pub const oauth2_userinfo_url = "sns/userinfo?access_token=%s&openid=%s&lang=%s";
    // Java: OAUTH2_VALIDATE_TOKEN_URL  [literal template: keep verbatim]
    pub const oauth2_validate_token_url = "sns/auth?access_token=%s&openid=%s";
    // Java: CONNECT_OAUTH2_AUTHORIZE_URL  [host: OPEN_DEFAULT_HOST_URL]  [literal template: keep verbatim]
    pub const connect_oauth2_authorize_url = "connect/oauth2/authorize?appid=%s&redirect_uri=%s&response_type=code&scope=%s&state=%s&connect_redirect=1#wechat_redirect";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [5][]const u8{
        oauth2_access_token_url,
        oauth2_refresh_token_url,
        oauth2_userinfo_url,
        oauth2_validate_token_url,
        connect_oauth2_authorize_url,
    };
};

/// Java enum `Other` — 12 constants.
pub const Other = struct {
    // Java: GET_ACCESS_TOKEN_URL  [literal template: keep verbatim]
    pub const get_access_token_url = "cgi-bin/token?grant_type=client_credential&appid=%s&secret=%s";
    // Java: GET_STABLE_ACCESS_TOKEN_URL
    pub const get_stable_access_token_url = "cgi-bin/stable_token";
    // Java: GET_TICKET_URL  [literal template: keep verbatim]
    pub const get_ticket_url = "cgi-bin/ticket/getticket?type=";
    // Java: SHORTURL_API_URL
    pub const shorturl_api_url = "cgi-bin/shorturl";
    // Java: SEMANTIC_SEMPROXY_SEARCH_URL
    pub const semantic_semproxy_search_url = "semantic/semproxy/search";
    // Java: GET_CALLBACK_IP_URL
    pub const get_callback_ip_url = "cgi-bin/getcallbackip";
    // Java: NETCHECK_URL
    pub const netcheck_url = "cgi-bin/callback/check";
    // Java: QRCONNECT_URL  [host: OPEN_DEFAULT_HOST_URL]  [literal template: keep verbatim]
    pub const qrconnect_url = "connect/qrconnect?appid=%s&redirect_uri=%s&response_type=code&scope=%s&state=%s#wechat_redirect";
    // Java: GET_CURRENT_AUTOREPLY_INFO_URL
    pub const get_current_autoreply_info_url = "cgi-bin/get_current_autoreply_info";
    // Java: CLEAR_QUOTA_URL
    pub const clear_quota_url = "cgi-bin/clear_quota";
    // Java: GEN_SHORTEN_URL
    pub const gen_shorten_url = "cgi-bin/shorten/gen";
    // Java: FETCH_SHORTEN_URL
    pub const fetch_shorten_url = "cgi-bin/shorten/fetch";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [12][]const u8{
        get_access_token_url,
        get_stable_access_token_url,
        get_ticket_url,
        shorturl_api_url,
        semantic_semproxy_search_url,
        get_callback_ip_url,
        netcheck_url,
        qrconnect_url,
        get_current_autoreply_info_url,
        clear_quota_url,
        gen_shorten_url,
        fetch_shorten_url,
    };
};

/// Java enum `Marketing` — 4 constants.
pub const Marketing = struct {
    // Java: USER_ACTION_SETS_ADD  [literal template: keep verbatim]
    pub const user_action_sets_add = "marketing/user_action_sets/add?version=v1.0";
    // Java: USER_ACTION_SETS_GET
    pub const user_action_sets_get = "marketing/user_action_sets/get";
    // Java: USER_ACTIONS_ADD  [literal template: keep verbatim]
    pub const user_actions_add = "marketing/user_actions/add?version=v1.0";
    // Java: WECHAT_AD_LEADS_GET
    pub const wechat_ad_leads_get = "marketing/wechat_ad_leads/get";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [4][]const u8{
        user_action_sets_add,
        user_action_sets_get,
        user_actions_add,
        wechat_ad_leads_get,
    };
};

/// Java enum `Menu` — 7 constants.
pub const Menu = struct {
    // Java: GET_CURRENT_SELFMENU_INFO
    pub const get_current_selfmenu_info = "cgi-bin/get_current_selfmenu_info";
    // Java: MENU_TRYMATCH
    pub const menu_trymatch = "cgi-bin/menu/trymatch";
    // Java: MENU_GET
    pub const menu_get = "cgi-bin/menu/get";
    // Java: MENU_DELCONDITIONAL
    pub const menu_delconditional = "cgi-bin/menu/delconditional";
    // Java: MENU_DELETE
    pub const menu_delete = "cgi-bin/menu/delete";
    // Java: MENU_CREATE
    pub const menu_create = "cgi-bin/menu/create";
    // Java: MENU_ADDCONDITIONAL
    pub const menu_addconditional = "cgi-bin/menu/addconditional";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [7][]const u8{
        get_current_selfmenu_info,
        menu_trymatch,
        menu_get,
        menu_delconditional,
        menu_delete,
        menu_create,
        menu_addconditional,
    };
};

/// Java enum `Qrcode` — 3 constants.
pub const Qrcode = struct {
    // Java: QRCODE_CREATE
    pub const qrcode_create = "cgi-bin/qrcode/create";
    // Java: SHOW_QRCODE  [host: MP_DEFAULT_HOST_URL]
    pub const show_qrcode = "cgi-bin/showqrcode";
    // Java: SHOW_QRCODE_WITH_TICKET  [host: MP_DEFAULT_HOST_URL]  [literal template: keep verbatim]
    pub const show_qrcode_with_ticket = "cgi-bin/showqrcode?ticket=%s";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [3][]const u8{
        qrcode_create,
        show_qrcode,
        show_qrcode_with_ticket,
    };
};

/// Java enum `ShakeAround` — 4 constants.
pub const ShakeAround = struct {
    // Java: SHAKEAROUND_USER_GETSHAKEINFO
    pub const shakearound_user_getshakeinfo = "shakearound/user/getshakeinfo";
    // Java: SHAKEAROUND_PAGE_ADD
    pub const shakearound_page_add = "shakearound/page/add";
    // Java: SHAKEAROUND_DEVICE_BINDPAGE
    pub const shakearound_device_bindpage = "shakearound/device/bindpage";
    // Java: SHAKEAROUND_RELATION_SEARCH
    pub const shakearound_relation_search = "shakearound/relation/search";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [4][]const u8{
        shakearound_user_getshakeinfo,
        shakearound_page_add,
        shakearound_device_bindpage,
        shakearound_relation_search,
    };
};

/// Java enum `SubscribeMsg` — 12 constants.
pub const SubscribeMsg = struct {
    // Java: SUBSCRIBE_MESSAGE_AUTHORIZE_URL  [host: MP_DEFAULT_HOST_URL]  [literal template: keep verbatim]
    pub const subscribe_message_authorize_url = "mp/subscribemsg?action=get_confirm&appid=%s&scene=%d&template_id=%s&redirect_url=%s&reserved=%s#wechat_redirect";
    // Java: SEND_MESSAGE_ONCE_URL
    pub const send_message_once_url = "cgi-bin/message/template/subscribe";
    // Java: SEND_SUBSCRIBE_MESSAGE_URL
    pub const send_subscribe_message_url = "cgi-bin/message/subscribe/bizsend";
    // Java: GET_PUB_TEMPLATE_TITLE_LIST_URL
    pub const get_pub_template_title_list_url = "wxaapi/newtmpl/getpubtemplatetitles";
    // Java: GET_PUB_TEMPLATE_KEY_WORDS_BY_ID_URL
    pub const get_pub_template_key_words_by_id_url = "wxaapi/newtmpl/getpubtemplatekeywords";
    // Java: TEMPLATE_ADD_URL
    pub const template_add_url = "wxaapi/newtmpl/addtemplate";
    // Java: TEMPLATE_LIST_URL
    pub const template_list_url = "wxaapi/newtmpl/gettemplate";
    // Java: TEMPLATE_DEL_URL
    pub const template_del_url = "wxaapi/newtmpl/deltemplate";
    // Java: GET_CATEGORY_URL
    pub const get_category_url = "wxaapi/newtmpl/getcategory";
    // Java: UNIFORM_MSG_SEND_URL
    pub const uniform_msg_send_url = "cgi-bin/message/wxopen/template/uniform_send";
    // Java: ACTIVITY_ID_CREATE_URL
    pub const activity_id_create_url = "cgi-bin/message/wxopen/activityid/create";
    // Java: UPDATABLE_MSG_SEND_URL
    pub const updatable_msg_send_url = "cgi-bin/message/wxopen/updatablemsg/send";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [12][]const u8{
        subscribe_message_authorize_url,
        send_message_once_url,
        send_subscribe_message_url,
        get_pub_template_title_list_url,
        get_pub_template_key_words_by_id_url,
        template_add_url,
        template_list_url,
        template_del_url,
        get_category_url,
        uniform_msg_send_url,
        activity_id_create_url,
        updatable_msg_send_url,
    };
};

/// Java enum `TemplateMsg` — 6 constants.
pub const TemplateMsg = struct {
    // Java: MESSAGE_TEMPLATE_SEND
    pub const message_template_send = "cgi-bin/message/template/send";
    // Java: TEMPLATE_API_SET_INDUSTRY
    pub const template_api_set_industry = "cgi-bin/template/api_set_industry";
    // Java: TEMPLATE_GET_INDUSTRY
    pub const template_get_industry = "cgi-bin/template/get_industry";
    // Java: TEMPLATE_API_ADD_TEMPLATE
    pub const template_api_add_template = "cgi-bin/template/api_add_template";
    // Java: TEMPLATE_GET_ALL_PRIVATE_TEMPLATE
    pub const template_get_all_private_template = "cgi-bin/template/get_all_private_template";
    // Java: TEMPLATE_DEL_PRIVATE_TEMPLATE
    pub const template_del_private_template = "cgi-bin/template/del_private_template";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [6][]const u8{
        message_template_send,
        template_api_set_industry,
        template_get_industry,
        template_api_add_template,
        template_get_all_private_template,
        template_del_private_template,
    };
};

/// Java enum `UserBlacklist` — 3 constants.
pub const UserBlacklist = struct {
    // Java: GETBLACKLIST
    pub const getblacklist = "cgi-bin/tags/members/getblacklist";
    // Java: BATCHBLACKLIST
    pub const batchblacklist = "cgi-bin/tags/members/batchblacklist";
    // Java: BATCHUNBLACKLIST
    pub const batchunblacklist = "cgi-bin/tags/members/batchunblacklist";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [3][]const u8{
        getblacklist,
        batchblacklist,
        batchunblacklist,
    };
};

/// Java enum `UserTag` — 8 constants.
pub const UserTag = struct {
    // Java: TAGS_CREATE
    pub const tags_create = "cgi-bin/tags/create";
    // Java: TAGS_GET
    pub const tags_get = "cgi-bin/tags/get";
    // Java: TAGS_UPDATE
    pub const tags_update = "cgi-bin/tags/update";
    // Java: TAGS_DELETE
    pub const tags_delete = "cgi-bin/tags/delete";
    // Java: TAG_GET
    pub const tag_get = "cgi-bin/user/tag/get";
    // Java: TAGS_MEMBERS_BATCHTAGGING
    pub const tags_members_batchtagging = "cgi-bin/tags/members/batchtagging";
    // Java: TAGS_MEMBERS_BATCHUNTAGGING
    pub const tags_members_batchuntagging = "cgi-bin/tags/members/batchuntagging";
    // Java: TAGS_GETIDLIST
    pub const tags_getidlist = "cgi-bin/tags/getidlist";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [8][]const u8{
        tags_create,
        tags_get,
        tags_update,
        tags_delete,
        tag_get,
        tags_members_batchtagging,
        tags_members_batchuntagging,
        tags_getidlist,
    };
};

/// Java enum `Wifi` — 3 constants.
pub const Wifi = struct {
    // Java: BIZWIFI_SHOP_LIST
    pub const bizwifi_shop_list = "bizwifi/shop/list";
    // Java: BIZWIFI_SHOP_GET
    pub const bizwifi_shop_get = "bizwifi/shop/get";
    // Java: BIZWIFI_SHOP_UPDATE
    pub const bizwifi_shop_update = "bizwifi/shop/update";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [3][]const u8{
        bizwifi_shop_list,
        bizwifi_shop_get,
        bizwifi_shop_update,
    };
};

/// Java enum `AiOpen` — 3 constants.
pub const AiOpen = struct {
    // Java: TRANSLATE_URL  [literal template: keep verbatim]
    pub const translate_url = "cgi-bin/media/voice/translatecontent?lfrom=%s&lto=%s";
    // Java: VOICE_UPLOAD_URL  [literal template: keep verbatim]
    pub const voice_upload_url = "cgi-bin/media/voice/addvoicetorecofortext?format=%s&voice_id=%s&lang=%s";
    // Java: VOICE_QUERY_RESULT_URL
    pub const voice_query_result_url = "cgi-bin/media/voice/queryrecoresultfortext";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [3][]const u8{
        translate_url,
        voice_upload_url,
        voice_query_result_url,
    };
};

/// Java enum `Ocr` — 14 constants.
pub const Ocr = struct {
    // Java: IDCARD  [literal template: keep verbatim]
    pub const idcard = "cv/ocr/idcard?img_url=%s";
    // Java: FILEIDCARD
    pub const fileidcard = "cv/ocr/idcard";
    // Java: BANK_CARD  [literal template: keep verbatim]
    pub const bank_card = "cv/ocr/bankcard?img_url=%s";
    // Java: FILE_BANK_CARD
    pub const file_bank_card = "cv/ocr/bankcard";
    // Java: DRIVING  [literal template: keep verbatim]
    pub const driving = "cv/ocr/driving?img_url=%s";
    // Java: FILE_DRIVING
    pub const file_driving = "cv/ocr/driving";
    // Java: DRIVING_LICENSE  [literal template: keep verbatim]
    pub const driving_license = "cv/ocr/drivinglicense?img_url=%s";
    // Java: FILE_DRIVING_LICENSE
    pub const file_driving_license = "cv/ocr/drivinglicense";
    // Java: BIZ_LICENSE  [literal template: keep verbatim]
    pub const biz_license = "cv/ocr/bizlicense?img_url=%s";
    // Java: FILE_BIZ_LICENSE
    pub const file_biz_license = "cv/ocr/bizlicense";
    // Java: COMM  [literal template: keep verbatim]
    pub const comm = "cv/ocr/comm?img_url=%s";
    // Java: FILE_COMM
    pub const file_comm = "cv/ocr/comm";
    // Java: MENU  [literal template: keep verbatim]
    pub const menu = "cv/ocr/menu?img_url=%s";
    // Java: FILE_MENU
    pub const file_menu = "cv/ocr/menu";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [14][]const u8{
        idcard,
        fileidcard,
        bank_card,
        file_bank_card,
        driving,
        file_driving,
        driving_license,
        file_driving_license,
        biz_license,
        file_biz_license,
        comm,
        file_comm,
        menu,
        file_menu,
    };
};

/// Java enum `Card` — 21 constants.
pub const Card = struct {
    // Java: CARD_CREATE
    pub const card_create = "card/create";
    // Java: CARD_GET
    pub const card_get = "card/get";
    // Java: CARD_GET_TICKET  [literal template: keep verbatim]
    pub const card_get_ticket = "cgi-bin/ticket/getticket?type=wx_card";
    // Java: CARD_CODE_DECRYPT
    pub const card_code_decrypt = "card/code/decrypt";
    // Java: CARD_CODE_GET
    pub const card_code_get = "card/code/get";
    // Java: CARD_CODE_CONSUME
    pub const card_code_consume = "card/code/consume";
    // Java: CARD_CODE_MARK
    pub const card_code_mark = "card/code/mark";
    // Java: CARD_TEST_WHITELIST
    pub const card_test_whitelist = "card/testwhitelist/set";
    // Java: CARD_QRCODE_CREATE
    pub const card_qrcode_create = "card/qrcode/create";
    // Java: CARD_LANDING_PAGE_CREATE
    pub const card_landing_page_create = "card/landingpage/create";
    // Java: CARD_CODE_UNAVAILABLE
    pub const card_code_unavailable = "card/code/unavailable";
    // Java: CARD_DELETE
    pub const card_delete = "card/delete";
    // Java: CARD_CODE_DEPOSIT
    pub const card_code_deposit = "card/code/deposit";
    // Java: CARD_CODE_DEPOSIT_COUNT
    pub const card_code_deposit_count = "card/code/getdepositcount";
    // Java: CARD_CODE_CHECKCODE
    pub const card_code_checkcode = "card/code/checkcode";
    // Java: CARD_MPNEWS_GETHTML
    pub const card_mpnews_gethtml = "card/mpnews/gethtml";
    // Java: CARD_MODIFY_STOCK
    pub const card_modify_stock = "card/modifystock";
    // Java: CARD_CODE_UPDATE
    pub const card_code_update = "card/code/update";
    // Java: CARD_PAYCELL_SET
    pub const card_paycell_set = "card/paycell/set";
    // Java: CARD_SELF_CONSUME_CELL_SET
    pub const card_self_consume_cell_set = "card/selfconsumecell/set";
    // Java: CARD_USER_CARD_LIST
    pub const card_user_card_list = "card/user/getcardlist";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [21][]const u8{
        card_create,
        card_get,
        card_get_ticket,
        card_code_decrypt,
        card_code_get,
        card_code_consume,
        card_code_mark,
        card_test_whitelist,
        card_qrcode_create,
        card_landing_page_create,
        card_code_unavailable,
        card_delete,
        card_code_deposit,
        card_code_deposit_count,
        card_code_checkcode,
        card_mpnews_gethtml,
        card_modify_stock,
        card_code_update,
        card_paycell_set,
        card_self_consume_cell_set,
        card_user_card_list,
    };
};

/// Java enum `DataCube` — 17 constants.
pub const DataCube = struct {
    // Java: GET_USER_SUMMARY
    pub const get_user_summary = "datacube/getusersummary";
    // Java: GET_USER_CUMULATE
    pub const get_user_cumulate = "datacube/getusercumulate";
    // Java: GET_ARTICLE_SUMMARY
    pub const get_article_summary = "datacube/getarticlesummary";
    // Java: GET_ARTICLE_TOTAL
    pub const get_article_total = "datacube/getarticletotal";
    // Java: GET_USER_READ
    pub const get_user_read = "datacube/getuserread";
    // Java: GET_USER_READ_HOUR
    pub const get_user_read_hour = "datacube/getuserreadhour";
    // Java: GET_USER_SHARE
    pub const get_user_share = "datacube/getusershare";
    // Java: GET_USER_SHARE_HOUR
    pub const get_user_share_hour = "datacube/getusersharehour";
    // Java: GET_UPSTREAM_MSG
    pub const get_upstream_msg = "datacube/getupstreammsg";
    // Java: GET_UPSTREAM_MSG_HOUR
    pub const get_upstream_msg_hour = "datacube/getupstreammsghour";
    // Java: GET_UPSTREAM_MSG_WEEK
    pub const get_upstream_msg_week = "datacube/getupstreammsgweek";
    // Java: GET_UPSTREAM_MSG_MONTH
    pub const get_upstream_msg_month = "datacube/getupstreammsgmonth";
    // Java: GET_UPSTREAM_MSG_DIST
    pub const get_upstream_msg_dist = "datacube/getupstreammsgdist";
    // Java: GET_UPSTREAM_MSG_DIST_WEEK
    pub const get_upstream_msg_dist_week = "datacube/getupstreammsgdistweek";
    // Java: GET_UPSTREAM_MSG_DIST_MONTH
    pub const get_upstream_msg_dist_month = "datacube/getupstreammsgdistmonth";
    // Java: GET_INTERFACE_SUMMARY
    pub const get_interface_summary = "datacube/getinterfacesummary";
    // Java: GET_INTERFACE_SUMMARY_HOUR
    pub const get_interface_summary_hour = "datacube/getinterfacesummaryhour";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [17][]const u8{
        get_user_summary,
        get_user_cumulate,
        get_article_summary,
        get_article_total,
        get_user_read,
        get_user_read_hour,
        get_user_share,
        get_user_share_hour,
        get_upstream_msg,
        get_upstream_msg_hour,
        get_upstream_msg_week,
        get_upstream_msg_month,
        get_upstream_msg_dist,
        get_upstream_msg_dist_week,
        get_upstream_msg_dist_month,
        get_interface_summary,
        get_interface_summary_hour,
    };
};

/// Java enum `Kefu` — 15 constants.
pub const Kefu = struct {
    // Java: MESSAGE_CUSTOM_SEND
    pub const message_custom_send = "cgi-bin/message/custom/send";
    // Java: GET_KF_LIST
    pub const get_kf_list = "cgi-bin/customservice/getkflist";
    // Java: GET_ONLINE_KF_LIST
    pub const get_online_kf_list = "cgi-bin/customservice/getonlinekflist";
    // Java: KFACCOUNT_ADD
    pub const kfaccount_add = "customservice/kfaccount/add";
    // Java: KFACCOUNT_UPDATE
    pub const kfaccount_update = "customservice/kfaccount/update";
    // Java: KFACCOUNT_INVITE_WORKER
    pub const kfaccount_invite_worker = "customservice/kfaccount/inviteworker";
    // Java: KFACCOUNT_UPLOAD_HEAD_IMG  [literal template: keep verbatim]
    pub const kfaccount_upload_head_img = "customservice/kfaccount/uploadheadimg?kf_account=%s";
    // Java: KFACCOUNT_DEL  [literal template: keep verbatim]
    pub const kfaccount_del = "customservice/kfaccount/del?kf_account=%s";
    // Java: KFSESSION_CREATE
    pub const kfsession_create = "customservice/kfsession/create";
    // Java: KFSESSION_CLOSE
    pub const kfsession_close = "customservice/kfsession/close";
    // Java: KFSESSION_GET_SESSION  [literal template: keep verbatim]
    pub const kfsession_get_session = "customservice/kfsession/getsession?openid=%s";
    // Java: KFSESSION_GET_SESSION_LIST  [literal template: keep verbatim]
    pub const kfsession_get_session_list = "customservice/kfsession/getsessionlist?kf_account=%s";
    // Java: KFSESSION_GET_WAIT_CASE
    pub const kfsession_get_wait_case = "customservice/kfsession/getwaitcase";
    // Java: MSG_RECORD_LIST
    pub const msg_record_list = "customservice/msgrecord/getmsglist";
    // Java: CUSTOM_TYPING
    pub const custom_typing = "cgi-bin/message/custom/typing";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [15][]const u8{
        message_custom_send,
        get_kf_list,
        get_online_kf_list,
        kfaccount_add,
        kfaccount_update,
        kfaccount_invite_worker,
        kfaccount_upload_head_img,
        kfaccount_del,
        kfsession_create,
        kfsession_close,
        kfsession_get_session,
        kfsession_get_session_list,
        kfsession_get_wait_case,
        msg_record_list,
        custom_typing,
    };
};

/// Java enum `MassMessage` — 9 constants.
pub const MassMessage = struct {
    // Java: MEDIA_UPLOAD_NEWS_URL
    pub const media_upload_news_url = "cgi-bin/media/uploadnews";
    // Java: MEDIA_UPLOAD_VIDEO_URL
    pub const media_upload_video_url = "cgi-bin/media/uploadvideo";
    // Java: MESSAGE_MASS_SENDALL_URL
    pub const message_mass_sendall_url = "cgi-bin/message/mass/sendall";
    // Java: MESSAGE_MASS_SEND_URL
    pub const message_mass_send_url = "cgi-bin/message/mass/send";
    // Java: MESSAGE_MASS_PREVIEW_URL
    pub const message_mass_preview_url = "cgi-bin/message/mass/preview";
    // Java: MESSAGE_MASS_DELETE_URL
    pub const message_mass_delete_url = "cgi-bin/message/mass/delete";
    // Java: MESSAGE_MASS_SPEED_GET_URL
    pub const message_mass_speed_get_url = "cgi-bin/message/mass/speed/get";
    // Java: MESSAGE_MASS_SPEED_SET_URL
    pub const message_mass_speed_set_url = "cgi-bin/message/mass/speed/set";
    // Java: MESSAGE_MASS_GET_URL
    pub const message_mass_get_url = "cgi-bin/message/mass/get";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [9][]const u8{
        media_upload_news_url,
        media_upload_video_url,
        message_mass_sendall_url,
        message_mass_send_url,
        message_mass_preview_url,
        message_mass_delete_url,
        message_mass_speed_get_url,
        message_mass_speed_set_url,
        message_mass_get_url,
    };
};

/// Java enum `Material` — 11 constants.
pub const Material = struct {
    // Java: MEDIA_GET_URL
    pub const media_get_url = "cgi-bin/media/get";
    // Java: JSSDK_MEDIA_GET_URL
    pub const jssdk_media_get_url = "cgi-bin/media/get/jssdk";
    // Java: MEDIA_UPLOAD_URL  [literal template: keep verbatim]
    pub const media_upload_url = "cgi-bin/media/upload?type=%s";
    // Java: IMG_UPLOAD_URL
    pub const img_upload_url = "cgi-bin/media/uploadimg";
    // Java: MATERIAL_ADD_URL  [literal template: keep verbatim]
    pub const material_add_url = "cgi-bin/material/add_material?type=%s";
    // Java: NEWS_ADD_URL
    pub const news_add_url = "cgi-bin/material/add_news";
    // Java: MATERIAL_GET_URL
    pub const material_get_url = "cgi-bin/material/get_material";
    // Java: NEWS_UPDATE_URL
    pub const news_update_url = "cgi-bin/material/update_news";
    // Java: MATERIAL_DEL_URL
    pub const material_del_url = "cgi-bin/material/del_material";
    // Java: MATERIAL_GET_COUNT_URL
    pub const material_get_count_url = "cgi-bin/material/get_materialcount";
    // Java: MATERIAL_BATCHGET_URL
    pub const material_batchget_url = "cgi-bin/material/batchget_material";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [11][]const u8{
        media_get_url,
        jssdk_media_get_url,
        media_upload_url,
        img_upload_url,
        material_add_url,
        news_add_url,
        material_get_url,
        news_update_url,
        material_del_url,
        material_get_count_url,
        material_batchget_url,
    };
};

/// Java enum `MemberCard` — 8 constants.
pub const MemberCard = struct {
    // Java: MEMBER_CARD_CREATE
    pub const member_card_create = "card/create";
    // Java: MEMBER_CARD_ACTIVATE
    pub const member_card_activate = "card/membercard/activate";
    // Java: MEMBER_CARD_USER_INFO_GET
    pub const member_card_user_info_get = "card/membercard/userinfo/get";
    // Java: MEMBER_CARD_UPDATE_USER
    pub const member_card_update_user = "card/membercard/updateuser";
    // Java: MEMBER_CARD_ACTIVATE_USER_FORM
    pub const member_card_activate_user_form = "card/membercard/activateuserform/set";
    // Java: MEMBER_CARD_ACTIVATE_URL
    pub const member_card_activate_url = "card/membercard/activate/geturl";
    // Java: MEMBER_CARD_UPDATE
    pub const member_card_update = "card/update";
    // Java: MEMBER_CARD_ACTIVATE_TEMP_INFO
    pub const member_card_activate_temp_info = "card/membercard/activatetempinfo/get";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [8][]const u8{
        member_card_create,
        member_card_activate,
        member_card_user_info_get,
        member_card_update_user,
        member_card_activate_user_form,
        member_card_activate_url,
        member_card_update,
        member_card_activate_temp_info,
    };
};

/// Java enum `Store` — 6 constants.
pub const Store = struct {
    // Java: POI_GET_WX_CATEGORY_URL
    pub const poi_get_wx_category_url = "cgi-bin/poi/getwxcategory";
    // Java: POI_UPDATE_URL
    pub const poi_update_url = "cgi-bin/poi/updatepoi";
    // Java: POI_LIST_URL
    pub const poi_list_url = "cgi-bin/poi/getpoilist";
    // Java: POI_DEL_URL
    pub const poi_del_url = "cgi-bin/poi/delpoi";
    // Java: POI_GET_URL
    pub const poi_get_url = "cgi-bin/poi/getpoi";
    // Java: POI_ADD_URL
    pub const poi_add_url = "cgi-bin/poi/addpoi";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [6][]const u8{
        poi_get_wx_category_url,
        poi_update_url,
        poi_list_url,
        poi_del_url,
        poi_get_url,
        poi_add_url,
    };
};

/// Java enum `User` — 5 constants.
pub const User = struct {
    // Java: USER_INFO_BATCH_GET_URL
    pub const user_info_batch_get_url = "cgi-bin/user/info/batchget";
    // Java: USER_GET_URL
    pub const user_get_url = "cgi-bin/user/get";
    // Java: USER_INFO_URL
    pub const user_info_url = "cgi-bin/user/info";
    // Java: USER_INFO_UPDATE_REMARK_URL
    pub const user_info_update_remark_url = "cgi-bin/user/info/updateremark";
    // Java: USER_CHANGE_OPENID_URL
    pub const user_change_openid_url = "cgi-bin/changeopenid";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [5][]const u8{
        user_info_batch_get_url,
        user_get_url,
        user_info_url,
        user_info_update_remark_url,
        user_change_openid_url,
    };
};

/// Java enum `Comment` — 8 constants.
pub const Comment = struct {
    // Java: OPEN
    pub const open = "cgi-bin/comment/open";
    // Java: CLOSE
    pub const close = "cgi-bin/comment/close";
    // Java: LIST
    pub const list = "cgi-bin/comment/list";
    // Java: MARK_ELECT
    pub const mark_elect = "cgi-bin/comment/markelect";
    // Java: UNMARK_ELECT
    pub const unmark_elect = "cgi-bin/comment/unmarkelect";
    // Java: DELETE
    pub const delete = "cgi-bin/comment/delete";
    // Java: REPLY_ADD
    pub const reply_add = "cgi-bin/comment/reply/add";
    // Java: REPLY_DELETE
    pub const reply_delete = "cgi-bin/comment/reply/delete";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [8][]const u8{
        open,
        close,
        list,
        mark_elect,
        unmark_elect,
        delete,
        reply_add,
        reply_delete,
    };
};

/// Java enum `ImgProc` — 6 constants.
pub const ImgProc = struct {
    // Java: QRCODE  [literal template: keep verbatim]
    pub const qrcode = "cv/img/qrcode?img_url=%s";
    // Java: FILE_QRCODE
    pub const file_qrcode = "cv/img/qrcode";
    // Java: SUPER_RESOLUTION  [literal template: keep verbatim]
    pub const super_resolution = "cv/img/superresolution?img_url=%s";
    // Java: FILE_SUPER_RESOLUTION
    pub const file_super_resolution = "cv/img/superresolution";
    // Java: AI_CROP  [literal template: keep verbatim]
    pub const ai_crop = "cv/img/aicrop?img_url=%s&ratios=%s";
    // Java: FILE_AI_CROP  [literal template: keep verbatim]
    pub const file_ai_crop = "cv/img/aicrop?ratios=%s";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [6][]const u8{
        qrcode,
        file_qrcode,
        super_resolution,
        file_super_resolution,
        ai_crop,
        file_ai_crop,
    };
};

/// Java enum `Invoice` — 16 constants.
pub const Invoice = struct {
    // Java: GET_AUTH_URL
    pub const get_auth_url = "card/invoice/getauthurl";
    // Java: GET_AUTH_DATA
    pub const get_auth_data = "card/invoice/getauthdata";
    // Java: REJECT_INSERT
    pub const reject_insert = "card/invoice/rejectinsert";
    // Java: MAKE_OUT_INVOICE
    pub const make_out_invoice = "card/invoice/makeoutinvoice";
    // Java: CLEAR_OUT_INVOICE
    pub const clear_out_invoice = "card/invoice/clearoutinvoice";
    // Java: QUERY_INVOICE_INFO
    pub const query_invoice_info = "card/invoice/queryinvoceinfo";
    // Java: SET_CONTACT_SET_BIZ_ATTR  [literal template: keep verbatim]
    pub const set_contact_set_biz_attr = "card/invoice/setbizattr?action=set_contact";
    // Java: GET_CONTACT_SET_BIZ_ATTR  [literal template: keep verbatim]
    pub const get_contact_set_biz_attr = "card/invoice/setbizattr?action=get_contact";
    // Java: SET_AUTH_FIELD_SET_BIZ_ATTR  [literal template: keep verbatim]
    pub const set_auth_field_set_biz_attr = "card/invoice/setbizattr?action=set_auth_field";
    // Java: GET_AUTH_FIELD_SET_BIZ_ATTR  [literal template: keep verbatim]
    pub const get_auth_field_set_biz_attr = "card/invoice/setbizattr?action=get_auth_field";
    // Java: SET_PAY_MCH_SET_BIZ_ATTR  [literal template: keep verbatim]
    pub const set_pay_mch_set_biz_attr = "card/invoice/setbizattr?action=set_pay_mch";
    // Java: GET_PAY_MCH_SET_BIZ_ATTR  [literal template: keep verbatim]
    pub const get_pay_mch_set_biz_attr = "card/invoice/setbizattr?action=get_pay_mch";
    // Java: GET_INVOICE_INFO
    pub const get_invoice_info = "card/invoice/reimburse/getinvoiceinfo";
    // Java: GET_INVOICE_BATCH
    pub const get_invoice_batch = "card/invoice/reimburse/getinvoicebatch";
    // Java: UPDATE_INVOICE_STATUS
    pub const update_invoice_status = "card/invoice/reimburse/updateinvoicestatus";
    // Java: UPDATE_STATUS_BATCH
    pub const update_status_batch = "card/invoice/reimburse/updatestatusbatch";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [16][]const u8{
        get_auth_url,
        get_auth_data,
        reject_insert,
        make_out_invoice,
        clear_out_invoice,
        query_invoice_info,
        set_contact_set_biz_attr,
        get_contact_set_biz_attr,
        set_auth_field_set_biz_attr,
        get_auth_field_set_biz_attr,
        set_pay_mch_set_biz_attr,
        get_pay_mch_set_biz_attr,
        get_invoice_info,
        get_invoice_batch,
        update_invoice_status,
        update_status_batch,
    };
};

/// Java enum `Guide` — 50 constants.
pub const Guide = struct {
    // Java: ADD_GUIDE
    pub const add_guide = "cgi-bin/guide/addguideacct";
    // Java: UPDATE_GUIDE
    pub const update_guide = "cgi-bin/guide/updateguideacct";
    // Java: GET_GUIDE
    pub const get_guide = "cgi-bin/guide/getguideacct";
    // Java: DEL_GUIDE
    pub const del_guide = "cgi-bin/guide/delguideacct";
    // Java: LIST_GUIDE
    pub const list_guide = "cgi-bin/guide/getguideacctlist";
    // Java: CREATE_QR_CODE
    pub const create_qr_code = "cgi-bin/guide/guidecreateqrcode";
    // Java: GET_GUIDE_CHAT_RECORD
    pub const get_guide_chat_record = "cgi-bin/guide/getguidebuyerchatrecord";
    // Java: SET_GUIDE_CONFIG
    pub const set_guide_config = "cgi-bin/guide/setguideconfig";
    // Java: GET_GUIDE_CONFIG
    pub const get_guide_config = "cgi-bin/guide/getguideconfig";
    // Java: SET_GUIDE_ACCT_CONFIG
    pub const set_guide_acct_config = "cgi-bin/guide/setguideacctconfig";
    // Java: GET_GUIDE_ACCT_CONFIG
    pub const get_guide_acct_config = "cgi-bin/guide/getguideacctconfig";
    // Java: PUSH_SHOW_WX_PATH_MENU
    pub const push_show_wx_path_menu = "cgi-bin/guide/pushshowwxapathmenu";
    // Java: NEW_GUIDE_GROUP
    pub const new_guide_group = "cgi-bin/guide/newguidegroup";
    // Java: GET_GUIDE_GROUP_LIST
    pub const get_guide_group_list = "cgi-bin/guide/getguidegrouplist";
    // Java: GET_GROUP_GUIDE_INFO
    pub const get_group_guide_info = "cgi-bin/guide/getgroupinfo";
    // Java: ADD_GROUP_GUIDE
    pub const add_group_guide = "cgi-bin/guide/addguide2guidegroup";
    // Java: DEL_GROUP_GUIDE
    pub const del_group_guide = "cgi-bin/guide/delguide2guidegroup";
    // Java: GET_GROUP_ON_GUIDE
    pub const get_group_on_guide = "cgi-bin/guide/getgroupbyguide";
    // Java: DEL_GROUP
    pub const del_group = "cgi-bin/guide/delguidegroup";
    // Java: ADD_GUIDE_BUYER_RELATION
    pub const add_guide_buyer_relation = "cgi-bin/guide/addguidebuyerrelation";
    // Java: DEL_GUIDE_BUYER_RELATION
    pub const del_guide_buyer_relation = "cgi-bin/guide/delguidebuyerrelation";
    // Java: GET_GUIDE_BUYER_RELATION_LIST
    pub const get_guide_buyer_relation_list = "cgi-bin/guide/getguidebuyerrelationlist";
    // Java: REBIND_GUIDE_ACCT_FOR_BUYER
    pub const rebind_guide_acct_for_buyer = "cgi-bin/guide/rebindguideacctforbuyer";
    // Java: UPDATE_GUIDE_BUYER_RELATION
    pub const update_guide_buyer_relation = "cgi-bin/guide/updateguidebuyerrelation";
    // Java: GET_GUIDE_BUYER_RELATION_BY_BUYER
    pub const get_guide_buyer_relation_by_buyer = "cgi-bin/guide/getguidebuyerrelationbybuyer";
    // Java: GET_GUIDE_BUYER_RELATION
    pub const get_guide_buyer_relation = "cgi-bin/guide/getguidebuyerrelation";
    // Java: NEW_GUIDE_TAG_OPTION
    pub const new_guide_tag_option = "cgi-bin/guide/newguidetagoption";
    // Java: DEL_GUIDE_TAG_OPTION
    pub const del_guide_tag_option = "cgi-bin/guide/delguidetagoption";
    // Java: ADD_GUIDE_TAG_OPTION
    pub const add_guide_tag_option = "cgi-bin/guide/addguidetagoption";
    // Java: GET_GUIDE_TAG_OPTION
    pub const get_guide_tag_option = "cgi-bin/guide/getguidetagoption";
    // Java: ADD_GUIDE_BUYER_TAG
    pub const add_guide_buyer_tag = "cgi-bin/guide/addguidebuyertag";
    // Java: GET_GUIDE_BUYER_TAG
    pub const get_guide_buyer_tag = "cgi-bin/guide/getguidebuyertag";
    // Java: QUERY_GUIDE_BUYER_BY_TAG
    pub const query_guide_buyer_by_tag = "cgi-bin/guide/queryguidebuyerbytag";
    // Java: DEL_GUIDE_BUYER_TAG
    pub const del_guide_buyer_tag = "cgi-bin/guide/delguidebuyertag";
    // Java: ADD_GUIDE_BUYER_DISPLAY_TAG
    pub const add_guide_buyer_display_tag = "cgi-bin/guide/addguidebuyerdisplaytag";
    // Java: GET_GUIDE_BUYER_DISPLAY_TAG
    pub const get_guide_buyer_display_tag = "cgi-bin/guide/getguidebuyerdisplaytag";
    // Java: SET_GUIDE_CARD_MATERIAL
    pub const set_guide_card_material = "cgi-bin/guide/setguidecardmaterial";
    // Java: GET_GUIDE_CARD_MATERIAL
    pub const get_guide_card_material = "cgi-bin/guide/getguidecardmaterial";
    // Java: DEL_GUIDE_CARD_MATERIAL
    pub const del_guide_card_material = "cgi-bin/guide/delguidecardmaterial";
    // Java: SET_GUIDE_IMAGE_MATERIAL
    pub const set_guide_image_material = "cgi-bin/guide/setguideimagematerial";
    // Java: GET_GUIDE_IMAGE_MATERIAL
    pub const get_guide_image_material = "cgi-bin/guide/getguideimagematerial";
    // Java: DEL_GUIDE_IMAGE_MATERIAL
    pub const del_guide_image_material = "cgi-bin/guide/delguideimagematerial";
    // Java: SET_GUIDE_WORD_MATERIAL
    pub const set_guide_word_material = "cgi-bin/guide/setguidewordmaterial";
    // Java: GET_GUIDE_WORD_MATERIAL
    pub const get_guide_word_material = "cgi-bin/guide/getguidewordmaterial";
    // Java: DEL_GUIDE_WORD_MATERIAL
    pub const del_guide_word_material = "cgi-bin/guide/delguidewordmaterial";
    // Java: ADD_GUIDE_MASSED_JOB
    pub const add_guide_massed_job = "cgi-bin/guide/addguidemassendjob";
    // Java: GET_GUIDE_MASSED_JOB_LIST
    pub const get_guide_massed_job_list = "cgi-bin/guide/getguidemassendjoblist";
    // Java: GET_GUIDE_MASSED_JOB
    pub const get_guide_massed_job = "cgi-bin/guide/getguidemassendjob";
    // Java: UPDATE_GUIDE_MASSED_JOB
    pub const update_guide_massed_job = "cgi-bin/guide/updateguidemassendjob";
    // Java: CANCEL_GUIDE_MASSED_JOB
    pub const cancel_guide_massed_job = "cgi-bin/guide/cancelguidemassendjob";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [50][]const u8{
        add_guide,
        update_guide,
        get_guide,
        del_guide,
        list_guide,
        create_qr_code,
        get_guide_chat_record,
        set_guide_config,
        get_guide_config,
        set_guide_acct_config,
        get_guide_acct_config,
        push_show_wx_path_menu,
        new_guide_group,
        get_guide_group_list,
        get_group_guide_info,
        add_group_guide,
        del_group_guide,
        get_group_on_guide,
        del_group,
        add_guide_buyer_relation,
        del_guide_buyer_relation,
        get_guide_buyer_relation_list,
        rebind_guide_acct_for_buyer,
        update_guide_buyer_relation,
        get_guide_buyer_relation_by_buyer,
        get_guide_buyer_relation,
        new_guide_tag_option,
        del_guide_tag_option,
        add_guide_tag_option,
        get_guide_tag_option,
        add_guide_buyer_tag,
        get_guide_buyer_tag,
        query_guide_buyer_by_tag,
        del_guide_buyer_tag,
        add_guide_buyer_display_tag,
        get_guide_buyer_display_tag,
        set_guide_card_material,
        get_guide_card_material,
        del_guide_card_material,
        set_guide_image_material,
        get_guide_image_material,
        del_guide_image_material,
        set_guide_word_material,
        get_guide_word_material,
        del_guide_word_material,
        add_guide_massed_job,
        get_guide_massed_job_list,
        get_guide_massed_job,
        update_guide_massed_job,
        cancel_guide_massed_job,
    };
};

/// Java enum `Draft` — 6 constants.
pub const Draft = struct {
    // Java: ADD_DRAFT
    pub const add_draft = "cgi-bin/draft/add";
    // Java: UPDATE_DRAFT
    pub const update_draft = "cgi-bin/draft/update";
    // Java: GET_DRAFT
    pub const get_draft = "cgi-bin/draft/get";
    // Java: DEL_DRAFT
    pub const del_draft = "cgi-bin/draft/delete";
    // Java: LIST_DRAFT
    pub const list_draft = "cgi-bin/draft/batchget";
    // Java: COUNT_DRAFT
    pub const count_draft = "cgi-bin/draft/count";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [6][]const u8{
        add_draft,
        update_draft,
        get_draft,
        del_draft,
        list_draft,
        count_draft,
    };
};

/// Java enum `FreePublish` — 5 constants.
pub const FreePublish = struct {
    // Java: SUBMIT
    pub const submit = "cgi-bin/freepublish/submit";
    // Java: GET_ARTICLE
    pub const get_article = "cgi-bin/freepublish/getarticle";
    // Java: GET_PUSH_STATUS
    pub const get_push_status = "cgi-bin/freepublish/get";
    // Java: DEL_PUSH
    pub const del_push = "cgi-bin/freepublish/delete";
    // Java: BATCH_GET
    pub const batch_get = "cgi-bin/freepublish/batchget";

    /// All path values of this family; consumed by the tests below.
    /// Generated together with the constants — no manual re-listing.
    pub const all = [5][]const u8{
        submit,
        get_article,
        get_push_status,
        del_push,
        batch_get,
    };
};

// ---- 测试支撑：把 28 个家族的 `all` 数组汇成编译期元组，供下方测试统一遍历 ----
const all_families = .{
    Device.all,
    OAuth2.all,
    Other.all,
    Marketing.all,
    Menu.all,
    Qrcode.all,
    ShakeAround.all,
    SubscribeMsg.all,
    TemplateMsg.all,
    UserBlacklist.all,
    UserTag.all,
    Wifi.all,
    AiOpen.all,
    Ocr.all,
    Card.all,
    DataCube.all,
    Kefu.all,
    MassMessage.all,
    Material.all,
    MemberCard.all,
    Store.all,
    User.all,
    Comment.all,
    ImgProc.all,
    Invoice.all,
    Guide.all,
    Draft.all,
    FreePublish.all,
};

/// 常量总数（生成脚本写入，作为完整性护栏）。
pub const total_count: usize = 276;

test "全部常量：非空、相对路径（不以 http 开头）、且不含前导斜杠" {
    inline for (all_families) |paths| {
        for (paths) |p| {
            try std.testing.expect(p.len > 0);
            try std.testing.expect(!std.mem.startsWith(u8, p, "http"));
            try std.testing.expect(!std.mem.startsWith(u8, p, "/"));
        }
    }
}

test "每个家族内部无重复路径值" {
    inline for (all_families) |paths| {
        for (paths, 0..) |p, i| {
            for (paths[i + 1 ..]) |q| {
                try std.testing.expect(!std.mem.eql(u8, p, q));
            }
        }
    }
}

test "完整性护栏：常量总数 276，家族数 28" {
    var total: usize = 0;
    var fam_count: usize = 0;
    inline for (all_families) |paths| {
        total += paths.len;
        fam_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 276), total);
    try std.testing.expectEqual(@as(usize, 28), fam_count);
    try std.testing.expectEqual(total_count, total);
}

test "抽样核对：~10 个知名路径与 WxMpApiUrl.java 一致" {
    // 纯路径（无查询串）——与 Java path 逐字一致（仅去掉前导 '/'）
    try std.testing.expectEqualStrings("cgi-bin/user/info", User.user_info_url);
    try std.testing.expectEqualStrings("cgi-bin/menu/create", Menu.menu_create);
    try std.testing.expectEqualStrings("cgi-bin/message/mass/sendall", MassMessage.message_mass_sendall_url);
    try std.testing.expectEqualStrings("cgi-bin/qrcode/create", Qrcode.qrcode_create);
    try std.testing.expectEqualStrings("cgi-bin/user/get", User.user_get_url);
    try std.testing.expectEqualStrings("cgi-bin/template/api_add_template", TemplateMsg.template_api_add_template);
    try std.testing.expectEqualStrings("cgi-bin/draft/add", Draft.add_draft);

    // 带查询串模板的常量：整串逐字保留，故用「前缀」核对知名路径部分
    try std.testing.expect(std.mem.startsWith(u8, Other.get_access_token_url, "cgi-bin/token"));
    try std.testing.expect(std.mem.startsWith(u8, Material.material_add_url, "cgi-bin/material/add_material"));
    // Java 为 addguideacct（任务描述里的 addguide 是约写），用前缀核对
    try std.testing.expect(std.mem.startsWith(u8, Guide.add_guide, "cgi-bin/guide/addguide"));

    // 同时把这些模板的完整字面值逐字锁死，确保占位符未丢失
    try std.testing.expectEqualStrings(
        "cgi-bin/token?grant_type=client_credential&appid=%s&secret=%s",
        Other.get_access_token_url,
    );
    try std.testing.expectEqualStrings("cgi-bin/material/add_material?type=%s", Material.material_add_url);
    try std.testing.expectEqualStrings("cgi-bin/guide/addguideacct", Guide.add_guide);
}

test "参数化 URL 模板：占位符 / 查询串 / 片段逐字保留" {
    // 结尾就是 '?' 或 '='（Java 原样，不补参数）
    try std.testing.expectEqualStrings("device/compel_unbind?", Device.device_compel_unbind);
    try std.testing.expectEqualStrings("cgi-bin/ticket/getticket?type=", Other.get_ticket_url);
    // 多个 %s + #wechat_redirect 片段（OPEN host）
    try std.testing.expectEqualStrings(
        "connect/oauth2/authorize?appid=%s&redirect_uri=%s&response_type=code&scope=%s&state=%s&connect_redirect=1#wechat_redirect",
        OAuth2.connect_oauth2_authorize_url,
    );
    // %d + %s 混合（MP host）
    try std.testing.expectEqualStrings(
        "mp/subscribemsg?action=get_confirm&appid=%s&scene=%d&template_id=%s&redirect_url=%s&reserved=%s#wechat_redirect",
        SubscribeMsg.subscribe_message_authorize_url,
    );
    try std.testing.expectEqualStrings("cgi-bin/showqrcode?ticket=%s", Qrcode.show_qrcode_with_ticket);
    try std.testing.expectEqualStrings("customservice/kfaccount/uploadheadimg?kf_account=%s", Kefu.kfaccount_upload_head_img);
}

test "url() 拼接 helper 与 Host 主机" {
    try std.testing.expectEqualStrings(
        "https://api.weixin.qq.com/cgi-bin/user/info",
        url(Host.api, User.user_info_url),
    );
    try std.testing.expectEqualStrings(
        "https://mp.weixin.qq.com/cgi-bin/showqrcode",
        url(Host.mp, Qrcode.show_qrcode),
    );
}
