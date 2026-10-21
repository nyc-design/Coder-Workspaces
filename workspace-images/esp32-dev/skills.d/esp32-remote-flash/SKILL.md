---
name: esp32-remote-flash
description: Flash or monitor an ESP32 board that is plugged into the user's local PC from this Coder workspace. Use when the user wants to test/flash firmware on real hardware, mentions a board not being found, /dev/ttyUSB, serial port, esptool, idf.py flash, or "monitor". Explains the RFC2217 network-serial bridge that replaces USB passthrough.
---

# Flashing an ESP32 from a Coder workspace

Coder workspaces run as sysbox containers on a shared remote host. The user's
board is attached to their **local PC**, not this host. There is no USB device
to pass through, and sysbox blocks the host kernel modules that VirtualHere or
usbip would need. The working approach is **network serial over RFC2217**,
which esptool/idf.py support natively and which forwards the DTR/RTS lines the
ESP32 uses to enter its download bootloader.

## Step 1 — user starts a serial bridge on their PC

The board must be reachable over the network. Ask the user to run, on the
machine the board is plugged into:

```bash
# esp_rfc2217_server.py ships with ESP-IDF / esptool.
# pip install esptool   # if they don't have it
esp_rfc2217_server.py -v -p 4000 /dev/ttyUSB0    # Linux/macOS
esp_rfc2217_server.py -v -p 4000 COM5            # Windows
```

## Step 2 — make the port reachable from the workspace

Any of these works; pick what the user already has:

- **Tailscale** between their PC and the Coder host → use the tailnet IP.
- `coder port-forward <workspace> --tcp 4000:4000` run from their PC.
- A plain SSH reverse tunnel: `ssh -R 4000:localhost:4000 <host>`.

Confirm reachability: `nc -vz <host> 4000` from the workspace.

## Step 3 — flash / monitor from here

Use the baked `esp-remote` wrapper (preferred):

```bash
esp-remote flash   <host:port>     # build already done? just flash
esp-remote monitor <host:port>     # serial monitor
esp-remote run     <host:port>     # build + flash + monitor
esp-remote esptool <host:port> -- chip_id   # raw esptool
```

Or drive idf.py / esptool directly with a pyserial URL:

```bash
. "$IDF_PATH/export.sh"
idf.py -p 'rfc2217://<host>:4000?ign_set_control' flash monitor
esptool.py --port 'rfc2217://<host>:4000?ign_set_control' chip_id
```

`espflash` is also available and accepts a similar `--port` value.

## Notes & gotchas

- `?ign_set_control` tolerates bridges that don't expose every modem control
  line; esptool still toggles EN/IO0 over the RFC2217 control channel.
- If auto-reset into the bootloader fails, the user can hold the BOOT button
  while flashing starts, then release.
- Throughput is network-bound; large flashes are slower than local USB but
  fully functional for firmware testing.
- Never assume `/dev/ttyUSB*` exists inside the container — it does not unless
  a device was explicitly bridged. Default to the RFC2217 flow.
