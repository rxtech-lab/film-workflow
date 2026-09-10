import React, {useEffect, useRef, useState} from 'react';
import {createRoot} from 'react-dom/client';
import {Player, PlayerRef} from '@remotion/player';
import {MyComposition, COMPOSITION_FPS, COMPOSITION_DURATION_IN_FRAMES, COMPOSITION_WIDTH, COMPOSITION_HEIGHT} from 'rx-composition';

// This page belongs to the app. Each web view owns a Player; compiled code is shared.
type Command = {serial: number; frame: number; playing: boolean; rate: number; volume: number; muted: boolean};
declare global {
  interface Window {
    rxPreviewCommand?: (command: Command) => void;
    rxPendingCommand?: Command;
    rxEmit: (type: string, detail?: Record<string, unknown>) => void;
  }
}

const params = new URLSearchParams(location.search);
const width = Number(params.get('width')) || COMPOSITION_WIDTH;
const height = Number(params.get('height')) || COMPOSITION_HEIGHT;
const emit = window.rxEmit;

function Preview() {
  const ref = useRef<PlayerRef>(null);
  const [rate, setRate] = useState(1);
  const command = useRef<Command | undefined>(undefined);
  const lastSerial = useRef(-1);

  useEffect(() => {
    const player = ref.current!;
    const apply = (next: Command) => {
      if (!Number.isFinite(next.frame) || next.serial < lastSerial.current) return;
      lastSerial.current = next.serial;
      if (!(next.rate > 0 && next.rate <= 10) || !(next.volume >= 0 && next.volume <= 1)) {
        player.pause();
        emit('limitation', {message: 'This speed or volume needs a rendered preview.'});
        return;
      }
      const previous = command.current;
      command.current = next;
      setRate(next.rate);
      const frame = Math.max(0, Math.min(COMPOSITION_DURATION_IN_FRAMES - 1, Math.floor(next.frame)));
      const drift = Math.abs(player.getCurrentFrame() - frame);
      if (!previous || !next.playing || previous.playing !== next.playing || previous.rate !== next.rate || drift > 2) {
        if (drift !== 0) player.seekTo(frame);
      }
      player.setVolume(next.volume);
      next.muted ? player.mute() : player.unmute();
      if (next.playing && !player.isPlaying()) player.play();
      if (!next.playing && player.isPlaying()) player.pause();
    };
    window.rxPreviewCommand = apply;
    const events = {
      waiting: () => emit('buffering', {value: true}),
      resume: () => emit('buffering', {value: false}),
      ended: () => emit('ended'),
      error: (event: {detail: {error: Error}}) => emit('error', {message: event.detail.error.message}),
    };
    for (const [name, listener] of Object.entries(events)) player.addEventListener(name as any, listener as any);
    emit('ready', {fps: COMPOSITION_FPS, frames: COMPOSITION_DURATION_IN_FRAMES, width, height});
    if (window.rxPendingCommand) apply(window.rxPendingCommand);
    return () => {
      player.pause();
      delete window.rxPreviewCommand;
      for (const [name, listener] of Object.entries(events)) player.removeEventListener(name as any, listener as any);
    };
  }, []);

  return <Player ref={ref} component={MyComposition} fps={COMPOSITION_FPS}
    durationInFrames={COMPOSITION_DURATION_IN_FRAMES} compositionWidth={width} compositionHeight={height}
    playbackRate={rate} controls={false} clickToPlay={false} spaceKeyToPlayOrPause={false}
    doubleClickToFullscreen={false} moveToBeginningWhenEnded={false} initialVolume={1}
    style={{width: '100%', height: '100%', background: 'transparent'}}
    errorFallback={({error}) => { queueMicrotask(() => emit('error', {message: error.message})); return null; }}/>
}

// Decoder errors are playback limitations. Syntax/component errors remain real errors.
document.addEventListener('error', (event) => {
  const target = event.target;
  if (target instanceof HTMLMediaElement && target.error) {
    emit('limitation', {message: target.error.message || 'This media needs a rendered preview.'});
  }
}, true);
window.addEventListener('unhandledrejection', (event) => emit('error', {message: String(event.reason)}));
createRoot(document.getElementById('root')!).render(<Preview/>);
