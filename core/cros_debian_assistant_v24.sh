#!/usr/bin/env bash
# CROS Debian Assistant v24
set -euo pipefail

APP_DIR="${HOME}/.cros-debian-assistant"
BIN_DIR="${HOME}/.local/bin"
APP="${APP_DIR}/assistant.py"

mkdir -p "$APP_DIR" "$BIN_DIR"

cat > "$APP" <<'PY'
#!/usr/bin/env python3
from __future__ import annotations
import json, os, re, shlex, shutil, subprocess, sys, threading, importlib.util, traceback
from pathlib import Path
from datetime import datetime

ROOT=Path.home()/".cros-debian-assistant"
ROOT.mkdir(parents=True, exist_ok=True)
DB=ROOT/"knowledge.json"
CFG=ROOT/"config.json"
HISTORY=ROOT/"history.jsonl"
PLUGIN_DIR=ROOT/"plugins"
PLUGIN_DIR.mkdir(parents=True, exist_ok=True)

# Terminal colors. Set NO_COLOR=1 to disable them.
if os.getenv("NO_COLOR") or not sys.stdout.isatty():
    RESET=BOLD=DIM=RED=GREEN=YELLOW=BLUE=MAGENTA=CYAN=WHITE=""
else:
    RESET="\033[0m"; BOLD="\033[1m"; DIM="\033[2m"; RED="\033[31m"
    GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"
    MAGENTA="\033[35m"; CYAN="\033[36m"; WHITE="\033[37m"

def color(text, tone="WHITE"):
    return f"{globals().get(tone, '')}{text}{RESET}"

def banner(title, subtitle=None):
    print("\n" + color("═" * 58, "CYAN"))
    print(color("  " + title, "BOLD"))
    if subtitle:
        print(color("  " + subtitle, "DIM"))
    print(color("═" * 58, "CYAN"))

def menu_choice(prompt, options, default=None):
    print("\n" + color(prompt, "CYAN"))
    for key, title, detail in options:
        print(f"  {color(str(key), 'YELLOW')}) {color(title, 'BOLD')} — {detail}")
    while True:
        suffix = f" [{default}]" if default is not None else ""
        ans=input(f"{color('Choice', 'CYAN')}{suffix}: " ).strip()
        if not ans and default is not None: ans=str(default)
        for key, _, _ in options:
            if ans.lower()==str(key).lower(): return ans.lower()
        print(color("Please choose one of the numbers shown above.", "RED"))

DEFAULT_CFG={
 "execute_commands": True,
 "remember_solutions": True,
 "scan_project_files": True,
 "max_file_bytes": 500_000,
}
if not CFG.exists(): CFG.write_text(json.dumps(DEFAULT_CFG,indent=2))
if not DB.exists(): DB.write_text(json.dumps({"solutions":[],"projects":[]},indent=2))

def load(path, default):
    try: return json.loads(path.read_text())
    except Exception: return default
def save(path,obj): path.write_text(json.dumps(obj,indent=2))
def log(event,**kw):
    with HISTORY.open("a") as f:
        f.write(json.dumps({"time":datetime.now().isoformat(timespec="seconds"),
                            "event":event,**kw})+"\n")
def norm(s): return re.sub(r"\s+"," ",s.lower()).strip()


def _safe_plugin_id(value):
    return re.sub(r"[^a-zA-Z0-9_-]+", "-", str(value or "plugin")).strip("-").lower() or "plugin"

def discover_plugins():
    PLUGIN_DIR.mkdir(parents=True, exist_ok=True)
    found=[]
    for folder in sorted(PLUGIN_DIR.iterdir(), key=lambda x:x.name.casefold()):
        if not folder.is_dir() or folder.name.startswith("_"):
            continue
        manifest_path=folder/"plugin.json"
        if not manifest_path.exists():
            continue
        try:
            manifest=json.loads(manifest_path.read_text())
            pid=_safe_plugin_id(manifest.get("id") or folder.name)
            entry=str(manifest.get("entry") or "plugin.py")
            entry_path=(folder/entry).resolve()
            if not entry_path.exists() or PLUGIN_DIR.resolve() not in entry_path.parents:
                raise ValueError("entry file is missing or outside the plugin directory")
            found.append({
                "id":pid,
                "name":str(manifest.get("name") or pid),
                "description":str(manifest.get("description") or "CROS plugin tool"),
                "version":str(manifest.get("version") or "1.0"),
                "author":str(manifest.get("author") or "Local plugin"),
                "enabled":bool(manifest.get("enabled", True)),
                "folder":folder,
                "manifest":manifest_path,
                "entry":entry_path,
                "panel_entry": manifest.get("panel"),
            })
        except Exception as exc:
            found.append({
                "id":_safe_plugin_id(folder.name),
                "name":folder.name,
                "description":f"Plugin could not be loaded: {exc}",
                "version":"?",
                "author":"",
                "enabled":False,
                "folder":folder,
                "manifest":manifest_path,
                "entry":None,
                "error":str(exc),
            })
    return found

def create_plugin_template(plugin_id, name, description):
    pid=_safe_plugin_id(plugin_id)
    folder=PLUGIN_DIR/pid
    folder.mkdir(parents=True, exist_ok=True)
    manifest={
        "id":pid,
        "name":name or pid.replace("-"," ").title(),
        "description":description or "Custom CROS plugin",
        "version":"1.0",
        "author":"You",
        "enabled":True,
        "entry":"plugin.py",
        "panel":"build_panel",
    }
    (folder/"plugin.json").write_text(json.dumps(manifest,indent=2)+"\n")
    entry = "\n".join([
        "import tkinter as tk",
        "from tkinter import ttk",
        "",
        "# CROS inline plugin API:",
        "#   build_panel(parent, gui) -> build the plugin inside CROS's main content area",
        "#   gui.execute_command(\"command\", auto_confirm=False) -> run through CROS's terminal environment",
        "#   gui.log_line(\"text\", \"ok\") -> mirror a message into CROS's output panel",
        "#   gui._active_board() -> get the currently selected board record, if any",
        "",
        "def build_panel(parent, gui):",
        "    frame = ttk.Frame(parent, padding=20)",
        "    frame.pack(fill=\"both\", expand=True)",
        "    ttk.Label(frame, text=\"My CROS Plugin\", font=(\"TkDefaultFont\", 16, \"bold\")).pack(anchor=\"w\")",
        "    ttk.Label(frame, text=\"Replace this panel with your own controls and function.\", wraplength=700).pack(anchor=\"w\", pady=(6,16))",
        "    ttk.Button(frame, text=\"Run a test command\", command=lambda: gui.execute_command(\"printf 'Hello from my CROS plugin\\n'\", auto_confirm=True)).pack(anchor=\"w\")",
        "    return frame",
    ]) + "\n"
    (folder/"plugin.py").write_text(entry)
    return folder

ERRORS={
"command not found":[
 "Check spelling and PATH: command -v <command>.",
 "Install the Debian package that provides the command if appropriate.",
 "For a local executable, try ./program or add its directory to PATH."],
"No such file or directory":[
 "Run pwd and ls -la to verify the current directory and path.",
 "Linux filenames are case-sensitive; check capitalization and spaces."],
"Permission denied":[
 "Check ls -l and parent-directory permissions.",
 "For your own executable, chmod +x <file> may be appropriate.",
 "Avoid sudo unless the operation genuinely requires elevated privileges."],
"ModuleNotFoundError":[
 "Check the import spelling and active Python interpreter.",
 "For a project, activate its virtual environment before installing packages.",
 "Use python3 -m pip show <package> to inspect the installed package."],
"ImportError":[
 "Check package/API compatibility and the interpreter being used.",
 "Try importing the package directly to isolate the problem."],
"SyntaxError":[
 "Inspect the reported line and the line immediately before it.",
 "Look for missing quotes, commas, brackets, parentheses, or colons."],
"IndentationError":[
 "Use consistent indentation; 4 spaces is the normal Python convention.",
 "Check the block immediately above the reported line."],
"NameError":[
 "Check spelling and variable/function scope.",
 "Make sure the name is defined before it is used."],
"TypeError":[
 "Inspect the types of the values involved.",
 "Check the function signature and argument order."],
"AttributeError":[
 "Inspect the object's type and available attributes.",
 "Check for an API/version mismatch."],
"FileNotFoundError":[
 "Verify the path with pwd and ls -la.",
 "Check capitalization and whether a relative path is based on the intended directory."],
"PermissionError":[
 "Check ownership and permissions.",
 "Prefer moving work into a user-writable directory rather than using sudo."],
"externally-managed-environment":[
 "Use a virtual environment: python3 -m venv .venv",
 "Then activate it: source .venv/bin/activate",
 "Install project packages inside that environment."],
"Unable to locate package":[
 "Run sudo apt update.",
 "Check the exact Debian package name with apt search <term>."],
"dpkg was interrupted":[
 "Run sudo dpkg --configure -a.",
 "Then, if needed, sudo apt-get -f install."],
"Could not get lock":[
 "Another apt/dpkg operation may be running. Wait for it.",
 "Do not blindly delete package-manager lock files."],
"EACCES":[
 "Check ownership and permissions of the target.",
 "Use a user-writable path where possible."],
"ENOSPC":[
 "Check disk space with df -h.",
 "Check inode exhaustion with df -i."],
"Connection refused":[
 "Check that the target service is running and listening on the expected port.",
 "Inspect ss -ltnp and service logs."],
"Address already in use":[
 "Find the process using the port with ss -ltnp.",
 "Choose another port or stop the intended conflicting service."],
"fatal: not a git repository":[
 "Run git status from inside the project.",
 "Use git init only for a genuinely new repository."],
"Permission denied (publickey)":[
 "Check your SSH key and remote URL.",
 "Run ssh -T against the relevant Git host."],
"CONFLICT (content)":[
 "Resolve the <<<<<<< / ======= / >>>>>>> sections.",
 "Then git add the resolved files and continue the Git operation."],
"npm ERR!":[
 "Read the first specific error above the summary.",
 "Check node -v and npm -v.",
 "For lockfile projects, npm ci is often preferable to npm install."],
"avrdude":[
 "Verify board, serial port, USB data cable, and port ownership.",
 "Check the selected bootloader/board configuration."],
"esptool":[
 "Verify ESP family, serial port, cable, and bootloader mode.",
 "Some boards require holding BOOT/FLASH while starting the upload."],
"undefined reference":[
 "A symbol was declared but its implementation was not linked.",
 "Check source/object/library inclusion and linker flags.",
 "For C++, check namespaces and function signatures."],
"segmentation fault":[
 "Look for native-extension, pointer, buffer, or driver problems.",
 "Reproduce minimally; C/C++ programs can be inspected with gdb."],
"ModuleNotFoundError":[
 "Verify the package name and Python interpreter.",
 "Use python3 -m pip show <package> or the project's package manager."]
}

BOARDS=[
("Arduino Uno R3",["arduino","uno","atmega328","avr"],"5V AVR; simple GPIO and classic Arduino C++"),
("Arduino Nano",["nano","atmega328","avr"],"Compact AVR board with common Arduino tooling"),
("Arduino Mega 2560",["mega","atmega2560"],"More GPIO and serial interfaces"),
("ESP32",["esp32","wifi","bluetooth","ble","iot","web server"],"Wi-Fi/Bluetooth MCU; Arduino/C++ or ESP-IDF"),
("ESP8266",["esp8266","wifi","iot"],"Wi-Fi MCU for smaller IoT projects"),
("Raspberry Pi Pico / RP2040",["pico","rp2040","micropython"],"Microcontroller; MicroPython or C/C++"),
("Raspberry Pi Pico 2 / RP2350",["pico 2","pico2","rp2350"],"Newer Pico-family MCU"),
("Raspberry Pi",["raspberry pi","raspi","linux","gpio","camera"],"Linux SBC; Python/C/C++/Node and GPIO"),
("BBC micro:bit",["microbit","micro:bit","makecode"],"Education-oriented board with Python/MakeCode")
]

# Commercial board catalog used by the GUI. Technical identifiers stay internal so
# the visual selector shows product names rather than chipset/package terminology.
COMMERCIAL_BOARDS=[
    {"name":"Arduino Uno R3","family":"arduino","fqbn":"arduino:avr:uno","profile":"arduino","native_code":"ino","reason":"Classic Arduino board for LEDs, sensors, buttons, and basic motors."},
    {"name":"Arduino Nano (ATmega328P)","family":"arduino","fqbn":"arduino:avr:nano:cpu=atmega328old","profile":"arduino","native_code":"ino","reason":"Compact Arduino for projects that need the Uno-style ecosystem in a smaller package."},
    {"name":"Arduino Nano Every","family":"arduino","fqbn":"arduino:megaavr:nanoevery","profile":"arduino","native_code":"ino","reason":"Compact modern Arduino for sensors, controls, and embedded automation."},
    {"name":"Arduino Mega 2560 Rev3","family":"arduino","fqbn":"arduino:avr:mega","profile":"arduino","native_code":"ino","reason":"Choose this when you need many pins, serial ports, or larger Arduino projects."},
    {"name":"Arduino Leonardo","family":"arduino","fqbn":"arduino:avr:leonardo","profile":"arduino","native_code":"ino","reason":"USB-capable Arduino suited to keyboard, mouse, and controller-style projects."},
    {"name":"Arduino Micro","family":"arduino","fqbn":"arduino:avr:micro","profile":"arduino","native_code":"ino","reason":"Small USB-capable Arduino for compact controller and HID projects."},
    {"name":"ESP32 DevKitC V4","family":"esp32","fqbn":"esp32:esp32:esp32","profile":"esp32","native_code":"cpp","reason":"Common ESP32 development board for Wi-Fi, Bluetooth, sensors, and web projects."},
    {"name":"DOIT ESP32 DEVKIT V1","family":"esp32","fqbn":"esp32:esp32:esp32","profile":"esp32","native_code":"cpp","reason":"Popular ESP32 development board for wireless and embedded C++ projects."},
    {"name":"NodeMCU 1.0 (ESP-12E Module)","family":"esp8266","fqbn":"esp8266:esp8266:nodemcuv2","profile":"esp32","native_code":"cpp","reason":"Wi-Fi-focused board for lightweight IoT and web-control projects."},
    {"name":"LOLIN D1 mini","family":"esp8266","fqbn":"esp8266:esp8266:d1_mini","profile":"esp32","native_code":"cpp","reason":"Very compact Wi-Fi board for small sensors and connected devices."},
    {"name":"Raspberry Pi Pico","family":"pico","fqbn":"rp2040:rp2040:rpipico","profile":"pico","native_code":"cpp","reason":"Compact microcontroller board for MicroPython, C++, and hardware projects."},
    {"name":"Raspberry Pi Pico W","family":"pico","fqbn":"rp2040:rp2040:rpipicow","profile":"pico","native_code":"cpp","reason":"Pico-class board with wireless connectivity for connected embedded projects."},
    {"name":"Raspberry Pi Pico 2","family":"pico","fqbn":"rp2040:rp2040:rpipico2","profile":"pico","native_code":"cpp","reason":"Newer Pico-family board for more capable embedded projects."},
    {"name":"Raspberry Pi Pico 2 W","family":"pico","fqbn":"rp2040:rp2040:rpipico2w","profile":"pico","native_code":"cpp","reason":"Pico 2-family board with wireless connectivity."},
    {"name":"BBC micro:bit v2","family":"microbit","fqbn":"","profile":"microbit","native_code":"cpp","reason":"Small educational board for Python or MakeCode projects."},
    {"name":"Raspberry Pi 4 Model B","family":"raspberrypi","fqbn":"","profile":"raspberrypi","native_code":"cpp","reason":"Full Linux computer for Python, C++, GPIO, cameras, and services."},
    {"name":"Raspberry Pi 5","family":"raspberrypi","fqbn":"","profile":"raspberrypi","native_code":"cpp","reason":"Newer Raspberry Pi computer for Linux applications, GPIO, and development."},
]


def commercial_board(name):
    for board in COMMERCIAL_BOARDS:
        if board["name"] == name:
            return board
    return None

BOARD_CATALOG_CACHE=None

def _clean_display_name(value):
    return re.sub(r"\s+", " ", str(value or "")).strip()

def _compact_text(value):
    return re.sub(r"[^a-z0-9]", "", str(value or "").lower())

def _is_subsequence(needle, haystack):
    if not needle:
        return True
    it=iter(haystack)
    return all(any(ch == target for ch in it) for target in needle)

def board_search_score(query, board):
    # Search is intentionally based on the commercial/display name only.
    # It supports normal keyword matches plus ordered-character (subsequence) matches.
    raw=str(query or "").strip().lower()
    if not raw:
        return 0
    name=board["name"]
    folded=_compact_text(name)
    tokens=[_compact_text(t) for t in re.split(r"\s+", raw) if _compact_text(t)]
    if not tokens:
        return 0
    score=0
    for token in tokens:
        if token in folded:
            score += 100 + len(token)*3
        elif _is_subsequence(token, folded):
            score += 55 + len(token)*2
        else:
            return None
    # Whole-query ordered matching gets a small bonus (e.g. "ardno" -> Arduino).
    joined=_compact_text(raw)
    if _is_subsequence(joined, folded):
        score += 20
    # Prefer names that start with the searched characters.
    if folded.startswith(_compact_text(tokens[0])):
        score += 10
    return score

def _fallback_board_catalog():
    out=[]
    for b in COMMERCIAL_BOARDS:
        out.append({
            "name":b["name"],
            "family":b.get("family",""),
            "profile":b.get("profile",""),
            "native_code":b.get("native_code", "cpp"),
            "reason":b.get("reason",""),
            "vendor":b["name"].split()[0] if b.get("name") else "",
            "source":"CROS built-in catalog",
        })
    return out

def load_board_catalog(force=False):
    global BOARD_CATALOG_CACHE
    if BOARD_CATALOG_CACHE is not None and not force:
        return BOARD_CATALOG_CACHE
    catalog=_fallback_board_catalog()
    # PlatformIO supplies a much broader, up-to-date commercial board catalog when
    # it is installed. We keep the GUI display name-only while retaining technical
    # identifiers internally for future tooling.
    pio=shutil.which("pio") or shutil.which("platformio")
    if pio:
        try:
            proc=subprocess.run([pio,"boards","--json-output"],capture_output=True,text=True,timeout=45)
            if proc.returncode==0 and proc.stdout.strip():
                data=json.loads(proc.stdout)
                if isinstance(data,dict):
                    data=data.get("boards",data.get("items",[]))
                if isinstance(data,list):
                    for item in data:
                        if not isinstance(item,dict):
                            continue
                        name=_clean_display_name(item.get("name") or item.get("title"))
                        if not name:
                            continue
                        # PlatformIO's human-readable name is what the GUI searches.
                        family=_clean_display_name(item.get("platform"))
                        native="cpp"
                        fam_l=family.lower()
                        # PlatformIO board catalogs expose the platform but not a
                        # universal single "native language" field. Use the
                        # conventional source type for the platform family.
                        if "arduino" in fam_l or "atmelavr" in fam_l or "megaavr" in fam_l:
                            native="ino"
                        elif "microbit" in fam_l or "nordicnrf52" in fam_l:
                            native="cpp"
                        elif "python" in fam_l:
                            native="cpp"
                        catalog.append({
                            "name":name,
                            "family":family,
                            "profile":family,
                            "native_code":native,
                            "reason":"PlatformIO board catalog entry.",
                            "vendor":_clean_display_name(item.get("vendor")),
                            "source":"PlatformIO board catalog",
                            "id":_clean_display_name(item.get("id")),
                        })
        except Exception:
            pass
    dedup={}
    for b in catalog:
        key=_compact_text(b.get("name"))
        if not key:
            continue
        current=dedup.get(key)
        if current is None or (current.get("source")!="PlatformIO board catalog" and b.get("source")=="PlatformIO board catalog"):
            dedup[key]=b
    BOARD_CATALOG_CACHE=sorted(dedup.values(),key=lambda x:x["name"].casefold())
    return BOARD_CATALOG_CACHE

def board_comment_checklist(language, board_name=None):
    board_text=board_name or "Choose board"
    items=[
        f"Confirm board: {board_text}",
        "Confirm upload port: set the correct /dev/tty* device before flashing",
        "Verify required libraries / dependencies are installed",
        "Verify pin assignments, voltage levels, and connected hardware",
        "Build / compile without errors",
        "Upload and test on the target hardware",
        "Verify serial monitor baud rate if the project uses Serial",
        "Remove or update placeholders before sharing the project",
    ]
    prefix="#" if language in ("python","pico") else "//"
    return prefix+" CROS PROJECT CHECKLIST\n"+"\n".join(f"{prefix} [ ] {item}" for item in items)+"\n"+prefix+" End checklist\n\n"

TEMPLATES={
"python":("main.py",'#!/usr/bin/env python3\n\n\ndef main():\n    print("Hello from ChromeOS Debian")\n\n\nif __name__ == "__main__":\n    main()\n'),
"cpp":("main.cpp",'#include <iostream>\n\nint main() {\n    std::cout << "Hello from ChromeOS Debian\\n";\n    return 0;\n}\n'),
"javascript":("app.js",'console.log("Hello from ChromeOS Debian");\n'),
"arduino":("sketch.ino",'void setup() {\n  Serial.begin(115200);\n}\n\nvoid loop() {\n}\n'),
"esp32":("sketch.ino",'void setup() {\n  Serial.begin(115200);\n}\n\nvoid loop() {\n  delay(1000);\n}\n'),
"pico":("main.py",'from machine import Pin\nfrom time import sleep\n\nled = Pin("LED", Pin.OUT)\nwhile True:\n    led.toggle()\n    sleep(1)\n')
}

def detect(text):
    found=[]
    for key in ERRORS:
        if key.lower() in text.lower() and key not in found: found.append(key)
    regexes=[
      (r"traceback \(most recent call last\):","Python traceback"),
      (r"\berror:\s+","Compiler error"),
      (r"\bfatal error:\s+","Compiler fatal error"),
      (r"exit code\s+\d+","Process exit code"),
    ]
    for pat,label in regexes:
        if re.search(pat,text,re.I) and label not in found: found.append(label)
    return found

def error_report(text):
    hits=detect(text)
    if not hits: return False
    db=load(DB,{"solutions":[],"projects":[]})
    print("\n=== AUTOMATIC ERROR DETECTION ===")
    for e in hits:
        print("\n•",e)
        for fix in ERRORS.get(e,["Capture the full error and inspect the first specific diagnostic."]):
            print("  -",fix)
        previous=[x["solution"] for x in db["solutions"]
                  if norm(x["error"])==norm(e)]
        if previous:
            print("  Previously remembered alternatives:")
            for x in previous[-5:]: print("    *",x)
    log("error",errors=hits,text=text[-5000:])
    return True

def board_match(text):
    n=norm(text); ranked=[]
    for name,terms,reason in BOARDS:
        score=sum(1 for t in terms if t in n)
        if score: ranked.append((score,name,reason))
    if not ranked:
        if any(x in n for x in ["wifi","bluetooth","ble","iot","web"]):
            ranked=[(3,"ESP32",BOARDS[3][2]),(2,"Raspberry Pi",BOARDS[7][2])]
        elif any(x in n for x in ["micropython","pico","rp2040"]):
            ranked=[(3,"Raspberry Pi Pico / RP2040",BOARDS[5][2])]
        elif any(x in n for x in ["camera","linux","server","gpio"]):
            ranked=[(3,"Raspberry Pi",BOARDS[7][2])]
        elif any(x in n for x in ["led","button","servo","motor"]):
            ranked=[(2,"Arduino Uno R3",BOARDS[0][2]),(1,"ESP32",BOARDS[3][2])]
    return sorted(ranked,reverse=True)

def project_files():
    cfg=load(CFG,DEFAULT_CFG)
    if not cfg.get("scan_project_files",True): return []
    skip={".git",".venv","venv","node_modules","__pycache__","build","dist"}
    result=[]
    for p in Path(".").rglob("*"):
        if p.is_file() and not any(part in skip for part in p.parts):
            try:
                if p.stat().st_size <= cfg.get("max_file_bytes",500000):
                    result.append(p)
            except OSError: pass
    return result[:5000]

def inspect_project():
    files=project_files()
    print(f"Project: {Path.cwd()}")
    print(f"Files inspected: {len(files)}")
    exts={}
    for p in files: exts[p.suffix or "[no extension]"]=exts.get(p.suffix or "[no extension]",0)+1
    for k,v in sorted(exts.items(),key=lambda x:-x[1])[:15]: print(f"  {k}: {v}")
    indicators={
      "Python":[".py"],"C/C++":[".c",".h",".cc",".cpp",".hpp"],
      "JavaScript/Node":[".js",".mjs",".cjs"],"Arduino":[".ino"],
      "Shell":[".sh"],"Rust":[".rs"],"Go":[".go"]
    }
    detected=[name for name,suffs in indicators.items() if any(p.suffix in suffs for p in files)]
    if detected: print("Detected ecosystems:",", ".join(detected))
    log("project_scan",cwd=str(Path.cwd()),files=len(files))

BOARD_FORMATS={
    "desktop": {
        "label": "Desktop / Portable C++",
        "indent": 4, "tabs": False, "brace": "Attach", "column": 100,
        "style": "LLVM",
        "extra": ["SortIncludes: true", "SpaceBeforeParens: ControlStatements"],
    },
    "arduino": {
        "label": "Arduino",
        "indent": 2, "tabs": False, "brace": "Attach", "column": 100,
        "style": "LLVM",
        "extra": ["SortIncludes: false", "SpaceBeforeParens: ControlStatements"],
    },
    "esp32": {
        "label": "ESP32",
        "indent": 2, "tabs": False, "brace": "Attach", "column": 100,
        "style": "LLVM",
        "extra": ["SortIncludes: false", "SpaceBeforeParens: ControlStatements"],
    },
    "pico": {
        "label": "Raspberry Pi Pico / RP2040 / RP2350",
        "indent": 4, "tabs": False, "brace": "Attach", "column": 100,
        "style": "LLVM",
        "extra": ["SortIncludes: true", "SpaceBeforeParens: ControlStatements"],
    },
    "raspberrypi": {
        "label": "Raspberry Pi Linux",
        "indent": 4, "tabs": False, "brace": "Attach", "column": 110,
        "style": "LLVM",
        "extra": ["SortIncludes: true", "SpaceBeforeParens: ControlStatements"],
    },
}

BOARD_ALIASES={
    "desktop":"desktop", "linux":"desktop", "portable":"desktop", "generic":"desktop",
    "arduino":"arduino", "uno":"arduino", "nano":"arduino", "mega":"arduino",
    "esp32":"esp32", "esp-32":"esp32",
    "pico":"pico", "rp2040":"pico", "rp2350":"pico", "pico2":"pico", "pico 2":"pico",
    "raspberry pi":"raspberrypi", "raspi":"raspberrypi", "pi":"raspberrypi",
}

def choose_board_format():
    options=[
      ("1","Desktop / Portable C++","4 spaces, general-purpose Linux/desktop style"),
      ("2","Arduino / AVR","2 spaces, Arduino-friendly embedded style"),
      ("3","ESP32","2 spaces, Arduino/ESP32 embedded style"),
      ("4","Raspberry Pi Pico","4 spaces, Pico SDK / embedded C++ style"),
      ("5","Raspberry Pi Linux","4 spaces, wider 110-column Linux C++ style"),
    ]
    choice=menu_choice("Choose the board/target formatting profile",options,"1")
    return {"1":"desktop","2":"arduino","3":"esp32","4":"pico","5":"raspberrypi"}[choice]

def resolve_board_format(value):
    key=norm(value)
    for alias, profile in BOARD_ALIASES.items():
        if key == alias or alias in key:
            return profile
    return None

def write_clang_format(profile="desktop", indent_width=None, use_tabs=None, brace_style=None, column_limit=None):
    p=BOARD_FORMATS.get(profile, BOARD_FORMATS["desktop"])
    indent=p["indent"] if indent_width is None else indent_width
    tabs=p["tabs"] if use_tabs is None else use_tabs
    braces=p["brace"] if brace_style is None else brace_style
    column=p["column"] if column_limit is None else column_limit
    tab_mode="ForIndentation" if tabs else "Never"
    cfg=(
        f"BasedOnStyle: {p['style']}\n"
        f"IndentWidth: {indent}\n"
        f"UseTab: {tab_mode}\n"
        f"BreakBeforeBraces: {braces}\n"
        f"ColumnLimit: {column}\n"
        "IncludeBlocks: Preserve\n"
        "AllowShortFunctionsOnASingleLine: Empty\n"
        + "\n".join(p["extra"]) + "\n"
    )
    target=Path(".clang-format")
    if target.exists():
        ans=input(color(f".clang-format exists. Replace it with the {p['label']} profile? [y/N] ", "YELLOW")).strip().lower()
        if ans!="y":
            return False
    target.write_text(cfg)
    print(color(f"Applied {p['label']} formatting profile to {target}.", "GREEN"))
    return True

def maybe_format_cpp(path, profile="desktop"):
    profile_label=BOARD_FORMATS.get(profile, BOARD_FORMATS["desktop"])["label"]
    clang=shutil.which("clang-format")
    if not clang:
        print(color("clang-format is not installed.", "YELLOW"))
        ans=input(color("Install it now so I can format this file? [Y/n] ", "CYAN")).strip().lower()
        if ans in ("", "y", "yes"):
            sudo=shutil.which("sudo")
            apt=shutil.which("apt-get")
            if not sudo or not apt:
                print(color("I couldn't find sudo/apt-get. Install clang-format manually:", "YELLOW"))
                print("sudo apt-get update && sudo apt-get install -y clang-format")
                return
            try:
                print(color("Installing clang-format...", "CYAN"))
                subprocess.run([sudo, apt, "update"], check=True)
                subprocess.run([sudo, apt, "install", "-y", "clang-format"], check=True)
                clang=shutil.which("clang-format")
            except subprocess.CalledProcessError:
                print(color("clang-format installation failed. The file was left as-is.", "YELLOW"))
                return
            if not clang:
                print(color("clang-format was installed, but the command is not on PATH yet. Restart the terminal and run the formatter again.", "YELLOW"))
                return
        else:
            print("Install later with: sudo apt-get update && sudo apt-get install -y clang-format")
            return
    try:
        subprocess.run([clang,"-i",str(path)],check=True)
        print(color(f"Formatted {path} using the {profile_label} profile.", "GREEN"))
    except Exception as exc:
        print(color(f"clang-format could not format the file: {exc}", "YELLOW"))

def cpp_wizard(name=None):
    banner("C++ Project Setup", "Choose the target board first so formatting and starter code match it.")
    target_options=[
      ("1","Desktop / Linux","Portable C++ using g++/clang++"),
      ("2","Arduino / AVR","Uno, Nano, Mega and other Arduino-style C++"),
      ("3","ESP32","Wi-Fi/Bluetooth embedded C++"),
      ("4","Raspberry Pi Pico","RP2040 / RP2350 embedded C++"),
      ("5","Raspberry Pi","C++ running on Raspberry Pi Linux"),
      ("6","Other / decide later","Portable C++ with no board-specific assumptions"),
    ]
    target=menu_choice("1. What are you building for?",target_options,"1")

    profile_map={"1":"desktop","2":"arduino","3":"esp32","4":"pico","5":"raspberrypi","6":"desktop"}
    profile=profile_map[target]
    pinfo=BOARD_FORMATS[profile]
    print("\n" + color("Formatting preset:","CYAN"), color(pinfo["label"],"GREEN"))
    print(f"  Indent: {pinfo['indent']} spaces | Braces: {pinfo['brace']} | Column limit: {pinfo['column']}")

    custom=menu_choice("2. Use the board preset or customize indentation?", [
      ("1","Use board preset","Keep the board-specific formatting defaults"),
      ("2","Customize","Choose indentation and brace placement yourself"),
    ], "1")

    if custom=="1":
        indent=pinfo["indent"]; use_tabs=pinfo["tabs"]; braces=pinfo["brace"]; column=pinfo["column"]
    else:
        style_options=[
          ("1","4 spaces","Traditional readable C++"),
          ("2","2 spaces","Compact embedded-project style"),
          ("3","Tabs","Use tabs for indentation"),
        ]
        style=menu_choice("3. How should indentation look?",style_options,"1")
        indent=2 if style=="2" else 4
        use_tabs=style=="3"
        brace_options=[
          ("1","Same line","int main() {"),
          ("2","New line","int main()\n{"),
        ]
        brace_choice=menu_choice("4. Where should opening braces go?",brace_options,"1")
        braces="Attach" if brace_choice=="1" else "Allman"
        column=pinfo["column"]

    filename=name or "main.cpp"
    p=Path(filename)
    if p.exists():
        print(color(f"Refusing to overwrite existing file: {p}", "RED"))
        return

    target_names={
      "1":"Desktop / Linux", "2":"Arduino / AVR", "3":"ESP32",
      "4":"Raspberry Pi Pico / RP2040 / RP2350", "5":"Raspberry Pi Linux", "6":"Portable C++"
    }
    chosen=target_names[target]
    if target=="2":
        content="#include <Arduino.h>\n\nvoid setup() {\n  Serial.begin(115200);\n}\n\nvoid loop() {\n}\n"
    elif target=="3":
        content="#include <Arduino.h>\n\nvoid setup() {\n  Serial.begin(115200);\n}\n\nvoid loop() {\n  delay(1000);\n}\n"
    elif target=="4":
        content="#include <cstdio>\n\nint main() {\n    std::printf(\"Hello from Raspberry Pi Pico C++\\n\");\n    return 0;\n}\n"
    else:
        content=TEMPLATES["cpp"][1]
    p.write_text(content)
    print(color(f"Created {p}", "GREEN"))
    print(f"Target: {color(chosen, 'CYAN')}")
    write_clang_format(profile, indent_width=indent, use_tabs=use_tabs, brace_style=braces, column_limit=column)
    maybe_format_cpp(p, profile)

    if target in ("1","5"):
        print(color("Build example:", "CYAN"), f"g++ -std=c++17 -Wall -Wextra {p.name} -o {p.stem}")
    elif target in ("2","3"):
        print(color("Board setup:", "CYAN"), "Use `boards` for the guided board selector and compatibility notes.")
    elif target=="4":
        print(color("Pico note:", "CYAN"), "Choose your RP2040/RP2350 SDK or Arduino-Pico toolchain next.")
    log("create",kind="cpp",file=str(p),target=chosen,format_profile=profile,indent=indent,use_tabs=use_tabs,braces=braces)

def format_cpp_file(path_value, board_value=None):
    p=Path(path_value)
    if not p.exists():
        print(color(f"File not found: {p}", "RED")); return
    if p.suffix.lower() not in {".cpp",".cc",".cxx",".hpp",".h"}:
        print(color("That does not look like a C/C++ source/header file.", "YELLOW")); return
    profile=resolve_board_format(board_value or "") if board_value else None
    if not profile:
        profile=choose_board_format()
    pinfo=BOARD_FORMATS[profile]
    print(color(f"Using {pinfo['label']} formatting profile", "CYAN"))
    if not write_clang_format(profile):
        return
    maybe_format_cpp(p, profile)
    log("format",file=str(p),format_profile=profile)


def create_file(kind,name=None):
    if kind=="cpp":
        cpp_wizard(name); return
    default,content=TEMPLATES[kind]
    p=Path(name or default)
    if p.exists():
        print(color("Refusing to overwrite existing file:", "RED"),p)
        return
    language = "python" if kind in ("python","pico") else "cpp" if kind in ("arduino","esp32") else "javascript" if kind=="javascript" else kind
    if language in ("python","pico","javascript","cpp","arduino","esp32"):
        content = board_comment_checklist(language, "Choose board") + content
    p.write_text(content)
    print(color("Created:", "GREEN"),p)
    if kind=="python":
        print("Suggested setup: python3 -m venv .venv && source .venv/bin/activate")
    if kind in ("arduino","esp32","pico"):
        print("Board helper: boards <describe the project>")
    log("create",kind=kind,file=str(p))

def interactive_boards():
    banner("Board Selector", "Pick the board by what you want to build, not by part-number knowledge.")
    options=[
      ("1","Arduino Uno R3","5V beginner board — LEDs, buttons, sensors, basic motors"),
      ("2","Arduino Nano","Small Arduino — similar use cases to Uno in a compact package"),
      ("3","Arduino Mega 2560","Lots of pins — larger projects with many sensors or serial devices"),
      ("4","ESP32","Wi-Fi + Bluetooth — IoT, web controls, wireless sensors"),
      ("5","ESP8266","Wi-Fi-focused projects where a smaller MCU is enough"),
      ("6","Raspberry Pi Pico / RP2040","Low-cost microcontroller — MicroPython or C/C++"),
      ("7","Raspberry Pi Pico 2 / RP2350","Newer Pico family — more capable MCU projects"),
      ("8","Raspberry Pi","Full Linux computer — Python, C++, Node, GPIO, camera"),
      ("9","BBC micro:bit","Education-friendly board — Python or MakeCode"),
    ]
    choice=menu_choice("Choose a board",options)
    name,_,reason=BOARDS[int(choice)-1]
    tools={
      "Arduino Uno R3":"Arduino IDE / arduino-cli",
      "Arduino Nano":"Arduino IDE / arduino-cli",
      "Arduino Mega 2560":"Arduino IDE / arduino-cli",
      "ESP32":"Arduino / PlatformIO / ESP-IDF",
      "ESP8266":"Arduino / PlatformIO",
      "Raspberry Pi Pico / RP2040":"MicroPython / Pico SDK / Arduino",
      "Raspberry Pi Pico 2 / RP2350":"MicroPython / Pico SDK / Arduino",
      "Raspberry Pi":"Debian Linux toolchain",
      "BBC micro:bit":"MicroPython / MakeCode",
    }[name]
    print("\n"+color(name,"GREEN"))
    print(color("Why it fits:","CYAN"),reason)
    print(color("Common tools:","CYAN"),tools)
    print(color("Tip:","YELLOW"),"Verify the exact board revision, voltage, pins, and peripherals before wiring hardware.")
    log("board_select",board=name)

def remember(error,solution):
    db=load(DB,{"solutions":[],"projects":[]})
    db["solutions"].append({"error":error,"solution":solution,
                            "time":datetime.now().isoformat(timespec="seconds")})
    save(DB,db); print("Saved permanently:",DB); log("remember",error=error)

def run_command(command):
    cfg=load(CFG,DEFAULT_CFG)
    print("Proposed command:")
    print("  "+command)
    if not cfg.get("execute_commands",True):
        print("Command execution is disabled in configuration.")
        return
    if input("Run it? [y/N] ").strip().lower()!="y":
        print("Skipped.")
        return
    try:
        p=subprocess.run(command,shell=True,text=True,capture_output=True)
        if p.stdout: print(p.stdout,end="")
        if p.stderr: print(p.stderr,end="",file=sys.stderr)
        combined=(p.stdout or "")+"\n"+(p.stderr or "")
        if p.returncode:
            print(f"\nProcess exited with code {p.returncode}.")
        error_report(combined)
        log("command",command=command,returncode=p.returncode)
    except Exception as exc:
        print("Execution failure:",exc)

def plugin_help_text():
    banner("CROS Plugins", "See what plugin tools CROS can load and how plugin releases are installed")
    print(color("To view plugin information:", "CYAN"))
    print("  cros-assist plugins")
    print("  cros-assist --gui")
    print()
    print(color("Current plugin directory:", "CYAN"))
    print(f"  {PLUGIN_DIR}")
    print()
    print("CROS plugins are distributed as separate trusted release bundles. Place the plugin")
    print("release in ChromeOS' Linux files, extract it, and run the release installer.")
    print("Plugins are then loaded from the directory above.")
    print()
    print(color("Currently completed CROS plugin families:", "CYAN"))
    for name in [
        "CNC / PCB Manufacturing",
        "Logic Analyzer + Board Datasheet",
        "Pin Planner",
        "Electronics Calculator + KiCad BOM",
        "KiCad Assistant",
    ]:
        print("  - " + name)
    print()
    print("Only install plugin bundles you trust; plugin Python runs with your user permissions.")

def help_text():
    banner("CROS Debian Assistant", "Natural-language terminal, coding, hardware, and error help")
    print(color("Natural language:", "CYAN"))
    print("  Type a plain-English request. The assistant detects coding, Linux, hardware and error-related intent.")
    print("\n"+color("Coding:", "CYAN"))
    print("  new python [file.py]")
    print("  new cpp [file.cpp]        ← guided C++ formatting/setup wizard")
    print("  new javascript [app.js]")
    print("  new arduino [sketch.ino]")
    print("  new esp32 [sketch.ino]")
    print("  new pico [main.py]")
    print("  inspect")
    print("\n"+color("Hardware:", "CYAN"))
    print("  boards                     ← searchable commercial board selector")
    print("  boards <project description>   ← natural-language board matching")
    print("  GUI Upload page             ← choose file + board + serial port together")
    print("\n"+color("Errors:", "CYAN"))
    print("  Paste a complete error/log.")
    print("  errors")
    print("  repeat")
    print("  remember <error> => <solution>")
    print("\n"+color("System:", "CYAN"))
    print("  doctor")
    print("  plugins                    ← plugin information and installation guidance")
    print("  run <command>")
    print("\n"+color("Persistence:", "CYAN"))
    print("  ~/.cros-debian-assistant/")
    print("  cros-assist --reset-knowledge")
    print("  cros-assist --uninstall")

def doctor():
    print("=== CROS Debian Assistant Doctor ===")
    print("Python:",sys.version.split()[0])
    print("Working directory:",Path.cwd())
    print("Assistant data:",ROOT)
    for cmd in ["python3","python3-config","git","curl","wget","ssh",
                "gcc","g++","clang-format","make","cmake","node","npm","arduino-cli"]:
        print(f"{cmd:16}",shutil.which(cmd) or "not installed")
    print("\nStorage:")
    try:
        u=shutil.disk_usage(Path.home())
        print(f"  total={u.total//(1024**3)} GiB free={u.free//(1024**3)} GiB")
    except Exception: pass
    log("doctor")

def handle(q):
    raw=q.strip(); n=norm(raw)
    if not raw:return
    if n in ("help","?"): help_text(); return
    if n in ("plugins","plugin help","plugin info","cros plugins","cros plugin"): plugin_help_text(); return
    if n in ("exit","quit"): raise SystemExit
    if n=="doctor": doctor(); return
    if n=="inspect" or n.startswith("inspect "): inspect_project(); return
    if n=="errors":
        print("Recognized built-in error families:")
        for x in sorted(ERRORS): print(" -",x)
        return
    if n=="repeat":
        db=load(DB,{"solutions":[],"projects":[]})
        if not db["solutions"]: print("No alternate solutions have been remembered.")
        for x in db["solutions"][-25:]:
            print(f"[{x['error']}] {x['solution']}")
        return
    if n.startswith("remember "):
        m=re.match(r"remember\s+(.+?)\s*=>\s*(.+)",raw,re.I)
        if not m: print("Use: remember <error> => <solution>")
        else: remember(m.group(1),m.group(2))
        return
    if n in ("boards","board","select board","board select"):
        interactive_boards(); return
    if n.startswith("boards"):
        desc=raw[6:].strip()
        r=board_match(desc)
        if not r:
            print(color("I couldn't narrow it down yet.", "YELLOW"))
            print("Try `boards` for the guided selector, or describe Wi-Fi/Bluetooth, voltage, sensors, motors, GPIO, and programming language.")
        else:
            banner("Board Match", "These are matches to your project description; this is not a wiring guarantee.")
            for i,(score,name,reason) in enumerate(r[:6],1):
                print(f"  {color(str(i), 'YELLOW')}. {color(name, 'BOLD')} — {reason}")
        return
    if n.startswith("new "):
        parts=raw.split(None,2); kind=parts[1].lower()
        aliases={"py":"python","python":"python","cpp":"cpp","c++":"cpp",
                 "js":"javascript","javascript":"javascript","node":"javascript",
                 "arduino":"arduino","esp32":"esp32","pico":"pico"}
        if kind in aliases:
            create_file(aliases[kind],parts[2] if len(parts)>2 else None); return
    if n.startswith("format"):
        parts=raw.split()
        if len(parts)<2:
            print("Use: format <file.cpp> [board]")
            print("Boards: arduino, esp32, pico, raspberry pi, desktop")
        else:
            format_cpp_file(parts[1], " ".join(parts[2:]) if len(parts)>2 else None)
        return
    if n.startswith("run "):
        run_command(raw[4:].strip()); return
    if error_report(raw): return

    intents=[]
    if any(x in n for x in ["python","pip","venv"]): intents.append("Python")
    if any(x in n for x in ["c++","cpp","gcc","g++","cmake"]): intents.append("C/C++")
    if any(x in n for x in ["node","npm","javascript","js"]): intents.append("JavaScript/Node")
    if any(x in n for x in ["arduino","uno","nano","mega"]): intents.append("Arduino")
    if any(x in n for x in ["esp32","esp8266","wifi","bluetooth","iot"]): intents.append("IoT/ESP")
    if any(x in n for x in ["pico","rp2040","rp2350","micropython"]): intents.append("Pico/MicroPython")
    if any(x in n for x in ["git","github","branch","commit"]): intents.append("Git")
    if intents: print("Detected intent:",", ".join(dict.fromkeys(intents)))
    else: print("Detected intent: general terminal/coding assistance")
    print("Try `help`, `inspect`, `boards <project>`, or paste the complete error.")


def gui_write_clang_format(profile, overwrite=False):
    p=BOARD_FORMATS.get(profile, BOARD_FORMATS["desktop"])
    target=Path(".clang-format")
    if target.exists() and not overwrite:
        return False
    indent=p["indent"]
    tabs=p["tabs"]
    braces=p["brace"]
    column=p["column"]
    tab_mode="ForIndentation" if tabs else "Never"
    cfg=(
        f"BasedOnStyle: {p['style']}\n"
        f"IndentWidth: {indent}\n"
        f"UseTab: {tab_mode}\n"
        f"BreakBeforeBraces: {braces}\n"
        f"ColumnLimit: {column}\n"
        "IncludeBlocks: Preserve\n"
        "AllowShortFunctionsOnASingleLine: Empty\n"
        + "\n".join(p["extra"]) + "\n"
    )
    target.write_text(cfg)
    return True


def gui_main():
    import tkinter as tk
    from tkinter import ttk, messagebox, filedialog, simpledialog
    import threading
    import queue

    class CrosGUI:
        def __init__(self, root):
            self.root=root
            self.root.title("CROS Debian Assistant")
            self.root.geometry("1040x720")
            self.root.minsize(900,620)
            self.root.configure(bg="#0b1020")
            self.q=queue.Queue()
            self.proc=None
            self.dot_phase=0
            self.gui_cfg=load(CFG, dict(DEFAULT_CFG))
            self.plugin_records=discover_plugins()
            self.selected_board_name=self.gui_cfg.get("selected_board", "")
            # Backward compatibility: older versions saved only the board name.
            # If that name is from the built-in catalog, migrate it to the full
            # board record immediately; PlatformIO selections are already saved
            # as selected_board_info by v18.
            if not self.gui_cfg.get("selected_board_info") and self.selected_board_name:
                legacy_board = commercial_board(self.selected_board_name)
                if legacy_board:
                    self.gui_cfg["selected_board_info"] = dict(legacy_board)
                    save(CFG, self.gui_cfg)
            self._setup_style(ttk)
            self._build()
            self._animate()
            self._poll_queue()
            self.show_home()

        def _setup_style(self, ttk):
            s=ttk.Style()
            try: s.theme_use("clam")
            except Exception: pass
            s.configure("Panel.TFrame", background="#11182b")
            s.configure("Card.TFrame", background="#17213a")