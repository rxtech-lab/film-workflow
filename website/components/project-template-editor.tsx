"use client";
import { useEffect, useState } from "react";
import type { ProjectTemplateDefinition } from "@/lib/marketplace/template";
const field = "w-full rounded-xl border border-line bg-elevated p-2 text-sm";
export const emptyTemplate: ProjectTemplateDefinition = { version: 1, prompt: "", videoStyle: "", editingGuidance: "", width: 1920, height: 1080, fps: 30, shots: [], footageRequirements: [], marketplaceItems: [] };
export function TemplateEditor({ text, onChange }: { text: string; onChange: (text: string) => void }) {
  let value = emptyTemplate;
  try { if (text) value = JSON.parse(text) as ProjectTemplateDefinition; } catch { /* Keep the form usable for a new draft. */ }
  const [query, setQuery] = useState("");
  const [items, setItems] = useState<{ id: string; title: string }[]>([]);
  useEffect(() => {
    const controller = new AbortController();
    const timer = setTimeout(() => { void fetch(`/api/v1/marketplace/items?catalog_version=2&q=${encodeURIComponent(query)}`, { signal: controller.signal }).then((r) => r.json()).then((r) => setItems(r.items?.filter((i: { kind: string }) => i.kind !== "project_template") ?? [])).catch(() => {}); }, 250);
    return () => { clearTimeout(timer); controller.abort(); };
  }, [query]);
  const update = (patch: Partial<ProjectTemplateDefinition>) => onChange(JSON.stringify({ ...value, ...patch }, null, 2));
  return <div className="col-span-2 space-y-4">
    <label className="block">Project prompt<textarea className={field} value={value.prompt} onChange={(e) => update({ prompt: e.target.value })} /></label>
    <label className="block">Video style<textarea className={field} value={value.videoStyle} onChange={(e) => update({ videoStyle: e.target.value })} /></label>
    <label className="block">Editing guidance<textarea className={field} value={value.editingGuidance} onChange={(e) => update({ editingGuidance: e.target.value })} /></label>
    <div className="flex gap-3">{(["width", "height", "fps"] as const).map((key) => <label key={key}>{key === "fps" ? "Frame rate" : key}<input type="number" className={field} value={value[key]} onChange={(e) => update({ [key]: Number(e.target.value) })} /></label>)}</div>
    <h3>Shots and footage instructions</h3>
    {value.shots.map((shot, index) => {
      const requirement = value.footageRequirements.find((r) => r.id === shot.footageRequirementId);
      const change = (patch: Partial<typeof shot>) => update({ shots: value.shots.map((s) => s.id === shot.id ? { ...s, ...patch } : s) });
      return <div key={shot.id} className="space-y-2 rounded-xl border border-line p-3">
        <div className="flex gap-2"><span>{index + 1}.</span><input aria-label="Shot title" className={field} value={shot.title} onChange={(e) => change({ title: e.target.value })} /><button type="button" onClick={() => update({ shots: value.shots.filter((s) => s.id !== shot.id), footageRequirements: value.footageRequirements.filter((r) => r.id !== shot.footageRequirementId || value.shots.some((s) => s.id !== shot.id && s.footageRequirementId === r.id)) })}>Remove</button></div>
        <div className="flex gap-2"><button type="button" disabled={index === 0} onClick={() => { const shots = [...value.shots]; [shots[index - 1], shots[index]] = [shots[index], shots[index - 1]]; update({ shots }); }}>Move up</button><button type="button" disabled={index === value.shots.length - 1} onClick={() => { const shots = [...value.shots]; [shots[index + 1], shots[index]] = [shots[index], shots[index + 1]]; update({ shots }); }}>Move down</button></div>
        <label>Shot direction<textarea className={field} value={shot.instructions} onChange={(e) => change({ instructions: e.target.value })} /></label>
        <label>Suggested seconds<input type="number" min="0.1" step="0.1" className={field} value={shot.durationSeconds} onChange={(e) => change({ durationSeconds: Number(e.target.value) })} /></label>
        <label>Marketplace footage or composition<select className={field} value={shot.marketplaceItemId ?? ""} onChange={(e) => change(e.target.value ? { marketplaceItemId: e.target.value, footageRequirementId: undefined } : { marketplaceItemId: undefined, footageRequirementId: value.footageRequirements.find((r) => r.id === shot.id)?.id })}><option value="">User-provided footage</option>{value.marketplaceItems.map((i) => <option key={i.itemId} value={i.itemId}>{i.purpose}</option>)}</select></label>
        <label>Transition to next shot<select className={field} value={shot.transition?.modifierId ?? ""} onChange={(e) => change({ transition: e.target.value ? { modifierId: e.target.value, parameters: {}, durationSeconds: 0.5 } : undefined })}><option value="">Cut</option><option value="rx.cross-dissolve">Cross dissolve</option><option value="rx.fade-color">Fade through color</option><option value="rx.directional-wipe">Directional wipe</option>{shot.transition && !shot.transition.modifierId.startsWith("rx.") ? <option value={shot.transition.modifierId}>{shot.transition.modifierId}</option> : null}</select></label>
        {shot.transition ? <label>Transition seconds<input className={field} type="number" min="0.01" max="10" step="0.1" value={shot.transition.durationSeconds ?? 0.5} onChange={(e) => change({ transition: { ...shot.transition!, durationSeconds: Number(e.target.value) } })} /></label> : null}
        <details><summary>Advanced shot effects and transition settings</summary><textarea className={field} key={shot.id + JSON.stringify(shot.effects) + JSON.stringify(shot.transition)} defaultValue={JSON.stringify({ effects: shot.effects, transition: shot.transition }, null, 2)} onBlur={(e) => { try { const settings = JSON.parse(e.target.value); change({ effects: settings.effects ?? [], transition: settings.transition }); e.target.setCustomValidity(""); } catch { e.target.setCustomValidity("Enter valid effect and transition settings."); e.target.reportValidity(); } }} /></details>
        {requirement ? <><label>Footage needed<textarea className={field} value={requirement.instructions} onChange={(e) => update({ footageRequirements: value.footageRequirements.map((r) => r.id === requirement.id ? { ...r, instructions: e.target.value, title: shot.title } : r) })} /></label><select aria-label="Media type" className={field} value={requirement.mediaType} onChange={(e) => update({ footageRequirements: value.footageRequirements.map((r) => r.id === requirement.id ? { ...r, mediaType: e.target.value as typeof r.mediaType } : r) })}><option value="video">Video</option><option value="image">Image</option><option value="audio">Audio</option></select><label><input type="checkbox" checked={requirement.required} onChange={(e) => update({ footageRequirements: value.footageRequirements.map((r) => r.id === requirement.id ? { ...r, required: e.target.checked } : r) })} /> Required</label></> : null}
      </div>;
    })}
    <button type="button" onClick={() => { const id = crypto.randomUUID(); update({ shots: [...value.shots, { id, title: `Shot ${value.shots.length + 1}`, instructions: "", durationSeconds: 5, footageRequirementId: id, effects: [] }], footageRequirements: [...value.footageRequirements, { id, title: `Shot ${value.shots.length + 1}`, mediaType: "video", required: true, instructions: "" }] }); }}>Add shot</button>
    <h3>Marketplace items</h3>
    {value.marketplaceItems.map((item) => <div key={item.itemId} className="flex gap-2"><input className={field} aria-label="How this item is used" value={item.purpose} onChange={(e) => update({ marketplaceItems: value.marketplaceItems.map((i) => i.itemId === item.itemId ? { ...i, purpose: e.target.value } : i) })} /><label><input type="checkbox" checked={item.required} onChange={(e) => update({ marketplaceItems: value.marketplaceItems.map((i) => i.itemId === item.itemId ? { ...i, required: e.target.checked } : i) })} />Required</label><button type="button" onClick={() => update({ marketplaceItems: value.marketplaceItems.filter((i) => i.itemId !== item.itemId) })}>Remove</button></div>)}
    <input className={field} placeholder="Search marketplace assets" value={query} onChange={(e) => setQuery(e.target.value)} />
    <select className={field} aria-label="Add marketplace item" value="" onChange={(e) => { const item = items.find((i) => i.id === e.target.value); if (item && !value.marketplaceItems.some((i) => i.itemId === item.id)) update({ marketplaceItems: [...value.marketplaceItems, { itemId: item.id, purpose: item.title, required: true }] }); }}><option value="">Add marketplace item…</option>{items.map((i) => <option key={i.id} value={i.id}>{i.title}</option>)}</select>
  </div>;
}
