//! v0.3.10 C2：isolation pattern（对齐 Tauri isolation 的防伪造语义）。
//!
//! 模型：应用声明 32 字节对称密钥（`Config.isolation.key_hex`）。框架给每个页面
//! 挂一个**随机 origin 的隔离 iframe**（`ziltiso://<session-random>/`，独立 scheme，
//! 跨源不可读），iframe 的页面由框架服务并内嵌密钥 + 纯 JS HMAC-SHA256。
//! 前端的 invoke 走：主页面 → postMessage → 隔离 iframe → HMAC 签名
//! `HMAC(key, "v1|m|a|n")` → `{n, s}` 回传 → 主页面以 sealed 形态发给 Zig →
//! Zig 校验签名 + nonce 防重放 → 分发。
//!
//! 为什么是 HMAC 而非 AES-GCM：威胁模型 = **伪造调用**（远程页面拿不到 key，
//! 无法产出合法签名）；机密性不在模型内（method/args 对页面本身可见）。
//! WebCrypto 的 `crypto.subtle` 只在 secure context 可用——自定义 scheme 的
//! iframe 不保证，故用**纯 JS 实现**（无任何环境依赖）。
//!
//! 安全面：
//! - 远程/被注入页面拿不到 key（跨源）→ 无法产出合法 HMAC（伪造必拒）；
//! - 明文 invoke（伪造）→ 分发层直接拒绝（`IsolationRequired` + `__zilt.isoRejected`）；
//! - nonce 每次随机（`crypto.getRandomValues`——非 secure context 也可用），
//!   Zig 侧有界重放缓存（512 槽）拦截重放；
//! - 签名域 "zilt-iso-invoke-v1" 防跨协议重用；
//! - iframe 只应答 parent 的 seal 请求（`e.source === window.parent`）——
//!   第三方 iframe 无法把隔离页当签名 oracle。
//!
//! 范围（文档化）：密封面 = invoke（命令）；事件回传不密封（远程页面本可读取
//! 响应，isolation 防的是「伪造调用」而非「读取响应」）。
const std = @import("std");

/// 签名域（JS 侧逐字一致；换协议版本时变更）
pub const domain_invoke = "zilt-iso-invoke-v1";

const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const hex_lower = "0123456789abcdef";

/// 32 字节对称密钥
pub const Key = struct {
    bytes: [32]u8,
};

/// 解析 64 字符 hex 密钥（应用侧声明；非法长度/字符报错）
pub fn keyFromHex(hex: []const u8) !Key {
    if (hex.len != 64) return error.InvalidKeyHex;
    var key: Key = undefined;
    _ = std.fmt.hexToBytes(&key.bytes, hex) catch return error.InvalidKeyHex;
    return key;
}

/// nonce 字节 → 32 字符 hex（JS 侧同样输出小写 hex）
pub fn nonceHex(nonce: [16]u8) [32]u8 {
    var out: [32]u8 = undefined;
    for (nonce, 0..) |b, i| {
        out[i * 2] = hex_lower[(b >> 4) & 0xF];
        out[i * 2 + 1] = hex_lower[b & 0xF];
    }
    return out;
}

/// 签名（Zig 侧：单测往返 + server 场景；JS 侧为纯 JS HMAC 同构实现）。
/// 待签消息 = `domain ++ "|" ++ method ++ "|" ++ args_json ++ "|" ++ nonce_hex`。
pub fn signJson(key: Key, method: []const u8, args_json: []const u8, nonce_hex: []const u8) [Hmac.mac_length]u8 {
    var hasher = Hmac.init(&key.bytes);
    hasher.update(domain_invoke[0..domain_invoke.len]);
    hasher.update("|"[0.."|".len]);
    hasher.update(method);
    hasher.update("|"[0.."|".len]);
    hasher.update(args_json);
    hasher.update("|"[0.."|".len]);
    hasher.update(nonce_hex);
    var mac: [Hmac.mac_length]u8 = undefined;
    hasher.final(&mac);
    return mac;
}

/// 校验 + 防重放（nonce_hex 必须未见过）。任何失败都返回 false。
/// method/args_json 来自明文消息（分发层据此放行）。
pub fn verifyJson(cache: *ReplayCache, key: Key, nonce_hex: []const u8, method: []const u8, args_json: []const u8, sig_hex: []const u8) bool {
    if (nonce_hex.len != 32) return false;
    for (nonce_hex) |ch| {
        if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return false;
    }
    if (sig_hex.len != 64) return false;
    var want: [Hmac.mac_length]u8 = undefined;
    _ = std.fmt.hexToBytes(&want, sig_hex) catch return false;
    const got = signJson(key, method, args_json, nonce_hex);
    if (!std.crypto.timing_safe.eql([Hmac.mac_length]u8, got, want)) return false;
    return cache.record(nonce_hex);
}

/// 有界重放缓存（固定 512 槽环形；槽复用 = 最旧 nonce 出窗——重放窗口足够小；
/// UI 线程独占分发，无锁）。
pub const ReplayCache = struct {
    const slots = 512;
    seen: [slots][32]u8 = undefined,
    seen_len: [slots]u8 = @splat(0),
    cursor: usize = 0,

    pub fn record(self: *ReplayCache, nonce_hex: []const u8) bool {
        for (self.seen[0..], self.seen_len[0..]) |slot, len| {
            if (len == nonce_hex.len and std.mem.eql(u8, slot[0..len], nonce_hex)) return false;
        }
        const i = self.cursor % slots;
        self.cursor += 1;
        const n = @min(nonce_hex.len, 32);
        @memcpy(self.seen[i][0..n], nonce_hex[0..n]);
        self.seen_len[i] = @intCast(n);
        return true;
    }
};

/// v0.3.10 C2：规范化 JSON（对象键排序递归；数组保序）——签名跨引擎一致的基础。
/// **为什么必须**：jsc_value_to_json 不保留插入序（实测 {"a":2,"b":3} → {"b":3,"a":2}），
/// 页侧 JSON.stringify 与 Zig 侧重序列化的键序不同 → 签名必须覆盖规范化形态。
pub fn canonicalize(alloc: std.mem.Allocator, v: std.json.Value, out: *std.ArrayListUnmanaged(u8)) !void {
    switch (v) {
        .null => try out.appendSlice(alloc, "null"),
        .bool => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
        .integer => |i| {
            const j = try std.fmt.allocPrint(alloc, "{d}", .{i});
            defer alloc.free(j);
            try out.appendSlice(alloc, j);
        },
        .float => |f| {
            const j = try std.json.Stringify.valueAlloc(alloc, f, .{});
            defer alloc.free(j);
            try out.appendSlice(alloc, j);
        },
        .number_string => |s| try out.appendSlice(alloc, s),
        .string => |str| {
            const j = try std.json.Stringify.valueAlloc(alloc, str, .{});
            defer alloc.free(j);
            try out.appendSlice(alloc, j);
        },
        .array => |arr| {
            try out.append(alloc, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(alloc, ',');
                try canonicalize(alloc, item, out);
            }
            try out.append(alloc, ']');
        },
        .object => |obj| {
            try out.append(alloc, '{');
            var keys: std.ArrayListUnmanaged([]const u8) = .empty;
            defer keys.deinit(alloc);
            var kit = obj.iterator();
            while (kit.next()) |e| keys.append(alloc, e.key_ptr.*) catch return error.OutOfMemory;
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            for (keys.items, 0..) |k, i| {
                if (i > 0) try out.append(alloc, ',');
                const kj = try std.json.Stringify.valueAlloc(alloc, k, .{});
                defer alloc.free(kj);
                try out.appendSlice(alloc, kj);
                try out.append(alloc, ':');
                try canonicalize(alloc, obj.get(k).?, out);
            }
            try out.append(alloc, '}');
        },
    }
}

/// 随机 origin 会话段（16 hex；每进程生成——iframe origin 每会话不同）
pub fn sessionRandom(buf: *[16]u8, seed: u64) []const u8 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, seed ^ @as(u64, @intFromPtr(buf)), .little);
    for (bytes, 0..) |b, i| {
        buf[i * 2] = hex_lower[(b >> 4) & 0xF];
        buf[i * 2 + 1] = hex_lower[b & 0xF];
    }
    return buf[0..16];
}

/// 隔离 iframe 页面（框架服务 `ziltiso://<random>/` 时返回）。
/// 纯 JS SHA-256/HMAC（无 WebCrypto——`crypto.subtle` 在自定义 scheme 的 iframe
/// 不保证 secure context）。只应答 parent 的 seal 请求（e.source === window.parent
/// ——防止其他源把 iframe 当签名 oracle）。
pub fn iframeHtml(alloc: std.mem.Allocator, key_hex: []const u8) ![]u8 {
    // key_hex 是 hex 字符集，嵌入 JS 字符串无需转义
    return std.fmt.allocPrint(alloc,
        "<!doctype html><script>" ++
            "(function(){{" ++
            "var KEY_HEX='{s}';" ++
            "var DOMAIN='{s}';" ++
            // ---- 纯 JS SHA-256 ----
            "var K=new Uint32Array([0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5," ++
            "0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174," ++
            "0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da," ++
            "0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967," ++
            "0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85," ++
            "0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070," ++
            "0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3," ++
            "0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]);" ++
            "function sha256(msg){{" ++
            "var len=msg.length;var withOne=new Uint8Array((((len+8)>>6)+1)<<6);" ++
            "withOne.set(msg);withOne[len]=0x80;" ++
            "var bitLenHi=Math.floor(len/536870912);var bitLenLo=(len<<3)>>>0;" ++
            "var dv=new DataView(withOne.buffer);" ++
            "dv.setUint32(withOne.length-8,bitLenHi);dv.setUint32(withOne.length-4,bitLenLo);" ++
            "var h=new Uint32Array([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]);" ++
            "var w=new Uint32Array(64);" ++
            "for(var off=0;off<withOne.length;off+=64){{" ++
            "for(var i=0;i<16;i++)w[i]=dv.getUint32(off+i*4);" ++
            "for(var i=16;i<64;i++){{var x=w[i-15];var y=w[i-2];" ++
            "w[i]=(w[i-16]+((x>>>7|x<<25)^(x>>>18|x<<14)^(x>>>3))+w[i-7]+((y>>>17|y<<15)^(y>>>19|y<<13)^(y>>>10)))>>>0;}}" ++
            "var a=h[0],b=h[1],c2=h[2],d=h[3],e=h[4],f=h[5],g=h[6],hh=h[7];" ++
            "for(var i=0;i<64;i++){{" ++
            "var t1=(hh+((e>>>6|e<<26)^(e>>>11|e<<21)^(e>>>25|e<<7))+((e&f)^(~e&g))+K[i]+w[i])>>>0;" ++
            "var t2=((a>>>2|a<<30)^(a>>>13|a<<19)^(a>>>22|a<<10))+((a&b)^(a&c2)^(b&c2))>>>0;" ++
            "hh=g;g=f;f=e;e=(d+t1)>>>0;d=c2;c2=b;b=a;a=(t1+t2)>>>0;" ++
            "}}" ++
            "h[0]=(h[0]+a)>>>0;h[1]=(h[1]+b)>>>0;h[2]=(h[2]+c2)>>>0;h[3]=(h[3]+d)>>>0;" ++
            "h[4]=(h[4]+e)>>>0;h[5]=(h[5]+f)>>>0;h[6]=(h[6]+g)>>>0;h[7]=(h[7]+hh)>>>0;" ++
            "}}" ++
            "var out=new Uint8Array(32);" ++
            "var od=new DataView(out.buffer);" ++
            "for(var i=0;i<8;i++)od.setUint32(i*4,h[i]);" ++
            "return out;" ++
            "}}" ++
            "function utf8(s){{return new TextEncoder().encode(s);}}" ++
            "function toHex(bytes){{var s='';for(var i=0;i<bytes.length;i++){{var v=bytes[i];var hi=(v>>4)&15,lo=v&15;" ++
            "s+=String.fromCharCode(hi<10?48+hi:87+hi);s+=String.fromCharCode(lo<10?48+lo:87+lo);}}return s;}}" ++
            "function hmac(key,msg){{" ++
            "var k=key;if(k.length>64)k=sha256(k);" ++
            "var pad=new Uint8Array(64);pad.set(k);" ++
            "var ip=new Uint8Array(64+msg.length);ip.set(pad.map(function(v){{return v^0x36;}}));ip.set(msg,64);" ++
            "var inner=sha256(ip);" ++
            "var op=new Uint8Array(64+32);op.set(pad.map(function(v){{return v^0x5c;}}));op.set(inner,64);" ++
            "return sha256(op);" ++
            "}}" ++
            // ---- seal 服务 ----
            "window.addEventListener('message',function(e){{" ++
            "var d=e.data||{{}};" ++
            "if(d.ziltIso!==1||d.kind!=='seal')return;" ++
            "if(e.source!==window.parent)return;" ++
            "try{{" ++
            "var n=new Uint8Array(16);crypto.getRandomValues(n);" ++
            "var nh=toHex(n);" ++
            "function canon(v){{if(v===null||typeof v!=='object')return JSON.stringify(v);if(Array.isArray(v))return '['+v.map(function(x){{return x===undefined?'null':canon(x);}}).join(',')+']';var ks=Object.keys(v).sort().filter(function(k){{return v[k]!==undefined;}});return '{{'+ks.map(function(k){{return JSON.stringify(k)+':'+canon(v[k]);}}).join(',')+'}}';}}var msg=DOMAIN+'|'+String(d.method)+'|'+canon(d.args??{{}})+'|'+nh;" ++
            "var KEY=new Uint8Array(32);for(var i=0;i<32;i++)KEY[i]=parseInt(KEY_HEX.substr(i*2,2),16);var sig=hmac(KEY,utf8(msg));" ++
            "e.source.postMessage({{ziltIso:1,kind:'sealed',reqId:d.reqId,sealed:{{n:nh,s:toHex(sig)}}}},'*');" ++
            "}}catch(err){{" ++
            "e.source.postMessage({{ziltIso:1,kind:'sealed',reqId:d.reqId,sealed:null,error:String(err)}},'*');" ++
            "}};" ++
            "}});" ++
            "try{{parent.postMessage({{ziltIso:1,kind:'ready'}},'*');}}catch(_){{}}" ++
            "}})();" ++
            "</script>", .{ key_hex, domain_invoke });
}

const testing = std.testing;

/// comptime 重复 hex 对（0.17 无 `**` 字符串重复操作符）
fn hexRep(comptime n: usize, comptime pair: *const [2]u8) [n * 2]u8 {
    var out: [n * 2]u8 = undefined;
    for (0..n) |i| {
        out[i * 2] = pair[0];
        out[i * 2 + 1] = pair[1];
    }
    return out;
}

test "v0.3.10 C2: 密钥解析（长度/字符校验）" {
    const good = hexRep(32, "00");
    _ = try keyFromHex(&good);
    try testing.expectError(error.InvalidKeyHex, keyFromHex(&hexRep(31, "00")));
    try testing.expectError(error.InvalidKeyHex, keyFromHex(&hexRep(32, "zz")));
}

test "v0.3.10 C2: sign/verify 往返（HMAC-SHA256 + nonce 防重放）" {
    const key_hex = hexRep(32, "11");
    const key = try keyFromHex(&key_hex);
    var cache = ReplayCache{};

    const nonce_hex = nonceHex([_]u8{1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1});
    const sig = signJson(key, "greet", "{\"name\":\"iso\"}", &nonce_hex);
    var sig_hex: [64]u8 = undefined;
    for (sig, 0..) |b, i| {
        sig_hex[i * 2] = hex_lower[(b >> 4) & 0xF];
        sig_hex[i * 2 + 1] = hex_lower[b & 0xF];
    }
    // 首次校验 ✓
    try testing.expect(verifyJson(&cache, key, &nonce_hex, "greet", "{\"name\":\"iso\"}", &sig_hex));
    // 同 nonce 重放 → 拒绝
    try testing.expect(!verifyJson(&cache, key, &nonce_hex, "greet", "{\"name\":\"iso\"}", &sig_hex));
    // 新 nonce + 对应新签名 → ✓（签名绑定 nonce）
    const nonce2 = nonceHex([_]u8{2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2});
    const sig2 = signJson(key, "greet", "{\"name\":\"iso\"}", &nonce2);
    var sig2_hex: [64]u8 = undefined;
    for (sig2, 0..) |b, i| {
        sig2_hex[i * 2] = hex_lower[(b >> 4) & 0xF];
        sig2_hex[i * 2 + 1] = hex_lower[b & 0xF];
    }
    try testing.expect(verifyJson(&cache, key, &nonce2, "greet", "{\"name\":\"iso\"}", &sig2_hex));
    // 篡改 args → 签名不符
    var cache2 = ReplayCache{};
    const nonce3 = nonceHex([_]u8{3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3});
    try testing.expect(!verifyJson(&cache2, key, &nonce3, "greet", "{\"name\":\"hacked\"}", &sig_hex));
    // 篡改 method → 签名不符
    try testing.expect(!verifyJson(&cache2, key, &nonce3, "evil", "{\"name\":\"iso\"}", &sig_hex));
    // 错误密钥 → 拒绝
    const wrong = try keyFromHex(&hexRep(32, "ff"));
    var cache3 = ReplayCache{};
    try testing.expect(!verifyJson(&cache3, wrong, &nonce3, "greet", "{\"name\":\"iso\"}", &sig_hex));
    // 非法 nonce（大写 hex / 长度不符）→ 拒绝
    var cache4 = ReplayCache{};
    try testing.expect(!verifyJson(&cache4, key, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "greet", "{}", &sig_hex));
    try testing.expect(!verifyJson(&cache4, key, "abcd", "greet", "{}", &sig_hex));
}

test "v0.3.10 C2: canonicalize 键序无关（跨引擎签名基础）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 同一内容两种键序 → 规范化后逐字相同
    const v1 = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"a\":2,\"b\":3,\"c\":[1,{\"y\":true,\"x\":null}]}", .{});
    const v2 = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"c\":[1,{\"x\":null,\"y\":true}],\"b\":3,\"a\":2}", .{});
    var o1: std.ArrayListUnmanaged(u8) = .empty;
    var o2: std.ArrayListUnmanaged(u8) = .empty;
    try canonicalize(a, v1, &o1);
    try canonicalize(a, v2, &o2);
    try testing.expectEqualStrings(o1.items, o2.items);
    try testing.expectEqualStrings("{\"a\":2,\"b\":3,\"c\":[1,{\"x\":null,\"y\":true}]}", o1.items);
    // 字符串转义（引号与换行）形态保持
    const v3 = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"q\":\"quote\\\"and\\nnewline\"}", .{});
    var o3: std.ArrayListUnmanaged(u8) = .empty;
    try canonicalize(a, v3, &o3);
    try testing.expect(std.mem.indexOf(u8, o3.items, "\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, o3.items, "\\n") != null);
}

test "v0.3.10 C2: 会话随机段 + iframe 页面形态" {
    var buf: [16]u8 = undefined;
    const r1 = sessionRandom(&buf, 12345);
    try testing.expectEqual(@as(usize, 16), r1.len);
    var buf2: [16]u8 = undefined;
    const r2 = sessionRandom(&buf2, 67890);
    try testing.expect(!std.mem.eql(u8, r1, r2));

    const html = try iframeHtml(testing.allocator, &hexRep(32, "11"));
    defer testing.allocator.free(html);
    try testing.expect(std.mem.indexOf(u8, html, "sha256") != null);
    try testing.expect(std.mem.indexOf(u8, html, domain_invoke) != null);
    try testing.expect(std.mem.indexOf(u8, html, "e.source!==window.parent") != null);
    try testing.expect(std.mem.indexOf(u8, html, "1111111111111111") != null);
    // 不依赖 WebCrypto subtle（secure context 不可用风险）
    try testing.expect(std.mem.indexOf(u8, html, "crypto.subtle") == null);
}
