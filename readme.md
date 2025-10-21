# Workstation
Runneth Over Studio's default Linux Mint workstation configurations.

## Post-Install Script
Performs system updates, applies various themes & aesthetics, and installs & configures the following:

- **.NET SDK**
- **Vulkan SDK**
- **LibreOffice** (Flatpak)
- **VS Code** - Code Editor
- **Joplin** - Note-Taking
- **Bitwarden** - Password Vault
- **Blender** - 3D Modeling & Rendering
- **FreeCAD** - Parametric CAD
- **Inkscape** - Vector Graphics
- **Krita** - Raster Art
- **Flameshot** - Screenshot Utility

You can safely re-run the script at any time. Installed packages and Flatpaks are skipped automatically, and your existing VS Code settings are merged non-destructively with backups created in ~/.config/Code/User/.

## Running Directly from GitHub
You can run the setup script directly from this repository without cloning it locally.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Runneth-Over-Studio/Workstation/main/scripts/mint-workstation-setup.sh)
```

> 💡 This uses `curl` to fetch the script from GitHub and pipes it directly into `bash`.
> You’ll be prompted for sudo when needed.

## Optional Flags
| Flag            | Description                                                            | Example                                     |
| --------------- | ---------------------------------------------------------------------- | ------------------------------------------- |
| `--skip-vulkan` | Skips Vulkan SDK installation                                          | `./mint-workstation-setup.sh --skip-vulkan` |
| `--gpu=auto`    | Detects GPU vendor and installs drivers automatically (**default**)    | `./mint-workstation-setup.sh --gpu=auto`    |
| `--gpu=nvidia`  | Installs proprietary NVIDIA drivers using `ubuntu-drivers autoinstall` | `./mint-workstation-setup.sh --gpu=nvidia`  |
| `--gpu=amd`     | Installs Mesa Vulkan drivers (AMD open-source stack)                   | `./mint-workstation-setup.sh --gpu=amd`     |
| `--gpu=intel`   | Installs Mesa Vulkan drivers (Intel open-source stack)                 | `./mint-workstation-setup.sh --gpu=intel`   |
| `--help`        | Displays all available options                                         | `./mint-workstation-setup.sh --help`        |

## Verification
You can confirm successful installs using:

```bash
dotnet --info
vulkaninfo | head
code --version
flatpak list
```
