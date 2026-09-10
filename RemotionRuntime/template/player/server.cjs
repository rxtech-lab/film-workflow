// A loopback-only, per-project compiler/server. No files are generated in the film.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const {BundlerInternals, webpack} = require('@remotion/bundler');

async function main() {
  const [project, cache] = process.argv.slice(2);
  if (!project || !cache) throw new Error('Expected project and cache directories');
  const token = crypto.randomBytes(24).toString('hex');
  const prefix = '/' + token;
  fs.mkdirSync(cache, {recursive: true});
  const publicRoot = path.join(project, 'public');
  const listeners = new Set();
  let status = {type: 'building'};
  const broadcast = (message) => {
    status = message;
    if (message.type === 'compiled') console.log('RX_PREVIEW_CHANGED');
    for (const res of listeners) res.write(`data: ${JSON.stringify(message)}\n\n`);
  };
  const html = `<!doctype html><html><head><meta charset="utf-8"><style>html,body,#root{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}*{user-select:none}</style></head><body><div id="root"></div><script>
    window.remotion_staticBase=${JSON.stringify(prefix + '/public')};
    window.rxEmit=(type,detail={})=>window.webkit?.messageHandlers?.rxPreview?.postMessage({type,...detail});
    let loaded=false;
    const events=new EventSource(${JSON.stringify(prefix + '/events')});
    events.onmessage=e=>{const state=JSON.parse(e.data);if(state.type==='compiled'){
      if(loaded){location.reload();return} loaded=true;
      const script=document.createElement('script');script.src=${JSON.stringify(prefix + '/player.js')};document.body.appendChild(script);
    }else{window.rxEmit(state.type,state)}};
    events.onerror=()=>window.rxEmit('error',{message:'The preview server disconnected. Retry the preview.'});
    window.addEventListener('error',e=>{if(e.message)window.rxEmit('error',{message:e.message})});
  </script></body></html>`;

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    if (!url.pathname.startsWith(prefix + '/')) { res.writeHead(404).end(); return; }
    let relative;
    try { relative = decodeURIComponent(url.pathname.slice(prefix.length + 1)); }
    catch { res.writeHead(400).end(); return; }
    if (relative === 'events') {
      res.writeHead(200, {'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive'});
      listeners.add(res); res.write(`data: ${JSON.stringify(status)}\n\n`);
      req.on('close', () => listeners.delete(res)); return;
    }
    if (relative === '') { res.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'}).end(html); return; }
    if (relative === 'status') { res.writeHead(200, {'Content-Type': 'application/json'}).end(JSON.stringify(status)); return; }
    try {
      const root = relative.startsWith('public/') ? publicRoot : cache;
      const file = fs.realpathSync(path.resolve(root, relative.startsWith('public/') ? relative.slice(7) : relative));
      const realRoot = fs.realpathSync(root);
      if (!file.startsWith(realRoot + path.sep) || !fs.statSync(file).isFile()) { res.writeHead(403).end(); return; }
      const size = fs.statSync(file).size;
      const types = {'.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.webp':'image/webp','.mp4':'video/mp4','.mov':'video/quicktime','.mp3':'audio/mpeg','.wav':'audio/wav','.m4a':'audio/mp4','.woff2':'font/woff2','.json':'application/json'};
      const headers = {'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control':'no-store', 'Accept-Ranges':'bytes'};
      const match = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
      let start = 0, end = size - 1;
      if (match) {
        start = match[1] ? Number(match[1]) : Math.max(0, size - Number(match[2]));
        end = match[1] && match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
        if (start > end || start >= size) { res.writeHead(416, {'Content-Range':`bytes */${size}`}).end(); return; }
        headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
      }
      headers['Content-Length'] = Math.max(0, end - start + 1);
      res.writeHead(match ? 206 : 200, headers);
      if (req.method === 'HEAD' || size === 0) { res.end(); return; }
      fs.createReadStream(file, {start, end}).on('error', () => res.destroy()).pipe(res);
    } catch { res.writeHead(404).end(); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  console.log('RX_PREVIEW_URL=http://127.0.0.1:' + server.address().port + prefix + '/');

  const host = path.join(__dirname, 'host.tsx');
  const [, config] = await BundlerInternals.webpackConfig({
    entry: host, userDefinedComponent: path.join(project, 'src/Composition.tsx'),
    outDir: cache, environment: 'production', enableCaching: false, remotionRoot: project,
    maxTimelineTracks: null, keyboardShortcutsEnabled: false, bufferStateDelayInMilliseconds: 0,
    poll: null, experimentalClientSideRenderingEnabled: false, experimentalVisualModeEnabled: false,
    askAIEnabled: false, extraPlugins: [],
    webpackOverride: current => ({...current, entry: [host], devtool: false,
      optimization: {...current.optimization, minimize: false},
      resolve: {...current.resolve, alias: {...current.resolve.alias, 'rx-composition': path.join(project, 'src/Composition.tsx')}},
      output: {...current.output, filename: 'player.js', publicPath: prefix + '/'}}),
  });
  const compiler = webpack(config);
  compiler.hooks.invalid.tap('RxPreview', () => broadcast({type: 'building'}));
  const watcher = compiler.watch({aggregateTimeout: 180}, (error, stats) => {
    if (error || stats.hasErrors()) {
      broadcast({type: 'error', message: error?.message || stats.toString({all:false, errors:true})});
    } else broadcast({type: 'compiled'});
  });
  let assetTimer;
  const assets = fs.existsSync(publicRoot) ? fs.watch(publicRoot, {recursive:true}, () => {
    clearTimeout(assetTimer); assetTimer = setTimeout(() => broadcast({type:'compiled'}), 180);
  }) : null;
  const close = () => { assets?.close(); watcher.close(() => server.close(() => process.exit(0))); for (const res of listeners) res.end(); };
  process.on('SIGTERM', close); process.on('SIGINT', close);
}
main().catch(error => { console.error(error); process.exit(1); });
