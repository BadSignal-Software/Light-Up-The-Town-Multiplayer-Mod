# Light Up The Town - Multiplayer Mod (Lutt-Net) 💡🌐

[![Status](https://img.shields.io/badge/Status-Alpha%20Development-orange)](#)
[![Version](https://img.shields.io/badge/Version-v0.08-blue)](#)
[![Engine](https://img.shields.io/badge/Engine-Unreal%20Engine%204%2F5-informational)](#)

A multiplayer modification for **Light Up The Town**, created by **ShadowCanvas815** and **Shadow_sOftw4re**.

---

## 📌 Project Overview

**Lutt-Net** aims to bring seamless multiplayer functionality to *Light Up The Town*. 

> ⚠️ **Note:** This project is currently in **early alpha development (v0.08)**. Features are actively being built, tested, and updated. Expect bugs and frequent updates.

Estimated Completion Date: 1 - 2 months.

Are we on track for completion date? ✅

---

## 🛠️ Development Team

| Name | Role |
| :--- | :--- |
| **ShadowCanvas** (`ShadowCanvas815`) | Main Developer |
| **CtrlSoftware** (`Ctr1_sOftw4re`) | Assistant Developer & QA Tester |

---

## ⚡ Current Status & Features

* **Current Version:** `v0.08`
* **Development Phase:** Early Alpha
* **Core Architecture:** UE4SS Injection + Python Bridge (`bridge.py`)

---

## 📥 Installation Guide

### Step 1: Download & Prerequisites
1. Ensure **Python 3.x** is installed on your system ([Download Python](https://www.python.org/downloads/)).
2. Download the latest `MultiplayerModTest.zip` from the [Releases page](../../releases).

### Step 2: Extract Mod Files
Navigate to your game installation directory, typically located at:
```text
C:\SteamLibrary\steamapps\common\Light Up The Town\LightUpTheTown\Binaries\Win64
```

1. Extract the `ue4ss` folder from the zip file into the directory above.
2. Place `dwmapi.dll` into the same directory (`Win64`) to enable mod injection.

---

## 🚀 How to Run & Connect

### Step 1: Open the Mod Directory
1. Navigate to:
   ```text
   C:\SteamLibrary\steamapps\common\Light Up The Town\LightUpTheTown\Binaries\Win64\ue4ss\Mods\LUTTNet
   ```
2. Click on the folder directory bar at the top, type `cmd`, and press **Enter** to open Command Prompt directly in this folder.

### Step 2: Launch the Connection Bridge

* **To Host a Game:**
  ```bash
  python bridge.py host 7777
  ```

* **To Join a Game:**
  ```bash
  python bridge.py join <HOST_IP_OR_DOMAIN> 7777
  ```

---

## 🌐 Networking Setup Options

To connect with players outside your local network, select one of the following methods:

### Method 1: Tailscale (Recommended)
1. Install [Tailscale](https://tailscale.com/) on both machines.
2. Invite your friend to your Tailnet.
3. Replace `<HOST_IP_OR_DOMAIN>` with the Host’s Tailscale IP or Tailscale domain name.

### Method 2: Port Forwarding
1. Access your router settings and forward port `7777` (UDP/TCP).
2. Use your Public IP address or a Dynamic DNS (DDNS) host.
   > **Note:** Ensure your ISP does not put you behind **CGNAT**, as this prevents port forwarding from working.

---

## 🗺️ Roadmap & Future Improvements

- [ ] In-game GUI interface
- [ ] Automated room code system (no command line required)
- [ ] Super easy installation
- [ ] Stability fixes and sync optimization

---

## 💬 Community & Support

Got feedback, bug reports, or questions?

* 🐛 **Bug Reports & Ideas:** Open an [Issue](../../issues) on this repository.
* 📢 **Updates:** Keep an eye on this repository for new releases and updates!

---
*Developed by ShadowCanvas & Shadow_sOftw4re.*
