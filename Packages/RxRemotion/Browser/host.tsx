import React, {useContext,useEffect,useRef,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {flushSync} from 'react-dom';
import {Internals} from 'remotion';
import {Player} from '@remotion/player';
import {injectCSS,makeDefaultPreviewCSS} from './node_modules/remotion/dist/cjs/default-css.js';

// The only adapter to the pinned Remotion 4.0.459 internals.
const w = window as any;
const tick = () => new Promise(resolve=>{const channel=new MessageChannel();channel.port1.onmessage=()=>{channel.port1.close();channel.port2.close();resolve(undefined)};channel.port2.postMessage(0)});
const roots = new Map<string, ReturnType<typeof createRoot>>();
function root(id:string) {
  if(!roots.has(id)) roots.set(id,createRoot(document.getElementById(id)!));
  return roots.get(id)!;
}
const contexts = (children:React.ReactNode) => <Internals.RemotionRootContexts
  numberOfAudioTags={0} logLevel="error" audioLatencyHint="playback" videoEnabled audioEnabled frameState={null} visualModeEnabled={false}>
  {children}</Internals.RemotionRootContexts>;

class Errors extends React.Component<{children:React.ReactNode},{failed:boolean}> {
  state={failed:false};
  static getDerivedStateFromError(){return {failed:true}}
  componentDidCatch(error:Error){w.rxError=error.message;w.rxEmit('error',{message:error.message})}
  render(){return this.state.failed?null:this.props.children}
}

export async function start(config:any) {
  injectCSS(makeDefaultPreviewCSS(null,'transparent'));
  await import(/* @vite-ignore */ config.base+'compiled/entry.js');
  const Root=Internals.getRoot();
  if(!Root) throw new Error('The project entrypoint must call registerRoot().');
  flushSync(()=>root('registry').render(<Errors>{contexts(<Internals.CompositionManagerProvider
    onlyRenderComposition={null} currentCompositionMetadata={null} initialCompositions={[]} initialCanvasContent={null}>
    <Root/></Internals.CompositionManagerProvider>)}</Errors>));
  await tick();await tick();
  const compositions=Internals.compositionsRef.current?.getCompositions() ?? [];
  if(!compositions.length) throw new Error(w.rxError || 'No compositions were registered.');
  const resolved=[];
  for(const c of compositions) {
    const props={...c.defaultProps,...config.inputProps};
    const metadata=c.calculateMetadata ? await c.calculateMetadata({defaultProps:c.defaultProps,props,
      abortSignal:new AbortController().signal,compositionId:c.id,isRendering:config.mode==='render'}) : {};
    resolved.push({...c,...metadata,props:metadata.props??props});
  }
  const publicMetadata=resolved.map(({id,width,height,fps,durationInFrames})=>({id,width,height,fps,durationInFrames}));
  w.rxCompositions=publicMetadata;
  if(config.mode==='discover') {w.rxEmit('discovered',{compositions:publicMetadata});return}
  const c=resolved.find(c=>c.id===config.compositionID);
  if(!c) throw new Error('Composition not found: '+config.compositionID);
  for(const key of ['width','height','fps']) if(config.settings?.[key]!=null)c[key]=config.settings[key];
  for(const key of ['width','height','fps','durationInFrames'])
    if(!(c[key]>0) || !Number.isFinite(c[key]))throw new Error('Invalid composition '+key);
  if(c.width>8192||c.height>8192||c.fps>240||!Number.isInteger(c.width)||!Number.isInteger(c.height)||!Number.isSafeInteger(c.durationInFrames))throw new Error('Unsupported composition size or timing');
  const metadata={id:c.id,width:c.width,height:c.height,fps:c.fps,durationInFrames:c.durationInFrames};
  if(config.mode==='render'&&w.webkit?.messageHandlers?.rxRemotion){
    w.rxEmit('viewport',metadata);
    const deadline=(w.rxRealNow||performance.now.bind(performance))()+config.timeout*1000;
    while(window.innerWidth!==c.width||window.innerHeight!==c.height){
      if((w.rxRealNow||performance.now.bind(performance))()>deadline)throw new Error('Native viewport did not reach the composition dimensions');
      await tick();
    }
  }
  flushSync(()=>root('registry').render(null));
  if(config.mode==='render') {
    const portal=Internals.portalNode(); document.getElementById('stage')!.append(portal);
    // Render directly under the same providers as Composition's portal.
    flushSync(()=>root('registry').render(<Errors>{contexts(<Internals.CompositionManagerProvider
      onlyRenderComposition={c.id} currentCompositionMetadata={metadata} initialCompositions={[]}
      initialCanvasContent={{type:'composition',compositionId:c.id}}>
      <Internals.ResolveCompositionContext.Provider value={{[c.id]:{type:'success',result:c}}}>
        <Internals.RenderAssetManagerProvider><Root/></Internals.RenderAssetManagerProvider>
      </Internals.ResolveCompositionContext.Provider>
    </Internals.CompositionManagerProvider>)}</Errors>));
    const renderFrame=async(frame:number)=>{
      w.rxRestoreCapture?.();
      flushSync(()=>w.remotion_setFrame(frame,c.id,1));
      const deadline=(w.rxRealNow||performance.now.bind(performance))()+config.timeout*1000;
      let stable=0;
      while(stable<2){
        await tick();w.rxPumpAnimations?.(frame,c.fps);
        if(w.rxError || w.remotion_cancelledError)throw new Error(w.rxError||String(w.remotion_cancelledError));
        if((w.rxRealNow||performance.now.bind(performance))()>deadline)throw new Error('Timed out waiting for frame '+frame+' resources');
        stable=w.remotion_delayRenderHandles.length===0?stable+1:0;
      }
      flushSync(()=>{});
      await tick();
      await Promise.all([...document.querySelectorAll('link[rel=stylesheet]')].map((link:any)=>link.sheet?Promise.resolve():new Promise((resolve,reject)=>{link.addEventListener('load',resolve,{once:true});link.addEventListener('error',()=>reject(new Error('Stylesheet failed: '+link.href)),{once:true})})));
      await document.fonts.ready;
      await Promise.all([...document.images].filter(image=>image.currentSrc||image.src).map(image=>image.decode().catch(()=>{throw new Error('Image failed: '+image.src)})));
      await w.rxPrepareCapture(frame,c.fps);
      return {frame,assets:(w.remotion_collectAssets?.()??[]).filter((a:any)=>a.type==='audio'||a.type==='video')};
    };
    w.rxRenderFrame=async(frame:number)=>{let timer:any;try{return await Promise.race([renderFrame(frame),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Frame resources timed out at frame '+frame)),config.timeout*1000)})])}finally{clearTimeout(timer)}};
    w.rxEmit('ready',{...metadata,frames:metadata.durationInFrames});
  } else {
    function Preview(){
      const ref=useRef<any>(null); const [rate,setRate]=useState(1); const last=useRef(-1);
      useEffect(()=>{
        const p=ref.current;
        w.rxPreviewCommand=(next:any)=>{
          if(next.serial<last.current)return;last.current=next.serial;
          if(!(next.rate>0&&next.rate<=10)||!(next.volume>=0&&next.volume<=1)){
            p.pause();w.rxEmit('limitation',{message:'This speed or volume requires a native rendered preview.'});return;
          }
          setRate(next.rate);
          const frame=Math.max(0,Math.min(c.durationInFrames-1,Math.floor(next.frame)));
          if(!next.playing||Math.abs(p.getCurrentFrame()-frame)>2)p.seekTo(frame);
          p.setVolume(next.volume);next.muted?p.mute():p.unmute();next.playing?p.play():p.pause();
        };
        const listeners={frameupdate:(e:any)=>w.rxEmit('frame',{frame:e.detail.frame}),waiting:()=>w.rxEmit('buffering',{value:true}),resume:()=>w.rxEmit('buffering',{value:false}),
          ended:()=>w.rxEmit('ended'),error:(e:any)=>w.rxEmit('error',{message:e.detail.error.message})};
        for(const [name,fn]of Object.entries(listeners))p.addEventListener(name,fn);
        w.rxEmit('ready',{...metadata,frames:metadata.durationInFrames});if(w.rxPendingCommand)w.rxPreviewCommand(w.rxPendingCommand);
        return ()=>{p.pause();for(const [name,fn]of Object.entries(listeners))p.removeEventListener(name,fn)};
      },[]);
      return <Player ref={ref} component={c.component} inputProps={c.props} fps={c.fps} durationInFrames={c.durationInFrames}
        compositionWidth={c.width} compositionHeight={c.height} playbackRate={rate} controls={false}
        clickToPlay={false} spaceKeyToPlayOrPause={false} doubleClickToFullscreen={false}
        moveToBeginningWhenEnded={false} style={{width:'100%',height:'100%',background:'transparent'}}
        errorFallback={({error}:any)=>{w.rxEmit('error',{message:error.message});return null}}/>;
    }
    flushSync(()=>root('stage').render(<Errors><Preview/></Errors>));
  }
}
