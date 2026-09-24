#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="${HOME}/.cros-debian-assistant/plugins"
PLUGIN_DIR="$PLUGIN_ROOT/pin-planner"
CACHE_DIR="${HOME}/.cros-debian-assistant/plugin-cache"
CACHE_FILE="$CACHE_DIR/pin-planner.json"
mkdir -p "$PLUGIN_DIR" "$CACHE_DIR"
cat > "$PLUGIN_DIR/plugin.json" <<'JSON'
{
  "id": "pin-planner",
  "name": "Pin Planner",
  "version": "1.0.0",
  "description": "Plan GPIO/peripheral assignments for the active CROS board with conflict detection and export.",
  "entry": "plugin.py",
  "panel": "build_panel"
}
JSON
cat > "$PLUGIN_DIR/plugin.py" <<'PY'
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from pathlib import Path
import json
import subprocess
import shutil
import re

CACHE_DIR=Path.home()/".cros-debian-assistant"/"plugin-cache"
CACHE_FILE=CACHE_DIR/"pin-planner.json"
STATE={"assignments":{},"search":"","board":""}

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

COMMON = {
    "Arduino Uno": ["D0/RX","D1/TX","D2/INT0","D3/PWM","D4","D5/PWM","D6/PWM","D7","D8","D9/PWM","D10/SS","D11/MOSI","D12/MISO","D13/SCK/LED","A0","A1","A2","A3","A4/SDA","A5/SCL"],
    "Arduino Mega": [f"D{i}" for i in range(0,54)],
    "ESP32": [f"GPIO{i}" for i in range(0,40)],
    "ESP32-S3": [f"GPIO{i}" for i in range(0,48)],
    "Raspberry Pi Pico": [f"GP{i}" for i in range(0,30)],
    "Raspberry Pi Pico 2": [f"GP{i}" for i in range(0,48)],
}

def pin_choices(board):
    n=(board or {}).get("name","")
    for key,value in COMMON.items():
        if key.lower() in n.lower():
            return value
    return ["GPIO/Pin 0","GPIO/Pin 1","GPIO/Pin 2","GPIO/Pin 3","GPIO/Pin 4","GPIO/Pin 5","GPIO/Pin 6","GPIO/Pin 7","GPIO/Pin 8","GPIO/Pin 9","GPIO/Pin 10","GPIO/Pin 11","GPIO/Pin 12","GPIO/Pin 13","GPIO/Pin 14","GPIO/Pin 15","Custom"]

def build_panel(parent,gui):
    frame=ttk.Frame(parent); frame.pack(fill="both",expand=True,padx=10,pady=10)
    frame.columnconfigure(1,weight=1); frame.rowconfigure(2,weight=1)
    active=gui._active_board() or {}
    board_name=active.get("name","No active board")
    ttk.Label(frame,text=f"✓ Active board: {board_name}",font=("TkDefaultFont",13,"bold")).grid(row=0,column=0,columnspan=2,sticky="w",pady=(0,8))
    ttk.Label(frame,text="Use Boards to change the active board. Pin Planner will follow it automatically.",foreground="#777f90").grid(row=1,column=0,columnspan=2,sticky="w")
    pins=pin_choices(active)
    assignments=dict(STATE.get("assignments",{}))
    selected_pin=tk.StringVar(value=pins[0] if pins else "")
    selected_function=tk.StringVar()
    listbox=tk.Listbox(frame,height=18,exportselection=False)
    listbox.grid(row=2,column=0,sticky="nsw",pady=10)
    table=ttk.Treeview(frame,columns=("pin","function"),show="headings",height=18)
    table.heading("pin",text="Pin")
    table.heading("function",text="Assigned function")
    table.column("pin",width=170)
    table.column("function",width=300)
    table.grid(row=2,column=1,sticky="nsew",pady=10,padx=(12,0))
    sc=ttk.Scrollbar(frame,orient="vertical",command=table.yview); sc.grid(row=2,column=2,sticky="ns",pady=10); table.configure(yscrollcommand=sc.set)
    for p in pins: listbox.insert("end",p)
    form=ttk.Frame(frame); form.grid(row=3,column=0,columnspan=3,sticky="ew")
    ttk.Label(form,text="Function / signal").pack(side="left")
    ttk.Entry(form,textvariable=selected_function,width=35).pack(side="left",padx=6)
    status=tk.StringVar(value="")
    def refresh():
        table.delete(*table.get_children())
        used={}
        for pin in pins:
            fn=assignments.get(pin,"")
            if fn: used.setdefault(fn,[]).append(pin)
            table.insert("", "end", values=(pin,fn))
        dup=[f"{fn}: {', '.join(ps)}" for fn,ps in used.items() if len(ps)>1]
        status.set("⚠ Potential duplicate signal assignment: "+"; ".join(dup) if dup else f"{len([x for x in assignments.values() if x])} assigned pin(s).")
        STATE["assignments"]=assignments; STATE["board"]=board_name; save()
    def choose(_=None):
        sel=listbox.curselection()
        if sel: selected_pin.set(listbox.get(sel[0])); selected_function.set(assignments.get(selected_pin.get(),""))
    def assign():
        p=selected_pin.get(); fn=selected_function.get().strip()
        if not p or not fn: return
        assignments[p]=fn; refresh()
    def clear():
        p=selected_pin.get()
        assignments.pop(p,None); refresh(); selected_function.set("")
    def export():
        path=filedialog.asksaveasfilename(defaultextension=".h",filetypes=[("C header","*.h"),("Text","*.txt")])
        if not path:return
        lines=[f"// CROS Pin Planner — {board_name}","// Generated from the active board selection.",""]
        for pin,fn in assignments.items():
            macro="PIN_"+re.sub(r"[^A-Za-z0-9]+","_",fn.upper()).strip("_")
            lines.append(f"#define {macro} {pin}")
        Path(path).write_text("\n".join(lines)+"\n")
        status.set(f"Exported {path}")
    listbox.bind("<<ListboxSelect>>",choose)
    ttk.Button(form,text="Assign",command=assign).pack(side="left",padx=4)
    ttk.Button(form,text="Clear",command=clear).pack(side="left",padx=4)
    ttk.Button(form,text="Export Header",command=export).pack(side="left",padx=4)
    ttk.Label(frame,textvariable=status).grid(row=4,column=0,columnspan=3,sticky="w",pady=8)
    refresh()
    return frame

PY
if [[ ! -f "$CACHE_FILE" ]]; then
cat > "$CACHE_FILE" <<'JSON'
{
  "assignments": {},
  "search": "",
  "board": ""
}
JSON
fi
echo "Installed CROS plugin: Pin Planner"
echo "Settings cache: $CACHE_FILE"
echo "Use: cros → Plugins → Reload Plugins"