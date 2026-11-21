// 注入到每个插件 JSContext 里的运行时（JS 代码）。
// 提供：module/exports、console、setTimeout、fetch、http、axios(子集)、qs、utils、require()

let pluginRuntimeJS = #"""
var module = { exports: {} };
var exports = module.exports;
var global = this; var globalThis = this; var window = this;

var console = (function () {
  function fmt(args) {
    return Array.prototype.map.call(args, function (a) {
      if (typeof a === 'string') return a;
      try { return JSON.stringify(a); } catch (e) { return String(a); }
    }).join(' ');
  }
  var c = { log: function () { __log(fmt(arguments)); } };
  c.info = c.warn = c.error = c.debug = c.log;
  return c;
})();

function setTimeout(fn, ms) { __setTimeout(fn, ms || 0); return 0; }
function clearTimeout() {}

var qs = {
  stringify: function (obj) {
    if (!obj) return '';
    return Object.keys(obj).filter(function (k) { return obj[k] !== undefined && obj[k] !== null; })
      .map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(obj[k]); }).join('&');
  },
  parse: function (str) {
    var out = {};
    (str || '').replace(/^\?/, '').split('&').forEach(function (p) {
      if (!p) return;
      var i = p.indexOf('=');
      var k = decodeURIComponent(i < 0 ? p : p.slice(0, i));
      out[k] = i < 0 ? '' : decodeURIComponent(p.slice(i + 1).replace(/\+/g, ' '));
    });
    return out;
  }
};

function __findHeader(headers, name) {
  name = name.toLowerCase();
  for (var k in headers) if (k.toLowerCase() === name) return headers[k];
  return undefined;
}

// 统一的底层请求：返回 Promise<{status, headers, body, data}>
function __httpRequest(opts) {
  if (typeof opts === 'string') opts = { url: opts };
  opts = opts || {};
  var url = opts.url || '';
  var params = opts.params;
  if (params && typeof params === 'object') {
    var q = qs.stringify(params);
    if (q) url += (url.indexOf('?') >= 0 ? '&' : '?') + q;
  }
  var headers = {};
  var srcHeaders = opts.headers || {};
  for (var k in srcHeaders) headers[k] = String(srcHeaders[k]);
  var body = opts.body !== undefined ? opts.body : opts.data;
  if (body !== undefined && body !== null && typeof body !== 'string') {
    var ct = __findHeader(headers, 'content-type') || '';
    if (ct.indexOf('x-www-form-urlencoded') >= 0) {
      body = qs.stringify(body);
    } else {
      body = JSON.stringify(body);
      if (!ct) headers['Content-Type'] = 'application/json';
    }
  }
  var payload = {
    url: url,
    method: (opts.method || 'GET').toUpperCase(),
    headers: headers,
    body: body === undefined || body === null ? null : String(body),
    timeout: opts.timeout ? opts.timeout / 1000 : 20
  };
  return new Promise(function (resolve, reject) {
    __request(JSON.stringify(payload), function (err, resJSON) {
      if (err) { reject(new Error(err)); return; }
      var res = JSON.parse(resJSON);
      var data = res.body;
      try { data = JSON.parse(res.body); } catch (e) {}
      res.data = data;
      resolve(res);
    });
  });
}

var http = {
  request: __httpRequest,
  get: function (url, opts) { opts = opts || {}; opts.url = url; opts.method = 'GET'; return __httpRequest(opts); },
  post: function (url, body, opts) { opts = opts || {}; opts.url = url; opts.method = 'POST'; opts.body = body; return __httpRequest(opts); }
};

function fetch(url, opts) {
  opts = opts || {};
  opts.url = url;
  return __httpRequest(opts).then(function (res) {
    return {
      status: res.status, ok: res.status >= 200 && res.status < 300, headers: res.headers,
      text: function () { return Promise.resolve(res.body); },
      json: function () { return Promise.resolve(JSON.parse(res.body)); }
    };
  });
}

// axios 子集（兼容 MusicFree 风格插件里常见的用法）
var axios = (function () {
  function wrap(p, config) {
    return p.then(function (res) {
      return { status: res.status, statusText: '', headers: res.headers, data: res.data, config: config };
    });
  }
  function axios(config, cfg2) {
    if (typeof config === 'string') { cfg2 = cfg2 || {}; cfg2.url = config; config = cfg2; }
    return wrap(__httpRequest(config), config);
  }
  axios.request = axios;
  ['get', 'delete', 'head'].forEach(function (m) {
    axios[m] = function (url, config) { config = config || {}; config.url = url; config.method = m; return axios(config); };
  });
  ['post', 'put', 'patch'].forEach(function (m) {
    axios[m] = function (url, data, config) { config = config || {}; config.url = url; config.method = m; config.data = data; return axios(config); };
  });
  axios.create = function () { return axios; };
  axios.default = axios;
  axios.defaults = { headers: { common: {} } };
  return axios;
})();

var utils = {
  md5: function (s) { return __hash('md5', String(s)); },
  sha1: function (s) { return __hash('sha1', String(s)); },
  sha256: function (s) { return __hash('sha256', String(s)); },
  base64Encode: function (s) { return __b64encode(String(s)); },
  base64Decode: function (s) { return __b64decode(String(s)); }
};
function btoa(s) { return __b64encode(String(s)); }
function atob(s) { return __b64decode(String(s)); }

// 极简 crypto-js 兼容层：只支持 MD5/SHA1/SHA256().toString() 和 Base64/Utf8 编解码
var __CryptoJS = (function () {
  function hashObj(algo) { return function (s) { var h = __hash(algo, String(s)); return { toString: function () { return h; } }; }; }
  function W(str) { this.__s = str; } W.prototype.toString = function (enc) { return enc && enc.__b64 ? __b64encode(this.__s) : this.__s; };
  return {
    MD5: hashObj('md5'), SHA1: hashObj('sha1'), SHA256: hashObj('sha256'),
    enc: {
      Utf8: { parse: function (s) { return new W(String(s)); }, stringify: function (w) { return w.__s; } },
      Base64: { __b64: true, parse: function (s) { return new W(__b64decode(String(s))); }, stringify: function (w) { return __b64encode(w.__s); } }
    }
  };
})();

function require(name) {
  switch (name) {
    case 'axios': return axios;
    case 'qs': return qs;
    case 'crypto-js': return __CryptoJS;
    default: throw new Error('音乐盒暂不支持模块: ' + name);
  }
}

// Swift 调用插件方法的统一入口
function __invoke(method, argsJSON, onOk, onErr) {
  try {
    var target = module.exports && module.exports.default ? module.exports.default : module.exports;
    var fn = target[method];
    if (typeof fn !== 'function') { onErr('插件没有实现 ' + method); return; }
    var args = JSON.parse(argsJSON);
    Promise.resolve(fn.apply(target, args)).then(function (r) {
      onOk(JSON.stringify(r === undefined ? null : r));
    }, function (e) {
      onErr(String((e && e.message) || e));
    });
  } catch (e) {
    onErr(String((e && e.message) || e));
  }
}

function __info() {
  var t = module.exports && module.exports.default ? module.exports.default : module.exports;
  return JSON.stringify({
    name: t.platform || t.name || '',
    version: t.version ? String(t.version) : '',
    author: t.author ? String(t.author) : '',
    srcUrl: t.srcUrl || '',
    hasSearch: typeof t.search === 'function',
    hasLyric: typeof t.getLyric === 'function'
  });
}
"""#
