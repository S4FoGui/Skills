# Guia de referência: NVIDIA no Linux

Índice: §1 Camadas · §2 Instalar driver · §3 Secure Boot/MOK · §4 Notebook híbrido · §5 VA-API · §6 Sintoma → ação · §7 Recovery · §8 Verificação pós-reboot

## 1. Camadas (por que quebra)

1. **Kernel:** DRM + módulos `nvidia`, `nvidia_modeset`, `nvidia_uvm`, `nvidia_drm`.
2. **Userspace:** libGLX/EGL, Vulkan ICD, VA-API/VDPAU, GBM.
3. **Display/compositor:** Wayland (Mutter, KWin, Hyprland, Sway) ou Xorg.

Quase todo bug é **desalinhamento entre camadas**: nouveau competindo com o proprietário, `modeset` desligado, DKMS sem recompilar após update de kernel, VRAM não preservada no suspend, Wayland sem Explicit Sync (driver < 555).

## 2. Instalar o driver (só se `NO_DRIVER`)

Não fixe número de versão de memória: use o recomendado pela distro e confirme na página de suporte da NVIDIA se a GPU é antiga (branch legacy).

**Debian/Ubuntu/Pop!_OS/Mint**
```bash
sudo apt update && sudo apt install -y build-essential dkms linux-headers-$(uname -r)
ubuntu-drivers devices          # mostra o recomendado (Ubuntu/Pop)
sudo ubuntu-drivers install     # instala o recomendado
# Debian: sudo apt install nvidia-driver (repo non-free habilitado)
```

**Fedora/RHEL (RPM Fusion)**
```bash
sudo dnf install -y https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
  https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
# Aguarde o akmods compilar (alguns minutos) ANTES de reiniciar:
modinfo -F version nvidia       # deve retornar a versão
```

**Arch/EndeavourOS/Manjaro**
```bash
sudo pacman -S --needed base-devel linux-headers nvidia-dkms nvidia-utils lib32-nvidia-utils nvidia-settings egl-wayland
# Kernel padrão: pode usar o pacote `nvidia` (pré-compilado) em vez de nvidia-dkms.
# Early loading (opcional): em /etc/mkinitcpio.conf → MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)
sudo mkinitcpio -P
```

**openSUSE:** use o repositório oficial NVIDIA (`zypper addrepo` + `zypper install-new-recommends --repo NVIDIA`).

## 3. Secure Boot / MOK (manual, exige console físico)

Com Secure Boot ativo, módulos DKMS precisam de assinatura. O agente **não** consegue concluir isso sozinho: o enrollment pede senha e confirmação no boot (tela azul do MOK Manager).

- **Ubuntu/Debian:** o instalador do driver costuma pedir a senha MOK. Se foi pulada: `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der` → reinicie → *Enroll MOK*.
- **Fedora:** `sudo kmodgenca -a` e `sudo mokutil --import /etc/pki/akmods/certs/public_key.der` → reinicie → *Enroll MOK*.
- **Alternativa:** desativar Secure Boot na BIOS (decisão do usuário).
- Verificar: `mokutil --sb-state`, `dmesg | grep -i "module verification"`.

## 4. Notebook híbrido (Optimus/PRIME)

- O script já aplica `NVreg_DynamicPowerManagement=0x02` (RTD3, Turing+) e **não** exporta variáveis NVIDIA globais.
- Rodar app na NVIDIA: `__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only <app>` (ou `prime-run <app>` onde existir).
- Alternar modo global: `envycontrol` (`--switch integrated|hybrid|nvidia`) ou `supergfxctl` (ASUS). Exige reboot.
- Não habilite `nvidia-persistenced` em híbrido: mantém a GPU acordada e anula o RTD3.

## 5. Aceleração de mídia (VA-API)

```bash
# Arch: nvidia-vaapi-driver · Fedora: nvidia-vaapi-driver (RPM Fusion) · Debian/Ubuntu: nvidia-vaapi-driver (ou libva-nvidia-driver)
export LIBVA_DRIVER_NAME=nvidia NVD_BACKEND=direct
vainfo                      # deve listar perfis NVDEC
```
Firefox: `about:config` → `media.ffmpeg.vaapi.enabled=true` (e, se necessário, `MOZ_DISABLE_RDD_SANDBOX=1`). Em desktops o script grava essas variáveis em `/etc/environment.d/`.

## 6. Sintoma → causa → ação

| Sintoma | Causa provável | Ação |
|---|---|---|
| Tela preta no boot (GDM/SDDM não abre) | nouveau ativo ou sem `modeset=1` | `fix` (blacklist + initramfs); se não logar, §7 |
| Tela preta ao acordar do suspend | VRAM não preservada | `fix` (`PreserveVideoMemoryAllocations=1` + services) |
| Flickering/tearing no Wayland | Driver < 555 sem Explicit Sync, ou sem modeset | Atualizar driver para ≥ 555 + compositor/Xwayland recentes; ou usar X11 |
| `NVIDIA-SMI has failed because it couldn't communicate` | Kernel novo sem DKMS recompilado; Secure Boot; nouveau | `diag` → `fix` (rebuild DKMS) → §3 se Secure Boot |
| Bateria acaba rápido (híbrido) | dGPU presa em D0 | `fix` (RTD3) + modo `hybrid`/`integrated`; sem persistenced |
| CPU alta em vídeo no navegador | Sem VA-API para NVDEC | §5 |
| Jogo/Vulkan não abre | ICD ausente (`nvidia-utils`/`libnvidia-gl` faltando) | Reinstalar userspace do driver; `vulkaninfo --summary` |

## 7. Recovery (sem interface gráfica)

1. No GRUB, edite a linha do kernel (`e`): acrescente `nouveau.modeset=0 systemd.unit=multi-user.target` (ou `3`) e boot (`Ctrl+X`).
2. Ou use TTY: `Ctrl+Alt+F3`.
3. Logue, rode `sudo ./scripts/piton-nvidia-doctor.sh fix` (ou `rollback` se o problema surgiu após o fix).
4. `sudo reboot`.

Arquivos gerados pelo script (todos removíveis pelo `rollback`): `/etc/modprobe.d/99-piton-nvidia.conf`, `/etc/modprobe.d/99-piton-nouveau-blacklist.conf`, `/etc/environment.d/99-piton-nvidia.conf`. Backups em `/var/backups/piton-nvidia/<timestamp>/`.

## 8. Verificação pós-reboot

```bash
nvidia-smi                                              # GPU e versão
cat /sys/module/nvidia_drm/parameters/modeset           # Y
cat /sys/module/nvidia/parameters/NVreg_PreserveVideoMemoryAllocations   # 1
lsmod | grep -E '^(nouveau|nvidia)'                     # só nvidia*
systemctl is-enabled nvidia-suspend nvidia-hibernate nvidia-resume
sudo ./scripts/piton-nvidia-doctor.sh diag --porcelain 2>/dev/null | grep -E '^(ISSUES|PENDING_REBOOT)='
```
Teste de suspend: suspender e acordar uma vez; a sessão deve voltar sem tela preta.
