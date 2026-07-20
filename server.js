#!/usr/bin/env node
// High-throughput HTTP file server for Vision Pro transfers over the USB4 bridge.
//
// Usage:   TOKEN=abc123 node server.js [shareDir] [port]
// Serves:  GET  /<token>/           -> directory listing
//          GET  /<token>/<file>     -> download (Range/resume supported)
//          PUT  /<token>/<file>     -> upload from the Vision Pro (e.g. a-shell curl -T)
//
// The token path segment keeps random devices on a shared LAN (hotel WiFi
// bridged into the same subnet) from browsing the share.

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');

const SHARE = path.resolve(process.argv[2] || path.join(__dirname, 'share'));
const PORT = Number(process.argv[3] || 8080);
const TOKEN = process.env.TOKEN || crypto.randomBytes(3).toString('hex');
const CHUNK = 8 * 1024 * 1024; // 8 MiB reads keep syscall count low at 10+ Gbps

fs.mkdirSync(SHARE, { recursive: true });

const fmtBytes = (n) => {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return n.toFixed(i ? 2 : 0) + ' ' + u[i];
};

const logXfer = (verb, name, bytes, t0, ok) => {
  const secs = Number(process.hrtime.bigint() - t0) / 1e9;
  const gbps = (bytes * 8 / 1e9 / secs).toFixed(2);
  console.log(`[${new Date().toISOString()}] ${verb} ${name}: ${fmtBytes(bytes)} in ${secs.toFixed(1)}s = ${gbps} Gbps ${ok ? '' : '(aborted)'}`);
};

const server = http.createServer((req, res) => {
  const parts = req.url.split('?')[0].split('/').filter(Boolean).map(decodeURIComponent);
  if (parts.shift() !== TOKEN) {
    res.writeHead(404);
    return res.end('not found\n');
  }
  const abs = path.join(SHARE, ...parts);
  if (!abs.startsWith(SHARE)) {
    res.writeHead(403);
    return res.end();
  }
  const name = parts.join('/') || '/';

  if (req.method === 'PUT') {
    const t0 = process.hrtime.bigint();
    let recvd = 0;
    req.on('data', (c) => { recvd += c.length; });
    const ws = fs.createWriteStream(abs, { highWaterMark: CHUNK });
    req.pipe(ws);
    ws.on('finish', () => {
      logXfer('PUT', name, recvd, t0, true);
      res.writeHead(201);
      res.end('ok\n');
    });
    req.on('aborted', () => logXfer('PUT', name, recvd, t0, false));
    ws.on('error', (e) => { res.writeHead(500); res.end(e.message + '\n'); });
    return;
  }

  let st;
  try { st = fs.statSync(abs); } catch { res.writeHead(404); return res.end('not found\n'); }

  if (st.isDirectory()) {
    const rows = fs.readdirSync(abs)
      .filter((f) => !f.startsWith('.'))
      .map((f) => {
        const s = fs.statSync(path.join(abs, f));
        const href = `/${TOKEN}/${parts.concat(f).map(encodeURIComponent).join('/')}`;
        return `<li style="margin:8px 0"><a href="${href}">${f}</a> — ${fmtBytes(s.size)}</li>`;
      }).join('\n');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(`<html><body style="font: 28px -apple-system, sans-serif; padding: 40px"><h2>vision-transfer</h2><ul>${rows}</ul></body></html>`);
  }

  let start = 0, end = st.size - 1, code = 200;
  const headers = {
    'Content-Type': 'application/octet-stream',
    'Accept-Ranges': 'bytes',
    'Content-Disposition': `attachment; filename="${path.basename(abs)}"`,
  };
  const m = /bytes=(\d*)-(\d*)/.exec(req.headers.range || '');
  if (m && (m[1] || m[2])) {
    if (m[1]) { start = Number(m[1]); if (m[2]) end = Number(m[2]); }
    else { start = st.size - Number(m[2]); }
    code = 206;
    headers['Content-Range'] = `bytes ${start}-${end}/${st.size}`;
  }
  headers['Content-Length'] = end - start + 1;
  res.writeHead(code, headers);
  if (req.method === 'HEAD') return res.end();

  const t0 = process.hrtime.bigint();
  let sent = 0;
  const stream = fs.createReadStream(abs, { start, end, highWaterMark: CHUNK });
  stream.on('data', (c) => { sent += c.length; });
  stream.pipe(res);
  res.on('close', () => {
    stream.destroy();
    logXfer(`GET${code === 206 ? '(range)' : ''}`, name, sent, t0, sent === end - start + 1);
  });
});

// A 25 GB PUT at low speed would trip Node's default 5-minute request timeout.
server.requestTimeout = 0;
server.timeout = 0;

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Sharing ${SHARE}`);
  for (const [ifname, addrs] of Object.entries(os.networkInterfaces())) {
    for (const a of addrs || []) {
      if (a.family === 'IPv4' && !a.internal) {
        console.log(`  http://${a.address}:${PORT}/${TOKEN}/   (${ifname})`);
      }
    }
  }
});
