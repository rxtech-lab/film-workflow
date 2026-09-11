// All filesystem access is mediated by the scoped Swift resource server.
export async function compile(config) {
  const base = config.base;
  const catalog = await (await fetch(base + 'web/catalog.json')).json();
  const files = new Set(await (await fetch(base + 'files')).json());
  await new Promise((resolve,reject) => {
    const script = document.createElement('script'); script.src=base+'web/esbuild-browser.js';
    script.onload=resolve; script.onerror=reject; document.head.append(script);
  });
  await window.esbuild.initialize({wasmURL:base+'web/esbuild.wasm'});
  const normalize = value => {
    const result=[];
    for(const part of value.split('/')) {
      if(part==='..') {if(!result.length) throw new Error('Import escapes the project');result.pop()}
      else if(part && part!=='.') result.push(part);
    }
    return result.join('/');
  };
  const resolveFile = value => {
    for(const extension of ['', '.tsx','.ts','.jsx','.js','.mjs','.json','/index.tsx','/index.ts','/index.js']) {
      if(files.has(value+extension)) return value+extension;
    }
    throw new Error(`Cannot resolve local import: ${value}`);
  };
  const result = await window.esbuild.build({entryPoints:[config.entryPoint], bundle:true, write:false,
    format:'esm', platform:'browser', target:'safari26', jsx:'automatic', outdir:'/compiled',
    sourcemap:'inline', define:{'process.env.NODE_ENV':'"production"'},
    plugins:[{name:'swift-project',setup(build){
      build.onResolve({filter:/.*/},args=>{
        if(args.namespace==='vendor-css')return {path:new URL(args.path,args.importer).href,external:true};
        if(args.kind==='url-token'){
          if(/^(https?:|data:|#)/.test(args.path))return {path:args.path,external:true};
          const path=resolveFile(normalize(args.importer.split('/').slice(0,-1).join('/')+'/'+args.path));
          return {path:base+'source/'+path.split('/').map(encodeURIComponent).join('/'),external:true};
        }
        if(catalog[args.path]) {
          const url=base+'web/'+catalog[args.path];
          if(args.path.endsWith('.css')) return {path:url,namespace:'vendor-css'};
          return {path:url,external:true};
        }
        if(args.kind==='entry-point') return {path:resolveFile(normalize(args.path)),namespace:'project'};
        if(!args.path.startsWith('.')) throw new Error(`Unsupported import "${args.path}". Use a bundled library or a project-local browser module. Node APIs and npm installation are unavailable.`);
        return {path:resolveFile(normalize(args.importer.split('/').slice(0,-1).join('/')+'/'+args.path)),namespace:'project'};
      });
      build.onLoad({filter:/.*/,namespace:'vendor-css'},async args=>({contents:await (await fetch(args.path)).text(),loader:'css'}));
      build.onLoad({filter:/.*/,namespace:'project'},async args=>{
        const ext=args.path.split('.').pop();
        const loader={ts:'ts',tsx:'tsx',js:'js',jsx:'jsx',mjs:'js',json:'json',css:'css'}[ext];
        const url=base+'source/'+args.path.split('/').map(encodeURIComponent).join('/');
        if(!loader) return {contents:`export default ${JSON.stringify(url)}`,loader:'js'};
        const response=await fetch(url);if(!response.ok) throw new Error('Cannot read '+args.path);
        return {contents:await response.text(),loader};
      });
    }}]});
  for(const file of result.outputFiles) {
    const name=file.path.endsWith('.css')?'entry.css':'entry.js';
    const response=await fetch(base+'compiled/'+name,{method:'PUT',body:file.contents});
    if(!response.ok) throw new Error('Could not store compiled composition');
  }
  window.rxEmit('compiled');
}
