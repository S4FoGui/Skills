---
name: nvidia-linux-doctor
description: Diagnostica, corrige e faz rollback de problemas de GPU NVIDIA no Linux (Debian/Ubuntu, Arch, Fedora/RHEL, openSUSE), cobrindo duas camadas - sistema/driver (tela preta, nouveau, DKMS, Secure Boot, Wayland, suspend, Optimus) e jogos (Steam, Proton, Wine, DXVK, VKD3D, Lutris, Heroic, Vulkan, libs 32-bit, Flatpak, launch options, PRIME offload). Use SEMPRE que o usuário mencionar NVIDIA no Linux com tela preta, nvidia-smi falhando ("couldn't communicate with the NVIDIA driver"), driver que não carrega após update de kernel, flickering/tearing no Wayland, bateria acabando em notebook híbrido, jogo que não abre no Proton ou roda na GPU integrada, "No GPUs found", stutter, DLSS/NVAPI, ou pedir para "instalar/consertar driver NVIDIA" ou "otimizar NVIDIA para jogos" - mesmo sem citar a palavra "skill" ou "diagnóstico".
---

# NVIDIA Linux Doctor

Fluxo para um agente diagnosticar e corrigir NVIDIA no Linux com segurança: **diagnosticar → explicar → confirmar → aplicar → reiniciar → verificar**. Duas camadas, nesta ordem:

| Camada | Script | Referência | Quando |
|---|---|---|---|
| **A. Sistema/driver** | `scripts/piton-nvidia-doctor.sh` | `references/guia-nvidia-linux.md` | Sempre primeiro: driver, kernel, DKMS, nouveau, Wayland, suspend |
| **B. Jogos** | `scripts/nvidia-gaming-fix.sh` | `references/jogos-nvidia-linux.md`, `references/steam-launch-options.md` | Depois que A está limpa e o problema envolve Steam/Proton/Wine/launchers |

Regra: se o sintoma é de jogo, rode `diag` da camada A mesmo assim. Com driver quebrado (`NO_DRIVER`, `MODULE_NOT_LOADED`, `NOUVEAU_ACTIVE`, `DKMS_BROKEN`), a camada B não tem o que diagnosticar (o script retorna `DRIVER_NOT_READY`).

## Pré-condições

- O agente precisa estar **na máquina com a GPU** (ou com shell nela). Em sandbox/VM sem GPU, o script só vai reportar `NO_GPU`: peça ao usuário para rodar `sudo bash scripts/piton-nvidia-doctor.sh diag` e colar a saída.
- `fix` e `rollback` exigem root. `diag` e `--dry-run` rodam sem root, mas `dkms`/`mokutil` podem dar resultado incompleto.
- Sessão remota (SSH) em máquina com tela preta: ok, e é até o caso comum. Avise que o reboot derruba a sessão.

## Fluxo da camada A (sistema/driver)

1. **Diagnosticar** (somente leitura):
   ```bash
   sudo bash scripts/piton-nvidia-doctor.sh diag --porcelain 2>/dev/null   # stdout = CHAVE=valor
   ```
   Para o relatório legível, rode sem `--porcelain`. Leia `ISSUES` e `PENDING_REBOOT`.

2. **Interpretar** `ISSUES` pela tabela abaixo.

3. **Propor o plano** em 2–4 linhas (o que será alterado e por quê) e **pedir confirmação** antes de qualquer escrita. Mostre o que será feito com:
   ```bash
   sudo bash scripts/piton-nvidia-doctor.sh fix --dry-run
   ```

4. **Aplicar** após o "sim":
   ```bash
   sudo bash scripts/piton-nvidia-doctor.sh fix
   ```
   Flags: `--no-env` (não gera variáveis de ambiente), `--dry-run`, `--porcelain`.

5. **Reiniciar só com autorização explícita** (`sudo reboot`). Depois, rode as verificações do §8 do guia e um `diag` final: `ISSUES` deve estar vazio, exceto `NO_VAAPI`, que é opcional.

6. **Se piorou:** `sudo bash scripts/piton-nvidia-doctor.sh rollback` remove só os arquivos que o script criou e reconstrói o initramfs. Backups ficam em `/var/backups/piton-nvidia/`.

## Tabela ISSUES → ação

| Código | Significado | Ação |
|---|---|---|
| `NO_GPU`, `NO_NVIDIA_GPU` | Sem GPU NVIDIA visível | Parar. Conferir `lspci`, BIOS, máquina errada. Não instalar nada |
| `NO_DRIVER` | Driver proprietário ausente | Instalar conforme guia §2 (confirmar com usuário), depois `diag` de novo |
| `MODULE_NOT_LOADED` | Instalado, mas não carrega | Checar `dmesg \| grep -i nvidia`; combinar com `NOUVEAU_ACTIVE`, `DKMS_BROKEN`, `SECURE_BOOT_BLOCK`; `fix` |
| `NOUVEAU_ACTIVE` | nouveau carregado | `fix` (blacklist + initramfs) + reboot |
| `DKMS_BROKEN` | Módulo não compilado p/ o kernel atual | `fix`; se falhar, instalar headers e ler `/var/lib/dkms/nvidia/*/build/make.log` |
| `SECURE_BOOT_BLOCK` | Secure Boot impede o módulo | **Não** resolvível pelo `fix`. Guia §3 (MOK, exige console físico) ou desativar na BIOS: decisão do usuário |
| `NO_MODESET` | `nvidia-drm.modeset` ausente | `fix` + reboot |
| `NO_PRESERVE_VRAM`, `SLEEP_SVC_OFF` | Risco de tela preta no suspend | `fix` + reboot |
| `OLD_DRIVER_WAYLAND` | Wayland com driver < 555 | Atualizar driver (fora do `fix`) ou sugerir sessão X11 |
| `NO_VULKAN_ICD` | Userspace do driver incompleto | Reinstalar pacote de userspace (`nvidia-utils`/`libnvidia-gl`) |
| `NO_VAAPI` | Sem decodificação por hardware | Opcional, só se o usuário reclamar de CPU alta em vídeo: guia §5 |

`PENDING_REBOOT=true` significa que a configuração já está escrita e só falta reiniciar: não rode `fix` de novo.

## Fluxo da camada B (jogos)

1. Rodar como **usuário comum** (não root; precisa de `$HOME`, `DISPLAY`/`WAYLAND_DISPLAY` e do Steam do usuário):
   ```bash
   bash scripts/nvidia-gaming-fix.sh check --porcelain 2>/dev/null
   ```
2. Interpretar `ISSUES` (obrigatórios) e `OPTIONAL` (só mencionar se relevante ao sintoma):

| Código | Significado | Ação |
|---|---|---|
| `DRIVER_NOT_READY` | Driver não funcional | Voltar à camada A |
| `NO_NVIDIA_GPU` | Sem NVIDIA | Parar |
| `MODESET_OFF` | `nvidia-drm.modeset` desligado | Camada A (`NO_MODESET`) |
| `NO_VULKAN_NVIDIA` | Vulkan não enxerga a NVIDIA (DXVK/VKD3D/Proton quebram) | Reinstalar userspace do driver (camada A, guia §2); não resolvível pelo `apply` |
| `NO_32BIT_LIBS` | Faltam libs NVIDIA 32-bit | `apply` |
| `PRIME_OFFLOAD_FAIL` | Em híbrido, offload não ativa a NVIDIA | Problema de driver/PRIME: camada A. Se `PRIME_OFFLOAD=ok`, basta usar as launch options |
| `FLATPAK_GL_MISMATCH` | Extensões Flatpak GL/GL32 não batem com o driver | `apply` (instala as extensões) ou `flatpak update` |
| `NO_VULKAN_TOOLS`, `NO_GLXINFO` (opcionais) | Falta `vulkaninfo`/`glxinfo` | `apply` |
| `NO_GAMEMODE`, `NO_MANGOHUD`, `NO_GAMESCOPE` (opcionais) | Ferramentas extras | Só `apply --with-tools` se o usuário quiser |

3. Mostrar o plano com `apply --dry-run`, **pedir confirmação**, então `apply` (ou `apply --yes` após o "sim"). O `apply` instala somente o que o `check` apontou e **nunca troca o driver**; no Arch exige `[multilib]` habilitado, no Fedora exige RPM Fusion, e openSUSE fica manual.
4. Sem `ISSUES` e o jogo ainda falha: o problema é de configuração por jogo. Ler `references/steam-launch-options.md` e propor **uma** opção de inicialização por vez (híbrido: PRIME; Wayland: `SDL_VIDEODRIVER=x11` ou sessão X11; diagnóstico: `PROTON_LOG=1`). Para sintoma → causa, ver `references/jogos-nvidia-linux.md` §3.
5. Se o usuário precisar de ajuda externa, coletar a lista do §6 do guia de jogos.

## O que o `fix` da camada A faz (e deliberadamente não faz)

Faz: backup; blacklist do nouveau; `/etc/modprobe.d/99-piton-nvidia.conf` (`modeset=1`, `fbdev=1` se driver ≥ 545, `PreserveVideoMemoryAllocations=1`, `NVreg_TemporaryFilePath`); `NVreg_DynamicPowerManagement=0x02` **só em híbrido**; variáveis Wayland/VA-API **só em desktop de GPU única**; `systemctl enable` de `nvidia-suspend/hibernate/resume`; rebuild de akmods/DKMS; rebuild do initramfs.

Não faz, por segurança: assinar módulos (Secure Boot), instalar/remover driver, `restart` dos serviços de sleep (disparam a rotina de suspend fora de hora e podem derrubar a sessão), habilitar `nvidia-persistenced` (anula economia de energia em híbrido), exportar `GBM_BACKEND`/`__GLX_VENDOR_LIBRARY_NAME` globais em notebook híbrido (quebra PRIME offload).

## Guardrails

- Nunca rode `fix`, instale/remova pacotes ou reinicie sem confirmação explícita do usuário na conversa atual.
- Se o usuário usa nouveau de propósito (ex.: GPU sem suporte no driver atual), não aplique o blacklist.
- Não edite GRUB, `/etc/default/grub` nem `mkinitcpio.conf` por conta própria; proponha a mudança e mostre o diff.
- Launch options de Steam são alteradas pelo usuário na interface da Steam; o agente propõe o texto, não edita arquivos da Steam por conta própria.
- Não afirme que "resolveu" antes do reboot e da verificação pós-reboot.
- Se `fix` retornar erro de DKMS/initramfs, pare, mostre o erro e não encadeie novos comandos às cegas.

## Relatório final ao usuário

Formato curto: **Causa** (1 linha) · **O que foi alterado** (arquivos/serviços) · **Pendente** (reboot, MOK, etc.) · **Como desfazer** (`rollback`).

## Arquivos

- `scripts/piton-nvidia-doctor.sh` — camada A: `diag | fix | rollback | help`, `--dry-run`, `--porcelain`, `--no-env`.
- `scripts/nvidia-gaming-fix.sh` — camada B: `check | apply | steam-options | help`, `--dry-run`, `--yes`, `--with-tools`, `--porcelain`.
- `references/guia-nvidia-linux.md` — instalação por distro, Secure Boot/MOK, híbrido, VA-API, sintomas, recovery via GRUB/TTY, verificação pós-reboot. Ler o §2 ao instalar driver, o §3 em Secure Boot e o §7 se o usuário estiver sem interface gráfica.
- `references/jogos-nvidia-linux.md` — pacotes de jogos por distro, sintoma → ação, Flatpak, Wayland x X11, o que coletar para pedir ajuda.
- `references/steam-launch-options.md` — opções de inicialização da Steam (PRIME, Vulkan, Proton log, NVAPI, GameMode, MangoHud, Gamescope, SDL/X11).
