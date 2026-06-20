# Walmart Minecraft — A Real-Time 3D Voxel Game on an FPGA

A Minecraft-inspired, first-person voxel game built from scratch on a Xilinx Spartan-7
(Urbana board) FPGA. The world is rendered in real time at 320×240 over HDMI using a
hardware **raycasting engine** written in SystemVerilog, driven by a MicroBlaze soft
processor running C that reads a USB keyboard and updates the game state.

> ECE 385 (Digital Systems Laboratory) — Spring 2026 Final Project
> William Wei ([@WilliamWei1126](https://github.com/WilliamWei1126)) & Eason Lin

---

## Demo

| | |
|---|---|
| **Movement** | `W` `A` `S` `D` to walk, `←` / `→` arrow keys to turn |
| **Place block** | `1` dirt · `2` sand · `3` leaves · `4` redstone · `5` glass · `6` water · `Q` error block |
| **Stack** | Press a place key again on the same spot to grow the block taller (up to height 7) |
| **Break block** | `Space` while aiming at a block |

Players spawn in an open 32×32 world of grass surrounded by grey walls, with a rendered
sky. Blocks come in 7 types and can be stacked to build pyramids, staircases, and other
structures. Screenshots of the gameplay are in the project report (`Final_report.pdf`).

---

## How It Works

The system is split into a **software half** (C on MicroBlaze) and a **hardware half**
(custom SystemVerilog video IP), connected over an **AXI4-Lite** bus.

```
USB keyboard ──SPI──► MAX3421E ──► MicroBlaze (C)
                                      │
                                      │ AXI4-Lite
                                      ▼
                         ┌──────────────────────────┐
                         │  hdmi_text_controller IP  │
                         │  ┌────────────────────┐   │
                         │  │ World BRAM (1024)  │   │
                         │  │ Player/camera regs │   │
                         │  └─────────┬──────────┘   │
                         │            ▼              │
                         │   raycaster_engine ───►   │  double-buffered
                         │            │          frame buffer (BRAM)
                         │            ▼              │
                         │   VGA timing ► TMDS ──────┼──► HDMI ► monitor
                         └──────────────────────────┘
```

**Software (MicroBlaze + C).** The C program polls the USB keyboard through a MAX3421E
USB host controller (driven over AXI Quad SPI). It owns all the game logic: player
position, camera direction, collision rejection (you can't walk into a solid block), and
which blocks get placed or deleted. Player position and camera vectors use **Q16.16
fixed-point** (16 integer bits, 16 fractional bits) instead of IEEE-754 floats, which
keeps the math cheap and lets the hardware reuse the same number format. The C code writes
all of this into the hardware over AXI.

**Hardware (raycasting engine).** For each of the 320 screen columns, the engine shoots a
ray from the player into the world, walks the grid with a **DDA** (digital differential
analyzer) traversal until it hits a block, and uses the perpendicular distance to that
block to decide how tall to draw the column — closer blocks look bigger, giving the 3D
effect. To support variable-height blocks, the ray keeps stepping past the first hit to
find taller blocks behind it, stopping only once the column is fully covered. The whole
thing is implemented as a **20-state FSM pipeline** (see `raycaster_engine.sv`). Output is
**double-buffered** in BRAM so the screen never tears.

The raycasting math follows the classic [Lode Vandevenne raycasting
tutorial](https://lodev.org/cgtutor/raycasting.html), adapted to fixed-point and to FPGA
timing constraints.

### AXI Memory Map

| Region | Address | Purpose |
|---|---|---|
| World BRAM | `0x0000`–`0x0FFC` | 1024 cells. Each cell: low 4 bits = block type, next 3 bits = height. |
| Register | `0x2000` | Player X |
| Register | `0x2004` | Player Y |
| Register | `0x200C` | Camera direction X |
| Register | `0x2010` | Camera direction Y |
| Register | `0x2014` | Camera plane X |
| Register | `0x2018` | Camera plane Y |

---

## Repository Layout

```
Final_Project/
├── Block_game.xpr              # Vivado project file (open this to build)
├── mb_usb_hdmi_top.xsa         # Exported hardware handoff for Vitis
├── src/
│   ├── mb_usb_hdmi_top.sv      # Top-level module
│   └── hex_driver.sv           # Hex display driver
├── design_source/
│   ├── VGA_controller.sv       # 640×480 VGA timing generator
│   ├── Color_Mapper.sv
│   └── mb_block/               # MicroBlaze block design + generated IP
├── lab7.2ipv2/src/             # Custom video IP source (the interesting part)
│   ├── raycaster_engine.sv     # The 3D raycasting FSM
│   ├── hdmi_text_controller_v1_0.sv      # Top wrapper for the custom IP
│   ├── hdmi_text_controller_v1_0_AXI.sv  # AXI4-Lite slave + world BRAM + registers
│   └── hdmi_text_controller_v1_0_tb.sv   # Testbench
├── software/                   # C code for the MicroBlaze
│   ├── lw_usb_main.c           # Main game loop: input, movement, block edits
│   ├── lw_usb/                 # Lightweight USB / MAX3421E HID driver stack
│   └── hdmi_text_controller.c  # AXI read/write helpers
├── hdmi_tx_1.0/                # Real Digital HDMI (TMDS) transmitter IP
└── pin_assignment/
    └── mb_usb_hdmi_top.xdc     # Board pin constraints
```

The files worth reading first are **`lab7.2ipv2/src/raycaster_engine.sv`** (the rendering
engine) and **`software/lw_usb_main.c`** (the game logic).

---

## Building & Running

You'll need **Vivado** and **Vitis** (2023.x or compatible) and a Spartan-7 Urbana board
with an HDMI monitor and a USB keyboard.

1. Open `Block_game.xpr` in Vivado.
2. Generate the bitstream and program the board (`mb_usb_hdmi_top` is the top module).
3. Export the hardware (`mb_usb_hdmi_top.xsa` is included) and open it in Vitis.
4. Build the application from the `software/` sources and run it on the MicroBlaze.
5. Plug in an HDMI monitor and a USB keyboard, and start building.

---

## Engineering Highlights

The hard part of this project was **meeting timing** for a per-pixel 3D renderer on a small
FPGA. The first working version had a worst negative slack (WNS) of about **−99 ns** — far
from closing. A sequence of optimizations brought it to **−0.5 ns**:

- Switched from **IEEE-754 floats to Q16.16 fixed-point**, eliminating floating-point
  cores from the critical path (the single biggest win).
- Replaced multiplies and divides by powers of two with **bit shifts**.
- Dropped in Xilinx **Divider Generator IP** for the unavoidable divisions (delta
  distances and projected wall height) instead of inferring slow logic.
- **Pipelined the FSM** — splitting heavy operations (e.g. ray-direction multiply) across
  extra states so no single stage blew the clock period.
- **Double-buffered** the frame in BRAM to remove tearing.

Final design ran at **~61.6 MHz** using 4421 LUTs, 36 DSPs, 28.5 BRAMs, and 4490
flip-flops, drawing 0.44 W total.

---

## Use of AI

AI assistance (Claude) was used for narrow, well-scoped tasks: generating Minecraft-style
color palettes, debugging Vivado/Vitis errors and syntax, and suggesting timing
optimizations (which is how the Divider Generator IP was identified). The camera-plane
math in `lw_usb_main.c` was AI-assisted and is marked in a code comment. The architecture,
raycasting FSM, AXI integration, and game logic are our own.

---

## Limitations & Future Work

Because raycasting projects the world column-by-column, the camera can only look left and
right — **not up or down**. Pitch would require a true 3D renderer (e.g. per-pixel
raycasting or a triangle rasterizer) rather than the 2.5D column approach. Other natural
extensions: textured blocks (the block-texture ROM is stubbed in the block diagram),
flowing water, and a larger world.
