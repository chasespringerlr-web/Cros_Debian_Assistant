#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ROOT="${HOME}/.cros-debian-assistant/plugins"
PLUGIN_DIR="$PLUGIN_ROOT/logic-analyzer-datasheet"
CACHE_DIR="${HOME}/.cros-debian-assistant/plugin-cache"
CACHE_FILE="$CACHE_DIR/logic-analyzer-datasheet.json"

mkdir -p "$PLUGIN_DIR" "$CACHE_DIR"

cat > "$PLUGIN_DIR/plugin.json" <<'JSON'
{
  "id": "logic-analyzer-datasheet",
  "name": "Logic Analyzer + Board Datasheet",
  "version": "1.0.0",
  "description": "Inline digital logic capture viewer and board documentation helper.",
  "entry": "plugin.py",
  "panel": "build_panel"
}
JSON

cat > "$PLUGIN_DIR/plugin.py" <<'PY'
import tkinter as tk
from tkinter import ttk, filedialog
from pathlib import Path
import csv
import json
import re
import webbrowser

CACHE_DIR = Path.home() / ".cros-debian-assistant" / "plugin-cache"
CACHE_FILE = CACHE_DIR / "logic-analyzer-datasheet.json"

BOARDS = [
    {
        "name": "Arduino Uno Rev3",
        "vendor": "Arduino",
        "docs": "https://store.arduino.cc/products/arduino-uno-rev3",
        "datasheet": "https://docs.arduino.cc/resources/datasheets/A000066-datasheet.pdf",
        "notes": "ATmega328P-based board with USB, SPI, I2C, UART, and 5 V logic."
    },
    {
        "name": "Arduino Nano Every",
        "vendor": "Arduino",
        "docs": "https://store.arduino.cc/products/nano-every",
        "datasheet": "https://docs.arduino.cc/resources/datasheets/ABX00028-datasheet.pdf",
        "notes": "Compact ATmega4809-based Arduino board."
    },
    {
        "name": "Arduino Mega 2560 Rev3",
        "vendor": "Arduino",
        "docs": "https://store.arduino.cc/products/arduino-mega-2560-rev3",
        "datasheet": "https://docs.arduino.cc/resources/datasheets/A000067-datasheet.pdf",
        "notes": "ATmega2560-based board with a large GPIO count and multiple hardware serial ports."
    },
    {
        "name": "ESP32-DevKitC V4",
        "vendor": "Espressif",
        "docs": "https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32/esp32-devkitc/user_guide.html",
        "datasheet": "https://www.espressif.com/sites/default/files/documentation/esp32_datasheet_en.pdf",
        "notes": "ESP32 development board with Wi-Fi, Bluetooth, GPIO, ADC, UART, SPI, and I2C."
    },
    {
        "name": "ESP32-S3-DevKitC-1",
        "vendor": "Espressif",
        "docs": "https://docs.espressif.com/projects/esp-dev-kits/en/latest/esp32s3/esp32-s3-devkitc-1/user_guide.html",
        "datasheet": "https://www.espressif.com/sites/default/files/documentation/esp32-s3_datasheet_en.pdf",
        "notes": "ESP32-S3 development board with USB, Wi-Fi/BLE, GPIO, ADC, SPI, and I2C."
    },
    {
        "name": "Raspberry Pi Pico",
        "vendor": "Raspberry Pi",
        "docs": "https://www.raspberrypi.com/documentation/microcontrollers/pico-series.html",
        "datasheet": "https://datasheets.raspberrypi.com/pico/pico-datasheet.pdf",
        "notes": "RP2040 microcontroller board with programmable I/O, SPI, I2C, UART, ADC, and PWM."
    },
    {
        "name": "Raspberry Pi Pico W",
        "vendor": "Raspberry Pi",
        "docs": "https://www.raspberrypi.com/documentation/microcontrollers/pico-series.html",
        "datasheet": "https://datasheets.raspberrypi.com/picow/pico-w-datasheet.pdf",
        "notes": "RP2040 wireless variant with Wi-Fi and Bluetooth."
    },
    {
        "name": "Raspberry Pi Pico 2",
        "vendor": "Raspberry Pi",
        "docs": "https://www.raspberrypi.com/documentation/microcontrollers/pico-series.html",
        "datasheet": "https://datasheets.raspberrypi.com/pico/pico-2-datasheet.pdf",
        "notes": "RP2350-based Pico-family board."
    },
    {
        "name": "Raspberry Pi Pico 2 W",
        "vendor": "Raspberry Pi",
        "docs": "https://www.raspberrypi.com/documentation/microcontrollers/pico-series.html",
        "datasheet": "https://datasheets.raspberrypi.com/picow/pico-2-w-datasheet.pdf",
        "notes": "RP2350 wireless Pico-family board."
    },
]

def _load_state():
    state = dict({
        "csv": "",
        "sample_rate": "1000000",
        "selected_board": "Arduino Uno Rev3",
        "search": "",
    })
    try:
        if CACHE_FILE.exists():
            data = json.loads(CACHE_FILE.read_text())
            if isinstance(data, dict):
                state.update(data)
    except Exception:
        pass
    return state

STATE = _load_state()

def _save_state():
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = CACHE_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(STATE, indent=2) + "\n")
        tmp.replace(CACHE_FILE)
    except Exception:
        pass

def _ordered_match(needle, haystack):
    needle = re.sub(r"\s+", "", needle.lower())
    haystack = re.sub(r"\s+", "", haystack.lower())
    if not needle:
        return True
    pos = 0
    for ch in needle:
        pos = haystack.find(ch, pos)
        if pos < 0:
            return False
        pos += 1
    return True

def _load_capture(path):
    rows = []
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for row in csv.reader(fh):
            if row and any(cell.strip() for cell in row):
                rows.append(row)

    if not rows:
        raise ValueError("The CSV is empty.")

    first = rows[0]
    has_header = bool(first and not re.fullmatch(r"[-+0-9.eE]+", first[0].strip()))
    if has_header:
        channel_names = [x.strip() or f"CH{i}" for i, x in enumerate(first[1:], start=0)]
        data_rows = rows[1:]
    else:
        channel_names = [f"CH{i}" for i in range(max(0, len(first) - 1))]
        data_rows = rows

    samples = []
    for row in data_rows:
        if len(row) < 2:
            continue
        try:
            t = float(row[0])
        except Exception:
            continue
        values = []
        for value in row[1:1 + len(channel_names)]:
            try:
                values.append(1 if float(value) >= 0.5 else 0)
            except Exception:
                values.append(0)
        while len(values) < len(channel_names):
            values.append(0)
        samples.append((t, values))

    if not samples:
        raise ValueError("No numeric samples were found.")
    return channel_names, samples

def build_panel(parent, gui):
    frame = ttk.Frame(parent)
    frame.pack(fill="both", expand=True, padx=10, pady=10)

    notebook = ttk.Notebook(frame)
    notebook.pack(fill="both", expand=True)

    # ---------------- Logic Analyzer tab ----------------
    logic = ttk.Frame(notebook, padding=12)
    notebook.add(logic, text="Logic Analyzer")
    logic.columnconfigure(1, weight=1)
    logic.rowconfigure(1, weight=1)

    path_var = tk.StringVar(value=STATE.get("csv", ""))
    rate_var = tk.StringVar(value=STATE.get("sample_rate", "1000000"))
    status_var = tk.StringVar(value="Load a digital CSV capture.")

    def sync_logic(*_):
        STATE["csv"] = path_var.get()
        STATE["sample_rate"] = rate_var.get()
        _save_state()

    path_var.trace_add("write", sync_logic)
    rate_var.trace_add("write", sync_logic)

    top = ttk.Frame(logic)
    top.grid(row=0, column=0, columnspan=2, sticky="ew", pady=(0, 8))

    ttk.Label(top, text="CSV capture").pack(side="left")
    ttk.Entry(top, textvariable=path_var, width=50).pack(side="left", padx=6, fill="x", expand=True)
    ttk.Button(
        top, text="Browse",
        command=lambda: path_var.set(
            filedialog.askopenfilename(
                filetypes=[("CSV files", "*.csv"), ("All files", "*.*")]
            )
        )
    ).pack(side="left")
    ttk.Label(top, text="Sample rate").pack(side="left", padx=(14, 4))
    ttk.Entry(top, textvariable=rate_var, width=12).pack(side="left")

    controls = ttk.Frame(logic)
    controls.grid(row=1, column=0, sticky="nsw", padx=(0, 10))

    canvas = tk.Canvas(logic, background="#11131a", highlightthickness=0)
    canvas.grid(row=1, column=1, sticky="nsew")

    channel_list = tk.Listbox(controls, height=14, exportselection=False)
    channel_list.pack(fill="y")

    capture = {"names": [], "samples": []}

    def draw_capture():
        canvas.delete("all")
        names = capture["names"]
        samples = capture["samples"]
        if not names or not samples:
            canvas.create_text(
                30, 30, anchor="nw",
                fill="#c9ced8",
                text="[logic capture display]"
            )
            return

        width = max(720, canvas.winfo_width())
        height = max(480, canvas.winfo_height())
        left = 70
        top_y = 25
        row_height = max(48, int((height - 45) / max(1, len(names))))

        t0 = samples[0][0]
        t1 = samples[-1][0] if len(samples) > 1 else t0 + 1.0
        span = max(t1 - t0, 1e-12)

        for index, name in enumerate(names):
            base = top_y + index * row_height
            high = base + 8
            low = base + 28

            canvas.create_text(8, base + 18, anchor="w", fill="#ffffff", text=name)
            canvas.create_line(left, low, width - 12, low, fill="#2a2e39")

            previous = None
            previous_x = None
            previous_y = None

            for timestamp, values in samples:
                value = values[index] if index < len(values) else 0
                x = left + ((timestamp - t0) / span) * (width - left - 12)
                y = high if value else low

                if previous is not None and value != previous:
                    canvas.create_line(previous_x, previous_y, x, previous_y, fill="#63d297", width=2)
                    canvas.create_line(x, high, x, low, fill="#63d297", width=2)

                canvas.create_line(x, y, x + 1, y, fill="#63d297", width=2)
                previous = value
                previous_x = x
                previous_y = y

    def load_capture():
        try:
            names, samples = _load_capture(path_var.get())
            capture["names"] = names
            capture["samples"] = samples

            channel_list.delete(0, "end")
            for name in names:
                channel_list.insert("end", name)

            status_var.set(
                f"Loaded {len(samples):,} samples across {len(names)} digital channels."
            )
            draw_capture()
        except Exception as exc:
            status_var.set(f"Error: {exc}")
            gui.log_line(f"Logic Analyzer: {exc}", "error")

    def make_test_capture():
        target = CACHE_DIR / "logic-analyzer-test.csv"
        CACHE_DIR.mkdir(parents=True, exist_ok=True)

        with target.open("w", newline="", encoding="utf-8") as fh:
            writer = csv.writer(fh)
            writer.writerow(["time", "CLK", "DATA", "ENABLE"])
            for i in range(300):
                t = i / 1000.0
                clk = i % 2
                data = 1 if (i // 15) % 2 else 0
                enable = 1 if 50 <= i < 250 else 0
                writer.writerow([f"{t:.6f}", clk, data, enable])

        path_var.set(str(target))
        load_capture()

    ttk.Button(controls, text="Load Capture", command=load_capture).pack(fill="x", pady=4)
    ttk.Button(controls, text="Generate Test Capture", command=make_test_capture).pack(fill="x", pady=4)
    ttk.Label(
        controls, textvariable=status_var, wraplength=240, justify="left"
    ).pack(anchor="w", pady=10)
    ttk.Label(
        controls,
        text="CSV format:\ntime, channel0, channel1, ...\nDigital values use 0/1.",
        foreground="#777f90",
        justify="left",
    ).pack(anchor="w")

    canvas.bind("<Configure>", lambda _event: draw_capture())

    # ---------------- Board Datasheet tab ----------------
    boards = ttk.Frame(notebook, padding=12)
    notebook.add(boards, text="Board Datasheet")

    boards.columnconfigure(1, weight=1)
    boards.rowconfigure(1, weight=1)

    search_var = tk.StringVar(value=STATE.get("search", ""))
    active_var = tk.StringVar(value=STATE.get("selected_board", ""))

    def sync_board_state(*_):
        STATE["search"] = search_var.get()
        STATE["selected_board"] = active_var.get()
        _save_state()

    search_var.trace_add("write", sync_board_state)
    active_var.trace_add("write", sync_board_state)

    ttk.Label(boards, text="Search commercial board names").grid(
        row=0, column=0, sticky="w"
    )
    ttk.Entry(boards, textvariable=search_var, width=36).grid(
        row=0, column=1, sticky="w", padx=6
    )

    board_list = tk.Listbox(boards, height=18, exportselection=False)
    board_list.grid(row=1, column=0, sticky="nsw", pady=8)

    detail = ttk.Frame(boards, padding=(16, 8))
    detail.grid(row=1, column=1, sticky="nsew")

    def refresh_board_list():
        query = search_var.get().strip().lower()
        board_list.delete(0, "end")

        for board in BOARDS:
            haystack = f"{board['name']} {board['vendor']}".lower()
            if not query or all(
                _ordered_match(part, haystack) for part in query.split()
            ):
                board_list.insert("end", board["name"])

        for index in range(board_list.size()):
            if board_list.get(index) == active_var.get():
                board_list.selection_set(index)
                board_list.see(index)
                break

    def show_board():
        if not board_list.curselection():
            return

        name = board_list.get(board_list.curselection()[0])
        board = next((item for item in BOARDS if item["name"] == name), None)
        if not board:
            return

        active_var.set(name)

        for child in detail.winfo_children():
            child.destroy()

        ttk.Label(
            detail, text=f"✓ Selected board: {board['name']}",
            font=("TkDefaultFont", 14, "bold")
        ).pack(anchor="w")

        ttk.Label(
            detail, text=board["vendor"], foreground="#777f90"
        ).pack(anchor="w", pady=(2, 12))

        ttk.Label(
            detail, text=board["notes"], wraplength=650, justify="left"
        ).pack(anchor="w", pady=(0, 14))

        buttons = ttk.Frame(detail)
        buttons.pack(anchor="w")

        ttk.Button(
            buttons, text="Open Documentation",
            command=lambda: webbrowser.open(board["docs"])
        ).pack(side="left", padx=(0, 6))

        ttk.Button(
            buttons, text="Open Datasheet",
            command=lambda: webbrowser.open(board["datasheet"])
        ).pack(side="left", padx=6)

        ttk.Label(
            detail,
            text="Documentation opens in your normal browser.",
            foreground="#777f90",
        ).pack(anchor="w", pady=18)

    search_var.trace_add("write", lambda *_: refresh_board_list())
    board_list.bind("<<ListboxSelect>>", lambda _event: show_board())

    def use_active_board():
        active = gui._active_board()
        if isinstance(active, dict):
            name = str(active.get("name", "")).strip()
            if name:
                search_var.set(name)
                active_var.set(name)
                refresh_board_list()

    ttk.Button(
        boards, text="Use Active CROS Board",
        command=use_active_board
    ).grid(row=2, column=0, sticky="w", pady=6)

    refresh_board_list()
    if active_var.get():
        for index in range(board_list.size()):
            if board_list.get(index) == active_var.get():
                board_list.selection_set(index)
                board_list.see(index)
                show_board()
                break

    _save_state()
    return frame

PY

if [[ ! -f "$CACHE_FILE" ]]; then
cat > "$CACHE_FILE" <<'JSON'
{
  "csv": "",
  "sample_rate": "1000000",
  "selected_board": "Arduino Uno Rev3",
  "search": ""
}
JSON
fi

echo "Installed CROS plugin: Logic Analyzer + Board Datasheet"
echo "Inline workspace with automatic settings cache."
echo "Use: cros → Plugins → Reload Plugins"