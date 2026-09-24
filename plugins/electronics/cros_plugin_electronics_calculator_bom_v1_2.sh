#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="${HOME}/.cros-debian-assistant/plugins"
PLUGIN_DIR="$PLUGIN_ROOT/electronics-calculator-bom"
CACHE_DIR="${HOME}/.cros-debian-assistant/plugin-cache"
CACHE_FILE="$CACHE_DIR/electronics-calculator-bom.json"

mkdir -p "$PLUGIN_DIR" "$CACHE_DIR"

cat > "$PLUGIN_DIR/plugin.json" <<'JSON'
{
  "id": "electronics-calculator-bom",
  "name": "Electronics Calculator + KiCad BOM",
  "version": "1.2.0",
  "description": "Electronics calculators plus a KiCad-native BOM workflow with automatic loading and CSV export.",
  "entry": "plugin.py",
  "panel": "build_panel"
}
JSON

cat > "$PLUGIN_DIR/plugin.py" <<'PY'
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from pathlib import Path
import json
import math
import re
import csv
import subprocess
import shutil
import os
import tempfile

CACHE_DIR=Path.home()/".cros-debian-assistant"/"plugin-cache"
CACHE_FILE=CACHE_DIR/"electronics-calculator-bom.json"
STATE={"schematic":"","calc_mode":"ohms","values":{}}

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

def _run_kicad_bom(path):
    exe = shutil.which("kicad-cli")
    if not exe:
        return None
    fd, temp_name = tempfile.mkstemp(prefix="cros-kicad-bom-", suffix=".csv")
    os.close(fd)
    temp_path = Path(temp_name)
    try:
        cmd = [
            exe, "sch", "export", "bom",
            "--output", str(temp_path),
            "--fields", "Reference,Value,Footprint,${QUANTITY},${DNP}",
            str(path),
        ]
        proc = subprocess.run(
            cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30
        )
        if proc.returncode != 0 or not temp_path.exists():
            return None

        rows=[]
        with temp_path.open(newline="", encoding="utf-8-sig", errors="replace") as fh:
            reader=csv.DictReader(fh)
            for row in reader:
                ref=row.get("Reference") or row.get("Refs") or row.get("References") or ""
                value=row.get("Value") or ""
                footprint=row.get("Footprint") or ""
                qty=row.get("${QUANTITY}") or row.get("Quantity") or row.get("Qty") or "1"
                dnp=row.get("${DNP}") or row.get("DNP") or ""
                rows.append({
                    "References":[x.strip() for x in re.split(r"[, ]+",ref) if x.strip()],
                    "Quantity":int(qty) if str(qty).strip().isdigit() else 1,
                    "Value":value,
                    "Footprint":footprint,
                    "MPN":row.get("MPN","") or "",
                    "Description":row.get("Description","") or "",
                    "Datasheet":row.get("Datasheet","") or "",
                    "DNP":dnp,
                })
        return rows
    except Exception:
        return None
    finally:
        try: temp_path.unlink(missing_ok=True)
        except Exception: pass

def _fallback_bom(path):
    text=Path(path).read_text(errors="replace")

    # Prefer placed symbol blocks with lib_id + Reference property.
    blocks=[]
    pos=0
    while True:
        m=re.search(r'\(\s*symbol\b',text[pos:])
        if not m: break
        start=pos+m.start()
        depth=0; in_str=False; esc=False; end=None
        for i,ch in enumerate(text[start:],start=start):
            if in_str:
                if esc: esc=False
                elif ch=="\\": esc=True
                elif ch=='"': in_str=False
                continue
            if ch=='"': in_str=True; continue
            if ch=="(": depth+=1
            elif ch==")":
                depth-=1
                if depth==0:
                    end=i+1
                    break
        if end is None: break
        block=text[start:end]
        if re.search(r'\(\s*lib_id\s+"',block):
            blocks.append(block)
        pos=end

    def prop(block,name):
        m=re.search(
            r'\(\s*property\s+"'+re.escape(name)+r'"\s+"((?:\\.|[^"])*)"',
            block,re.S
        )
        if not m:return ""
        return m.group(1).replace('\\"','"').replace("\\\\","\\")

    rows={}
    for block in blocks:
        ref=prop(block,"Reference")
        if not ref or ref.startswith("#"): continue
        # KiCad's default BOM flag is yes; only skip when explicitly no.
        bom=re.search(r'\(\s*in_bom\s+(yes|no)',block)
        if bom and bom.group(1)=="no": continue

        value=prop(block,"Value")
        footprint=prop(block,"Footprint")
        datasheet=prop(block,"Datasheet")
        desc=prop(block,"Description") or prop(block,"description")
        mpn=prop(block,"MPN") or prop(block,"Manufacturer Part Number")

        key=(value,footprint,mpn,desc)
        row=rows.setdefault(key,{
            "References":[],
            "Quantity":0,
            "Value":value,
            "Footprint":footprint,
            "MPN":mpn,
            "Description":desc,
            "Datasheet":datasheet,
            "DNP":"",
        })
        row["References"].append(ref)
        row["Quantity"] += 1

    return list(rows.values())

def parse_bom(path):
    rows=_run_kicad_bom(path)
    return rows if rows else _fallback_bom(path)

def fmt(x):
    try:return f"{x:.6g}"
    except:return str(x)

def build_panel(parent,gui):
    frame=ttk.Frame(parent); frame.pack(fill="both",expand=True,padx=10,pady=10)
    nb=ttk.Notebook(frame); nb.pack(fill="both",expand=True)

    # Calculator
    calc=ttk.Frame(nb,padding=12)
    nb.add(calc,text="Electronics Calculator")
    calc.columnconfigure(1,weight=1)
    calc.rowconfigure(1,weight=1)

    mode=tk.StringVar(value=STATE.get("calc_mode","ohms"))
    result=tk.StringVar(value="Choose a calculator, enter the values, then press Calculate.")

    ttk.Label(
        calc,
        text="Calculator type",
        font=("TkDefaultFont",11,"bold")
    ).grid(row=0,column=0,sticky="w")

    chooser=ttk.Combobox(
        calc,
        textvariable=mode,
        state="readonly",
        values=[
            "ohms law",
            "voltage divider",
            "LED resistor",
            "RC time constant",
            "power"
        ],
        width=28
    )
    chooser.grid(row=0,column=1,sticky="w",padx=8,pady=(0,12))

    input_card=ttk.LabelFrame(calc,text="Inputs",padding=12)
    input_card.grid(row=1,column=0,sticky="nw",padx=(0,14),pady=4)

    result_card=ttk.LabelFrame(calc,text="Result",padding=16)
    result_card.grid(row=1,column=1,sticky="nsew",pady=4)
    ttk.Label(
        result_card,
        textvariable=result,
        justify="left",
        wraplength=600,
        font=("TkDefaultFont",11)
    ).pack(anchor="nw")

    vars={}
    units={}

    specs={
        "ohms law":[
            ("Voltage","V","volts"),
            ("Current","I","amps"),
            ("Resistance","R","ohms"),
        ],
        "voltage divider":[
            ("Input voltage","Vin","volts"),
            ("Top resistor","R1","ohms"),
            ("Bottom resistor","R2","ohms"),
        ],
        "LED resistor":[
            ("Supply voltage","Vs","volts"),
            ("LED forward voltage","Vf","volts"),
            ("LED current","I","amps"),
        ],
        "RC time constant":[
            ("Resistance","R","ohms"),
            ("Capacitance","C","farads"),
        ],
        "power":[
            ("Voltage","V","volts"),
            ("Current","I","amps"),
            ("Resistance","R","ohms"),
        ],
    }

    def save_values():
        STATE["calc_mode"]=mode.get()
        STATE["values"]={key:var.get() for key,var in vars.items()}
        save()

    def rebuild_inputs(*_):
        for child in input_card.winfo_children():
            child.destroy()
        vars.clear()
        units.clear()

        chosen=mode.get()
        state_values=STATE.setdefault("values",{})

        for row,(label,key,unit) in enumerate(specs.get(chosen,[])):
            ttk.Label(
                input_card,
                text=label,
                font=("TkDefaultFont",10,"bold")
            ).grid(row=row,column=0,sticky="w",pady=5)

            var=tk.StringVar(value=str(state_values.get(key,"")))
            vars[key]=var
            units[key]=unit

            entry=ttk.Entry(input_card,textvariable=var,width=18)
            entry.grid(row=row,column=1,sticky="ew",padx=(10,6),pady=5)
            ttk.Label(
                input_card,
                text=unit,
                foreground="#777f90"
            ).grid(row=row,column=2,sticky="w",pady=5)

            var.trace_add("write",lambda *_:save_values())

        ttk.Label(
            input_card,
            text="Enter numeric values in the boxes above.",
            foreground="#777f90"
        ).grid(
            row=len(specs.get(chosen,[])),
            column=0,
            columnspan=3,
            sticky="w",
            pady=(10,6)
        )

        ttk.Button(
            input_card,
            text="Calculate",
            style="Accent.TButton",
            command=calculate
        ).grid(
            row=len(specs.get(chosen,[]))+1,
            column=0,
            columnspan=3,
            sticky="ew",
            pady=(8,0)
        )

        ttk.Button(
            input_card,
            text="Clear Inputs",
            command=clear_inputs
        ).grid(
            row=len(specs.get(chosen,[]))+2,
            column=0,
            columnspan=3,
            sticky="ew",
            pady=(6,0)
        )

        result.set(
            "Enter values in the Inputs section, then press Calculate."
        )

    def clear_inputs():
        for var in vars.values():
            var.set("")
        result.set("Inputs cleared.")

    def number(key):
        return float(vars[key].get().strip())

    def calculate():
        try:
            chosen=mode.get()

            if chosen=="ohms law":
                provided=set(k for k,v in vars.items() if v.get().strip())
                if {"V","I"} <= provided:
                    result.set(
                        f"Resistance = {number('V')/number('I'):.6g} Ω"
                    )
                elif {"V","R"} <= provided:
                    result.set(
                        f"Current = {number('V')/number('R'):.6g} A"
                    )
                elif {"I","R"} <= provided:
                    result.set(
                        f"Voltage = {number('I')*number('R'):.6g} V"
                    )
                else:
                    result.set("Enter any two of Voltage, Current, and Resistance.")

            elif chosen=="voltage divider":
                result.set(
                    f"Vout = {number('Vin')*number('R2')/(number('R1')+number('R2')):.6g} V"
                )

            elif chosen=="LED resistor":
                result.set(
                    f"Series resistor = {(number('Vs')-number('Vf'))/number('I'):.6g} Ω"
                )

            elif chosen=="RC time constant":
                result.set(
                    f"Time constant τ = {number('R')*number('C'):.6g} seconds"
                )

            elif chosen=="power":
                provided=set(k for k,v in vars.items() if v.get().strip())
                if {"V","I"} <= provided:
                    result.set(f"Power = {number('V')*number('I'):.6g} W")
                elif {"V","R"} <= provided:
                    result.set(f"Power = {number('V')**2/number('R'):.6g} W")
                elif {"I","R"} <= provided:
                    result.set(f"Power = {number('I')**2*number('R'):.6g} W")
                else:
                    result.set("Enter any two of Voltage, Current, and Resistance.")

        except ZeroDivisionError:
            result.set("Error: division by zero is not valid.")
        except ValueError:
            result.set("Error: enter numeric values in every required input.")
        except Exception as exc:
            result.set(f"Error: {exc}")

    chooser.bind("<<ComboboxSelected>>",rebuild_inputs)
    rebuild_inputs()

    # KiCad BOM
    bom=ttk.Frame(nb,padding=12); nb.add(bom,text="KiCad BOM")
    bom.columnconfigure(0,weight=1); bom.rowconfigure(2,weight=1)
    path=tk.StringVar(value=STATE.get("schematic",""))
    path.trace_add("write",lambda *_:(STATE.__setitem__("schematic",path.get()),save()))
    row=ttk.Frame(bom); row.grid(row=0,column=0,sticky="ew")
    ttk.Label(row,text=".kicad_sch").pack(side="left")
    ttk.Entry(row,textvariable=path,width=70).pack(side="left",fill="x",expand=True,padx=6)
    def browse_schematic():
        chosen=filedialog.askopenfilename(filetypes=[("KiCad schematic","*.kicad_sch"),("All","*.*")])
        if chosen:
            path.set(chosen)
            load_bom()
    ttk.Button(row,text="Browse",command=browse_schematic).pack(side="left")
    cols=("refs","qty","value","footprint","mpn")
    tree=ttk.Treeview(bom,columns=cols,show="headings",height=18)
    headers={"refs":"References","qty":"Qty","value":"Value","footprint":"Footprint","mpn":"MPN"}
    for c in cols:
        tree.heading(c,text=headers[c]); tree.column(c,width=150)
    tree.grid(row=2,column=0,sticky="nsew",pady=8)
    status=tk.StringVar(value="Select a KiCad schematic.")
    data=[]
    def load_bom():
        nonlocal data
        try:
            data=parse_bom(path.get())
            tree.delete(*tree.get_children())
            for r in data:
                tree.insert("", "end", values=(" ".join(r["References"]),r["Quantity"],r["Value"],r["Footprint"],r["MPN"]))
            status.set(f"{len(data)} grouped BOM line(s), {sum(r['Quantity'] for r in data)} component instance(s).")
        except Exception as e:
            status.set(f"Error: {e}")
            gui.log_line(f"KiCad BOM: {e}","error")
    def export_csv():
        if not data: load_bom()
        if not data:return
        target=filedialog.asksaveasfilename(defaultextension=".csv",filetypes=[("CSV","*.csv")])
        if not target:return
        with open(target,"w",newline="",encoding="utf-8") as f:
            w=csv.writer(f); w.writerow(["References","Quantity","Value","Footprint","MPN","Description","Datasheet"])
            for r in data:w.writerow([" ".join(r["References"]),r["Quantity"],r["Value"],r["Footprint"],r["MPN"],r["Description"],r["Datasheet"]])
        status.set(f"Exported {target}")
    ttk.Button(row,text="Load BOM",command=load_bom).pack(side="left",padx=6)
    ttk.Button(row,text="Refresh",command=load_bom).pack(side="left",padx=6)
    ttk.Button(row,text="Export CSV",command=export_csv).pack(side="left")
    ttk.Label(bom,textvariable=status).grid(row=3,column=0,sticky="w")
    ttk.Label(
        bom,
        text="KiCad CLI is used automatically when available; otherwise CROS uses its built-in schematic parser.",
        foreground="#777f90",
        wraplength=850
    ).grid(row=4,column=0,sticky="w",pady=(6,0))

    return frame

PY

if [[ ! -f "$CACHE_FILE" ]]; then
cat > "$CACHE_FILE" <<'JSON'
{
  "schematic": "",
  "calc_mode": "ohms",
  "values": {}
}
JSON
fi

echo "Installed CROS plugin: Electronics Calculator + KiCad BOM v1.2"
echo "BOM loading now uses KiCad CLI when available, with automatic fallback parsing."
echo "Use: cros → Plugins → Reload Plugins"