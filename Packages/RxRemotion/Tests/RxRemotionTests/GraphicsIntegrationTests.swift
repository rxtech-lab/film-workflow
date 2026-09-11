import AppKit
import AVFoundation
import Testing
@testable import RxRemotion

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_INTEGRATION"] == "1")) @MainActor
struct GraphicsIntegrationTests {
    func capture(_ source: String, name: String, frame: Int = 2, settings: RemotionRenderSettings = .init()) async throws -> NSBitmapImageRep {
        let helper = MediaIntegrationTests()
        let root = try helper.project(helper.constants + source)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: root)
        let output = URL(fileURLWithPath: "/tmp/rxremotion-\(name).png")
        try await engine.renderStill(project: project, frame: frame, to: output, settings: settings)
        return try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
    }
    @Test func canvasWebGLAndSVG() async throws {
        let image = try await capture("""
        import React,{useEffect,useRef} from 'react';import {AbsoluteFill,useCurrentFrame} from 'remotion';
        export function MyComposition(){const ref=useRef(null);const f=useCurrentFrame();useEffect(()=>{const gl=ref.current.getContext('webgl');gl.clearColor(0,1,0,1);gl.clear(gl.COLOR_BUFFER_BIT)},[f]);return <AbsoluteFill><canvas ref={ref} width={120} height={100}/><svg width={100} height={70}><circle cx={35} cy={35} r={30} fill='blue'/></svg></AbsoluteFill>}
        """, name: "webgl")
        #expect(try #require(image.colorAt(x: 30, y: 30)).greenComponent > 0.9)
    }
    @Test func particles() async throws {
        let image = try await capture("""
        import React,{useEffect,useState} from 'react';import Particles,{initParticlesEngine} from '@tsparticles/react';
        import {loadSlim} from '@tsparticles/slim';import {delayRender,continueRender} from 'remotion';
        export function MyComposition(){const [handle]=useState(()=>delayRender('particles'));const [ready,setReady]=useState(false);
        useEffect(()=>{initParticlesEngine(async engine=>{await loadSlim(engine)}).then(()=>setReady(true))},[]);
        return ready?<Particles particlesLoaded={async()=>continueRender(handle)} options={{fullScreen:{enable:false},background:{color:'#123456'},particles:{number:{value:20},color:{value:'#ffffff'},size:{value:5},move:{enable:true,speed:1}},detectRetina:false}} style={{width:320,height:180}}/>:null}
        """, name: "particles", frame: 5)
        let color = try #require(image.colorAt(x: 1, y: 1))
        #expect(color.alphaComponent > 0.9)
        var bright = 0
        for y in 0..<image.pixelsHigh { for x in 0..<image.pixelsWide {
            if (image.colorAt(x: x, y: y)?.redComponent ?? 0) > 0.8 { bright += 1 }
        } }
        #expect(bright > 100)
    }
    @Test func threeSceneExport() async throws {
        let helper = MediaIntegrationTests()
        let root = try helper.project(helper.constants + """
        import {Color, Mesh} from 'three';
        import {useThree} from '@react-three/fiber';
        import {Box} from '@react-three/drei';
        import {ThreeCanvas} from '@remotion/three';
        import {Sequence, useCurrentFrame, useVideoConfig} from 'remotion';
        function Scene(){
          const frame=useCurrentFrame();const {gl}=useThree();
          return <Box args={[1,1,1]} position={[frame<15?-1:1,0,0]} onAfterRender={function(){
            if(!(this instanceof Mesh))throw new Error('Three.js module identity mismatch');
            const context=gl.getContext(),pixel=new Uint8Array(4);
            context.readPixels(frame<15?100:220,90,1,1,context.RGBA,context.UNSIGNED_BYTE,pixel);
            gl.domElement.dataset.renderedFrame=String(frame);
            gl.domElement.dataset.green=String(pixel[1]);
          }}><meshBasicMaterial color={new Color('#00ff00')} toneMapped={false}/></Box>
        }
        export function MyComposition(){const {width,height}=useVideoConfig();return <ThreeCanvas
          width={width} height={height} dpr={1} orthographic camera={{position:[0,0,5],zoom:60}}
          gl={{alpha:true,antialias:false,preserveDrawingBuffer:true}}>
          <Sequence layout="none"><Scene/></Sequence>
        </ThreeCanvas>}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let project = try await engine.prepare(projectURL: root)
        for frame in [0, 15, 0] {
            let output = URL(fileURLWithPath: "/tmp/rxremotion-three-\(frame).png")
            try await engine.renderStill(project: project, frame: frame, to: output)
            let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
            let box = try #require(image.colorAt(x: frame < 15 ? 100 : 220, y: 90))
            #expect(box.greenComponent > 0.9); #expect(box.alphaComponent > 0.9)
            #expect(try #require(image.colorAt(x: frame < 15 ? 220 : 100, y: 90)).alphaComponent < 0.01)
        }
        let output = root.appendingPathComponent("three.mov")
        try await engine.renderMovie(project: project, to: output, settings: .init(codec: .proRes4444))
        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(frames); #expect(reader.startReading())
        var count = 0
        while let sample = frames.copyNextSampleBuffer() {
            let pixel = try #require(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            let bytes = try #require(CVPixelBufferGetBaseAddress(pixel)).assumingMemoryBound(to: UInt8.self)
            let row = 90 * CVPixelBufferGetBytesPerRow(pixel)
            let box = row + (count < 15 ? 100 : 220) * 4
            let clear = row + (count < 15 ? 220 : 100) * 4
            #expect(bytes[box + 1] > 230); #expect(bytes[box + 3] > 230)
            #expect(bytes[clear + 3] < 3)
            count += 1
        }
        #expect(reader.status == .completed); #expect(count == 30)
    }
    @Test func mapboxMissingTokenReportsError() async throws {
        do {
            _ = try await capture("""
            import {useEffect,useRef} from 'react';import mapboxgl from 'mapbox-gl';
            export function MyComposition(){const el=useRef(null);useEffect(()=>{const map=new mapboxgl.Map({container:el.current,style:{version:8,sources:{},layers:[{id:'background',type:'background',paint:{'background-color':'green'}}]}});return()=>map.remove()},[]);return <div ref={el} style={{width:320,height:180}}/>}
            """, name: "mapbox-invalid")
            Issue.record("Missing Mapbox token produced a blank success")
        } catch { #expect(error.localizedDescription.contains("access token")) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_MAPBOX_TOKEN"] != nil)) func mapbox() async throws {
        let image = try await capture("""
        import React,{useEffect,useRef,useState} from 'react';import mapboxgl from 'mapbox-gl';import {delayRender,continueRender,useCurrentFrame} from 'remotion';
        export function MyComposition(){const el=useRef(null);const [handle]=useState(()=>delayRender('mapbox'));const f=useCurrentFrame();
        useEffect(()=>{const map=new mapboxgl.Map({accessToken:\(String(data: try JSONEncoder().encode(ProcessInfo.processInfo.environment["RX_REMOTION_MAPBOX_TOKEN"] ?? ""), encoding: .utf8)!),container:el.current,style:{version:8,sources:{},layers:[{id:'background',type:'background',paint:{'background-color':'#22aa44'}}]},center:[0,0],zoom:1,interactive:false,attributionControl:false});map.on('load',()=>{map.triggerRepaint();continueRender(handle)});return()=>map.remove()},[]);
        return <div ref={el} style={{width:320,height:180}}/>}
        """, name: "mapbox")
        #expect(try #require(image.colorAt(x: 100, y: 80)).greenComponent > 0.5)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RX_REMOTION_MAPKIT"] == "1"))
    func mapKit() async throws {
        let image = try await capture("""
        import React from 'react';import {MapKitMap} from '@rxlab/remotion-maps';
        export function MyComposition(){return <MapKitMap center={{latitude:22.28,longitude:114.16}} zoom={12} width={320} height={180} markers={[{coordinate:{latitude:22.28,longitude:114.16},label:'Hong Kong'}]}/>}
        """, name: "mapkit", frame: 0)
        #expect(image.pixelsWide == 320)
        let engine = RemotionEngine(); defer { engine.closeAll() }
        let snapshot = try await engine.snapshotMapKit(.init(center: .init(latitude: 22.28, longitude: 114.16), zoom: 12,
            width: 320, height: 180, markers: [.init(coordinate: .init(latitude: 22.285, longitude: 114.16))]))
        #expect(snapshot.markerPoints.count == 1)
        #expect(snapshot.markerPoints[0].y < 90)
        #expect(try #require(image.colorAt(x: 160, y: 90)).alphaComponent > 0.9)
    }
    @Test func openStreetMap() async throws {
        URLProtocol.registerClass(FixtureTiles.self)
        defer { URLProtocol.unregisterClass(FixtureTiles.self) }
        let helper = MediaIntegrationTests()
        let root = try helper.project(helper.constants + """
        import React from 'react';import {OpenStreetMap} from '@rxlab/remotion-maps';
        export function MyComposition(){return <OpenStreetMap center={{latitude:0,longitude:0}} zoom={2} width={320} height={180} markers={[{coordinate:{latitude:0,longitude:0},label:'Center'}]}/>}
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RemotionEngine(configuration: .init(openStreetMap: .init(tileURL: "https://tiles.rxremotion.invalid/{z}/{x}/{y}.svg", attribution: "Fixture tiles · © OpenStreetMap contributors", allowsExport: true)))
        defer { engine.closeAll() }
        let prepared = try await engine.prepare(projectURL: root)
        let output = URL(fileURLWithPath: "/tmp/rxremotion-osm.png")
        try await engine.renderStill(project: prepared, frame: 0, to: output)
        let image = try #require(NSBitmapImageRep(data: Data(contentsOf: output)))
        #expect(try #require(image.colorAt(x: 30, y: 30)).greenComponent > 0.5)
    }
    @Test func unsupportedEffectsFail() async throws {
        do {
            _ = try await capture("export function MyComposition(){return <div style={{perspective:100}}>Unsupported</div>}", name: "unsupported")
            Issue.record("Unsupported snapshot effect was silently captured")
        } catch { #expect(error.localizedDescription.contains("Unsupported snapshot effect")) }
    }
    @Test func fourK() async throws {
        let image = try await capture("import React from 'react';import {AbsoluteFill} from 'remotion';export function MyComposition(){return <AbsoluteFill style={{background:'rgba(255,0,0,0.5)'}}/>}",
            name: "4k", frame: 0, settings: .init(width: 3840, height: 2160))
        #expect(image.pixelsWide == 3840); #expect(image.pixelsHigh == 2160)
        #expect(abs(try #require(image.colorAt(x: 100, y: 100)).alphaComponent - 0.5) < 0.03)
    }
}

private final class FixtureTiles: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "tiles.rxremotion.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // A deterministic tile fixture, served without contacting any map provider.
        let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='256' height='256'><rect width='256' height='256' fill='#22aa44'/></svg>"
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"image/svg+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(svg.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
