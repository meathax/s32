# MiSTerClaw MCP setup

[MiSTerClaw](https://github.com/catallo/misterclaw) is an MCP server that lets
an AI agent (e.g. Claude Code) drive a MiSTer-FPGA over the LAN — launch a core,
grab screenshots, poke DIP switches, read temps. Handy for iterating on this
Sega System 32 core against real hardware.

Install it at **user scope** so it's available in every Claude Code project,
**on a machine that shares the LAN with your MiSTer**. (It cannot work from a
cloud/web session — that has no route to your home network.)

## One-time install

### 1. Server on the MiSTer (PowerShell on your PC)

```powershell
Invoke-WebRequest -Uri "https://github.com/catallo/misterclaw/releases/download/v0.7.0/misterclaw-linux-arm7" -OutFile "misterclaw"
scp .\misterclaw root@<MISTER-IP>:/media/fat/Scripts/
ssh root@<MISTER-IP> "chmod +x /media/fat/Scripts/misterclaw && /media/fat/Scripts/misterclaw --install"
```

Server listens on TCP 9900 and autostarts on boot. Keep 9900 **off** the
public internet — LAN only.

### 2. MCP bridge in WSL2

```bash
curl -L -o ~/misterclaw-mcp \
  https://github.com/catallo/misterclaw/releases/download/v0.7.0/misterclaw-mcp-linux-amd64
chmod +x ~/misterclaw-mcp
whoami   # note this for the command below
```

### 3. Register it at user scope (global to all projects)

Run on your PC (PowerShell). Replace `YOUR_WSL_USER` (from `whoami`) and
`YOUR_MISTER_IP` (the MiSTer's LAN IP, e.g. `192.168.1.50`):

```powershell
claude mcp add misterclaw --scope user -- wsl.exe -e /home/YOUR_WSL_USER/misterclaw-mcp --host YOUR_MISTER_IP
```

Verify with `claude mcp list`; inside any project, `/mcp` should show
`misterclaw` connected. This writes to your user config (`~/.claude.json`), so
it's available in every Claude Code project.

> If you run Claude Code **inside WSL** instead of native Windows, drop the
> `wsl.exe` wrapper:
> `claude mcp add misterclaw --scope user -- /home/<user>/misterclaw-mcp --host <MISTER-IP>`
