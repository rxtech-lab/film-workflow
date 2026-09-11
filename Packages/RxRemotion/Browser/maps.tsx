import React,{useEffect,useRef,useState} from 'react';
import {flushSync} from 'react-dom';
import {useDelayRender} from 'remotion';
import L from 'leaflet';

export type Coordinate={latitude:number;longitude:number};
export type MapMarker={coordinate:Coordinate;color?:string;label?:string};
export type MapRoute={coordinates:Coordinate[];color?:string;width?:number};
export type MapProps={center:Coordinate;zoom:number;width:number;height:number;markers?:MapMarker[];
  routes?:MapRoute[];style?:React.CSSProperties;className?:string};
const w=window as any;
function failure(error:any){w.rxError=String(error.message||error);w.rxEmit('error',{message:w.rxError})}

export type MapKitProps=MapProps & {mapStyle?:'standard'|'muted'|'satellite'|'hybrid';
  onSnapshot?:(projection:{markerPoints:[number,number][];routePoints:[number,number][][]})=>void};
export function MapKitMap({center,zoom,width,height,markers=[],routes=[],style,className,mapStyle='standard',onSnapshot}:MapKitProps){
  const [image,setImage]=useState<string>();
  const {delayRender,continueRender}=useDelayRender();
  const request=JSON.stringify({center,zoom,width,height,markers,routes,mapStyle});
  useEffect(()=>{
    const handle=delayRender('MapKit snapshot');const abort=new AbortController();let url:string|undefined;
    fetch(w.rxBase+'native/map'+(onSnapshot?'?projection=1':''),{method:'POST',body:request,signal:abort.signal}).then(async response=>{
      if(!response.ok)throw new Error((await response.json()).error||'MapKit failed');
      if(onSnapshot){const result=await response.json();onSnapshot({markerPoints:result.markerPoints,routePoints:result.routePoints});url='data:image/png;base64,'+result.png}
      else url=URL.createObjectURL(await response.blob());const img=new Image();img.src=url;await img.decode();
      if(!abort.signal.aborted)flushSync(()=>setImage(url));continueRender(handle);
    }).catch(error=>{if(!abort.signal.aborted)failure(error);continueRender(handle)});
    return()=>{abort.abort();continueRender(handle);if(url)URL.revokeObjectURL(url)};
  },[request]);
  return <img src={image} width={width} height={height} style={style} className={className}/>;
}

export function OpenStreetMap({center,zoom,width,height,markers=[],routes=[],style,className}:MapProps){
  const host=useRef<HTMLDivElement>(null);const map=useRef<L.Map|null>(null);
  const {delayRender,continueRender}=useDelayRender();
  const request=JSON.stringify({center,zoom,width,height,markers,routes});
  useEffect(()=>{
    const provider=w.rxConfig.openStreetMap;
    if(!provider){failure(new Error('Configure an OpenStreetMap tile provider in app settings.'));return}
    if(w.rxMode==='render'&&!provider.allowsExport){failure(new Error('This tile provider is not configured to permit movie exports.'));return}
    if(!document.getElementById('rx-leaflet-css')){
      const link=document.createElement('link');link.id='rx-leaflet-css';link.rel='stylesheet';link.href=w.rxBase+'web/leaflet/leaflet.css';document.head.append(link);
    }
    const m=L.map(host.current!,{zoomControl:false,attributionControl:true,zoomAnimation:false,fadeAnimation:false,
      markerZoomAnimation:false,dragging:false,scrollWheelZoom:false,doubleClickZoom:false,keyboard:false,
      boxZoom:false,touchZoom:false,zoomSnap:0});map.current=m;
    return()=>{m.remove();map.current=null};
  },[]);
  useEffect(()=>{
    const m=map.current;if(!m)return;
    const provider=w.rxConfig.openStreetMap;
    const handle=delayRender('OpenStreetMap tiles');let complete=false;
    const done=()=>{if(!complete){complete=true;continueRender(handle)}};
    m.eachLayer(layer=>m.removeLayer(layer));m.invalidateSize({animate:false});
    m.setView([center.latitude,center.longitude],zoom,{animate:false});
    const tile=L.tileLayer(w.rxBase+'native/tile/{z}/{x}/{y}',{attribution:provider.attribution,
      minZoom:provider.minimumZoom,maxZoom:provider.maximumZoom,crossOrigin:true});
    tile.on('load',done);tile.on('tileerror',()=>{failure(new Error('An OpenStreetMap tile failed to load.'));done()});tile.addTo(m);
    for(const marker of markers){const pin=L.circleMarker([marker.coordinate.latitude,marker.coordinate.longitude],
      {radius:7,color:'#fff',weight:2,fillColor:marker.color||'#e84b3c',fillOpacity:1}).addTo(m);
      if(marker.label){const label=document.createElement('span');label.textContent=marker.label;pin.bindTooltip(label,{permanent:true,direction:'right'})}
    }
    for(const route of routes)L.polyline(route.coordinates.map(c=>[c.latitude,c.longitude]),
      {color:route.color||'#2676e8',weight:route.width||4}).addTo(m);
    if(!tile.isLoading())done();
    return()=>{tile.off();done()};
  },[request]);
  return <div ref={host} className={className} style={{isolation:'isolate',background:'#ddd',...style,width,height}}/>;
}
