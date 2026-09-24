#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="${HOME}/.cros-debian-assistant/plugins"
PLUGIN_DIR="$PLUGIN_ROOT/kicad-assistant"
CACHE_DIR="${HOME}/.cros-debian-assistant/plugin-cache"
CACHE_FILE="$CACHE_DIR/kicad-assistant.json"
mkdir -p "$PLUGIN_DIR" "$CACHE_DIR"
cat > "$PLUGIN_DIR/plugin.json" <<'JSON'
{
  "id": "kicad-assistant",
  "name": "KiCad Assistant",
  "version": "1.0.0",
  "description": "Inspect KiCad projects, schematics, PCB statistics, and open project files.",
  "entry": "plugin.py",
  "panel": "build_panel"
}
JSON
cat > "$PLUGIN_DIR/plugin.py" <<'PY'
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from pathlib import Path
import json
import re
import shutil
import subprocess

CACHE_DIR=Path.home()/".cros-debian-assistant"/"plugin-cache"
CACHE_FILE=CACHE_DIR/"kicad-assistant.json"
STATE={"project":""}

def load():
    try:
        if CACHE_FILE.exists():
            d=json.loads(CACHE_FILE.read_text())
            if isinstance(d,dict): STATE.update(d)
    except Exception: pass
def save():
    try:
        CACHE_DIR.mkdir(parents=True,exist_ok=True)
        t=CACHE_FILE.with_suffix(".tmp"); t.write_text(json.dumps(STATE,indent=2)+"\n"); t.replace(CACHE_FILE)
    except Exception: pass
load()

def stats_sch(path):
    text=Path(path).read_text(errors="replace")
    return {
        "Symbols": len(re.findall(r'\(\s*symbol\s+"',text)),
        "Wires": len(re.findall(r'\(\s*wire\s*\(',text)),
        "Junctions": len(re.findall(r'\(\s*junction\s*\(',text)),
        "Hierarchical sheets": len(re.findall(r'\(\s*sheet\s*$',text,re.M)),
        "References": len(re.findall(r'\(\s*property\s+"Reference"\s+"[^"]+"',text)),
    }

def stats_pcb(path):
    text=Path(path).read_text(errors="replace")
    layers=set(re.findall(r'\(\s*layer\s+"([^"]+)"\s+(?:signal|power|user|.*?)[)]',text))
    return {
        "Footprints": len(re.findall(r'\(\s*footprint\s+"',text)),
        "Pads": len(re.findall(r'\(\s*pad\s+"',text)),
        "Tracks": len(re.findall(r'\(\s*(?:segment|gr_line|gr_arc)\b',text)),
        "Vias": len(re.findall(r'\(\s*via\s*\(',text)),
        "Zones": len(re.findall(r'\(\s*zone\s*\(',text)),
        "Nets": len(re.findall(r'\(\s*net\s+\d+\s+"',text)),
        "Layer mentions": len(layers),
    }

def build_panel(parent,gui):
    frame=ttk.Frame(parent); frame.pack(fill="both",expand=True,padx=10,pady=10)
    frame.columnconfigure(0,weight=1); frame.rowconfigure(3,weight=1)
    path=tk.StringVar(value=STATE.get("project",""))
    path.trace_add("write",lambda *_:(STATE.__setitem__("project",path.get()),save()))
    row=ttk.Frame(frame); row.grid(row=0,column=0,sticky="ew")
    ttk.Label(row,text="KiCad project/folder").pack(side="left")
    ttk.Entry(row,textvariable=path,width=70).pack(side="left",fill="x",expand=True,padx=6)
    ttk.Button(row,text="Browse",command=lambda:path.set(filedialog.askdirectory())).pack(side="left")
    status=tk.StringVar(value="Choose a KiCad project folder.")
    summary=ttk.Treeview(frame,columns=("value",),show="headings",height=12)
    summary.heading("value",text="Value"); summary.column("value",width=250)
    summary.grid(row=3,column=0,sticky="nsew",pady=10)
    files=ttk.Treeview(frame,columns=("type","path"),show="headings",height=8)
    files.heading("type",text="Type"); files.heading("path",text="Path")
    files.column("type",width=120); files.column("path",width=600)
    files.grid(row=4,column=0,sticky="ew")
    actions=ttk.Frame(frame); actions.grid(row=2,column=0,sticky="w",pady=8)
    project_path=[None]
    def inspect():
        p=Path(path.get()).expanduser()
        if not p.exists(): status.set("Folder not found."); return
        project_path[0]=p
        summary.delete(*summary.get_children()); files.delete(*files.get_children())
        sch=list(p.rglob("*.kicad_sch")); pcb=list(p.rglob("*.kicad_pcb")); pro=list(p.rglob("*.kicad_pro"))
        for f in pro: files.insert("", "end", values=("Project",str(f)))
        for f in sch: files.insert("", "end", values=("Schematic",str(f)))
        for f in pcb: files.insert("", "end", values=("PCB",str(f)))
        for f in sch:
            for k,v in stats_sch(f).items(): summary.insert("", "end", values=(f"{f.name}: {k} = {v}",))
        for f in pcb:
            for k,v in stats_pcb(f).items(): summary.insert("", "end", values=(f"{f.name}: {k} = {v}",))
        status.set(f"Found {len(pro)} project file(s), {len(sch)} schematic(s), {len(pcb)} PCB(s).")
    ttk.Button(actions,text="Inspect Project",command=inspect).pack(side="left")
    def open_kicad():
        exe=shutil.which("kicad")
        if not exe: messagebox.showinfo("KiCad Assistant","KiCad executable not found in PATH."); return
        p=Path(path.get()).expanduser()
        pro=next(iter(p.rglob("*.kicad_pro")),None)
        target=pro or p
        subprocess.Popen([exe,str(target)])
    ttk.Button(actions,text="Open in KiCad",command=open_kicad).pack(side="left",padx=6)
    ttk.Label(frame,textvariable=status).grid(row=5,column=0,sticky="w")
    ttk.Label(frame,text="CROS reads KiCad's current S-expression files for inspection; edits are intentionally not written by this assistant.",foreground="#777f90",wraplength=800).grid(row=6,column=0,sticky="w",pady=8)
    return frame

PY
if [[ ! -f "$CACHE_FILE" ]]; then
cat > "$CACHE_FILE" <<'JSON'
{
  "project": ""
}
JSON
fi
echo "Installed CROS plugin: KiCad Assistant"
echo "Settings cache: $CACHE_FILE"
echo "Use: cros → Plugins → Reload Plugins"