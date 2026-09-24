#!/usr/bin/env bash
set -euo pipefail
PLUGIN_ROOT="${HOME}/.cros-debian-assistant/plugins"
PLUGIN_DIR="$PLUGIN_ROOT/cnc-manufacturing"
CACHE_DIR="${HOME}/.cros-debian-assistant/plugin-cache"
CACHE_FILE="$CACHE_DIR/cnc-manufacturing.json"

mkdir -p "$PLUGIN_DIR" "$CACHE_DIR"

cat > "$PLUGIN_DIR/plugin.json" <<'JSON'
{
  "id": "cnc-manufacturing",
  "name": "CNC / PCB Manufacturing",
  "version": "2.6.0",
  "description": "Integrated CNC workspace: Gerber to G-code, isolation calculator, tool library, and G-code simulator with fixed viewer surfaces and pointer-centered zoom.",
  "entry": "plugin.py",
  "panel": "build_panel"
}
JSON

cat > "$PLUGIN_DIR/plugin.py" <<'PY'
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
from pathlib import Path
import json, re, math, shutil

CACHE_DIR = Path.home() / ".cros-debian-assistant" / "plugin-cache"
CACHE_FILE = CACHE_DIR / "cnc-manufacturing.json"

DEFAULT_TOOLS = [
    {"name":"V-bit 0.2 mm","type":"V-bit","diameter":0.20,"feed":300,"plunge":100,"spindle":10000,"material":"PCB isolation"},
    {"name":"End mill 0.8 mm","type":"End mill","diameter":0.80,"feed":500,"plunge":200,"spindle":12000,"material":"PCB/general"},
    {"name":"End mill 1.0 mm","type":"End mill","diameter":1.00,"feed":450,"plunge":180,"spindle":12000,"material":"PCB/general"},
]

def load_cache():
    default = {
        "simulator":{"input":"","speed":"1.0"},
        "gerber": {"input":"","output":"","mode":"isolation","res":"0.10","clearance":"0.10","depth":"-0.12","safe":"2.0","tool":"V-bit 0.2 mm"},
        "calc": {"trace_width":"0.30","isolation":"0.30","tool_diam":"0.20","stepover":"0.10"},
        "tools": DEFAULT_TOOLS,
    }
    try:
        if CACHE_FILE.exists():
            d=json.loads(CACHE_FILE.read_text())
            if isinstance(d,dict):
                default.update(d)
    except Exception:
        pass
    if not isinstance(default.get("tools"), list) or not default["tools"]:
        default["tools"]=DEFAULT_TOOLS
    return default

STATE=load_cache()
def save_cache():
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp=CACHE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(STATE, indent=2)+"\n")
        tmp.replace(CACHE_FILE)
    except Exception:
        pass

def parse_gerber(path):
    text=Path(path).read_text(errors="replace")
    units="inch" if "%MOIN" in text.upper() else "mm"
    scale=25.4 if units=="inch" else 1.0
    m=re.search(r"%FS([LT])([AD])X(\d)(\d)Y(\d)(\d)\*%",text,re.I)
    ix,dx,iy,dy=(4,6,4,6)
    if m: ix,dx,iy,dy=map(int,m.groups()[2:])
    apertures={}
    for code,kind,args in re.findall(r"%ADD(\d+)([A-Za-z])(.*?)\*%",text,re.I):
        vals=[float(x) for x in re.split(r"[Xx,]",args) if x]
        apertures[int(code)]=(kind.upper(),vals)
    segs=[]; flashes=[]; x=y=0.0; cur=None; pol="positive"
    def coord(raw, digits):
        if not raw: return None
        sign=-1 if raw.startswith("-") else 1
        raw2=raw.lstrip("+-")
        return sign*(int(raw2)/(10**digits))*scale
    for tok in re.findall(r"%[^%]*%|[^*]+\*",text,re.S):
        t=tok.strip()
        if not t: continue
        if t.startswith("%"):
            up=t.upper()
            if "%LPC" in up: pol="clear"
            elif "%LPD" in up: pol="positive"
            continue
        up=t.upper()
        mm=re.match(r"D(\d+)\s*\*",up)
        if mm:
            d=int(mm.group(1))
            if d>=10: cur=d
            continue
        cm=re.search(r"X([+-]?\d+)Y([+-]?\d+)(?:D0([123]))?",up)
        if not cm: continue
        xn=coord(cm.group(1),dx); yn=coord(cm.group(2),dy)
        if xn is None or yn is None: continue
        op=int(cm.group(3) or 2)
        if op==2: x,y=xn,yn
        elif op==1: segs.append((x,y,xn,yn,cur,pol)); x,y=xn,yn
        else: flashes.append((xn,yn,cur,pol)); x,y=xn,yn
    return {"units":units,"apertures":apertures,"segments":segs,"flashes":flashes}

def aperture_size(ap):
    if not ap: return (0.2,0.2)
    k,a=ap
    if k=="C": return (a[0],a[0])
    if k in ("R","O"): return (a[0],a[1] if len(a)>1 else a[0])
    return (a[0] if a else 0.2, a[0] if a else 0.2)

def rasterize(layer, res):
    segs=layer["segments"]; flashes=layer["flashes"]; aps=layer["apertures"]
    xs=[]; ys=[]
    for x1,y1,x2,y2,ap,pol in segs:
        if pol=="positive": xs += [x1,x2]; ys += [y1,y2]
    for x,y,ap,pol in flashes:
        if pol=="positive": xs.append(x); ys.append(y)
    if not xs: raise ValueError("No positive-polarity copper primitives found.")
    xmin,xmax=min(xs),max(xs); ymin,ymax=min(ys),max(ys)
    pad=max(res*2,0.1); xmin-=pad; ymin-=pad; xmax+=pad; ymax+=pad
    w=max(2,int(math.ceil((xmax-xmin)/res))); h=max(2,int(math.ceil((ymax-ymin)/res)))
    if w*h>3_000_000: raise ValueError("Raster would exceed 3 million cells; increase raster step.")
    grid=[[False]*w for _ in range(h)]
    def mark(cx,cy,rx,ry):
        ix0=max(0,int((cx-rx-xmin)/res)); ix1=min(w-1,int((cx+rx-xmin)/res))
        iy0=max(0,int((cy-ry-ymin)/res)); iy1=min(h-1,int((cy+ry-ymin)/res))
        for iy in range(iy0,iy1+1):
            py=ymin+(iy+0.5)*res
            for ix in range(ix0,ix1+1):
                px=xmin+(ix+0.5)*res
                if ((px-cx)/(rx or 1e-9))**2+((py-cy)/(ry or 1e-9))**2<=1:
                    grid[iy][ix]=True
    def draw_seg(x1,y1,x2,y2,ap):
        rx,ry=aperture_size(aps.get(ap)); r=max(rx,ry)/2
        n=max(1,int(math.hypot(x2-x1,y2-y1)/(res/2)))
        for i in range(n+1):
            t=i/n; mark(x1+(x2-x1)*t,y1+(y2-y1)*t,r,r)
    for x1,y1,x2,y2,ap,pol in segs:
        if pol=="positive": draw_seg(x1,y1,x2,y2,ap)
    for x,y,ap,pol in flashes:
        if pol=="positive":
            rx,ry=aperture_size(aps.get(ap)); mark(x,y,rx/2,ry/2)
    return grid,xmin,ymin,res

def dilate_grid(grid,cells):
    if cells<=0: return [r[:] for r in grid]
    h=len(grid); w=len(grid[0]) if h else 0
    out=[[False]*w for _ in range(h)]
    rr=cells*cells
    for y,row in enumerate(grid):
        for x,val in enumerate(row):
            if not val: continue
            for yy in range(max(0,y-cells), min(h-1,y+cells)+1):
                dy=yy-y
                for xx in range(max(0,x-cells), min(w-1,x+cells)+1):
                    dx=xx-x
                    if dx*dx+dy*dy<=rr: out[yy][xx]=True
    return out

def boundary_paths(grid):
    h=len(grid); w=len(grid[0]) if h else 0
    segs=[]
    for y,row in enumerate(grid):
        for x,val in enumerate(row):
            if not val: continue
            if y==0 or not grid[y-1][x]: segs.append(((x,y),(x+1,y)))
            if y==h-1 or not grid[y+1][x]: segs.append(((x+1,y+1),(x,y+1)))
            if x==0 or not row[x-1]: segs.append(((x,y+1),(x,y)))
            if x==w-1 or not row[x+1]: segs.append(((x+1,y),(x+1,y+1)))
    unused=set(range(len(segs))); paths=[]
    while unused:
        i=unused.pop(); a,b=segs[i]; path=[a,b]
        changed=True
        while changed:
            changed=False
            for j in list(unused):
                c,d=segs[j]
                if c==path[-1]: path.append(d); unused.remove(j); changed=True; break
                if d==path[-1]: path.append(c); unused.remove(j); changed=True; break
                if d==path[0]: path.insert(0,c); unused.remove(j); changed=True; break
                if c==path[0]: path.insert(0,d); unused.remove(j); changed=True; break
        if len(path)>1: paths.append(path)
    return paths

def gcode_isolation(grid,xmin,ymin,res,depth,safe,feed,plunge,spindle,tool_diam,clearance):
    cells=int(math.ceil(max(0,tool_diam/2+clearance)/res))
    work=dilate_grid(grid,cells)
    paths=boundary_paths(work)
    g=["; CROS CNC Manufacturing - PCB isolation outline","G21","G90",f"G0 Z{safe:.3f}",f"M3 S{spindle:.0f}"]
    for p in paths:
        x0,y0=p[0]
        g += [f"G0 X{xmin+x0*res:.3f} Y{ymin+y0*res:.3f}", f"G1 Z{depth:.3f} F{plunge:.1f}"]
        for x,y in p[1:]:
            g.append(f"G1 X{xmin+x*res:.3f} Y{ymin+y*res:.3f} F{feed:.1f}")
        g.append(f"G0 Z{safe:.3f}")
    g += ["M5","G0 Z0","M2"]
    return "\n".join(g)+"\n", work, len(paths)

def gcode_pocket(grid,xmin,ymin,res,depth,safe,feed,plunge,spindle):
    g=["; CROS CNC Manufacturing - PCB pocket","G21","G90",f"G0 Z{safe:.3f}",f"M3 S{spindle:.0f}"]
    h=len(grid); w=len(grid[0]) if h else 0
    for iy,row in enumerate(grid):
        y=ymin+(iy+0.5)*res; ix=0
        while ix<w:
            while ix<w and not row[ix]: ix+=1
            if ix>=w: break
            start=ix
            while ix<w and row[ix]: ix+=1
            end=ix-1
            x1=xmin+(start+0.5)*res; x2=xmin+(end+0.5)*res
            g += [f"G0 X{x1:.3f} Y{y:.3f}",f"G1 Z{depth:.3f} F{plunge:.1f}",f"G1 X{x2:.3f} F{feed:.1f}",f"G0 Z{safe:.3f}"]
    g += ["M5","G0 Z0","M2"]
    return "\n".join(g)+"\n"

def build_panel(parent, gui):
    nb=ttk.Notebook(parent)
    nb.pack(fill="both", expand=True, padx=10, pady=10)

    # GERBER TAB
    gerber=ttk.Frame(nb,padding=12); nb.add(gerber,text="Gerber → G-code")
    gerber.columnconfigure(1,weight=1); gerber.rowconfigure(0,weight=1)
    left=ttk.Frame(gerber); left.grid(row=0,column=0,sticky="nsw",padx=(0,12))
    right=ttk.Frame(gerber); right.grid(row=0,column=1,sticky="nsew"); right.columnconfigure(0,weight=1); right.rowconfigure(0,weight=1)
    gs=STATE["gerber"]
    inp=tk.StringVar(value=gs.get("input","")); out=tk.StringVar(value=gs.get("output","")); mode=tk.StringVar(value=gs.get("mode","isolation")); res=tk.StringVar(value=str(gs.get("res","0.10"))); clr=tk.StringVar(value=str(gs.get("clearance","0.10"))); dep=tk.StringVar(value=str(gs.get("depth","-0.12"))); safe=tk.StringVar(value=str(gs.get("safe","2.0"))); tool=tk.StringVar(value=gs.get("tool","V-bit 0.2 mm"))
    tools_by_name={t["name"]:t for t in STATE["tools"]}
    tool_names=list(tools_by_name) or ["V-bit 0.2 mm"]
    if tool.get() not in tool_names: tool.set(tool_names[0])
    def sync():
        STATE["gerber"].update({"input":inp.get(),"output":out.get(),"mode":mode.get(),"res":res.get(),"clearance":clr.get(),"depth":dep.get(),"safe":safe.get(),"tool":tool.get()}); save_cache()
    for v in (inp,out,mode,res,clr,dep,safe,tool): v.trace_add("write",lambda *_:sync())
    ttk.Label(left,text="Copper Gerber",font=("TkDefaultFont",11,"bold")).pack(anchor="w")
    r=ttk.Frame(left); r.pack(fill="x",pady=4); ttk.Entry(r,textvariable=inp,width=34).pack(side="left",fill="x",expand=True)
    ttk.Button(r,text="Browse",command=lambda:(lambda p: inp.set(p))(filedialog.askopenfilename(filetypes=[("Gerber","*.gbr *.ger *.GTL *.GBR"),("All","*")]))).pack(side="left",padx=4)
    ttk.Label(left,text="Output G-code").pack(anchor="w",pady=(10,2)); ttk.Entry(left,textvariable=out,width=34).pack(fill="x")
    ttk.Label(left,text="Toolpath").pack(anchor="w",pady=(8,2)); ttk.Combobox(left,textvariable=mode,values=["isolation","pocket"],state="readonly",width=22).pack(fill="x")
    ttk.Label(left,text="Tool from library").pack(anchor="w",pady=(8,2))
    tool_box=ttk.Combobox(left,textvariable=tool,values=tool_names,state="readonly",width=22); tool_box.pack(fill="x")
    tool_info=tk.StringVar(value="")
    def update_tool_info(*_):
        t=tools_by_name.get(tool.get())
        if t:
            tool_info.set(f"✓ Selected tool: {t['name']}\nDiameter: {float(t['diameter']):.3f} mm  •  Feed: {t['feed']}\nPlunge: {t['plunge']}  •  Spindle: {t['spindle']} RPM")
        else:
            tool_info.set("No tool selected")
    tool.trace_add("write",update_tool_info)
    update_tool_info()
    ttk.Label(left,textvariable=tool_info,wraplength=260).pack(anchor="w",pady=(4,2))
    for label,var in [("Raster step (mm)",res),("Isolation clearance (mm)",clr),("Cut depth (mm)",dep),("Safe Z (mm)",safe)]:
        ttk.Label(left,text=label).pack(anchor="w",pady=(8,2)); ttk.Entry(left,textvariable=var,width=18).pack(fill="x")
    status=tk.StringVar(value="Built-in toolpath engine ready.")
    preview_state={"grid":None,"xmin":0.0,"ymin":0.0,"res":0.1,"mode":"isolation","tool":None,"target":None,
                   "zoom":1.0,"pan_x":0.0,"pan_y":0.0,"drag_start":None}
    preview_expanded={"value":False}
    preview_expand_label=tk.StringVar(value="⛶ Expand Preview")

    def toggle_preview():
        preview_expanded["value"]=not preview_expanded["value"]
        if preview_expanded["value"]:
            left.grid_remove()
            preview_expand_label.set("↙ Restore Controls")
            right.columnconfigure(0,weight=1)
            gerber.columnconfigure(0,weight=0)
        else:
            left.grid()
            preview_expand_label.set("⛶ Expand Preview")
            gerber.columnconfigure(0,weight=0)
            right.columnconfigure(0,weight=1)
        preview_state["zoom"]=1.0
        preview_state["pan_x"]=0.0
        preview_state["pan_y"]=0.0
        preview_state["drag_start"]=None
        draw_toolpath_preview()

    def draw_toolpath_preview():
        canvas.delete("all")
        grid=preview_state.get("grid")
        expanded=preview_expanded["value"]

        W=max(520,canvas.winfo_width())
        H=max(420,canvas.winfo_height())

        if not expanded or not grid:
            pad=14
            canvas.create_rectangle(pad,pad,W-pad,H-pad,
                                    outline="#596273",width=2)
            canvas.create_text(W/2,H/2,
                               text="[gcode display, double click to view]",
                               fill="#c9ced8",
                               font=("TkDefaultFont",12))
            return

        h=len(grid); w=len(grid[0]) if h else 0
        if not h or not w:
            return

        pad=25
        base_scale=min((W-2*pad)/max(w,1),(H-2*pad)/max(h,1))
        scale=base_scale*preview_state.get("zoom",1.0)
        xoff=(W-w*base_scale)/2 + preview_state.get("pan_x",0.0)
        yoff=(H-h*base_scale)/2 + preview_state.get("pan_y",0.0)

        # Copper/background raster.
        for yy,row in enumerate(grid):
            for xx,val in enumerate(row):
                if val:
                    qy=h-yy-1
                    x1=xoff+xx*scale
                    y1=yoff+qy*scale
                    canvas.create_rectangle(
                        x1,y1,
                        x1+max(1,scale),
                        y1+max(1,scale),
                        fill="#263142",
                        outline=""
                    )

        # Actual cutting path.
        if preview_state.get("mode")=="isolation":
            paths=boundary_paths(grid)
            for path in paths:
                if len(path)<2:
                    continue
                pts=[]
                for px,py in path:
                    qy=h-py
                    pts.extend([xoff+px*scale,yoff+qy*scale])
                canvas.create_line(*pts,fill="#63d297",width=2)
        else:
            for yy,row in enumerate(grid):
                xx=0
                while xx<w:
                    while xx<w and not row[xx]:
                        xx+=1
                    if xx>=w:
                        break
                    begin=xx
                    while xx<w and row[xx]:
                        xx+=1
                    finish=xx-1
                    qy=h-yy-0.5
                    y=yoff+qy*scale
                    canvas.create_line(
                        xoff+(begin+0.5)*scale,y,
                        xoff+(finish+0.5)*scale,y,
                        fill="#63d297",width=2
                    )

    def gerber_zoom_at(event, factor):
        if not preview_state.get("grid") or not preview_expanded["value"]:
            return
        grid=preview_state["grid"]
        h=len(grid); w=len(grid[0]) if h else 0
        if not h or not w:
            return
        W=max(520,canvas.winfo_width())
        H=max(420,canvas.winfo_height())
        pad=25
        base_scale=min((W-2*pad)/max(w,1),(H-2*pad)/max(h,1))
        old_zoom=preview_state.get("zoom",1.0)
        new_zoom=max(0.15,min(30.0,old_zoom*factor))
        old_scale=base_scale*old_zoom
        new_scale=base_scale*new_zoom
        base_x=(W-w*base_scale)/2
        base_y=(H-h*base_scale)/2
        old_pan_x=preview_state.get("pan_x",0.0)
        old_pan_y=preview_state.get("pan_y",0.0)

        # Keep the world point under the pointer fixed.
        world_x=(event.x-base_x-old_pan_x)/old_scale
        world_y=(event.y-base_y-old_pan_y)/old_scale
        preview_state["pan_x"]=event.x-base_x-world_x*new_scale
        preview_state["pan_y"]=event.y-base_y-world_y*new_scale
        preview_state["zoom"]=new_zoom
        draw_toolpath_preview()

    def gerber_wheel(event):
        if getattr(event,"num",None)==4 or getattr(event,"delta",0)>0:
            gerber_zoom_at(event,1.15)
        elif getattr(event,"num",None)==5 or getattr(event,"delta",0)<0:
            gerber_zoom_at(event,1/1.15)
        return "break"

    def gerber_drag_start(event):
        if not preview_expanded["value"]:
            return "break"
        preview_state["drag_start"]=(event.x,event.y,
                                     preview_state.get("pan_x",0.0),
                                     preview_state.get("pan_y",0.0))
        return "break"

    def gerber_drag(event):
        start=preview_state.get("drag_start")
        if not start:
            return "break"
        sx,sy,px,py=start
        preview_state["pan_x"]=px+(event.x-sx)
        preview_state["pan_y"]=py+(event.y-sy)
        draw_toolpath_preview()
        return "break"

    def gerber_drag_end(event):
        preview_state["drag_start"]=None
        return "break"

    def generate():
        try:
            p=Path(inp.get()).expanduser()
            if not p.exists(): raise ValueError("Choose a Gerber input first.")
            selected=tools_by_name.get(tool.get())
            if not selected: raise ValueError("Select a tool from the Tool Library tab.")
            layer=parse_gerber(p); grid,xmin,ymin,rr=rasterize(layer,float(res.get()))
            feed=float(selected["feed"]); plunge=float(selected["plunge"]); spindle=float(selected["spindle"]); td=float(selected["diameter"])
            if mode.get()=="isolation":
                txt,preview,n=gcode_isolation(grid,xmin,ymin,rr,float(dep.get()),float(safe.get()),feed,plunge,spindle,td,float(clr.get()))
                label=f"Isolation • {n} contour(s)"
            else:
                txt=gcode_pocket(grid,xmin,ymin,rr,float(dep.get()),float(safe.get()),feed,plunge,spindle); preview=grid; label="Pocket"
            target=Path(out.get() or p.with_suffix(".nc")).expanduser(); target.write_text(txt)
            preview_state.update({
                "grid": preview,
                "xmin": xmin,
                "ymin": ymin,
                "res": rr,
                "mode": mode.get(),
                "tool": selected,
                "target": target,
                "zoom": 1.0,
                "pan_x": 0.0,
                "pan_y": 0.0,
                "drag_start": None,
            })
            draw_toolpath_preview()
            status.set(f"{label} written to {target} • Tool: {selected['name']} • Ø {td:.3f} mm")
            gui.log_line(f"CNC plugin wrote {target}","ok")
        except Exception as e:
            status.set(f"Error: {e}"); gui.log_line(f"CNC plugin: {e}","error")
    ttk.Button(left,text="Generate G-code",command=generate).pack(fill="x",pady=(14,6))
    ttk.Button(left,text="Open Tool Library",command=lambda: nb.select(tools_tab)).pack(fill="x")
    ttk.Label(left,textvariable=status,wraplength=260).pack(anchor="w",pady=10)

    canvas=tk.Canvas(right,background="#11131a",highlightthickness=0,cursor="crosshair"); canvas.grid(row=0,column=0,sticky="nsew")
    canvas.bind("<Configure>",lambda e:draw_toolpath_preview())
    canvas.bind("<Double-Button-1>",lambda e:toggle_preview())
    canvas.bind("<MouseWheel>",gerber_wheel)
    canvas.bind("<Button-4>",gerber_wheel)
    canvas.bind("<Button-5>",gerber_wheel)
    canvas.bind("<ButtonPress-1>",gerber_drag_start)
    canvas.bind("<B1-Motion>",gerber_drag)
    canvas.bind("<ButtonRelease-1>",gerber_drag_end)
    draw_toolpath_preview()

    # CALCULATOR TAB
    calc=ttk.Frame(nb,padding=12); nb.add(calc,text="Isolation Calculator")
    c=STATE["calc"]
    tw=tk.StringVar(value=c.get("trace_width","0.30")); iso=tk.StringVar(value=c.get("isolation","0.30")); td=tk.StringVar(value=c.get("tool_diam","0.20")); so=tk.StringVar(value=c.get("stepover","0.10"))
    result=tk.StringVar(value="")
    def calc_save():
        STATE["calc"].update({"trace_width":tw.get(),"isolation":iso.get(),"tool_diam":td.get(),"stepover":so.get()}); save_cache()
    for v in (tw,iso,td,so): v.trace_add("write",lambda *_:calc_save())
    for label,var in [("Trace width (mm)",tw),("Desired isolation (mm)",iso),("Tool diameter (mm)",td),("Pass spacing / stepover (mm)",so)]:
        ttk.Label(calc,text=label).pack(anchor="w",pady=(10,2)); ttk.Entry(calc,textvariable=var,width=24).pack(anchor="w")
    def calculate():
        try:
            trace=float(tw.get()); isolation=float(iso.get()); dia=float(td.get()); step=float(so.get())
            if min(trace,isolation,dia,step)<=0: raise ValueError("All values must be positive.")
            first=dia/2+isolation
            passes=max(1,math.ceil(isolation/step))
            min_clear=first-dia/2
            result.set(f"First tool-center offset: {first:.3f} mm\nApprox. isolation passes: {passes}\nClearance represented from copper edge: {min_clear:.3f} mm\n\nRule of thumb: smaller tools can reach tighter isolation; verify with simulation.")
        except Exception as e: result.set(f"Error: {e}")
    ttk.Button(calc,text="Calculate",command=calculate).pack(anchor="w",pady=14)
    ttk.Label(calc,textvariable=result,justify="left",font=("TkDefaultFont",11)).pack(anchor="w")

    # TOOLS TAB
    tools_tab=ttk.Frame(nb,padding=12); nb.add(tools_tab,text="Tool Library")
    tools_tab.columnconfigure(0,weight=1); tools_tab.rowconfigure(0,weight=1)
    cols=("name","type","diameter","feed","plunge","spindle","material")
    tree=ttk.Treeview(tools_tab,columns=cols,show="headings",selectmode="browse")
    headers={"name":"Name","type":"Type","diameter":"Ø mm","feed":"Feed","plunge":"Plunge","spindle":"RPM","material":"Use"}
    for col in cols:
        tree.heading(col,text=headers[col]); tree.column(col,width=130,anchor="w")
    tree.grid(row=0,column=0,columnspan=4,sticky="nsew")
    sc=ttk.Scrollbar(tools_tab,orient="vertical",command=tree.yview); sc.grid(row=0,column=4,sticky="ns"); tree.configure(yscrollcommand=sc.set)
    name=tk.StringVar(); typ=tk.StringVar(value="End mill"); dia=tk.StringVar(value="0.20"); feed=tk.StringVar(value="300"); plunge=tk.StringVar(value="100"); rpm=tk.StringVar(value="10000"); mat=tk.StringVar(value="PCB isolation")
    form=ttk.Frame(tools_tab); form.grid(row=1,column=0,columnspan=5,sticky="ew",pady=(10,0))
    fields=[("Name",name),("Type",typ),("Diameter",dia),("Feed",feed),("Plunge",plunge),("Spindle RPM",rpm),("Material/use",mat)]
    for i,(lab,var) in enumerate(fields):
        ttk.Label(form,text=lab).grid(row=0,column=i,sticky="w",padx=3); ttk.Entry(form,textvariable=var,width=14).grid(row=1,column=i,padx=3)
    def refresh():
        tree.delete(*tree.get_children())
        for t in STATE["tools"]:
            tree.insert("", "end", values=(t["name"],t["type"],t["diameter"],t["feed"],t["plunge"],t["spindle"],t["material"]))
        vals=[t["name"] for t in STATE["tools"]]
        tool_box["values"]=vals
        if tool.get() not in vals and vals: tool.set(vals[0])
    def clear_form():
        for v,val in [(name,""),(typ,"End mill"),(dia,"0.20"),(feed,"300"),(plunge,"100"),(rpm,"10000"),(mat,"PCB isolation")]: v.set(val)
    def add_tool():
        try:
            if not name.get().strip(): raise ValueError("Tool name is required.")
            new={"name":name.get().strip(),"type":typ.get(),"diameter":float(dia.get()),"feed":float(feed.get()),"plunge":float(plunge.get()),"spindle":float(rpm.get()),"material":mat.get().strip()}
            STATE["tools"]=[t for t in STATE["tools"] if t["name"]!=new["name"]]+[new]; save_cache(); refresh(); tool.set(new["name"]); clear_form()
        except Exception as e: messagebox.showerror("Tool Library",str(e))
    def load_selected():
        sel=tree.selection()
        if not sel:return
        vals=tree.item(sel[0],"values")
        for v,val in zip((name,typ,dia,feed,plunge,rpm,mat),vals): v.set(val)
    def delete_selected():
        sel=tree.selection()
        if not sel:return
        n=tree.item(sel[0],"values")[0]
        STATE["tools"]=[t for t in STATE["tools"] if t["name"]!=n]; save_cache(); refresh()
    ttk.Button(form,text="Add / Update",command=add_tool).grid(row=2,column=0,pady=8,sticky="ew")
    ttk.Button(form,text="Load Selected",command=load_selected).grid(row=2,column=1,pady=8,sticky="ew")
    ttk.Button(form,text="Delete Selected",command=delete_selected).grid(row=2,column=2,pady=8,sticky="ew")
    ttk.Label(tools_tab,text="Changes are saved automatically to the CROS plugin cache.",foreground="#666").grid(row=2,column=0,columnspan=5,sticky="w")
    refresh()

    # G-CODE SIMULATOR TAB
    sim=ttk.Frame(nb,padding=12); nb.add(sim,text="G-code Simulator")
    sim.columnconfigure(1,weight=1); sim.rowconfigure(1,weight=1)
    sim_path=tk.StringVar(value=STATE.get("simulator",{}).get("input",""))
    sim_speed=tk.StringVar(value=str(STATE.get("simulator",{}).get("speed","1.0")))
    sim_status=tk.StringVar(value="Load a G-code file to preview its toolpath.")
    STATE.setdefault("simulator",{})
    def sim_save():
        STATE["simulator"].update({"input":sim_path.get(),"speed":sim_speed.get()})
        save_cache()
    sim_path.trace_add("write",lambda *_:sim_save())
    sim_speed.trace_add("write",lambda *_:sim_save())

    sim_left=ttk.Frame(sim); sim_left.grid(row=0,column=0,rowspan=2,sticky="nsw",padx=(0,12))
    sim_canvas=tk.Canvas(sim,background="#11131a",highlightthickness=0)
    sim_canvas.grid(row=1,column=1,sticky="nsew")
    sim_state={"segments":[],"pos":0,"bounds":(0,1,0,1),"playing":False,"after":None,
               "zoom":1.0,"pan_x":0.0,"pan_y":0.0,"drag_start":None,"expanded":False}

    def parse_gcode(path):
        segs=[]
        x=y=z=0.0
        motion="G0"
        minx=miny=float("inf"); maxx=maxy=float("-inf")
        for raw in Path(path).read_text(errors="replace").splitlines():
            line=re.sub(r"\(.*?\)","",raw).split(";")[0].strip().upper()
            if not line: continue
            gm=re.search(r"\bG([0123])\b",line)
            if gm: motion="G"+gm.group(1)
            xm=re.search(r"\bX([-+0-9.]+)",line); ym=re.search(r"\bY([-+0-9.]+)",line); zm=re.search(r"\bZ([-+0-9.]+)",line)
            nx=float(xm.group(1)) if xm else x
            ny=float(ym.group(1)) if ym else y
            nz=float(zm.group(1)) if zm else z
            if nx!=x or ny!=y:
                segs.append((x,y,nx,ny,motion,nz))
                minx=min(minx,x,nx); maxx=max(maxx,x,nx); miny=min(miny,y,ny); maxy=max(maxy,y,ny)
            x,y,z=nx,ny,nz
        if not segs:
            raise ValueError("No XY motion commands were found.")
        return segs,(minx,maxx,miny,maxy)

    def draw_sim():
        sim_canvas.delete("all")
        segs=sim_state["segments"]
        expanded=sim_state.get("expanded",False)
        W=max(700,sim_canvas.winfo_width()); H=max(500,sim_canvas.winfo_height())

        if not expanded or not segs:
            pad=14
            sim_canvas.create_rectangle(pad,pad,W-pad,H-pad,
                                        outline="#596273",width=2)
            sim_canvas.create_text(W/2,H/2,
                                   text="[gcode display, double click to view]",
                                   fill="#c9ced8",
                                   font=("TkDefaultFont",12))
            return

        minx,maxx,miny,maxy=sim_state["bounds"]
        spanx=max(maxx-minx,1e-6); spany=max(maxy-miny,1e-6)
        pad=35
        base_scale=min((W-2*pad)/spanx,(H-2*pad)/spany)
        scale=base_scale*sim_state.get("zoom",1.0)
        base_ox=40-minx*base_scale
        base_oy=H-40+miny*base_scale
        ox=base_ox+sim_state.get("pan_x",0.0)
        oy=base_oy+sim_state.get("pan_y",0.0)

        # Work envelope.
        sim_canvas.create_rectangle(
            ox+minx*scale, oy-maxy*scale,
            ox+maxx*scale, oy-miny*scale,
            outline="#2a2e39"
        )

        upto=max(0,min(sim_state["pos"],len(segs)))
        for x1,y1,x2,y2,motion,z in segs[:upto]:
            color="#63d297" if motion=="G1" else "#6aa9ff" if motion in ("G2","G3") else "#b0b4be"
            sim_canvas.create_line(
                ox+x1*scale,oy-y1*scale,
                ox+x2*scale,oy-y2*scale,
                fill=color,width=2
            )

        if upto:
            x1,y1,x2,y2,motion,z=segs[upto-1]
            sim_canvas.create_oval(
                ox+x2*scale-4,oy-y2*scale-4,
                ox+x2*scale+4,oy-y2*scale+4,
                fill="#ffcc66",outline=""
            )

    def sim_zoom_at(event, factor):
        if not sim_state.get("segments") or not sim_state.get("expanded"):
            return
        minx,maxx,miny,maxy=sim_state["bounds"]
        W=max(700,sim_canvas.winfo_width()); H=max(500,sim_canvas.winfo_height())
        spanx=max(maxx-minx,1e-6); spany=max(maxy-miny,1e-6)
        pad=35
        base_scale=min((W-2*pad)/spanx,(H-2*pad)/spany)
        old_zoom=sim_state.get("zoom",1.0)
        new_zoom=max(0.15,min(30.0,old_zoom*factor))
        old_scale=base_scale*old_zoom
        new_scale=base_scale*new_zoom
        base_ox=40-minx*base_scale
        base_oy=H-40+miny*base_scale
        old_pan_x=sim_state.get("pan_x",0.0)
        old_pan_y=sim_state.get("pan_y",0.0)

        # Convert pointer screen coordinate into the pre-zoom world coordinate.
        world_x=(event.x-base_ox-old_pan_x)/old_scale
        # Screen Y = base_oy + pan_y - world_y*scale
        world_y=(base_oy+old_pan_y-event.y)/old_scale
        sim_state["pan_x"]=event.x-base_ox-world_x*new_scale
        sim_state["pan_y"]=event.y-base_oy+world_y*new_scale
        sim_state["zoom"]=new_zoom
        draw_sim()

    def sim_wheel(event):
        if getattr(event,"num",None)==4 or getattr(event,"delta",0)>0:
            sim_zoom_at(event,1.15)
        elif getattr(event,"num",None)==5 or getattr(event,"delta",0)<0:
            sim_zoom_at(event,1/1.15)
        return "break"

    def sim_drag_start(event):
        if not sim_state.get("expanded"):
            return "break"
        sim_state["drag_start"]=(event.x,event.y,
                                 sim_state.get("pan_x",0.0),
                                 sim_state.get("pan_y",0.0))
        return "break"

    def sim_drag(event):
        start=sim_state.get("drag_start")
        if not start:
            return "break"
        sx,sy,px,py=start
        sim_state["pan_x"]=px+(event.x-sx)
        sim_state["pan_y"]=py+(event.y-sy)
        draw_sim()
        return "break"

    def sim_drag_end(event):
        sim_state["drag_start"]=None
        return "break"

    def toggle_sim_expand():
        sim_state["expanded"]=not sim_state.get("expanded",False)
        sim_state["zoom"]=1.0
        sim_state["pan_x"]=0.0
        sim_state["pan_y"]=0.0
        sim_state["drag_start"]=None
        if sim_state["expanded"]:
            sim_left.grid_remove()
            sim.columnconfigure(0,weight=0)
            sim.columnconfigure(1,weight=1)
        else:
            sim_left.grid()
            sim.columnconfigure(0,weight=0)
            sim.columnconfigure(1,weight=1)
        draw_sim()

    def sim_load():
        try:
            segs,bounds=parse_gcode(sim_path.get())
            sim_state.update({"segments":segs,"pos":0,"bounds":bounds,"playing":False,
                               "zoom":1.0,"pan_x":0.0,"pan_y":0.0,"drag_start":None,
                               "expanded":False})
            sim_status.set(f"Loaded {len(segs)} XY moves.")
            draw_sim()
            gui.log_line(f"G-code simulator loaded {sim_path.get()}","ok")
        except Exception as e:
            sim_status.set(f"Error: {e}")
            gui.log_line(f"G-code simulator: {e}","error")

    def sim_step():
        if not sim_state["segments"]: return
        sim_state["pos"]=min(len(sim_state["segments"]),sim_state["pos"]+1)
        draw_sim()
        if sim_state["pos"]>=len(sim_state["segments"]):
            sim_state["playing"]=False
            sim_status.set("Simulation complete.")

    def sim_tick():
        if not sim_state["playing"]: return
        sim_step()
        if sim_state["playing"]:
            try: delay=max(5,int(120/max(0.1,float(sim_speed.get()))))
            except Exception: delay=120
            sim_state["after"]=sim_canvas.after(delay,sim_tick)

    def sim_play():
        if not sim_state["segments"]: return
        if sim_state["pos"]>=len(sim_state["segments"]): sim_state["pos"]=0
        sim_state["playing"]=True
        sim_tick()

    def sim_pause():
        sim_state["playing"]=False
        if sim_state.get("after"):
            try: sim_canvas.after_cancel(sim_state["after"])
            except Exception: pass
            sim_state["after"]=None

    def sim_reset():
        sim_pause(); sim_state["pos"]=0; draw_sim(); sim_status.set("Simulation reset.")

    ttk.Label(sim_left,text="G-code file",font=("TkDefaultFont",11,"bold")).pack(anchor="w")
    rr=ttk.Frame(sim_left); rr.pack(fill="x",pady=4)
    ttk.Entry(rr,textvariable=sim_path,width=34).pack(side="left",fill="x",expand=True)
    ttk.Button(rr,text="Browse",command=lambda:(lambda p:sim_path.set(p))(filedialog.askopenfilename(filetypes=[("G-code","*.nc *.ngc *.gcode *.tap"),("All","*")]))).pack(side="left",padx=4)
    ttk.Button(sim_left,text="Load G-code",command=sim_load).pack(fill="x",pady=4)
    br=ttk.Frame(sim_left); br.pack(fill="x",pady=6)
    ttk.Button(br,text="▶ Play",command=sim_play).pack(side="left",padx=(0,4))
    ttk.Button(br,text="Ⅱ Pause",command=sim_pause).pack(side="left",padx=4)
    ttk.Button(br,text="Step",command=sim_step).pack(side="left",padx=4)
    ttk.Button(br,text="Reset",command=sim_reset).pack(side="left",padx=4)
    ttk.Label(sim_left,text="Simulation speed").pack(anchor="w",pady=(8,2))
    ttk.Entry(sim_left,textvariable=sim_speed,width=12).pack(anchor="w")
    ttk.Label(sim_left,textvariable=sim_status,wraplength=260).pack(anchor="w",pady=10)
    ttk.Label(sim_left,text="Preview only — this does not send motion to a machine.",foreground="#666",wraplength=260).pack(anchor="w")
    sim_canvas.bind("<Configure>",lambda e:draw_sim())
    sim_canvas.bind("<Double-Button-1>",lambda e:toggle_sim_expand())
    sim_canvas.bind("<MouseWheel>",sim_wheel)
    sim_canvas.bind("<Button-4>",sim_wheel)
    sim_canvas.bind("<Button-5>",sim_wheel)
    sim_canvas.bind("<ButtonPress-1>",sim_drag_start)
    sim_canvas.bind("<B1-Motion>",sim_drag)
    sim_canvas.bind("<ButtonRelease-1>",sim_drag_end)
    draw_sim()

    save_cache()
    return nb

PY

if [[ ! -f "$CACHE_FILE" ]]; then
cat > "$CACHE_FILE" <<'JSON'
{
  "simulator": {
    "input": "",
    "speed": "1.0"
  },
  "gerber": {
    "input": "",
    "output": "",
    "mode": "isolation",
    "res": "0.10",
    "clearance": "0.10",
    "depth": "-0.12",
    "safe": "2.0",
    "tool": "V-bit 0.2 mm"
  },
  "calc": {
    "trace_width": "0.30",
    "isolation": "0.30",
    "tool_diam": "0.20",
    "stepover": "0.10"
  },
  "tools": [
    {
      "name": "V-bit 0.2 mm",
      "type": "V-bit",
      "diameter": 0.2,
      "feed": 300,
      "plunge": 100,
      "spindle": 10000,
      "material": "PCB isolation"
    },
    {
      "name": "End mill 0.8 mm",
      "type": "End mill",
      "diameter": 0.8,
      "feed": 500,
      "plunge": 200,
      "spindle": 12000,
      "material": "PCB/general"
    },
    {
      "name": "End mill 1.0 mm",
      "type": "End mill",
      "diameter": 1.0,
      "feed": 450,
      "plunge": 180,
      "spindle": 12000,
      "material": "PCB/general"
    }
  ]
}
JSON
fi

echo "Installed CROS plugin: CNC / PCB Manufacturing v2.6"
echo "Viewer zoom/drag events no longer propagate to the surrounding CROS page."
echo "Use: cros → Plugins → Reload Plugins"