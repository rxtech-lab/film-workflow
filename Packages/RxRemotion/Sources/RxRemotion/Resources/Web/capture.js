// Loaded before project code, only in the isolated export WebView.
(() => {
  const w=window;
  const unsupported=new WeakSet();
  const transfer=HTMLCanvasElement.prototype.transferControlToOffscreen;
  if(transfer)HTMLCanvasElement.prototype.transferControlToOffscreen=function(){unsupported.add(this);return transfer.call(this)};
  const getContext=HTMLCanvasElement.prototype.getContext;
  HTMLCanvasElement.prototype.getContext=function(type,attributes){
    if(type==='webgpu')unsupported.add(this);
    if(type==='webgl'||type==='webgl2'||type==='experimental-webgl')attributes={...attributes,preserveDrawingBuffer:true};
    return getContext.call(this,type,attributes);
  };
  w.rxRealNow=performance.now.bind(performance);
  let virtualTime=0;
  Object.defineProperty(performance,'now',{value:()=>virtualTime});
  Date.now=()=>virtualTime;
  let seed=123456789;
  Math.random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed/4294967296};
  const callbacks=new Map();let serial=0;
  w.requestAnimationFrame=callback=>{callbacks.set(++serial,callback);return serial};
  w.cancelAnimationFrame=id=>callbacks.delete(id);
  w.rxPumpAnimations=(frame,fps)=>{
    virtualTime=frame/fps*1000;
    const pending=[...callbacks.values()];callbacks.clear();
    for(const callback of pending)callback(frame/fps*1000);
  };
  let replacements=[];
  w.rxRestoreCapture=()=>{for(const [original,image]of replacements)image.replaceWith(original);replacements=[]};
  const replace=async(element,src)=>{
    const image=new Image();
    for(const {name,value}of element.attributes)if(name!=='src')image.setAttribute(name,value);
    image.style.cssText=element.style.cssText;
    const style=getComputedStyle(element);
    image.style.width=style.width;image.style.height=style.height;
    image.src=src;await image.decode();element.replaceWith(image);replacements.push([element,image]);
  };
  w.rxPrepareCapture=async(frame,fps)=>{
    for(const animation of document.getAnimations()){animation.pause();animation.currentTime=frame/fps*1000}
    if(document.querySelector('#stage iframe,#stage audio:not([data-rx-remotion-audio])'))throw new Error('Iframe and raw HTML audio exports are unsupported. Use browser components and Remotion Audio.');
    const backgrounds=new Set();
    // A WK snapshot cannot faithfully capture these accelerated CSS effects.
    for(const element of document.getElementById('stage').querySelectorAll('*')){
      const style=getComputedStyle(element);
      for(const match of style.backgroundImage.matchAll(/url\(["']?(.*?)["']?\)/g))backgrounds.add(match[1]);
      const tileContainer=element.matches('img.leaflet-tile')?element.closest('.leaflet-container'):null;
      const opaqueTiles=tileContainer&&getComputedStyle(tileContainer).isolation==='isolate'&&/^rgb\(/.test(getComputedStyle(tileContainer).backgroundColor);
      if(style.mixBlendMode!=='normal'&&!opaqueTiles)throw new Error('CSS mix-blend-mode is not supported for transparent export');
      if(style.perspective!=='none'||(style.transform!=='none'&&!new DOMMatrix(style.transform).is2D)||style.backdropFilter!=='none')
        throw new Error('Unsupported snapshot effect: 3D perspective/transform or backdrop-filter. Use a 2D composition.');
    }
    await Promise.all([...backgrounds].map(async src=>{const image=new Image();image.src=src;try{await image.decode()}catch{throw new Error('Background image failed: '+src)}}));
    for(const map of w.rxMaps||[]){
      let rendered=false;map.once('render',()=>rendered=true);map.triggerRepaint();
      const deadline=w.rxRealNow()+30000;
      do{
        w.rxPumpAnimations(frame,fps);
        await new Promise(resolve=>{const ch=new MessageChannel();ch.port1.onmessage=()=>{ch.port1.close();ch.port2.close();resolve()};ch.port2.postMessage(0)});
        if(w.rxRealNow()>deadline)throw new Error('Mapbox tiles did not finish rendering');
              if(w.rxError)throw new Error(w.rxError);
      }while(!rendered||!map.loaded()||!map.areTilesLoaded());
    }
    for(const video of document.querySelectorAll('video')){
      if(!video.currentSrc)continue;
      const url=w.rxBase+'native/video?src='+encodeURIComponent(video.currentSrc)+'&time='+video.currentTime;
      await replace(video,url);
    }
    for(const canvas of document.querySelectorAll('canvas')){
      if(unsupported.has(canvas))throw new Error('WebGPU and worker-owned OffscreenCanvas exports are unsupported.');
      if(!canvas.width||!canvas.height)continue;
      try{await replace(canvas,canvas.toDataURL('image/png'))}
      catch{throw new Error('Canvas capture failed. Cross-origin textures must allow CORS; WebGPU capture is unsupported.')}
    }
  };
})();
