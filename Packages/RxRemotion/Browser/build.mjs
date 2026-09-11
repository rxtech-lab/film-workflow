// Maintainer-only resource build. Consumers of the Swift package never run this.
import {build} from 'esbuild';
import fs from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import crypto from 'node:crypto';
const directory = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const out = path.resolve(directory, '../Sources/RxRemotion/Resources/Web');
await fs.rm(out, {recursive:true,force:true});
await fs.mkdir(out, {recursive: true});
const packages = ['react','react/jsx-runtime','react/jsx-dev-runtime','react-dom','react-dom/client',
  'remotion','@remotion/player','mapbox-gl','react-map-gl/mapbox',
  '@tsparticles/react','@tsparticles/engine','@tsparticles/slim','leaflet',
  'three','@react-three/fiber','@react-three/drei','@remotion/three'];
const catalog = {};
const entryPoints = {host: './host.tsx', compiler: './compiler.js', maps: './maps.tsx'};
for (const [index, name] of packages.entries()) {
  const filename = `vendor-${index}`;
  catalog[name] = `${filename}.js`;
  entryPoints[filename] = `vendor:${name}`;
}
catalog['react-map-gl'] = catalog['react-map-gl/mapbox'];
catalog['@rxlab/remotion-maps'] = 'maps.js';
catalog['leaflet/dist/leaflet.css'] = 'leaflet/leaflet.css';
catalog['mapbox-gl/dist/mapbox-gl.css'] = 'mapbox-gl.css';
const nativeRemotion = {
  name: 'native-remotion', setup(builder) {
    builder.onResolve({filter: /^remotion$/}, () => ({path: path.join(directory, 'node_modules/remotion/dist/cjs/index.js')}));
    builder.onResolve({filter: /^vendor:/}, args => ({path: args.path.slice(7), namespace: 'vendor'}));
    builder.onLoad({filter: /.*/, namespace:'vendor'}, args => {
      // Use browser ESM exports directly so all 3D packages share the same
      // Three.js classes and Fiber context, without evaluating them in Node.
      if(['three','@react-three/fiber','@react-three/drei','@remotion/three'].includes(args.path))
        return {contents:`export * from ${JSON.stringify(args.path)};`,resolveDir:directory,loader:'js'};
      if(args.path==='leaflet')return {contents:`export * from 'leaflet/dist/leaflet-src.esm.js'; import * as L from 'leaflet/dist/leaflet-src.esm.js'; export default L;`,resolveDir:directory,loader:'js'};
      let names;
      try { names=Object.keys(require(args.path)).filter(n=>/^[a-zA-Z_$][\w$]*$/.test(n)&&n!=='default'&&n!=='__esModule'); }
      catch { return {contents:`export * from ${JSON.stringify(args.path)}; import * as M from ${JSON.stringify(args.path)}; export default M.default;`,resolveDir:directory,loader:'js'}; }
      if(args.path==='mapbox-gl')return {resolveDir:directory,loader:'js',contents:`
        import mapbox from 'mapbox-gl';
        const OriginalMap=mapbox.Map;
        export class Map extends OriginalMap {
          constructor(options){
            if(!document.getElementById('rx-mapbox-css')){const css=document.createElement('link');css.id='rx-mapbox-css';css.rel='stylesheet';css.href=window.rxBase+'web/mapbox-gl.css';document.head.append(css)}
            super({...options,preserveDrawingBuffer:window.rxMode==='render'||options.preserveDrawingBuffer});
            (window.rxMaps??=new Set()).add(this);this.on('remove',()=>window.rxMaps.delete(this));
            this.on('error',event=>{window.rxError='Mapbox: '+event.error.message;window.rxEmit('error',{message:window.rxError})});
          }
        }
        mapbox.Map=Map;export default mapbox;${names.filter(n=>n!=='Map').map(n=>`export const ${n}=mapbox.${n};`).join('')}
      `};
      const special=args.path==='remotion';
      if(special)names=names.filter(n=>n!=='Video'&&n!=='Html5Video');
      const contents=`import * as M from ${JSON.stringify(args.path)}; ${names.map(n=>`export const ${n}=M.${n};`).join('')} ${['@remotion/player','@tsparticles/engine','@tsparticles/slim'].includes(args.path)?'':'export default M.default;'} `+
        (special ? `import React from 'react'; export const Video = React.forwardRef((props,ref)=>M.getRemotionEnvironment().isRendering ? React.createElement(M.OffthreadVideo,props):React.createElement(M.Video,{...props,ref})); export const Html5Video=Video;` : '');
      return {contents,resolveDir:directory,loader:'js'};
    });
    builder.onLoad({filter: /AudioForRendering\.js$/}, async args => ({loader:'js', contents:
      (await fs.readFile(args.path,'utf8')).replace('"audio", { ref: audioRef,', '"audio", { "data-rx-remotion-audio": true, ref: audioRef,')
    }));
    builder.onLoad({filter: /offthread-video-source\.js$/}, () => ({loader:'js', contents:
      `exports.getOffthreadVideoSource = ({src,currentTime,transparent,toneMapped}) =>
        window.rxBase + 'native/video?src=' + encodeURIComponent(new URL(src,location.href).href) +
        '&time=' + encodeURIComponent(Math.max(0,currentTime)) + '&transparent=' + !!transparent;`
    }));
  }
};
await build({absWorkingDir:directory, entryPoints, bundle:true, splitting:true, format:'esm', platform:'browser',
  outdir:out, target:'safari26', minify:true, sourcemap:false, legalComments:'eof',
  define:{'process.env.NODE_ENV':'"production"'}, plugins:[nativeRemotion],
  loader:{'.png':'file','.svg':'file'}, chunkNames:'chunks/[name]-[hash]'});
await fs.copyFile(require.resolve('esbuild-wasm/esbuild.wasm'), path.join(out,'esbuild.wasm'));
await fs.copyFile(require.resolve('esbuild-wasm/lib/browser.min.js'), path.join(out,'esbuild-browser.js'));
await fs.mkdir(path.join(out,'leaflet'),{recursive:true});
await fs.copyFile(path.join(directory,'node_modules/leaflet/dist/leaflet.css'),path.join(out,'leaflet/leaflet.css'));
await fs.cp(path.join(directory,'node_modules/leaflet/dist/images'),path.join(out,'leaflet/images'),{recursive:true});
await fs.copyFile(require.resolve('mapbox-gl/dist/mapbox-gl.css'),path.join(out,'mapbox-gl.css'));
await fs.copyFile(path.join(directory,'capture.js'), path.join(out,'capture.js'));
await fs.writeFile(path.join(out,'catalog.json'),JSON.stringify(catalog,null,2));
const manifest = JSON.parse(await fs.readFile(path.join(directory,'package.json'),'utf8'));
const lock = await fs.readFile(path.join(directory,'package-lock.json'));
await fs.writeFile(path.join(out,'manifest.json'), JSON.stringify({engine:'1.0.0', dependencies:manifest.dependencies,
  lockHash:crypto.createHash('sha256').update(lock).digest('hex'),
  adapterHash:crypto.createHash('sha256').update((await Promise.all(['build.mjs','host.tsx','capture.js','compiler.js','maps.tsx'].map(file=>fs.readFile(path.join(directory,file))))).map(b=>b.toString()).join('')).digest('hex')},null,2));
await fs.copyFile(path.join(directory,'maps.tsx'),path.join(out,'maps-source.tsx'));
const notices = [];
async function licenses(root) {
  for (const item of await fs.readdir(root,{withFileTypes:true})) {
    if (item.name.startsWith('.')) continue;
    const file = path.join(root,item.name);
    if(item.isDirectory()) await licenses(file);
    else if(/^(licen[cs]e|notice|copying)(\.|$)/i.test(item.name)) {
      notices.push(`\n--- ${path.relative(directory,file)} ---\n${await fs.readFile(file,'utf8')}`);
    }
  }
}
await licenses(path.join(directory,'node_modules'));
await fs.writeFile(path.join(out,'THIRD-PARTY-NOTICES.txt'),notices.join('\n'));
console.log('Built standalone RxRemotion browser resources.');
