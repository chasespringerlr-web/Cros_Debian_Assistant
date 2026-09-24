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
            s.configure("Title.TLabel", background="#0b1020", foreground="#f4f7ff", font=("TkDefaultFont",18,"bold"))
            s.configure("Sub.TLabel", background="#0b1020", foreground="#a9b6d3", font=("TkDefaultFont",10))
            s.configure("CardTitle.TLabel", background="#17213a", foreground="#ffffff", font=("TkDefaultFont",12,"bold"))
            s.configure("CardText.TLabel", background="#17213a", foreground="#b9c4dd", font=("TkDefaultFont",9))
            s.configure("Nav.TButton", padding=(12,9), font=("TkDefaultFont",10,"bold"))
            s.configure("Action.TButton", padding=(14,10), font=("TkDefaultFont",10,"bold"))
            s.configure("Accent.TButton", padding=(16,11), font=("TkDefaultFont",10,"bold"))
            s.configure("Selected.TLabel", background="#102b1c", foreground="#57e389", font=("TkDefaultFont",10,"bold"), padding=(10,7))
            s.configure("CodeSelected.TLabel", background="#11263b", foreground="#72d9ff", font=("TkDefaultFont",10,"bold"), padding=(10,7))
            s.configure("CodeHint.TLabel", background="#17213a", foreground="#a9b6d3", font=("TkDefaultFont",9))

        def _build(self):
            outer=ttk.Frame(self.root, style="Panel.TFrame")
            outer.pack(fill="both",expand=True)
            header=tk.Frame(outer,bg="#0b1020",height=72)
            header.pack(fill="x")
            header.pack_propagate(False)
            left=tk.Frame(header,bg="#0b1020")
            left.pack(side="left",fill="both",expand=True)
            tk.Label(left,text="CROS Debian Assistant",bg="#0b1020",fg="#ffffff",font=("TkDefaultFont",18,"bold")).pack(anchor="w",padx=20,pady=(13,0))
            tk.Label(left,text="Your terminal, with a visual control panel",bg="#0b1020",fg="#9fb0d3",font=("TkDefaultFont",10)).pack(anchor="w",padx=21)
            self.status=tk.Label(header,text="● Ready",bg="#0b1020",fg="#57e389",font=("TkDefaultFont",10,"bold"))
            self.status.pack(side="right",padx=20)
            self.console_hidden=bool(self.gui_cfg.get("hide_cros_terminal",False))
            self.console_toggle=ttk.Button(header,text=("Show CROS Terminal" if self.console_hidden else "Hide CROS Terminal"),
                                           command=self.toggle_terminal_panel)
            self.console_toggle.pack(side="right",padx=(0,10))

            body=ttk.Frame(outer,style="Panel.TFrame")
            body.pack(fill="both",expand=True,padx=12,pady=10)

            # Scrollable sidebar: every navigation control lives inside a
            # dedicated canvas so the sidebar itself can grow without being
            # clipped on smaller displays. Trackpad/mouse wheel scrolling is
            # handled for the whole sidebar, including when the pointer is
            # over a button.
            nav_shell=ttk.Frame(body,style="Panel.TFrame",width=200)
            nav_shell.pack(side="left",fill="y",padx=(0,10))
            nav_shell.pack_propagate(False)
            self.nav_canvas=tk.Canvas(nav_shell,bg="#11182b",highlightthickness=0,bd=0,width=180)
            self.nav_scroll=ttk.Scrollbar(nav_shell,orient="vertical",command=self.nav_canvas.yview)
            self.nav_canvas.configure(yscrollcommand=self.nav_scroll.set)
            self.nav_canvas.pack(side="left",fill="both",expand=True)
            self.nav_scroll.pack(side="right",fill="y")
            nav=ttk.Frame(self.nav_canvas,style="Panel.TFrame")
            self.nav_window=self.nav_canvas.create_window((0,0),window=nav,anchor="nw")

            def _nav_resize(event):
                self.nav_canvas.itemconfigure(self.nav_window,width=event.width)
                self.nav_canvas.configure(scrollregion=self.nav_canvas.bbox("all"))
            nav.bind("<Configure>",_nav_resize)
            self.nav_canvas.bind("<Configure>",_nav_resize)

            self.nav=nav
            self.nav_shell=nav_shell
            self.rebuild_navigation()

            def _nav_wheel(event):
                widget=self.root.winfo_containing(event.x_root,event.y_root)
                while widget is not None:
                    if widget == nav or widget == self.nav_canvas:
                        if getattr(event,"delta",0):
                            raw=event.delta
                            step=-max(1,min(6,round(abs(raw)/120))) if raw>0 else max(1,min(6,round(abs(raw)/120)))
                            self.nav_canvas.yview_scroll(step,"units")
                        elif getattr(event,"num",None)==4:
                            self.nav_canvas.yview_scroll(-1,"units")
                        elif getattr(event,"num",None)==5:
                            self.nav_canvas.yview_scroll(1,"units")
                        return "break"
                    try:
                        widget=widget.master
                    except Exception:
                        break
                return None

            self.root.bind_all("<MouseWheel>",_nav_wheel,add="+")
            self.root.bind_all("<Button-4>",_nav_wheel,add="+")
            self.root.bind_all("<Button-5>",_nav_wheel,add="+")

            main=ttk.Frame(body,style="Panel.TFrame")
            main.pack(side="left",fill="both",expand=True)

            # All application pages share one scrollable content surface.
            # This avoids page-by-page scrollbar bugs and makes trackpad
            # scrolling work consistently across Home, C++, Boards,
            # Formatting, Watchdog, Doctor, and future pages.
            self.content_canvas=tk.Canvas(main,bg="#11182b",highlightthickness=0,bd=0)
            self.content_scroll=ttk.Scrollbar(main,orient="vertical",command=self.content_canvas.yview)
            self.content_canvas.configure(yscrollcommand=self.content_scroll.set)
            self.content_canvas.pack(side="left",fill="both",expand=True)
            self.content_scroll.pack(side="right",fill="y")
            self.content=ttk.Frame(self.content_canvas,style="Panel.TFrame")
            self.content_window=self.content_canvas.create_window((0,0),window=self.content,anchor="nw")

            def _content_resize(event):
                self.content_canvas.itemconfigure(self.content_window,width=event.width)
                self.content_canvas.configure(scrollregion=self.content_canvas.bbox("all"))
            self.content.bind("<Configure>",_content_resize)
            self.content_canvas.bind("<Configure>",_content_resize)

            # Trackpad/mouse-wheel input varies on Linux: some desktops emit
            # MouseWheel deltas while others use Button-4/Button-5. Handle
            # all of them and bind at the application level so new pages
            # inherit scrolling automatically.
            def _content_wheel(event):
                widget=self.root.winfo_containing(event.x_root,event.y_root)
                while widget is not None:
                    if widget == self.content or widget == self.content_canvas:
                        if getattr(event,"delta",0):
                            raw=event.delta
                            step=-max(1,min(6,round(abs(raw)/120))) if raw>0 else max(1,min(6,round(abs(raw)/120)))
                            self.content_canvas.yview_scroll(step,"units")
                        elif getattr(event,"num",None)==4:
                            self.content_canvas.yview_scroll(-1,"units")
                        elif getattr(event,"num",None)==5:
                            self.content_canvas.yview_scroll(1,"units")
                        return "break"
                    try:
                        widget=widget.master
                    except Exception:
                        break
                return None

            self.root.bind_all("<MouseWheel>",_content_wheel,add="+")
            self.root.bind_all("<Button-4>",_content_wheel,add="+")
            self.root.bind_all("<Button-5>",_content_wheel,add="+")

            self.console_frame=ttk.Frame(outer,style="Panel.TFrame")
            self.console_frame.pack(fill="x",padx=12,pady=(0,10))
            console_frame=self.console_frame
            row=ttk.Frame(console_frame,style="Panel.TFrame")
            row.pack(fill="x")
            ttk.Label(row,text="Terminal command",style="Sub.TLabel").pack(side="left",padx=(0,8))
            self.command_var=tk.StringVar()
            entry=ttk.Entry(row,textvariable=self.command_var)
            entry.pack(side="left",fill="x",expand=True)
            entry.bind("<Return>",lambda e:self.execute_entry())
            ttk.Button(row,text="Run",style="Action.TButton",command=self.execute_entry).pack(side="left",padx=(8,0))
            self.output=tk.Text(console_frame,height=10,bg="#080d18",fg="#dce6ff",insertbackground="#ffffff",relief="flat",font=("TkFixedFont",9))
            self.output.pack(fill="x",pady=(8,0))
            self.output.tag_configure("error",foreground="#ff6b6b")
            self.output.tag_configure("ok",foreground="#57e389")
            self.output.tag_configure("warn",foreground="#ffd166")
            self.output.tag_configure("cmd",foreground="#72a7ff")

        def rebuild_navigation(self):
            for w in self.nav.winfo_children():
                w.destroy()
            nav_items=[
                ("Home",self.show_home),
                ("Make Code",self.show_cpp),
                ("Boards",self.show_boards),
                ("Upload",self.show_upload),
                ("Format Code",self.show_format),
                ("Watchdog",self.show_watchdog),
                ("Doctor",self.show_doctor),
                ("Plugins",self.show_plugins),
            ]
            for label,cmd in nav_items:
                ttk.Button(self.nav,text=label,style="Nav.TButton",command=cmd).pack(fill="x",pady=4)
            enabled=[p for p in self.plugin_records if p.get("enabled") and not p.get("error")]
            if enabled:
                ttk.Separator(self.nav,orient="horizontal").pack(fill="x",pady=10)
                ttk.Label(self.nav,text="PLUGIN TOOLS",style="Sub.TLabel").pack(anchor="w",padx=10,pady=(0,4))
                for plugin in enabled:
                    ttk.Button(self.nav,text="↗ " + plugin["name"],style="Nav.TButton",command=lambda pl=plugin:self.open_plugin(pl)).pack(fill="x",pady=3)
            ttk.Separator(self.nav,orient="horizontal").pack(fill="x",pady=10)
            ttk.Button(self.nav,text="Clear Output",command=self.clear_output).pack(fill="x",pady=3)
            ttk.Button(self.nav,text="Quit Window",command=self.root.destroy).pack(fill="x",pady=3)
            try:
                self.nav.update_idletasks()
                self.nav_canvas.configure(scrollregion=self.nav_canvas.bbox("all"))
            except Exception:
                pass

        def open_plugin(self, plugin):
            try:
                entry=plugin.get("entry")
                if not entry or not Path(entry).exists():
                    raise FileNotFoundError("plugin entry file is missing")
                module_name="cros_plugin_" + _safe_plugin_id(plugin.get("id"))
                spec=importlib.util.spec_from_file_location(module_name, str(entry))
                if spec is None or spec.loader is None:
                    raise ImportError("could not create a plugin loader")
                module=importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)

                # New standard: render directly inside CROS's main content area.
                panel_name=plugin.get("panel_entry") or "build_panel"
                panel_builder=getattr(module,panel_name,None)
                if callable(panel_builder):
                    self._clear_content()
                    self._title(plugin.get("name",plugin.get("id","Plugin")),plugin.get("description","Inline CROS plugin"))
                    result=panel_builder(self.content,self)
                    if result is not None:
                        try:
                            result.pack_configure(fill="both",expand=True)
                        except Exception:
                            pass
                    self.log_line(f"Opened plugin panel: {plugin.get('name', plugin.get('id'))}","ok")
                    return

                # Backward compatibility for older plugins.
                opener=getattr(module,"open_window",None)
                if not callable(opener):
                    raise AttributeError("plugin.py must define build_panel(parent, gui) or open_window(root, gui)")
                result=opener(self.root,self)
                if result is not None:
                    try: result.lift()
                    except Exception: pass
                self.log_line(f"Opened legacy plugin window: {plugin.get('name', plugin.get('id'))}","ok")
            except Exception as exc:
                detail=traceback.format_exc()
                self.log_line(f"Plugin error: {exc}","error")
                print("[cros-plugin] " + detail, file=sys.stderr, flush=True)
                messagebox.showerror("Plugin error",f"{plugin.get('name', plugin.get('id','Plugin'))} could not be opened.\\n\\n{exc}\\n\\nSee the terminal for details.")
        def _write_plugin_manifest(self, plugin, enabled):
            try:
                data=load(plugin["manifest"],{})
                data["enabled"]=bool(enabled)
                save(plugin["manifest"],data)
                return True
            except Exception as exc:
                messagebox.showerror("Plugin update failed",str(exc))
                return False

        def create_plugin_from_gui(self):
            name=simpledialog.askstring("New CROS Plugin","Plugin window name:",parent=self.root)
            if not name: return
            pid=simpledialog.askstring("New CROS Plugin","Plugin ID (letters, numbers, - or _):",initialvalue=_safe_plugin_id(name),parent=self.root)
            if not pid: return
            desc=simpledialog.askstring("New CROS Plugin","What should this window do?",initialvalue="Custom CROS function",parent=self.root) or "Custom CROS function"
            folder=create_plugin_template(pid,name,desc)
            self.plugin_records=discover_plugins()
            self.rebuild_navigation()
            messagebox.showinfo("Plugin created",f"Created:\\n{folder}\\n\\nEdit plugin.py to build your window. It will appear in the sidebar now.")

        def show_plugins(self):
            self._clear_content(); self._title("Plugins","Add integrated CROS tools that run inside the main window.")
            intro=ttk.Frame(self.content,style="Card.TFrame"); intro.pack(fill="x",pady=(0,8))
            ttk.Label(intro,text="CROS Plugin Tools",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            ttk.Label(intro,text=f"Plugin folder: {PLUGIN_DIR}",style="CardText.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=(0,4))
            ttk.Label(intro,text="Plugins are embedded in the main CROS window and can use the same terminal environment through the CROS GUI command runner. Legacy window plugins remain supported. Only install plugins you trust; plugin Python runs with your user permissions.",style="CardText.TLabel",wraplength=820,justify="left").pack(anchor="w",padx=14,pady=(0,10))
            actions=ttk.Frame(intro,style="Card.TFrame"); actions.pack(fill="x",padx=14,pady=(0,12))
            ttk.Button(actions,text="Create Plugin Template",style="Accent.TButton",command=self.create_plugin_from_gui).pack(side="left")
            ttk.Button(actions,text=("Show CROS Terminal" if self.console_hidden else "Hide CROS Terminal"),command=self.toggle_terminal_panel).pack(side="left",padx=8)
            ttk.Button(actions,text="Open Plugin Folder",command=lambda: subprocess.Popen(["xdg-open",str(PLUGIN_DIR)]) if shutil.which("xdg-open") else messagebox.showinfo("Plugin folder",str(PLUGIN_DIR))).pack(side="left",padx=8)
            ttk.Button(actions,text="Reload Plugins",command=self.reload_plugins).pack(side="left")
            if not self.plugin_records:
                self._card(self.content,"No plugins installed","Create a plugin template to get started. Your new window will appear in the sidebar.")
                return
            for plugin in self.plugin_records:
                card=ttk.Frame(self.content,style="Card.TFrame"); card.pack(fill="x",pady=5)
                title=f"{'✓' if plugin.get('enabled') and not plugin.get('error') else '○'} {plugin.get('name',plugin.get('id','Plugin'))}"
                ttk.Label(card,text=title,style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(10,3))
                meta=f"v{plugin.get('version','?')}  •  {plugin.get('author','Local plugin')}  •  {plugin.get('id','')}"
                ttk.Label(card,text=meta,style="CardText.TLabel").pack(anchor="w",padx=14,pady=(0,3))
                ttk.Label(card,text=plugin.get('description',''),style="CardText.TLabel",wraplength=820,justify="left").pack(anchor="w",padx=14,pady=(0,8))
                if plugin.get('error'):
                    ttk.Label(card,text="⚠ " + plugin['error'],style="CodeHint.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=(0,8))
                buttons=ttk.Frame(card,style="Card.TFrame"); buttons.pack(fill="x",padx=14,pady=(0,10))
                if not plugin.get('error'):
                    ttk.Button(buttons,text="Open Tool",command=lambda pl=plugin:self.open_plugin(pl)).pack(side="left")
                    ttk.Button(buttons,text=("Disable" if plugin.get('enabled') else "Enable"),command=lambda pl=plugin:self.toggle_plugin(pl)).pack(side="left",padx=8)

        def toggle_plugin(self, plugin):
            enabled=not bool(plugin.get('enabled'))
            if self._write_plugin_manifest(plugin,enabled):
                self.plugin_records=discover_plugins()
                self.rebuild_navigation()
                self.show_plugins()

        def reload_plugins(self):
            self.plugin_records=discover_plugins()
            self.rebuild_navigation()
            self.show_plugins()

        def _clear_content(self):
            for w in self.content.winfo_children(): w.destroy()
            self.content_canvas.yview_moveto(0)

        def _title(self,title,subtitle):
            ttk.Label(self.content,text=title,style="Title.TLabel").pack(anchor="w")
            ttk.Label(self.content,text=subtitle,style="Sub.TLabel").pack(anchor="w",pady=(3,14))

        def _card(self,parent,title,text,command=None):
            card=ttk.Frame(parent,style="Card.TFrame")
            card.pack(fill="x",pady=6)
            ttk.Label(card,text=title,style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            ttk.Label(card,text=text,style="CardText.TLabel",wraplength=700,justify="left").pack(anchor="w",padx=14,pady=(0,10))
            if command:
                ttk.Button(card,text="Open",style="Action.TButton",command=command).pack(anchor="e",padx=14,pady=(0,12))
            return card

        def _active_board(self):
            # Boards is the single source of truth. Keep the complete selected
            # board record so PlatformIO-discovered boards work everywhere,
            # even when they are not part of CROS's fallback catalog.
            saved_board = self.gui_cfg.get("selected_board_info")
            if isinstance(saved_board, dict) and saved_board.get("name"):
                return saved_board
            if not self.selected_board_name:
                return None
            return commercial_board(self.selected_board_name)

        def _default_code_type(self, board, allowed=None):
            preferred=(board or {}).get("native_code") or "cpp"
            allowed=set(allowed or [])
            if allowed and preferred not in allowed:
                preferred="cpp" if "cpp" in allowed else next(iter(allowed))
            return preferred

        def _set_active_board(self, board):
            if board:
                board=dict(board)
                board["native_code"]=self._default_code_type(board)
                self.selected_board_name = board.get("name", "")
                self.gui_cfg["selected_board"] = self.selected_board_name
                self.gui_cfg["selected_board_info"] = dict(board)
                self.gui_cfg["selected_code_type"] = board.get("native_code", "cpp")
            else:
                self.selected_board_name = ""
                self.gui_cfg.pop("selected_board", None)
                self.gui_cfg.pop("selected_board_info", None)
            save(CFG, self.gui_cfg)
            if self.selected_board_name:
                self.log_line(f"Active board set to: {self.selected_board_name}", "ok")
            else:
                self.log_line("Active board cleared.", "warn")

        def _require_active_board(self):
            board=self._active_board()
            if board:
                return board
            messagebox.showinfo("Choose a board first", "Open Boards, select the board you are actually using, then return to this page. The selected board controls code generation, formatting, and upload settings.")
            self.show_boards()
            return None

        def show_home(self):
            self._clear_content(); self._title("Control Center","Pick an action instead of remembering commands.")
            welcome=ttk.Frame(self.content,style="Card.TFrame"); welcome.pack(fill="x",pady=(0,8))
            ttk.Label(welcome,text="Welcome to CROS Debian Assistant",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            welcome_text=(
                "CROS is a visual control panel and terminal assistant for your ChromeOS Debian machine. "
                "Use the sidebar to work with boards, code, uploads, diagnostics, and installed plugins.\n\n"
                "Open CROS from the Debian Terminal anytime by typing:  cros\n"
                "For terminal-based help, type:  cros-assist help\n"
                "To see available plugin information and installation guidance, type:  cros-assist plugins"
            )
            ttk.Label(welcome,text=welcome_text,style="CardText.TLabel",wraplength=820,justify="left").pack(anchor="w",padx=14,pady=(0,12))
            active=self._active_board()
            board_text=(f"✓ {active['name']} is the active board. Make Code, Format Code, and Upload use this selection." if active else "No board is selected yet. Choose one in Boards to make it the source of truth for coding, formatting, and upload.")
            self._card(self.content,"Active Board",board_text,self.show_boards)
            grid=ttk.Frame(self.content,style="Panel.TFrame"); grid.pack(fill="x")
            self._card(grid,"Make Code","Use the board selected in Boards, choose a compatible code type, then create and format the file.",self.show_cpp)
            self._card(grid,"Board Guide","Search commercial board names, choose one, and see its common development tools and capabilities.",self.show_boards)
            self._card(grid,"Upload to Board","Pick a file and serial port; the board selected in Boards supplies the upload target.",self.show_upload)
            self._card(grid,"Watchdog","See recent errors, get remembered solutions, and run a safe watchdog test.",self.show_watchdog)
            self._card(grid,"Format Code","Format an existing source/header file using the board selected in Boards.",self.show_format)

        def _make_code_types(self, board):
            # PlatformIO project sources include .c, .cpp, .S, .ino, and other
            # source forms. The official docs call out these common extensions;
            # .ino is only presented here when the selected board uses an Arduino
            # framework family where that form makes sense.
            family=(board or {}).get("family","").lower()
            types=[
                ("cpp","C++ source (.cpp)","PlatformIO source file — C++"),
                ("c","C source (.c)","PlatformIO source file — C"),
                ("asm","Assembly (.S)","PlatformIO source file — assembly; toolchain-specific"),
            ]
            if family in {"arduino","esp32","esp8266","pico"} or "arduino" in family:
                types.insert(2,("ino","Arduino sketch (.ino)","PlatformIO source file — Arduino sketch"))
            return types

        @staticmethod
        def _code_display_name(code_key):
            return {
                "cpp":"C++ source (.cpp)",
                "c":"C source (.c)",
                "ino":"Arduino sketch (.ino)",
                "asm":"Assembly (.S)",
            }.get(code_key, code_key.upper())

        def _set_code_type_widget(self, combo, code_key, type_map, selected_var, selected_banner, help_var):
            """Set both the Combobox's actual selection and its persistent visual cue."""
            label=None
            for candidate,(key,desc) in type_map.items():
                if key==code_key:
                    label=candidate
                    break
            if label is None and type_map:
                label=next(iter(type_map))
                code_key,desc=type_map[label]
            if label is None:
                return
            labels=list(type_map.keys())
            try:
                idx=labels.index(label)
                combo.current(idx)
            except ValueError:
                combo.set(label)
            selected_var.set(f"✓ Selected code type: {label}")
            selected_banner.set(f"Code type: {label}")
            try:
                _,desc=type_map[label]
            except Exception:
                desc="PlatformIO source type"
            help_var.set(desc)
            self.gui_cfg["selected_code_type"]=code_key
            save(CFG,self.gui_cfg)

        def show_cpp(self):
            self._clear_content(); self._title("Make Code","Boards is the source of truth: its selected board supplies the default code type. The dropdown and the visible selection banner always stay synchronized.")
            form=ttk.Frame(self.content,style="Card.TFrame"); form.pack(fill="x")

            board=self._active_board()
            ttk.Label(form,text="Active board",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            board_var=tk.StringVar(value=(f"✓ {board['name']}" if board else "No board selected"))
            ttk.Label(form,textvariable=board_var,style="Selected.TLabel").pack(anchor="w",padx=14,pady=(2,3))
            if board:
                ttk.Label(form,text=f"Board default code type: {self._code_display_name(board.get('native_code','cpp'))}",style="CodeHint.TLabel").pack(anchor="w",padx=14,pady=(4,6))
                ttk.Label(form,text=f"Formatting profile: {board.get('profile','desktop')} — controlled by Boards.",style="CardText.TLabel").pack(anchor="w",padx=14,pady=(0,8))
                ttk.Button(form,text="Change Board in Boards",command=self.show_boards).pack(anchor="w",padx=14,pady=(0,8))
            else:
                ttk.Label(form,text="Select a commercial board in Boards before creating code. That selection controls the default code type, formatting profile, and upload target throughout CROS.",style="CardText.TLabel",wraplength=720).pack(anchor="w",padx=14,pady=(0,8))
                ttk.Button(form,text="Open Boards",style="Accent.TButton",command=self.show_boards).pack(anchor="w",padx=14,pady=(0,10))
                return

            ttk.Label(form,text="Code type",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            code_type_var=tk.StringVar()
            code_combo=ttk.Combobox(form,textvariable=code_type_var,state="readonly")
            code_combo.pack(fill="x",padx=14)
            selected_code_var=tk.StringVar(value="")
            ttk.Label(form,textvariable=selected_code_var,style="CodeSelected.TLabel").pack(fill="x",padx=14,pady=(6,3))
            code_help=tk.StringVar()
            ttk.Label(form,textvariable=code_help,style="CodeHint.TLabel",wraplength=720,justify="left").pack(fill="x",padx=14,pady=(3,8))

            pio_text=("PlatformIO's documented project source directory accepts common source forms including .h, .c, .cpp, .S, and .ino. "
                      "CROS exposes the useful source-code choices for the active board and makes the selected value visible both in the dropdown and the persistent cue below it.")
            ttk.Label(form,text=pio_text,style="CardText.TLabel",wraplength=720,justify="left").pack(anchor="w",padx=14,pady=(0,10))

            ttk.Label(form,text="File name",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            name_var=tk.StringVar(value="main.cpp"); ttk.Entry(form,textvariable=name_var).pack(fill="x",padx=14)
            indent_var=tk.StringVar(value="preset")
            ttk.Label(form,text="Indentation",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            for k,t in [("preset","Use board preset"),("4","4 spaces"),("2","2 spaces"),("tab","Tabs")]:
                ttk.Radiobutton(form,text=t,variable=indent_var,value=k).pack(anchor="w",padx=18,pady=2)
            brace_var=tk.StringVar(value="preset")
            ttk.Label(form,text="Opening braces",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            for k,t in [("preset","Use board preset"),("attach","Same line: int main() {"),("allman","New line")]:
                ttk.Radiobutton(form,text=t,variable=brace_var,value=k).pack(anchor="w",padx=18,pady=2)

            type_map={}
            defaults={"cpp":"main.cpp","c":"main.c","ino":"sketch.ino","asm":"main.S"}
            choices=self._make_code_types(board)
            for key,label,desc in choices:
                type_map[label]=(key,desc)
            labels=list(type_map.keys())
            code_combo["values"]=labels
            allowed=[key for key,_,_ in choices]
            preferred=self._default_code_type(board, allowed)
            # Boards is authoritative for the default. Keep the saved type in sync
            # with the board before drawing the widget so the actual Tk selection,
            # saved config, and visual cue all agree.
            board_native=board.get("native_code") or preferred
            if board_native not in allowed:
                board_native=preferred
            board=dict(board)
            board["native_code"]=board_native
            self.gui_cfg["selected_board_info"]=dict(board)
            self.gui_cfg["selected_code_type"]=board_native
            save(CFG,self.gui_cfg)
            preferred_label=next((label for key,label,desc in choices if key==board_native), labels[0])
            code_combo.current(labels.index(preferred_label))
            selected_code_var.set(f"✓ Selected code type: {preferred_label}")
            code_help.set(type_map[preferred_label][1])
            name_var.set(defaults[board_native])

            def on_type_change(_=None):
                selected=code_combo.get()
                if selected not in type_map:
                    return
                key,desc=type_map[selected]
                self.gui_cfg["selected_code_type"]=key
                save(CFG,self.gui_cfg)
                selected_code_var.set(f"✓ Selected code type: {selected}")
                code_help.set(desc)
                name_var.set(defaults[key])

            code_combo.bind("<<ComboboxSelected>>",on_type_change)

            def create_clicked():
                selected=code_combo.get()
                key=type_map.get(selected,("cpp","") )[0]
                self._create_code_gui(board["name"],key,name_var.get(),indent_var.get(),brace_var.get())

            ttk.Button(form,text="Create Code + Format",style="Accent.TButton",command=create_clicked).pack(anchor="e",padx=14,pady=14)

        def _create_code_gui(self,board_name,code_type,name,indent_choice,brace_choice):
            board=self._active_board()
            if board and board.get("name") != board_name:
                board=commercial_board(board_name)
            if not board:
                messagebox.showerror("Board not found", "Select a commercial board from the list."); return
            profile=board.get("profile","desktop")
            defaults={"cpp":"main.cpp","c":"main.c","ino":"sketch.ino","asm":"main.S"}
            p=Path(name.strip() or defaults.get(code_type,"main.cpp"))
            if p.exists():
                messagebox.showerror("File exists",f"Refusing to overwrite:\n{p}"); return

            info=BOARD_FORMATS.get(profile,BOARD_FORMATS["desktop"])
            indent=info["indent"] if indent_choice=="preset" else (2 if indent_choice=="2" else 4)
            use_tabs=indent_choice=="tab"
            braces=info["brace"] if brace_choice=="preset" else ("Allman" if brace_choice=="allman" else "Attach")
            checklist=board_comment_checklist("cpp",board_name)

            if code_type=="cpp":
                if board.get("family") in ("arduino","esp32","esp8266"):
                    body="#include <Arduino.h>\n\nvoid setup() {\n  Serial.begin(115200);\n}\n\nvoid loop() {\n  delay(1000);\n}\n"
                elif board.get("family")=="pico":
                    body="#include <cstdio>\n\nint main() {\n    std::printf(\"Hello from Raspberry Pi Pico C++\n\");\n    return 0;\n}\n"
                else:
                    body=TEMPLATES["cpp"][1]
                content=checklist+body
            elif code_type=="c":
                body="#include <stdio.h>\n\nint main(void) {\n    printf(\"Hello from C\n\");\n    return 0;\n}\n"
                content=checklist+body
            elif code_type=="ino":
                content=checklist+"void setup() {\n  Serial.begin(115200);\n}\n\nvoid loop() {\n}\n"
            elif code_type=="asm":
                content=checklist+"/* Board-specific assembly belongs in the appropriate PlatformIO source tree.\n * Replace this placeholder with the instructions for your target architecture.\n */\n"
            else:
                messagebox.showerror("Unsupported code type","Choose one of the code types shown in the Make Code window."); return

            p.write_text(content)
            if code_type in {"cpp","c","ino"}:
                gui_write_clang_format(profile,overwrite=True)
                clang=shutil.which("clang-format")
                if not clang:
                    if messagebox.askyesno("clang-format missing","clang-format is not installed. Install it now?"):
                        self.execute_command("sudo apt-get update && sudo apt-get install -y clang-format",auto_confirm=True,callback=lambda ok:self._format_after_install(p,profile,indent,use_tabs,braces,ok))
                    else:
                        self.log_line("Created file, but left it unformatted because clang-format is not installed.","warn")
                else:
                    self.execute_command(f"clang-format -i {shlex.quote(str(p))}",auto_confirm=True)
            self.log_line(f"Created {p} for {board_name} as {code_type} with a commented project checklist.","ok")

        def _format_after_install(self,p,profile,indent,use_tabs,braces,ok):
            if ok and shutil.which("clang-format"):
                gui_write_clang_format(profile,overwrite=True)
                self.execute_command(f"clang-format -i {shlex.quote(str(p))}",auto_confirm=True)

        def show_boards(self):
            self._clear_content(); self._title("Board Guide","Browse compatible commercial boards in fast 20-item chunks, or search by keywords and ordered characters.")

            # Load a small built-in catalog immediately so the page is responsive.
            # The broader PlatformIO catalog is fetched in the background and
            # replaces/extends this list when ready, so opening the page never
            # blocks on a slow board-catalog query.
            catalog=_fallback_board_catalog()
            catalog=sorted(catalog,key=lambda x:x["name"].casefold())
            state={"catalog":catalog,"full_ready":False,"matches":[],"shown":0,"page_size":20,"loading":True}

            search=tk.StringVar()
            top=ttk.Frame(self.content,style="Card.TFrame"); top.pack(fill="x",pady=(0,8))
            count_var=tk.StringVar(value=f"Showing first {min(20,len(catalog))} of {len(catalog)} available immediately")
            status_var=tk.StringVar(value="Loading the full commercial board catalog in the background…")
            ttk.Label(top,text="Browse every board 20 at a time",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(10,2))
            ttk.Label(top,textvariable=status_var,style="CardText.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=(0,6))
            entry=ttk.Entry(top,textvariable=search); entry.pack(fill="x",padx=14,pady=(0,6))
            ttk.Label(top,text="Search accepts whole keywords, partial words, or characters kept in order. Example: `ardno` can find Arduino.",style="CardText.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=(0,6))
            ttk.Label(top,textvariable=count_var,style="CardText.TLabel").pack(anchor="w",padx=14,pady=(0,4))

            list_wrap=tk.Frame(top,bg="#0b1020")
            list_wrap.pack(fill="both",expand=True,padx=14,pady=(0,10))
            scrollbar=tk.Scrollbar(list_wrap,orient="vertical")
            listbox=tk.Listbox(list_wrap,height=16,bg="#0b1020",fg="#dce6ff",selectbackground="#315ea8",selectforeground="#ffffff",relief="flat",highlightthickness=0)
            listbox.pack(side="left",fill="both",expand=True)
            scrollbar.pack(side="right",fill="y")

            info_box=ttk.Frame(self.content,style="Card.TFrame"); info_box.pack(fill="x",pady=(8,0))
            matches_cache=[]
            matches_cache_visible=[]
            selected_board=[self._active_board()]
            selected_var=tk.StringVar(value=(f"✓ {selected_board[0]['name']}  •  Code: {self._code_display_name(selected_board[0].get('native_code','cpp'))}" if selected_board[0] else "No board selected"))

            selected_banner=ttk.Frame(self.content,style="Card.TFrame")
            selected_banner.pack(fill="x",pady=(0,8))
            ttk.Label(selected_banner,text="Selected board",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(10,2))
            ttk.Label(selected_banner,textvariable=selected_var,style="CardText.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=(0,10))

            def current_matches():
                query=search.get().strip()
                scored=[]
                for b in state["catalog"]:
                    score=board_search_score(query,b)
                    if score is not None:
                        scored.append((score,b))
                scored.sort(key=lambda item:(-item[0], item[1]["name"].casefold()))
                return [b for _,b in scored]

            def show_detail(board):
                for w in info_box.winfo_children(): w.destroy()
                if not board:
                    ttk.Label(info_box,text="No board name matched. Try fewer characters, shorter keywords, or a different character order.",style="CardText.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=14)
                    return
                prefix="✓ Selected: " if selected_board[0] and selected_board[0]["name"]==board["name"] else ""
                ttk.Label(info_box,text=prefix+board["name"],style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
                reason=board.get("reason") or "Board available in the catalog."
                ttk.Label(info_box,text=reason,style="CardText.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=(0,8))
                native_label={"ino":"Arduino sketch (.ino)","cpp":"C++ source (.cpp)","c":"C source (.c)","asm":"Assembly (.S)"}.get(board.get("native_code","cpp"), board.get("native_code","cpp"))
                ttk.Label(info_box,text=f"Make Code default: {native_label}",style="CardText.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=(0,8))
                vendor=board.get("vendor") or ""
                source=board.get("source") or ""
                meta=""
                if vendor: meta += f"Manufacturer: {vendor}    "
                if source: meta += f"Catalog: {source}"
                if meta:
                    ttk.Label(info_box,text=meta,style="CardText.TLabel",wraplength=820).pack(anchor="w",padx=14,pady=(0,8))
                selected = selected_board[0] and selected_board[0]["name"]==board["name"]
                ttk.Button(info_box,text=("✓ Board Selected" if selected else "Select This Board"),style="Accent.TButton",command=lambda b=board: select_board(b)).pack(anchor="e",padx=14,pady=(0,12))

            def render(reset=True):
                nonlocal matches_cache
                matches_cache=current_matches()
                if reset:
                    state["shown"]=0
                    listbox.delete(0,"end")
                load_more(force=True)
                if selected_board[0]:
                    for i in range(listbox.size()):
                        if i < len(matches_cache) and matches_cache[i]["name"]==selected_board[0]["name"]:
                            listbox.itemconfig(i,background="#235c3f",foreground="#ffffff")
                        else:
                            listbox.itemconfig(i,background="#0b1020",foreground="#dce6ff")
                if matches_cache:
                    listbox.selection_clear(0,"end")
                    listbox.selection_set(0)
                    listbox.see(0)
                    show_detail(matches_cache[0])
                else:
                    show_detail(None)

            def load_more(force=False):
                # Only add another batch when explicitly requested or when the
                # current visible data is nearly exhausted. Exactly 20 entries
                # are appended per batch until the filtered results are done.
                total=len(matches_cache)
                if state["shown"] >= total:
                    update_counts()
                    return
                next_shown=min(total,state["shown"]+state["page_size"])
                if not force and state["shown"] < state["page_size"]:
                    return
                for b in matches_cache[state["shown"]:next_shown]:
                    idx=listbox.size()
                    listbox.insert("end",b["name"])
                    if selected_board[0] and selected_board[0]["name"]==b["name"]:
                        listbox.itemconfig(idx,background="#235c3f",foreground="#ffffff")
                state["shown"]=next_shown
                update_counts()

            def update_counts():
                total=len(matches_cache)
                shown=state["shown"]
                if state["full_ready"]:
                    suffix=""
                else:
                    suffix=" · full catalog still loading"
                count_var.set(f"Loaded {shown} of {total} matching boards{suffix}")

            def maybe_load_more(*_):
                if not matches_cache:
                    return
                try:
                    first,last=listbox.yview()
                except Exception:
                    return
                if last >= 0.80 and state["shown"] < len(matches_cache):
                    load_more()

            def select_board(b):
                if not b:
                    return
                selected_board[0]=b
                self._set_active_board(b)
                selected_var.set(f"✓ {b['name']}  •  Code: {self._code_display_name(b.get('native_code','cpp'))}" )
                for i in range(listbox.size()):
                    try:
                        name=listbox.get(i)
                    except Exception:
                        name=""
                    if name == b["name"]:
                        listbox.itemconfig(i,background="#235c3f",foreground="#ffffff")
                    else:
                        listbox.itemconfig(i,background="#0b1020",foreground="#dce6ff")
                show_detail(b)
                self.log_line(f"Selected board: {b['name']}","ok")

            def on_list_select(_=None):
                sel=listbox.curselection()
                if sel and sel[0] < len(matches_cache):
                    # A click on a board is the selection action, not merely a preview.
                    select_board(matches_cache[sel[0]])

            def on_scrollbar(*args):
                listbox.yview(*args)
                listbox.after_idle(maybe_load_more)

            scrollbar.config(command=on_scrollbar)
            listbox.config(yscrollcommand=scrollbar.set)
            listbox.bind("<<ListboxSelect>>",on_list_select)

            def wheel(event):
                if getattr(event,"num",None)==4:
                    listbox.yview_scroll(-3,"units")
                elif getattr(event,"num",None)==5:
                    listbox.yview_scroll(3,"units")
                else:
                    delta=getattr(event,"delta",0)
                    listbox.yview_scroll(int(-delta/120*3) if delta else 0,"units")
                maybe_load_more()
                return "break"
            listbox.bind("<MouseWheel>",wheel)
            listbox.bind("<Button-4>",wheel)
            listbox.bind("<Button-5>",wheel)
            listbox.bind("<KeyRelease>",lambda e: maybe_load_more())
            listbox.bind("<ButtonRelease-1>",lambda e: maybe_load_more())
            listbox.bind("<Configure>",lambda e: maybe_load_more())

            def rebuild(*_):
                # Search filters the catalog that is currently available. While
                # PlatformIO is still being fetched, the small built-in catalog
                # remains usable; once the full catalog arrives we rebuild once.
                render(reset=True)

            entry.bind("<KeyRelease>",rebuild)
            render(reset=True)

            def background_load():
                try:
                    full=load_board_catalog()
                except Exception:
                    full=None
                def finish():
                    if full:
                        state["catalog"]=full
                        state["full_ready"]=True
                        state["loading"]=False
                        status_var.set("Full catalog loaded. Scroll near the bottom of each batch to load the next 20.")
                        render(reset=True)
                    else:
                        state["loading"]=False
                        status_var.set("The full catalog could not be loaded right now. The built-in catalog remains available.")
                        update_counts()
                self.root.after(0,finish)
            threading.Thread(target=background_load,daemon=True).start()

            self._card(self.content,"Fast browsing","Only 20 matching boards are placed in the list at a time. When you reach about 80% down the current batch, CROS loads the next 20. Searching filters the catalog without dumping hundreds of names into the window at once.")

        def _serial_ports(self):
            ports=[]
            for pattern in ("/dev/ttyACM*","/dev/ttyUSB*","/dev/ttyAMA*","/dev/ttyS*"):
                ports.extend(str(p) for p in sorted(Path("/dev").glob(pattern.replace("/dev/",""))))
            # de-duplicate while preserving sort order
            return sorted(dict.fromkeys(ports))

        def show_upload(self):
            self._clear_content(); self._title("Upload to Board","Choose the file, commercial board, and serial port together. The upload command is run in your Debian terminal environment.")
            form=ttk.Frame(self.content,style="Card.TFrame"); form.pack(fill="x")
            file_var=tk.StringVar()
            ttk.Label(form,text="File to upload",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            frow=ttk.Frame(form,style="Card.TFrame"); frow.pack(fill="x",padx=14)
            ttk.Entry(frow,textvariable=file_var).pack(side="left",fill="x",expand=True)
            def browse_file():
                path=filedialog.askopenfilename(title="Select code or firmware file",filetypes=[("Arduino / C++","*.ino *.cpp *.cc *.cxx"),("Firmware","*.bin *.hex *.uf2"),("Python","*.py"),("All files","*")])
                if path: file_var.set(path)
            ttk.Button(frow,text="Browse",command=browse_file).pack(side="left",padx=(8,0))

            ttk.Label(form,text="Active board",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            active=self._active_board()
            board_var=tk.StringVar(value=(f"✓ {active['name']}" if active else "No board selected"))
            ttk.Label(form,textvariable=board_var,style="Selected.TLabel").pack(anchor="w",padx=14,pady=(2,3))
            if active:
                ttk.Label(form,text="Upload target is controlled by the selection in Boards.",style="CardText.TLabel").pack(anchor="w",padx=14,pady=(0,8))
                ttk.Button(form,text="Change Board in Boards",command=self.show_boards).pack(anchor="w",padx=14,pady=(0,8))
            else:
                ttk.Label(form,text="Select a board in Boards before uploading.",style="CardText.TLabel").pack(anchor="w",padx=14,pady=(0,8))
                ttk.Button(form,text="Open Boards",command=self.show_boards).pack(anchor="w",padx=14,pady=(0,8))

            ttk.Label(form,text="Serial port",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            port_var=tk.StringVar()
            prow=ttk.Frame(form,style="Card.TFrame"); prow.pack(fill="x",padx=14)
            port_combo=ttk.Combobox(prow,textvariable=port_var,state="readonly")
            port_combo.pack(side="left",fill="x",expand=True)
            def refresh_ports():
                ports=self._serial_ports()
                port_combo["values"]=ports
                if ports:
                    port_combo.current(0)
                    self.log_line("Detected serial ports: "+", ".join(ports),"ok")
                else:
                    port_var.set("")
                    self.log_line("No /dev/ttyACM*, /dev/ttyUSB*, /dev/ttyAMA*, or /dev/ttyS* device detected.","warn")
            ttk.Button(prow,text="Refresh",command=refresh_ports).pack(side="left",padx=(8,0))

            info=ttk.Frame(form,style="Card.TFrame"); info.pack(fill="x",padx=14,pady=(12,6))
            ttk.Label(info,text="Supported directly",style="CardTitle.TLabel").pack(anchor="w",padx=10,pady=(8,3))
            ttk.Label(info,text="Arduino-style .ino projects are uploaded with arduino-cli using the selected board and port. Other firmware formats are shown here so you can select them, but the assistant will only run a verified uploader command when it knows the required flashing parameters.",style="CardText.TLabel",wraplength=720).pack(anchor="w",padx=10,pady=(0,8))

            def upload():
                path=Path(file_var.get()).expanduser()
                board=self._active_board()
                port=port_var.get().strip()
                if not path.exists(): messagebox.showerror("File not found",str(path)); return
                if not board: messagebox.showerror("Board required","Choose a commercial board."); return
                if not port: messagebox.showerror("Port required","Choose a serial port."); return
                if path.suffix.lower()==".ino" and board.get("fqbn"):
                    cmd=f"arduino-cli upload -p {shlex.quote(port)} --fqbn {shlex.quote(board['fqbn'])} {shlex.quote(str(path.parent))}"
                    self.execute_command(cmd)
                    return
                if path.suffix.lower()==".hex" and board["family"]=="arduino":
                    messagebox.showinfo("Hex upload","A raw HEX upload needs the exact bootloader/programmer settings. Use an Arduino CLI sketch upload or provide those settings before flashing.")
                    return
                if path.suffix.lower()==".uf2":
                    messagebox.showinfo("UF2 upload","UF2 files are normally copied through a board's bootloader USB storage rather than flashed through a serial port. The selected serial port is therefore not used for this file.")
                    return
                if path.suffix.lower()==".bin" and board["family"] in ("esp32","esp8266"):
                    messagebox.showinfo("Binary upload","A raw binary needs its flash offset(s) and image layout. I won't guess those values and risk corrupting the board. Use the project's documented flashing command in the terminal command box below.")
                    return
                messagebox.showinfo("Upload not configured","This file/board combination doesn't have a safe automatic uploader preset yet. Use the terminal command box with the board's documented uploader command.")

            ttk.Button(form,text="Upload Selected File",style="Accent.TButton",command=upload).pack(anchor="e",padx=14,pady=14)
            refresh_ports()

        def show_format(self):
            self._clear_content(); self._title("Format Code","Boards is the source of truth: this page uses the formatting profile of the currently selected board.")
            form=ttk.Frame(self.content,style="Card.TFrame"); form.pack(fill="x")
            active=self._active_board()
            ttk.Label(form,text="Active board",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            active_var=tk.StringVar(value=(f"✓ {active['name']}" if active else "No board selected"))
            ttk.Label(form,textvariable=active_var,style="Selected.TLabel").pack(anchor="w",padx=14,pady=(2,3))
            if active:
                ttk.Label(form,text=f"CROS will automatically use the {active.get('profile','desktop')} formatting profile for this board.",style="CardText.TLabel").pack(anchor="w",padx=14,pady=(0,8))
                ttk.Button(form,text="Change Board in Boards",command=self.show_boards).pack(anchor="w",padx=14,pady=(0,8))
            else:
                ttk.Label(form,text="Select a board in Boards first. Formatting is intentionally tied to that board selection.",style="CardText.TLabel",wraplength=720).pack(anchor="w",padx=14,pady=(0,8))
                ttk.Button(form,text="Open Boards",style="Accent.TButton",command=self.show_boards).pack(anchor="w",padx=14,pady=(0,10))
                return

            path_var=tk.StringVar(value=str(Path.cwd()/"main.cpp"))
            ttk.Label(form,text="Source/header file",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,4))
            row=ttk.Frame(form,style="Card.TFrame"); row.pack(fill="x",padx=14)
            ttk.Entry(row,textvariable=path_var).pack(side="left",fill="x",expand=True)
            ttk.Button(row,text="Browse",command=lambda:path_var.set(filedialog.askopenfilename())).pack(side="left",padx=(8,0))
            ttk.Label(form,text="The selected board controls indentation, braces, column width, and board-specific formatting choices.",style="CardText.TLabel",wraplength=720).pack(anchor="w",padx=14,pady=(6,10))
            ttk.Button(form,text="Apply Board Format",style="Accent.TButton",command=lambda:self._format_existing(path_var.get(),active.get("profile","desktop"))).pack(anchor="e",padx=14,pady=14)

        def _format_existing(self,path_value,profile):
            p=Path(path_value).expanduser()
            if not p.exists(): messagebox.showerror("File not found",str(p)); return
            if not gui_write_clang_format(profile,overwrite=True): return
            if not shutil.which("clang-format"):
                if messagebox.askyesno("clang-format missing","Install clang-format now?"):
                    self.execute_command("sudo apt-get update && sudo apt-get install -y clang-format",auto_confirm=True,callback=lambda ok:self._do_format(p,ok))
                return
            self._do_format(p,True)

        def _do_format(self,p,ok):
            if ok and shutil.which("clang-format"):
                self.execute_command(f"clang-format -i {shlex.quote(str(p))}",auto_confirm=True)

        def show_watchdog(self):
            self._clear_content(); self._title("Watchdog","Recent errors, remembered fixes, and a safe test.")
            db=load(DB,{"solutions":[],"projects":[]})
            text=""
            if not db["solutions"]: text="No remembered alternate solutions yet."
            else:
                text="\n".join(f"• {x['error']}: {x['solution']}" for x in db["solutions"][-12:])
            card=ttk.Frame(self.content,style="Card.TFrame"); card.pack(fill="both",expand=True)
            ttk.Label(card,text="Remembered solutions",style="CardTitle.TLabel").pack(anchor="w",padx=14,pady=(12,6))
            box=tk.Text(card,height=14,bg="#10172a",fg="#dce6ff",relief="flat",wrap="word"); box.pack(fill="both",expand=True,padx=14,pady=8); box.insert("1.0",text); box.configure(state="disabled")
            ttk.Button(card,text="Run Safe Watchdog Test",style="Accent.TButton",command=lambda:self.execute_command("definitely_not_a_real_command",auto_confirm=True)).pack(anchor="e",padx=14,pady=10)

        def show_doctor(self):
            self._clear_content(); self._title("System Doctor","Inspect tools and disk space without leaving this window.")
            ttk.Button(self.content,text="Run Doctor",style="Accent.TButton",command=lambda:self.execute_command("python3 " + shlex.quote(str(APP)) + " doctor",auto_confirm=True)).pack(anchor="w",pady=8)
            self._card(self.content,"What it checks","Python, Git, compilers, clang-format, Node/npm, Arduino CLI, and available home-directory storage.")

        def toggle_terminal_panel(self):
            self.console_hidden=not bool(getattr(self,"console_hidden",False))
            self.gui_cfg["hide_cros_terminal"]=self.console_hidden
            save(CFG,self.gui_cfg)
            if self.console_hidden:
                self.console_frame.pack_forget()
                self.console_toggle.configure(text="Show CROS Terminal")
                self.log_line("CROS terminal panel hidden. Commands continue to run normally.","ok")
            else:
                self.console_frame.pack(fill="x",padx=12,pady=(0,10))
                self.console_toggle.configure(text="Hide CROS Terminal")
                self.log_line("CROS terminal panel shown.","ok")

        def clear_output(self): self.output.delete("1.0","end")
        def log_line(self,line,tag=None):
            self.output.insert("end",line+"\n",tag or "")
            self.output.see("end")
        def execute_entry(self):
            cmd=self.command_var.get().strip()
            if cmd: self.execute_command(cmd); self.command_var.set("")
        def execute_command(self,command,auto_confirm=False,callback=None):
            if not command:return
            if not auto_confirm and not messagebox.askyesno("Run command",f"Run this in the terminal environment?\n\n{command}"):
                return
            self.status.configure(text="● Running",fg="#ffd166")
            self.log_line(f"$ {command}","cmd")
            print(f"\n[cros-gui] $ {command}",flush=True)
            def worker():
                ok=True
                try:
                    p=subprocess.Popen(command,shell=True,executable=os.environ.get("SHELL","/bin/bash"),stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1)
                    captured=[]
                    for line in p.stdout or []:
                        captured.append(line.rstrip("\n"))
                        sys.stdout.write("[cros-gui] "+line); sys.stdout.flush()
                        self.q.put(("out",line.rstrip("\n")))
                    code=p.wait(); ok=(code==0)
                    self.q.put(("done",code,callback,ok,"\n".join(captured)))
                except Exception as exc:
                    self.q.put(("out",f"Execution failure: {exc}")); self.q.put(("done",1,callback,False))
            threading.Thread(target=worker,daemon=True).start()
        def _poll_queue(self):
            try:
                while True:
                    item=self.q.get_nowait()
                    if item[0]=="out":
                        line=item[1]; tag=""
                        if detect(line): tag="error"
                        elif "warning" in line.lower(): tag="warn"
                        elif "success" in line.lower(): tag="ok"
                        self.log_line(line,tag)
                    elif item[0]=="done":
                        code,callback,ok,captured=item[1],item[2],item[3],item[4]
                        self.status.configure(text=("● Ready" if ok else f"● Exit {code}"),fg=("#57e389" if ok else "#ff6b6b"))
                        if captured: error_report(captured)
                        if callback: callback(ok)
            except queue.Empty: pass
            self.root.after(80,self._poll_queue)
        def _animate(self):
            self.dot_phase=(self.dot_phase+1)%4
            symbols=["●","◉","○","◉"]
            if self.status.cget("text").startswith("● Ready") or self.status.cget("text").startswith("◉ Ready") or self.status.cget("text").startswith("○ Ready"):
                self.status.configure(text=f"{symbols[self.dot_phase]} Ready")
            self.root.after(350,self._animate)

    root=tk.Tk()
    CrosGUI(root)
    root.mainloop()

def main():
    if "--gui" in sys.argv:
        try:
            gui_main()
        except ImportError as exc:
            print("Tkinter is not available. Install it with: sudo apt-get update && sudo apt-get install -y python3-tk")
            raise SystemExit(1)
        return
    if "--uninstall" in sys.argv:
        print("This permanently removes the local assistant data and launcher.")
        if input("Type DELETE to confirm: ").strip()=="DELETE":
            shutil.rmtree(ROOT,ignore_errors=True)
            for launcher in ("cros-assist", "cros"):
                try:(Path.home()/".local/bin"/launcher).unlink()
                except FileNotFoundError:pass
            print("Removed.")
        return
    if "--reset-knowledge" in sys.argv:
        save(DB,{"solutions":[],"projects":[]}); print("Learned solutions reset; configuration remains."); return
    args=" ".join(sys.argv[1:]).strip()
    if args: handle(args); return
    print(color("CROS Debian Assistant", "BOLD") + color(" — type `help`; Ctrl-D exits.", "DIM"))
    while True:
        try: handle(input("cros> "))
        except EOFError: print(); break
        except KeyboardInterrupt: print("\nUse `exit` to quit.")

if __name__=="__main__": main()
PY

chmod +x "$APP"

cat > "$BIN_DIR/cros-assist" <<'SH'
#!/usr/bin/env bash
exec python3 "$HOME/.cros-debian-assistant/assistant.py" "$@"
SH
chmod +x "$BIN_DIR/cros-assist"

# Short persistent trigger: open the graphical assistant as a second window.
cat > "$BIN_DIR/cros" <<'SH'
#!/usr/bin/env bash
set -e
if ! python3 -c 'import tkinter' >/dev/null 2>&1; then
  echo "CROS GUI needs Python Tkinter."
  echo "Installing python3-tk..."
  sudo apt-get update && sudo apt-get install -y python3-tk
fi
python3 "$HOME/.cros-debian-assistant/assistant.py" --gui "$@" &
disown 2>/dev/null || true
echo "CROS Assistant window opened. The terminal remains available for commands."
SH
chmod +x "$BIN_DIR/cros"

# Persist PATH for future Debian Terminal sessions. Keep it in both files
# because ChromeOS/Linux shells can start as either interactive or login shells.
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  touch "$rc"
  if ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$rc"; then
    printf '\n# CROS Debian Assistant\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc"
  fi
done

export PATH="$HOME/.local/bin:$PATH"

echo
echo "=============================================="
echo " CROS Debian Assistant installed successfully"
echo "=============================================="
echo
echo "Run now:"
echo "  cros-assist"
echo "  cros          # short trigger that survives new Debian sessions"
echo
echo "Examples:"
echo '  cros-assist "make a python file"'
echo '  cros-assist "boards wifi bluetooth sensor"'
echo "  cros-assist doctor"
echo