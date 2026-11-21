// 洛雪（LX Music）自定义源兼容层：注入 globalThis.lx 运行时与内置平台搜索。
// JS 内容与开发测试台里的 lx-runtime.js / lx-search.js 保持一致（已通过本地端到端测试）。

let lxRuntimeJS = #"""
// ===== MusicBox 洛雪（LX）兼容层运行时 =====
// 依赖 pluginRuntimeJS 已提供的：__log/__hash/__request/__setTimeout、qs、__httpRequest、__findHeader。
// 另外依赖 Swift 原生桥：__randomB64(n)、__zlibInflateB64(b64)、__zlibDeflateB64(b64)。

if (typeof console.group !== 'function') { console.group = console.log; }
if (typeof console.groupEnd !== 'function') { console.groupEnd = function () {}; }
if (typeof console.trace !== 'function') { console.trace = console.log; }

// ---------- UTF-8 / 字节工具 ----------
function __lxUtf8Encode(str) {
  str = String(str);
  var out = [];
  for (var i = 0; i < str.length; i++) {
    var c = str.charCodeAt(i);
    if (c < 0x80) { out.push(c); }
    else if (c < 0x800) { out.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f)); }
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < str.length) {
      var c2 = str.charCodeAt(++i);
      var cp = 0x10000 + ((c & 0x3ff) << 10) + (c2 & 0x3ff);
      out.push(0xf0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3f), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f));
    } else { out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f)); }
  }
  return new Uint8Array(out);
}

function __lxUtf8Decode(bytes) {
  var out = '';
  var i = 0;
  while (i < bytes.length) {
    var b = bytes[i];
    if (b < 0x80) { out += String.fromCharCode(b); i += 1; }
    else if (b >= 0xc0 && b < 0xe0) { out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f)); i += 2; }
    else if (b >= 0xe0 && b < 0xf0) { out += String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i + 1] & 0x3f) << 6) | (bytes[i + 2] & 0x3f)); i += 3; }
    else {
      var cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3f) << 12) | ((bytes[i + 2] & 0x3f) << 6) | (bytes[i + 3] & 0x3f);
      cp -= 0x10000;
      out += String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      i += 4;
    }
  }
  return out;
}

var __lxB64Chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function __lxB64EncodeBytes(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var b0 = bytes[i], b1 = i + 1 < bytes.length ? bytes[i + 1] : 0, b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
    out += __lxB64Chars[b0 >> 2];
    out += __lxB64Chars[((b0 & 3) << 4) | (b1 >> 4)];
    out += i + 1 < bytes.length ? __lxB64Chars[((b1 & 15) << 2) | (b2 >> 6)] : '=';
    out += i + 2 < bytes.length ? __lxB64Chars[b2 & 63] : '=';
  }
  return out;
}
function __lxB64DecodeBytes(str) {
  str = String(str).replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/=]/g, '');
  var out = [];
  for (var i = 0; i < str.length; i += 4) {
    var c0 = __lxB64Chars.indexOf(str[i]), c1 = __lxB64Chars.indexOf(str[i + 1]);
    var c2 = str[i + 2] === '=' || str[i + 2] === undefined ? -1 : __lxB64Chars.indexOf(str[i + 2]);
    var c3 = str[i + 3] === '=' || str[i + 3] === undefined ? -1 : __lxB64Chars.indexOf(str[i + 3]);
    out.push((c0 << 2) | (c1 >> 4));
    if (c2 >= 0) out.push(((c1 & 15) << 4) | (c2 >> 2));
    if (c3 >= 0) out.push(((c2 & 3) << 6) | c3);
  }
  return new Uint8Array(out);
}
function __lxHexEncode(bytes) {
  var out = '';
  for (var i = 0; i < bytes.length; i++) out += ('0' + bytes[i].toString(16)).slice(-2);
  return out;
}
function __lxHexDecode(str) {
  str = String(str);
  var out = new Uint8Array(Math.floor(str.length / 2));
  for (var i = 0; i < out.length; i++) out[i] = parseInt(str.substr(i * 2, 2), 16);
  return out;
}

// ---------- Buffer 极简实现（基于 Uint8Array） ----------
function __lxMakeBuf(bytes) {
  if (!(bytes instanceof Uint8Array)) bytes = new Uint8Array(bytes);
  bytes.toString = function (enc) {
    switch ((enc || 'utf8').toLowerCase()) {
      case 'hex': return __lxHexEncode(bytes);
      case 'base64': return __lxB64EncodeBytes(bytes);
      case 'binary': case 'latin1': case 'ascii': {
        var s = '';
        for (var i = 0; i < bytes.length; i += 8192) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
        return s;
      }
      default: return __lxUtf8Decode(bytes);
    }
  };
  return bytes;
}
function __lxToBytes(input, encoding) {
  if (input === null || input === undefined) return new Uint8Array(0);
  if (input instanceof Uint8Array) return new Uint8Array(input);
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  if (typeof input === 'string') {
    switch ((encoding || 'utf8').toLowerCase()) {
      case 'hex': return __lxHexDecode(input);
      case 'base64': return __lxB64DecodeBytes(input);
      case 'binary': case 'latin1': case 'ascii': {
        var out = new Uint8Array(input.length);
        for (var i = 0; i < input.length; i++) out[i] = input.charCodeAt(i) & 0xff;
        return out;
      }
      default: return __lxUtf8Encode(input);
    }
  }
  if (Array.isArray(input)) return new Uint8Array(input);
  if (typeof input === 'object' && input.type === 'Buffer' && Array.isArray(input.data)) return new Uint8Array(input.data);
  if (typeof input === 'object' && typeof input.length === 'number') return new Uint8Array(input);
  return __lxUtf8Encode(String(input));
}

var Buffer = {
  from: function (input, encoding) {
    if (typeof input === 'string') return __lxMakeBuf(__lxToBytes(input, encoding));
    return __lxMakeBuf(__lxToBytes(input));
  },
  alloc: function (size, fill) {
    var b = new Uint8Array(size || 0);
    if (fill !== undefined) b.fill(typeof fill === 'string' ? fill.charCodeAt(0) & 0xff : fill);
    return __lxMakeBuf(b);
  },
  allocUnsafe: function (size) { return __lxMakeBuf(new Uint8Array(size || 0)); },
  concat: function (list, totalLength) {
    var total = 0;
    var parts = list.map(function (p) { var b = __lxToBytes(p); total += b.length; return b; });
    var out = new Uint8Array(totalLength !== undefined ? totalLength : total);
    var off = 0;
    parts.forEach(function (b) { out.set(b.subarray(0, Math.max(0, out.length - off)), off); off += b.length; });
    return __lxMakeBuf(out);
  },
  isBuffer: function (x) { return x instanceof Uint8Array; },
  byteLength: function (str) { return typeof str === 'string' ? __lxUtf8Encode(str).length : __lxToBytes(str).length; }
};

// ---------- 纯 JS AES 加密（与 Node createCipheriv 行为一致，PKCS7 填充） ----------
var __lxAES = (function () {
  function gfMul(a, b) {
    var p = 0;
    for (var i = 0; i < 8; i++) {
      if (b & 1) p ^= a;
      var hi = a & 0x80;
      a = (a << 1) & 0xff;
      if (hi) a ^= 0x1b;
      b >>= 1;
    }
    return p;
  }
  function gfInv(a) {
    if (a === 0) return 0;
    for (var i = 1; i < 256; i++) if (gfMul(a, i) === 1) return i;
    return 0;
  }
  var sbox = new Uint8Array(256);
  for (var i = 0; i < 256; i++) {
    var inv = gfInv(i);
    var s = inv ^ ((inv << 1) | (inv >> 7)) ^ ((inv << 2) | (inv >> 6)) ^ ((inv << 3) | (inv >> 5)) ^ ((inv << 4) | (inv >> 4)) ^ 0x63;
    sbox[i] = s & 0xff;
  }
  var rcon = [0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36, 0x6c, 0xd8, 0xab, 0x4d];

  function expandKey(key) {
    var Nk = key.length / 4;
    var Nr = Nk + 6;
    var w = new Uint8Array(16 * (Nr + 1));
    w.set(key);
    var temp = new Uint8Array(4);
    for (var i = Nk; i < 4 * (Nr + 1); i++) {
      temp.set(w.subarray((i - 1) * 4, i * 4));
      if (i % Nk === 0) {
        var t = temp[0];
        temp[0] = sbox[temp[1]] ^ rcon[i / Nk - 1];
        temp[1] = sbox[temp[2]];
        temp[2] = sbox[temp[3]];
        temp[3] = sbox[t];
      } else if (Nk > 6 && i % Nk === 4) {
        for (var j = 0; j < 4; j++) temp[j] = sbox[temp[j]];
      }
      for (var k = 0; k < 4; k++) w[i * 4 + k] = w[(i - Nk) * 4 + k] ^ temp[k];
    }
    return { roundKeys: w, rounds: Nr };
  }

  function encryptBlock(input, roundKeys, rounds) {
    var s = new Uint8Array(16);
    s.set(input);
    function addRoundKey(r) { for (var i = 0; i < 16; i++) s[i] ^= roundKeys[r * 16 + i]; }
    function subBytes() { for (var i = 0; i < 16; i++) s[i] = sbox[s[i]]; }
    function shiftRows() {
      var t;
      t = s[1]; s[1] = s[5]; s[5] = s[9]; s[9] = s[13]; s[13] = t;
      t = s[2]; s[2] = s[10]; s[10] = t; t = s[6]; s[6] = s[14]; s[14] = t;
      t = s[15]; s[15] = s[11]; s[11] = s[7]; s[7] = s[3]; s[3] = t;
    }
    function xtime(x) { return ((x << 1) & 0xff) ^ (x & 0x80 ? 0x1b : 0); }
    function mixColumns() {
      for (var c = 0; c < 4; c++) {
        var i = c * 4;
        var a0 = s[i], a1 = s[i + 1], a2 = s[i + 2], a3 = s[i + 3];
        s[i] = xtime(a0) ^ (xtime(a1) ^ a1) ^ a2 ^ a3;
        s[i + 1] = a0 ^ xtime(a1) ^ (xtime(a2) ^ a2) ^ a3;
        s[i + 2] = a0 ^ a1 ^ xtime(a2) ^ (xtime(a3) ^ a3);
        s[i + 3] = (xtime(a0) ^ a0) ^ a1 ^ a2 ^ xtime(a3);
      }
    }
    addRoundKey(0);
    for (var r = 1; r < rounds; r++) { subBytes(); shiftRows(); mixColumns(); addRoundKey(r); }
    subBytes(); shiftRows(); addRoundKey(rounds);
    return s;
  }

  function encrypt(data, mode, key, iv) {
    var m = /^aes-(128|192|256)-([a-z0-9]+)$/i.exec(mode || '');
    if (!m) throw new Error('不支持的 AES 模式: ' + mode);
    var bits = parseInt(m[1], 10);
    var cipherMode = m[2].toLowerCase();
    if (key.length * 8 !== bits) throw new Error('AES 密钥长度与模式不符');
    var expanded = expandKey(key);
    // PKCS7 填充
    var padLen = 16 - (data.length % 16);
    var padded = new Uint8Array(data.length + padLen);
    padded.set(data);
    padded.fill(padLen, data.length);
    var out = new Uint8Array(padded.length);
    var prev = iv ? new Uint8Array(iv) : new Uint8Array(16);
    for (var off = 0; off < padded.length; off += 16) {
      var block = padded.subarray(off, off + 16);
      if (cipherMode === 'cbc') {
        var x = new Uint8Array(16);
        for (var i = 0; i < 16; i++) x[i] = block[i] ^ prev[i];
        block = x;
      } else if (cipherMode !== 'ecb') {
        throw new Error('暂不支持的 AES 模式: ' + mode);
      }
      var enc = encryptBlock(block, expanded.roundKeys, expanded.rounds);
      out.set(enc, off);
      if (cipherMode === 'cbc') prev = enc;
    }
    return out;
  }
  return { encrypt: encrypt };
})();

// ---------- 纯 JS RSA 公钥加密（NoPadding，输入左补零到模长；与 LX preload 实现一致） ----------
function __lxRsaEncrypt(dataBytes, keyPem) {
  var b64 = String(keyPem).replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  var der = __lxB64DecodeBytes(b64);
  var pos = 0;
  function readLen() {
    var b = der[pos++];
    if (b < 0x80) return b;
    var n = b & 0x7f, v = 0;
    for (var i = 0; i < n; i++) v = v * 256 + der[pos++];
    return v;
  }
  function readTag(tag) {
    if (der[pos++] !== tag) throw new Error('RSA 密钥解析失败');
    return readLen();
  }
  readTag(0x30); // 外层 SEQUENCE
  var algLen = readTag(0x30); // 算法 SEQUENCE，返回其长度
  pos += algLen;
  readTag(0x03); // BIT STRING（标签与长度已消费）
  pos += 1; // unused bits 计数
  readTag(0x30); // RSAPublicKey SEQUENCE
  var nLen = readTag(0x02);
  var nBytes = der.subarray(pos, pos + nLen); pos += nLen;
  var eLen = readTag(0x02);
  var eBytes = der.subarray(pos, pos + eLen);
  function bytesToBigInt(bytes) {
    var v = 0n;
    for (var i = 0; i < bytes.length; i++) v = v * 256n + BigInt(bytes[i]);
    return v;
  }
  var n = bytesToBigInt(nBytes);
  var e = bytesToBigInt(eBytes);
  var modLen = nBytes[0] === 0 ? nBytes.length - 1 : nBytes.length;
  var padded = new Uint8Array(modLen);
  padded.set(dataBytes.subarray(Math.max(0, dataBytes.length - modLen)), Math.max(0, modLen - dataBytes.length));
  var mVal = bytesToBigInt(padded);
  // 模幂（平方乘）
  var result = 1n;
  var base = mVal % n;
  var exp = e;
  while (exp > 0n) {
    if (exp & 1n) result = (result * base) % n;
    base = (base * base) % n;
    exp >>= 1n;
  }
  var out = new Uint8Array(modLen);
  var v2 = result;
  for (var i = modLen - 1; i >= 0; i--) { out[i] = Number(v2 & 0xffn); v2 >>= 8n; }
  return out;
}

// ---------- lx 全局对象 ----------
var __lxHandlers = {};
var __lxInitedData = null;
var __lxUpdateAlertData = null;

function __lxRequest(url, opts, callback) {
  if (typeof opts === 'function') { callback = opts; opts = {}; }
  opts = opts || {};
  var headers = {};
  var srcHeaders = opts.headers || {};
  for (var k in srcHeaders) headers[k] = srcHeaders[k];
  var body = opts.body;
  if (opts.form) {
    body = typeof opts.form === 'string' ? opts.form : qs.stringify(opts.form);
    if (!__findHeader(headers, 'content-type')) headers['Content-Type'] = 'application/x-www-form-urlencoded';
  } else if (opts.formData) {
    var boundary = '----MusicBoxLXFormBoundary' + Math.random().toString(16).slice(2);
    var parts = '';
    for (var fk in opts.formData) {
      var fv = opts.formData[fk];
      parts += '--' + boundary + '\r\nContent-Disposition: form-data; name="' + fk + '"\r\n\r\n' + String(fv) + '\r\n';
    }
    parts += '--' + boundary + '--\r\n';
    body = parts;
    headers['Content-Type'] = 'multipart/form-data; boundary=' + boundary;
  }
  if (body !== undefined && body !== null && typeof body !== 'string' && !(body instanceof Uint8Array)) {
    body = JSON.stringify(body);
    if (!__findHeader(headers, 'content-type')) headers['Content-Type'] = 'application/json';
  }
  if (body instanceof Uint8Array) body = __lxUtf8Decode(body);
  var promise = __httpRequest({
    url: url,
    method: (opts.method || 'get').toUpperCase(),
    headers: headers,
    body: body === undefined ? null : body,
    timeout: opts.timeout || 60000
  }).then(function (res) {
    var resp = {
      statusCode: res.status,
      statusMessage: '',
      headers: res.headers,
      body: res.data,
      raw: res.body
    };
    if (callback) { try { callback(null, resp, res.data); } catch (e) { __log('lx.request 回调异常: ' + e); } }
    return resp;
  }, function (err) {
    if (callback) { try { callback(err, null, null); } catch (e) {} }
    throw err;
  });
  var abort = function () {};
  abort.then = promise.then.bind(promise);
  abort.catch = promise.catch.bind(promise);
  return abort;
}

var lx = {
  EVENT_NAMES: { inited: 'inited', request: 'request', updateAlert: 'updateAlert' },
  on: function (eventName, handler) { __lxHandlers[eventName] = handler; },
  send: function (eventName, data) {
    if (eventName === 'inited') __lxInitedData = data;
    else if (eventName === 'updateAlert') __lxUpdateAlertData = data;
    return Promise.resolve();
  },
  request: __lxRequest,
  utils: {
    crypto: {
      aesEncrypt: function (buffer, mode, key, iv) {
        var data = __lxToBytes(buffer);
        var keyBytes = __lxToBytes(key);
        var ivBytes = iv === undefined || iv === null ? null : __lxToBytes(iv);
        return __lxMakeBuf(__lxAES.encrypt(data, mode, keyBytes, ivBytes));
      },
      rsaEncrypt: function (buffer, key) {
        var keyStr = typeof key === 'string' ? key : __lxUtf8Decode(__lxToBytes(key));
        return __lxMakeBuf(__lxRsaEncrypt(__lxToBytes(buffer), keyStr));
      },
      randomBytes: function (size) { return __lxMakeBuf(__lxB64DecodeBytes(__randomB64(size))); },
      md5: function (str) { return __hash('md5', String(str)); }
    },
    buffer: {
      from: function () { return Buffer.from.apply(null, arguments); },
      bufToString: function (buf, format) { return __lxMakeBuf(__lxToBytes(buf)).toString(format || 'utf8'); }
    },
    zlib: {
      inflate: function (buf) {
        try { return Promise.resolve(__lxMakeBuf(__lxB64DecodeBytes(__zlibInflateB64(__lxB64EncodeBytes(__lxToBytes(buf)))))); }
        catch (e) { return Promise.reject(e); }
      },
      deflate: function (data) {
        try { return Promise.resolve(__lxMakeBuf(__lxB64DecodeBytes(__zlibDeflateB64(__lxB64EncodeBytes(__lxToBytes(data)))))); }
        catch (e) { return Promise.reject(e); }
      }
    }
  },
  env: 'mobile',
  version: '2.0.0',
  currentScriptInfo: { name: '', description: '', version: '', author: '', homepage: '', rawScript: '' }
};
this.lx = lx;

function __lxSetScriptInfo(json) {
  try {
    var info = JSON.parse(json);
    lx.currentScriptInfo = {
      name: info.name || '', description: info.description || '',
      version: info.version || '', author: info.author || '',
      homepage: info.homepage || '', rawScript: info.rawScript || ''
    };
  } catch (e) {}
}

function __lxInitedJSON() {
  return __lxInitedData ? JSON.stringify(__lxInitedData) : null;
}

// Swift 调用洛雪脚本的 request 处理器
function __lxCallRequest(source, action, infoJSON, onOk, onErr) {
  var handler = __lxHandlers['request'];
  if (typeof handler !== 'function') { onErr('洛雪脚本没有注册 request 处理器'); return; }
  var info;
  try { info = JSON.parse(infoJSON); } catch (e) { onErr('参数解析失败'); return; }
  var ret;
  try { ret = handler({ source: source, action: action, info: info }); }
  catch (e) { onErr(String((e && e.message) || e)); return; }
  Promise.resolve(ret).then(function (r) {
    onOk(JSON.stringify(r === undefined ? null : r));
  }, function (e) {
    onErr(String((e && e.message) || e));
  });
}

"""#

let lxSearchJS = #"""
// ===== 内置平台搜索（洛雪脚本只提供取址，搜索由这里按平台实现，返回洛雪格式的 musicInfo） =====

function __lxFmtSize(bytes) {
  var b = typeof bytes === 'string' ? parseFloat(bytes) : bytes;
  if (!b || isNaN(b)) return '';
  return (b / 1048576).toFixed(2) + 'Mb';
}
function __lxStripTags(s) { return String(s || '').replace(/<[^>]+>/g, ''); }

var __lxSearchImpl = {
  kw: async function (keyword, page) {
    var url = 'http://search.kuwo.cn/r.s?client=kt&all=' + encodeURIComponent(keyword) +
      '&pn=' + (page - 1) + '&rn=30&uid=794762570&ver=kwplayer_ar_9.2.2.1&vipver=1&show_copyright_off=1&newver=1' +
      '&ft=music&cluster=0&strategy=2012&encoding=utf8&rformat=json&vermerge=1&mobi=1&issubtitle=1';
    var res = await http.get(url, { timeout: 45000 });
    var body = res.data || {};
    var list = (body.abslist || []).map(function (item) {
      var rid = String(item.MUSICRID || '').replace(/^MUSIC_/, '');
      var types = [];
      var minfo = String(item.MINFO || '');
      minfo.split(';').forEach(function (seg) {
        var m = /bitrate:(\d+),format:(\w+),size:([\d.]+Mb)/.exec(seg);
        if (!m) return;
        var br = parseInt(m[1], 10), fmt = m[2];
        var type = null;
        if (fmt === 'flac' && br >= 2000) type = 'flac24bit';
        else if (fmt === 'flac') type = 'flac';
        else if (br >= 320) type = '320k';
        else if (br >= 128) type = '128k';
        if (type && !types.some(function (t) { return t.type === type; })) types.push({ type: type, size: m[3] });
      });
      if (!types.length) types.push({ type: '128k', size: '' });
      return {
        id: rid, songmid: rid,
        name: item.SONGNAME || item.NAME || '',
        singer: item.ARTIST || '',
        source: 'kw',
        albumName: item.ALBUM || '', albumId: String(item.ALBUMID || ''),
        interval: parseInt(item.DURATION || '0', 10) || 0,
        types: types
      };
    });
    var total = parseInt(body.TOTAL || '0', 10) || 0;
    return { list: list, isEnd: total ? page * 30 >= total : list.length < 30 };
  },

  wy: async function (keyword, page) {
    var res = await http.post('https://music.163.com/api/cloudsearch/pc',
      qs.stringify({ s: keyword, type: 1, offset: (page - 1) * 30, limit: 30, total: true }),
      { timeout: 45000, headers: { 'Referer': 'https://music.163.com', 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15' } });
    var result = (res.data && res.data.result) || {};
    var songs = result.songs || [];
    var list = songs.map(function (s) {
      var types = [];
      if (s.l) types.push({ type: '128k', size: __lxFmtSize(s.l.size) });
      if (s.h) types.push({ type: '320k', size: __lxFmtSize(s.h.size) });
      if (s.sq) types.push({ type: 'flac', size: __lxFmtSize(s.sq.size) });
      if (s.hr) types.push({ type: 'flac24bit', size: __lxFmtSize(s.hr.size) });
      return {
        id: String(s.id), songmid: String(s.id),
        name: s.name || '',
        singer: (s.ar || []).map(function (a) { return a.name; }).join(' / '),
        source: 'wy',
        albumName: (s.al && s.al.name) || '', albumId: String((s.al && s.al.id) || ''),
        img: (s.al && s.al.picUrl) || '',
        interval: Math.round((s.dt || 0) / 1000),
        types: types
      };
    });
    var total = result.songCount || 0;
    return { list: list, isEnd: total ? page * 30 >= total : list.length < 30 };
  },

  kg: async function (keyword, page) {
    var url = 'https://songsearch.kugou.com/song_search_v2?keyword=' + encodeURIComponent(keyword) +
      '&page=' + page + '&pagesize=30&userid=0&clientver=&platform=WebFilter&filter=2&iscorrection=1&privilege_filter=0&area_code=1';
    var res = await http.get(url, { timeout: 45000, headers: { 'User-Agent': 'Mozilla/5.0' } });
    var data = (res.data && res.data.data) || {};
    var list = (data.lists || []).map(function (item) {
      var types = [];
      if (item.FileHash) types.push({ type: '128k', hash: item.FileHash, size: __lxFmtSize(item.FileSize) });
      if (item.HQFileHash) types.push({ type: '320k', hash: item.HQFileHash, size: __lxFmtSize(item.HQFileSize) });
      if (item.SQFileHash) types.push({ type: 'flac', hash: item.SQFileHash, size: __lxFmtSize(item.SQFileSize) });
      if (item.ResFileHash) types.push({ type: 'flac24bit', hash: item.ResFileHash, size: __lxFmtSize(item.ResFileSize) });
      return {
        id: item.FileHash, songmid: item.FileHash, hash: item.FileHash,
        name: __lxStripTags(item.OriSongName || item.SongName || ''),
        singer: __lxStripTags(item.SingerName || ''),
        source: 'kg',
        albumName: item.AlbumName || '', albumId: String(item.AlbumID || ''),
        img: String(item.Image || '').replace('{size}', '400'),
        interval: item.Duration || 0,
        types: types
      };
    });
    var total = data.total || 0;
    return { list: list, isEnd: total ? page * 30 >= total : list.length < 30 };
  },

  tx: async function (keyword, page) {
    var url = 'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=' + page + '&n=30&w=' +
      encodeURIComponent(keyword) + '&format=json&cr=1';
    var res = await http.get(url, { timeout: 45000, headers: { 'Referer': 'https://y.qq.com', 'User-Agent': 'Mozilla/5.0' } });
    var song = (res.data && res.data.data && res.data.data.song) || {};
    var list = (song.list || []).map(function (item) {
      var types = [];
      if (item.size128 > 0) types.push({ type: '128k', size: __lxFmtSize(item.size128) });
      if (item.size320 > 0) types.push({ type: '320k', size: __lxFmtSize(item.size320) });
      if (item.sizeflac > 0) types.push({ type: 'flac', size: __lxFmtSize(item.sizeflac) });
      return {
        id: item.songmid, songmid: item.songmid, strMediaMid: item.media_mid || '',
        name: __lxStripTags(item.songname || ''),
        singer: (item.singer || []).map(function (a) { return __lxStripTags(a.name); }).join(' / '),
        source: 'tx',
        albumName: item.albumname || '', albumId: String(item.albumid || ''), albumMid: item.albummid || '',
        img: item.albummid ? 'https://y.gtimg.cn/music/photo_new/T002R300x300M000' + item.albummid + '.jpg' : '',
        interval: item.interval || 0,
        types: types
      };
    });
    var total = song.totalnum || 0;
    return { list: list, isEnd: total ? page * 30 >= total : list.length < 30 };
  },

  mg: async function (keyword, page) {
    var url = 'https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/search_all.do?ua=Android_migu&version=5.0.1&text=' +
      encodeURIComponent(keyword) + '&pageNo=' + page + '&pageSize=20&searchSwitch=' + encodeURIComponent('{"song":1}');
    var res = await http.get(url, { timeout: 45000, headers: { 'User-Agent': 'Mozilla/5.0' } });
    var resultData = (res.data && res.data.songResultData) || {};
    var fmtMap = { PQ: '128k', HQ: '320k', SQ: 'flac', ZQ: 'flac24bit' };
    var list = (resultData.result || []).map(function (item) {
      var types = [];
      (item.newRateFormats || []).forEach(function (f) {
        var t = fmtMap[f.formatType];
        if (t) types.push({ type: t, size: __lxFmtSize(f.size) });
      });
      var alb = (item.albums && item.albums[0]) || {};
      return {
        id: String(item.copyrightId || item.id), songmid: String(item.copyrightId || item.id),
        copyrightId: String(item.copyrightId || ''), songId: String(item.id || ''),
        name: item.name || '',
        singer: (item.singers || []).map(function (a) { return a.name; }).join(' / '),
        source: 'mg',
        albumName: item.album || alb.name || '', albumId: String(item.albumId || alb.id || ''),
        img: item.img3 || item.img2 || item.img1 || alb.img || '',
        types: types
      };
    });
    return { list: list, isEnd: list.length < 20 };
  }
};

function __lxSearch(source, keyword, page) {
  var impl = __lxSearchImpl[source];
  if (!impl) return Promise.reject(new Error('不支持的平台: ' + source));
  return impl(keyword, page);
}

function __lxSearchBridge(source, keyword, page, onOk, onErr) {
  __lxSearch(source, keyword, page).then(function (r) {
    onOk(JSON.stringify(r));
  }, function (e) {
    onErr(String((e && e.message) || e));
  });
}

// ===== 内置歌词（洛雪平台源本身不提供歌词，这里按平台补上，返回 LRC 文本） =====

function __lxLrcTime(sec) {
  var t = Math.max(0, parseFloat(sec) || 0);
  var m = Math.floor(t / 60);
  var s = t - m * 60;
  return '[' + (m < 10 ? '0' : '') + m + ':' + (s < 10 ? '0' : '') + s.toFixed(2) + ']';
}
function __lxUnescape(s) {
  return String(s || '').replace(/&apos;/g, "'").replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#(\\d+);/g, function (_, n) { return String.fromCharCode(parseInt(n, 10)); }).replace(/&amp;/g, '&');
}

var __lxLyricImpl = {
  kw: async function (mi) {
    var res = await http.get('https://www.kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=' + encodeURIComponent(mi.songmid),
      { timeout: 20000, headers: { 'Referer': 'https://www.kuwo.cn', 'User-Agent': 'Mozilla/5.0' } });
    var list = (res.data && res.data.data && res.data.data.lrclist) || [];
    if (!list.length) return null;
    return list.map(function (l) { return __lxLrcTime(l.time) + (l.lineLyric || ''); }).join('\n');
  },
  wy: async function (mi) {
    var res = await http.get('https://music.163.com/api/song/lyric?id=' + encodeURIComponent(mi.songmid) + '&lv=1&tv=1',
      { timeout: 20000, headers: { 'Referer': 'https://music.163.com', 'User-Agent': 'Mozilla/5.0' } });
    var lrc = res.data && res.data.lrc && res.data.lrc.lyric;
    return lrc || null;
  },
  kg: async function (mi) {
    var kw = encodeURIComponent((mi.name || '') + '-' + (mi.singer || ''));
    var dur = Math.round((mi.interval || 0) * 1000);
    var sres = await http.get('https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&keyword=' + kw + '&duration=' + dur + '&hash=' + encodeURIComponent(mi.hash || ''),
      { timeout: 20000, headers: { 'User-Agent': 'Mozilla/5.0' } });
    var cand = sres.data && sres.data.candidates && sres.data.candidates[0];
    if (!cand) return null;
    var dres = await http.get('https://lyrics.kugou.com/download?ver=1&client=pc&id=' + cand.id + '&accesskey=' + cand.accesskey + '&fmt=lrc&charset=utf8',
      { timeout: 20000, headers: { 'User-Agent': 'Mozilla/5.0' } });
    var content = dres.data && dres.data.content;
    if (!content) return null;
    return lx.utils.buffer.bufToString(lx.utils.buffer.from(content, 'base64'), 'utf8');
  },
  tx: async function (mi) {
    var res = await http.get('https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=' + encodeURIComponent(mi.songmid) + '&format=json&nobase64=1&g_tk=5381',
      { timeout: 20000, headers: { 'Referer': 'https://y.qq.com', 'User-Agent': 'Mozilla/5.0' } });
    var lrc = res.data && res.data.lyric;
    return lrc ? __lxUnescape(lrc) : null;
  },
  mg: async function (mi) {
    var cid = mi.copyrightId || mi.songmid;
    var res = await http.get('https://app.c.nf.migu.cn/MIGUM2.0/v1.0/content/resourceinfo.do?copyrightId=' + encodeURIComponent(cid) + '&resourceType=2',
      { timeout: 20000, headers: { 'User-Agent': 'Mozilla/5.0' } });
    var r0 = res.data && res.data.resource && res.data.resource[0];
    if (!r0 || !r0.lrcUrl) return null;
    var lres = await http.get(r0.lrcUrl, { timeout: 20000, headers: { 'User-Agent': 'Mozilla/5.0' } });
    return (typeof lres.body === 'string' && lres.body) ? lres.body : null;
  }
};

function __lxLyricBridge(source, musicInfoJSON, onOk, onErr) {
  var impl = __lxLyricImpl[source];
  if (!impl) { onOk('null'); return; }
  var mi;
  try { mi = JSON.parse(musicInfoJSON); } catch (e) { onOk('null'); return; }
  impl(mi).then(function (lrc) {
    onOk(JSON.stringify(lrc || null));
  }, function () {
    onOk('null');
  });
}

"""#
