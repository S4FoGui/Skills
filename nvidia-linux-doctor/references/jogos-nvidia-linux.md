# Guia: NVIDIA no Linux para jogos (Steam, Proton, Wine, DXVK, VKD3D)

Índice: §1 Pré-requisito · §2 Pacotes por distro · §3 Sintoma → ação · §4 Flatpak · §5 Wayland/X11 · §6 O que coletar para pedir ajuda

## 1. Pré-requisito

A camada de jogos só funciona com o driver saudável (módulo carregado, `nvidia-smi` ok, sem nouveau). Se `nvidia-gaming-fix.sh check` retornar `DRIVER_NOT_READY`, pare e use `piton-nvidia-doctor.sh` (guia `guia-nvidia-linux.md`).

## 2. Pacotes por distro (referência manual)

Não fixe número de driver: use o recomendado pela distro (`ubuntu-drivers devices`). O `apply` do script instala apenas o que o check apontou e **nunca troca o driver**.

**Debian/Ubuntu/Mint/Pop!_OS**
```bash
sudo dpkg --add-architecture i386 && sudo apt update
sudo apt install vulkan-tools mesa-utils gamemode mangohud
# lib 32-bit com a MESMA branch do driver instalado (veja: dpkg -l 'libnvidia-gl-*')
sudo apt install libnvidia-gl-<branch>:i386
```
**Fedora/Nobara** (RPM Fusion nonfree habilitado; Nobara já traz)
```bash
sudo dnf install akmod-nvidia xorg-x11-drv-nvidia-libs.i686 mesa-vulkan-drivers.i686 vulkan-tools mesa-demos gamemode mangohud gamescope
modinfo -F version nvidia      # espere o akmod compilar antes de reiniciar
```
**Arch/Manjaro/EndeavourOS** (habilite `[multilib]` em `/etc/pacman.conf`, depois `pacman -Syu`)
```bash
sudo pacman -S --needed nvidia-utils lib32-nvidia-utils nvidia-settings vulkan-tools mesa-utils gamemode lib32-gamemode mangohud lib32-mangohud gamescope
# driver: `nvidia` (kernel padrão) ou `nvidia-dkms` + linux-headers (LTS/custom)
```
**openSUSE:** repositório NVIDIA oficial; pacotes `nvidia-video-G06`, `nvidia-gl-G06` e a variante 32-bit dos pacotes GL (nome varia com a versão).

## 3. Sintoma → causa → ação

| Sintoma | Causa provável | Ação |
|---|---|---|
| Jogo nem abre no Proton | Vulkan sem NVIDIA, libs 32-bit ausentes, Proton antigo | `check`; `NO_VULKAN_NVIDIA`/`NO_32BIT_LIBS`; testar Proton Experimental/GE-Proton; `PROTON_LOG=1` |
| "No GPUs found" / roda na iGPU | Falta PRIME offload | Launch options híbridas (`steam-launch-options.md`); `PRIME_OFFLOAD_FAIL` = problema de driver |
| Funciona no terminal, não no Flatpak | Extensão GL do Flatpak não bate com o driver | §4 (`FLATPAK_GL_MISMATCH`) |
| Tela preta/flicker no Wayland | Driver < 555, sem modeset | `piton-nvidia-doctor.sh` (`OLD_DRIVER_WAYLAND`, `NO_MODESET`); testar X11 e `gamescope -f -- %command%` |
| Crash após update de kernel | DKMS/Secure Boot | `piton-nvidia-doctor.sh` (`DKMS_BROKEN`, `SECURE_BOOT_BLOCK`) |
| Tearing no X11 | Sem compositor / sync | Usar compositor do ambiente; ou `nvidia-settings` → X Server Display Configuration → Advanced → *Force Full Composition Pipeline* (aumenta latência) |
| Stutter | Shader cache, Proton antigo, CPU governor | Shader Pre-Caching; `mangohud` para ver frametime; `gamemoderun`; `gamescope`; atualizar Proton |

## 4. Steam/Lutris/Heroic em Flatpak

O Flatpak usa extensões GL próprias, que precisam ter **exatamente** a versão do driver do host (pontos viram hífens):
```bash
flatpak update
flatpak install flathub org.freedesktop.Platform.GL.nvidia-<versao-com-hifens> org.freedesktop.Platform.GL32.nvidia-<versao-com-hifens>
# ex.: driver 580.65.06 → nvidia-580-65-06
```
Após atualizar o driver do host, é normal o Flatpak quebrar até a extensão correspondente existir no Flathub. Alternativa: aguardar ou usar a Steam nativa.

## 5. Wayland x X11

Ordem de teste para qualquer bug gráfico em jogo: (1) mesma sessão com `gamescope -f -- %command%`; (2) sessão X11; (3) `SDL_VIDEODRIVER=x11` por jogo; (4) outro Proton. Registre qual combinação funciona.

`nvidia-drm.modeset=1` vem do `fix` do doctor via `/etc/modprobe.d`. Só edite o GRUB/systemd-boot (`nvidia-drm.modeset=1` na linha do kernel) se, **depois do reboot**, `MODESET_OK` continuar `false` — e mostre o diff ao usuário antes.

## 6. O que coletar para pedir ajuda

Distro/versão · modelo da GPU · versão do driver (`nvidia-smi`) · Wayland ou X11 · jogo e launcher (Steam, Lutris, Heroic, Bottles) · versão do Proton/Wine · saída de `nvidia-gaming-fix.sh check` · `~/steam-<APPID>.log` (com `PROTON_LOG=1`).
