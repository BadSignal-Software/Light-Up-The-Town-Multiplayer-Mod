# Light Up The Town - Multiplayer Mod (Lutt-Net) 💡🌐

[![Status](https://img.shields.io/badge/Status-Alpha%20Development-orange)](#)
[![Version](https://img.shields.io/badge/Version-v0.11-blue)](#)
[![Engine](https://img.shields.io/badge/Engine-Unreal%20Engine%204%2F5-informational)](#)
[![Build Stability](https://img.shields.io/badge/Current%20Build-Unstable-red)](#)

A multiplayer modification for **Light Up The Town**, created by **ShadowCanvas815** and **Ctr1_sOftw4re**.

> ⚠️ **IMPORTANT:** This mod is currently in an **early alpha** build. Multiplayer and animations are the only features working right now. The build is **unstable** and may not work as intended. Expect bugs and frequent updates.

---

## 📌 Project Overview

**Lutt-Net** aims to bring seamless multiplayer functionality to *Light Up The Town*.

- **Estimated completion:** 1–2 months (✅ currently on track)
- **Newest addition:** Bean (temporary player model) and animations
- **Main problems:** Light syncing and textures

If you have anything that could help us, please [open an issue](../../issues) on this repository.

---

## 🛠️ Development Team

| Name | Role |
| :--- | :--- |
| **ShadowCanvas** (`ShadowCanvas815`) | Main Developer & Networking / Multiplayer Developer |
| **CtrlSoftware** (`Ctr1_sOftw4re`) | Assistant Developer, Texture & Animation Developer, QA Tester |

---

## ⚡ Current Status & Features

- **Current version:** `v0.11`
- **Development phase:** Early alpha
- **Build stability:** Unstable
- **Core architecture:** UE4SS injection + Python bridge (`bridge.py`)

---

## 📥 Installation Guide

### Step 1: Download & Prerequisites

1. Make sure **Python 3.x** is installed ([download Python](https://www.python.org/downloads/)).
2. Download the latest `MultiplayerModTest.zip` from the [Releases page](../../releases).

### Step 2: Extract Mod Files

Go to your game's installation directory, typically:

```text
C:\SteamLibrary\steamapps\common\Light Up The Town\LightUpTheTown\Binaries\Win64
```

1. Extract the `ue4ss` folder from the zip into that directory.
2. Place `dwmapi.dll` in the same `Win64` directory to enable mod injection.

---

## 🚀 How to Run & Connect

### Step 1: Open the Mod Directory

1. Navigate to:

   ```text
   C:\SteamLibrary\steamapps\common\Light Up The Town\LightUpTheTown\Binaries\Win64\ue4ss\Mods\LUTTNet
   ```

2. Click the folder path bar at the top, type `cmd`, and press **Enter** to open a Command Prompt in this folder.

### Step 2: Launch the Connection Bridge

**To host a game:**

```bash
python bridge.py host 7777
```

**To join a game:**

```bash
python bridge.py join <HOST_IP_OR_DOMAIN> 7777
```

---

## 🌐 Networking Setup Options

‼️ WE ARE PLANNING TO MAKE MULTIPLAYER JOINING MUCH SIMPLER LATER ON ONCE WE HAVE THE BASICS OF THE MOD DOWN - ADDING ROOM CODES ‼️

To play with people outside your local network, pick one of the following methods.

### Method 1: Tailscale (Recommended)

1. Install [Tailscale](https://tailscale.com/) on both machines.
2. Invite your friend to your Tailnet.
3. Use the host's Tailscale IP or Tailscale domain name in place of `<HOST_IP_OR_DOMAIN>`.

### Method 2: Port Forwarding

1. Open your router settings and forward port `7777` (UDP/TCP) to the host machine.
2. Use the host's public IP address or a Dynamic DNS (DDNS) hostname.

> **Note:** Make sure your ISP doesn't put you behind CGNAT, as this prevents port forwarding from working, this is only relevant if you are using method 2.

---

## 🔗 Helpful Links

- [Game's Steam store page](https://store.steampowered.com/app/3419910/Light_Up_The_Town/)
- [Python download](https://www.python.org/downloads/)
- [Tailscale download](https://tailscale.com/)

---

## 🗺️ Roadmap & Future Improvements

- [ ] In-game GUI
- [ ] Automated room code system (no command line required)
- [ ] Super easy installation
- [ ] Stability fixes and sync optimization

---

## 💬 Community & Support

Got feedback, bug reports, or questions?

- 🐛 **Bug reports & ideas:** [Open an issue](../../issues) on this repository.
- 📢 **Updates:** Keep an eye on this repository for new releases.

---

Developed by **ShadowCanvas** & **Ctr1_sOftw4re**.
