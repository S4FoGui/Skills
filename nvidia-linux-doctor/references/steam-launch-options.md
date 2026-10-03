# Opções de inicialização Steam para NVIDIA no Linux

Steam > Jogo > Propriedades > Opções de inicialização. **Teste uma por vez**; só combine depois de saber qual resolve. Todas terminam em `%command%`.

## Notebook híbrido (PRIME): jogo abre na iGPU

Proton/DXVK/VKD3D usam Vulkan, então a variante Vulkan é a que importa na maioria dos jogos Proton; a GLX vale para jogos nativos OpenGL.

```text
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia %command%
```
```text
__NV_PRIME_RENDER_OFFLOAD=1 __VK_LAYER_NV_optimus=NVIDIA_only %command%
```
Combinada (nativo + Proton) com GameMode e MangoHud:
```text
__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only gamemoderun mangohud %command%
```
Em desktop de GPU única essas variáveis são desnecessárias.

## Diagnóstico

```text
PROTON_LOG=1 %command%
```
Log em `~/steam-<APPID>.log` (o APPID aparece na URL da loja ou em `steamcmd`/Propriedades).

## Proton / NVIDIA

```text
PROTON_ENABLE_NVAPI=1 %command%
```
NVAPI/DLSS: em Proton Experimental ou GE-Proton recentes o NVAPI costuma já vir ativo para GPUs NVIDIA; use a variável só se o jogo não oferecer DLSS. Confirme também que o jogo não está num Proton antigo.

```text
__GL_SYNC_TO_VBLANK=1 %command%
```
Só para jogos nativos OpenGL com tearing.

## Ferramentas

```text
gamemoderun %command%
mangohud %command%
gamescope -f -- %command%
```
`gamescope` ajuda quando o problema é compositor/resolução/VRR. No Steam **Flatpak**, MangoHud e Gamescope exigem as extensões Flatpak correspondentes (ex.: `org.freedesktop.Platform.VulkanLayer.MangoHud`); sem elas o comando falha.

## Wayland com jogo SDL travando ou sem janela

```text
SDL_VIDEODRIVER=x11 %command%
```
Primeiro teste uma sessão X11 inteira; se resolver, o problema é Wayland/driver, não o jogo.

## Shader cache (stutter)

Steam > Configurações > Downloads > **Shader Pre-Caching** ligado.
