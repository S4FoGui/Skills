#!/usr/bin/env bash
# ==============================================================================
# NVIDIA LINUX GAMING — v2.0.0 (edição para agentes)
# Camada de jogos: Vulkan/DXVK/VKD3D, libs 32-bit, PRIME offload, Steam Flatpak.
# Pressupõe driver saudável: se não estiver, use piton-nvidia-doctor.sh primeiro.
#
# Uso: nvidia-gaming-fix.sh <check|apply|steam-options|help> [--dry-run] [--yes] [--with-tools] [--porcelain]
#
#   check          Somente leitura (padrão). Rode como USUÁRIO comum, não root.
#   apply          Instala só o que o check apontou (libs 32-bit, vulkan-tools, ext. Flatpak).
#                  Nunca troca/remove o driver. Pede confirmação, salvo com --yes.
#   steam-options  Imprime references/steam-launch-options.md.
#   --dry-run      Mostra os comandos do apply sem executar.
#   --yes          Não pergunta (use só após consentimento do usuário na conversa).
#   --with-tools   No apply, instala também gamemode/mangohud/gamescope.
#   --porcelain    Logs humanos em stderr; stdout recebe só CHAVE=valor.
# ==============================================================================

set -u
set -o pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_GRAY=$'\033[0;90m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_GRAY=''
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="check"; DRY_RUN=false; ASSUME_YES=false; WITH_TOOLS=false; PORCELAIN=false

PKG_FAMILY="unknown"; DISTRO_NAME="Unknown Linux"
NVIDIA_PRESENT=false; IS_HYBRID=false; DRIVER_READY=false; NV_VERSION=""
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
VULKAN_NVIDIA=false; LIBS32_OK=false; PRIME_OFFLOAD="unknown"
STEAM_KIND="none"; FLATPAK_GL="n/a"; MODESET_OK=false
HAS_GAMEMODE=false; HAS_MANGOHUD=false; HAS_GAMESCOPE=false; HAS_PROTONTRICKS=false
ISSUES=""; OPTIONAL=""
SUDO=""; [[ $EUID -ne 0 ]] && SUDO="sudo"

log_info()    { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_ok()      { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_err()     { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }
log_section() { echo -e "\n${C_BOLD}${C_BLUE}══ $* ══${C_RESET}"; }
add_list()    { # add_list <VAR> <codigo>
    local cur="${!1}"
    case ",$cur," in *",$2,"*) ;; *) printf -v "$1" '%s' "${cur:+$cur,}$2" ;; esac
}
add_issue() { add_list ISSUES "$1"; }
add_opt()   { add_list OPTIONAL "$1"; }
have()      { command -v "$1" >/dev/null 2>&1; }

run() {
    if $DRY_RUN; then log_info "[dry-run] $*"; return 0; fi
    log_info "Executando: $*"
    "$@"
}

confirm() {
    $DRY_RUN && return 0
    $ASSUME_YES && return 0
    if [[ ! -t 0 ]]; then log_warn "Sem TTY para perguntar. Reexecute com --yes após o consentimento do usuário."; return 1; fi
    local a; read -r -p "$1 [s/N] " a
    [[ "$a" =~ ^([sSyY]|[sS]im|[yY]es)$ ]]
}

# ==============================================================================
# CHECAGENS
# ==============================================================================
detect_system() {
    local id="unknown" like=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        id="${ID:-unknown}"; like="${ID_LIKE:-}"; DISTRO_NAME="${PRETTY_NAME:-$id}"
    fi
    case " $id $like " in
        *" debian "*|*" ubuntu "*)  PKG_FAMILY="debian" ;;
        *" fedora "*|*" rhel "*)    PKG_FAMILY="fedora" ;;
        *" arch "*)                 PKG_FAMILY="arch" ;;
        *" suse "*|*" opensuse "*)  PKG_FAMILY="suse" ;;
    esac
    log_info "Distro: ${C_BOLD}${DISTRO_NAME}${C_RESET} (família: ${PKG_FAMILY}) | Kernel: $(uname -r) | Sessão: ${SESSION_TYPE}"
    if [[ $EUID -eq 0 ]]; then
        log_warn "Rodando como root: Steam/HOME/DISPLAY do usuário não serão vistos. Prefira rodar o check como usuário comum."
    fi
}

check_gpu_and_driver() {
    log_section "1. GPU E DRIVER (pré-requisito)"
    local gpus=""
    have lspci && gpus="$(lspci -nn | grep -Ei 'vga|3d controller|display controller' || true)"
    if grep -qi nvidia <<<"$gpus"; then
        NVIDIA_PRESENT=true
        echo -e "${C_GRAY}${gpus}${C_RESET}"
        if [[ "$(wc -l <<<"$gpus")" -gt 1 ]] && grep -Eqi 'intel|amd|advanced micro' <<<"$gpus"; then
            IS_HYBRID=true; log_info "Notebook híbrido (iGPU + NVIDIA)."
        fi
    else
        log_err "Nenhuma GPU NVIDIA detectada${gpus:+ (GPUs: veja lspci)}."; add_issue "NO_NVIDIA_GPU"; return 1
    fi

    NV_VERSION="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
    [[ -z "$NV_VERSION" ]] && NV_VERSION="$(cat /sys/module/nvidia/version 2>/dev/null || true)"

    if grep -qs '^nvidia ' /proc/modules && have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
        DRIVER_READY=true; log_ok "Driver NVIDIA ativo (versão ${NV_VERSION:-?})."
    else
        log_err "Driver NVIDIA não está funcional. Resolva com piton-nvidia-doctor.sh antes de olhar a camada de jogos."
        add_issue "DRIVER_NOT_READY"; return 1
    fi

    if [[ -r /sys/module/nvidia_drm/parameters/modeset ]] && [[ "$(cat /sys/module/nvidia_drm/parameters/modeset)" =~ ^(Y|1)$ ]]; then
        MODESET_OK=true
    else
        log_warn "nvidia-drm.modeset desativado (afeta Wayland/PRIME sync)."; add_issue "MODESET_OFF"
    fi
}

check_vulkan() {
    log_section "2. VULKAN (DXVK / VKD3D / Proton)"
    if have vulkaninfo; then
        local vk; vk="$(vulkaninfo --summary 2>/dev/null || true)"
        if grep -qi nvidia <<<"$vk"; then
            VULKAN_NVIDIA=true; log_ok "vulkaninfo enxerga a NVIDIA."
        else
            log_err "vulkaninfo NÃO lista a NVIDIA (quebra DXVK/VKD3D/Proton)."; add_issue "NO_VULKAN_NVIDIA"
        fi
    else
        log_warn "vulkaninfo ausente (pacote vulkan-tools)."; add_opt "NO_VULKAN_TOOLS"
        if compgen -G "/usr/share/vulkan/icd.d/nvidia_icd*.json" >/dev/null || compgen -G "/etc/vulkan/icd.d/nvidia_icd*.json" >/dev/null; then
            VULKAN_NVIDIA=true; log_ok "ICD Vulkan da NVIDIA presente (checagem por arquivo)."
        else
            log_err "ICD Vulkan da NVIDIA ausente."; add_issue "NO_VULKAN_NVIDIA"
        fi
    fi
}

check_32bit_libs() {
    log_section "3. LIBS NVIDIA 32-BIT (Steam/Proton/Wine)"
    local dirs d
    case "$PKG_FAMILY" in
        debian) dirs="/usr/lib/i386-linux-gnu" ;;
        arch)   dirs="/usr/lib32" ;;
        fedora|suse) dirs="/usr/lib" ;;
        *)      dirs="/usr/lib/i386-linux-gnu /usr/lib32" ;;
    esac
    for d in $dirs; do
        if compgen -G "$d/libGLX_nvidia.so*" >/dev/null; then LIBS32_OK=true; break; fi
    done
    if $LIBS32_OK; then log_ok "Libs NVIDIA 32-bit presentes."; else log_err "Libs NVIDIA 32-bit ausentes (jogos 32-bit e muitos launchers falham)."; add_issue "NO_32BIT_LIBS"; fi
}

check_prime() {
    $IS_HYBRID || return 0
    log_section "4. PRIME OFFLOAD (híbrido)"
    if ! have glxinfo; then log_warn "glxinfo ausente (mesa-utils/mesa-demos): teste de offload não executado."; add_opt "NO_GLXINFO"; return 0; fi
    if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        log_warn "Sem sessão gráfica acessível (DISPLAY/WAYLAND_DISPLAY vazios): teste de offload não executado."; return 0
    fi
    local def off
    def="$(glxinfo -B 2>/dev/null | grep -E 'OpenGL renderer' || true)"
    off="$(__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia glxinfo -B 2>/dev/null | grep -E 'OpenGL renderer' || true)"
    log_info "Padrão : ${def:-?}"
    log_info "Offload: ${off:-?}"
    if grep -qi nvidia <<<"$off"; then
        PRIME_OFFLOAD="ok"; log_ok "PRIME offload funciona (use as launch options por jogo)."
    else
        PRIME_OFFLOAD="fail"; log_err "Offload NÃO ativa a NVIDIA."; add_issue "PRIME_OFFLOAD_FAIL"
    fi
}

check_launchers() {
    log_section "5. STEAM / LAUNCHERS / FLATPAK"
    local native=false flat=false
    [[ -d "$HOME/.steam/steam" || -d "$HOME/.local/share/Steam" ]] && native=true
    [[ -d "$HOME/.var/app/com.valvesoftware.Steam" ]] && flat=true
    if $native && $flat; then STEAM_KIND="native+flatpak"; elif $native; then STEAM_KIND="native"; elif $flat; then STEAM_KIND="flatpak"; fi
    if [[ "$STEAM_KIND" == "none" ]]; then log_info "Steam não detectado nos caminhos comuns (ok se usa Lutris/Heroic/Bottles)."; add_opt "NO_STEAM"
    else log_ok "Steam: $STEAM_KIND"; fi

    if have flatpak; then
        local apps rts want
        apps="$(flatpak list --app --columns=application 2>/dev/null || true)"
        if grep -Eq 'com.valvesoftware.Steam|net.lutris.Lutris|com.heroicgameslauncher.hgl|com.usebottles.bottles' <<<"$apps"; then
            rts="$(flatpak list --runtime --columns=application 2>/dev/null || true)"
            want="nvidia-${NV_VERSION//./-}"
            if [[ -n "$NV_VERSION" ]] && grep -Fxq "org.freedesktop.Platform.GL.${want}" <<<"$rts" && grep -Fxq "org.freedesktop.Platform.GL32.${want}" <<<"$rts"; then
                FLATPAK_GL="ok"; log_ok "Extensões Flatpak GL/GL32 batem com o driver (${want})."
            else
                FLATPAK_GL="mismatch"; log_err "Flatpak sem extensões GL/GL32 ${want}: jogos em Flatpak não veem o driver."; add_issue "FLATPAK_GL_MISMATCH"
            fi
        fi
    fi

    have gamemoderun   && HAS_GAMEMODE=true   || add_opt "NO_GAMEMODE"
    have mangohud      && HAS_MANGOHUD=true   || add_opt "NO_MANGOHUD"
    have gamescope     && HAS_GAMESCOPE=true  || add_opt "NO_GAMESCOPE"
    have protontricks  && HAS_PROTONTRICKS=true
    log_info "gamemode=$HAS_GAMEMODE mangohud=$HAS_MANGOHUD gamescope=$HAS_GAMESCOPE protontricks=$HAS_PROTONTRICKS (opcionais)"
}

run_check() {
    detect_system
    if check_gpu_and_driver; then
        check_vulkan
        check_32bit_libs
        check_prime
        check_launchers
    fi
    log_section "RESUMO"
    echo "Issues:    ${ISSUES:-nenhuma}"
    echo "Opcionais: ${OPTIONAL:-nenhum}"
}

emit_porcelain() {
    $PORCELAIN || return 0
    cat >&3 <<EOF
PKG_FAMILY=$PKG_FAMILY
SESSION_TYPE=$SESSION_TYPE
NVIDIA_PRESENT=$NVIDIA_PRESENT
IS_HYBRID=$IS_HYBRID
DRIVER_READY=$DRIVER_READY
NV_VERSION=$NV_VERSION
MODESET_OK=$MODESET_OK
VULKAN_NVIDIA=$VULKAN_NVIDIA
LIBS32_OK=$LIBS32_OK
PRIME_OFFLOAD=$PRIME_OFFLOAD
STEAM_KIND=$STEAM_KIND
FLATPAK_GL=$FLATPAK_GL
HAS_GAMEMODE=$HAS_GAMEMODE
HAS_MANGOHUD=$HAS_MANGOHUD
HAS_GAMESCOPE=$HAS_GAMESCOPE
ISSUES=$ISSUES
OPTIONAL=$OPTIONAL
EOF
}

# ==============================================================================
# APLICAÇÃO (nunca mexe no driver)
# ==============================================================================
pm_install() {
    case "$PKG_FAMILY" in
        debian) run $SUDO apt-get install -y "$@" ;;
        fedora) run $SUDO dnf install -y "$@" ;;
        arch)   run $SUDO pacman -S --needed --noconfirm "$@" ;;
        suse)   run $SUDO zypper install -y "$@" ;;
        *)      log_warn "Distro não suportada para instalação automática."; return 1 ;;
    esac
}

apply_lib32() {
    log_info "Instalando libs NVIDIA 32-bit para ${PKG_FAMILY}..."
    case "$PKG_FAMILY" in
        debian)
            run $SUDO dpkg --add-architecture i386
            run $SUDO apt-get update
            local branch
            branch="$(dpkg -l 2>/dev/null | awk '/^ii +libnvidia-gl-[0-9]+/ {sub(/libnvidia-gl-/,"",$2); sub(/:.*/,"",$2); print $2; exit}')"
            if [[ -n "$branch" ]]; then
                pm_install "libnvidia-gl-${branch}:i386"
            elif dpkg -l 2>/dev/null | grep -Eq '^ii +libgl1-nvidia-(glvnd-)?glx'; then
                pm_install "libgl1-nvidia-glvnd-glx:i386"
            else
                log_warn "Não identifiquei o pacote GL da NVIDIA instalado; instale manualmente a variante :i386 dele."; return 1
            fi ;;
        fedora)
            if ! rpm -q rpmfusion-nonfree-release >/dev/null 2>&1; then log_warn "RPM Fusion nonfree não detectado; sem ele não há pacote NVIDIA 32-bit. Pulando."; return 1; fi
            pm_install xorg-x11-drv-nvidia-libs.i686 mesa-vulkan-drivers.i686 ;;
        arch)
            if ! grep -q '^\[multilib\]' /etc/pacman.conf 2>/dev/null; then log_warn "Repositório [multilib] desabilitado em /etc/pacman.conf: habilite-o (e rode pacman -Syu) antes."; return 1; fi
            pm_install lib32-nvidia-utils ;;
        suse)
            log_warn "openSUSE: instale a variante 32-bit dos pacotes GL do repositório NVIDIA (nome varia por versão do driver). Manual." ; return 1 ;;
        *)  log_warn "Distro não suportada."; return 1 ;;
    esac
}

apply_flatpak_gl() {
    local want="nvidia-${NV_VERSION//./-}"
    run flatpak install -y flathub "org.freedesktop.Platform.GL.${want}" "org.freedesktop.Platform.GL32.${want}" \
        || log_warn "Falha ao instalar ${want}. Rode 'flatpak update' e confira se essa versão já existe no Flathub."
}

apply_fixes() {
    log_section "APLICANDO (sem tocar no driver)"
    if ! $DRIVER_READY; then log_err "Driver não está pronto. Use piton-nvidia-doctor.sh."; return 1; fi
    if [[ -z "$ISSUES$OPTIONAL" ]]; then log_ok "Nada a aplicar."; return 0; fi

    local did=false
    if [[ ",$OPTIONAL," == *",NO_VULKAN_TOOLS,"* ]]; then
        confirm "Instalar vulkan-tools?" && { pm_install vulkan-tools; did=true; }
    fi
    if [[ ",$OPTIONAL," == *",NO_GLXINFO,"* ]]; then
        local pkg="mesa-utils"; [[ "$PKG_FAMILY" == "fedora" ]] && pkg="mesa-demos"; [[ "$PKG_FAMILY" == "suse" ]] && pkg="Mesa-demo-x"
        confirm "Instalar $pkg (glxinfo)?" && { pm_install "$pkg"; did=true; }
    fi
    if [[ ",$ISSUES," == *",NO_32BIT_LIBS,"* ]]; then
        confirm "Instalar libs NVIDIA 32-bit?" && { apply_lib32; did=true; }
    fi
    if [[ ",$ISSUES," == *",FLATPAK_GL_MISMATCH,"* ]]; then
        confirm "Instalar extensões Flatpak GL/GL32 da NVIDIA (${NV_VERSION})?" && { apply_flatpak_gl; did=true; }
    fi
    if $WITH_TOOLS; then
        local tools
        case "$PKG_FAMILY" in
            arch)   tools="gamemode lib32-gamemode mangohud lib32-mangohud gamescope" ;;
            fedora) tools="gamemode mangohud gamescope" ;;
            debian) tools="gamemode mangohud" ;;
            *)      tools="gamemode mangohud" ;;
        esac
        # shellcheck disable=SC2086
        confirm "Instalar ferramentas opcionais ($tools)?" && { pm_install $tools; did=true; }
    fi

    if [[ ",$ISSUES," == *",PRIME_OFFLOAD_FAIL,"* || ",$ISSUES," == *",NO_VULKAN_NVIDIA,"* ]]; then
        log_warn "PRIME_OFFLOAD_FAIL / NO_VULKAN_NVIDIA não se resolvem aqui: reinstalar userspace do driver (piton-nvidia-doctor.sh / guia §2)."
    fi
    if $DRY_RUN; then log_info "Dry-run: nada foi alterado."
    elif $did; then log_ok "Concluído. Rode 'check' de novo para validar."; else log_info "Nada foi aplicado."; fi
}

print_help() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            check|--check)                     ACTION="check" ;;
            apply|--apply)                     ACTION="apply" ;;
            steam-options|--print-steam-options) ACTION="steam-options" ;;
            help|--help|-h)                    ACTION="help" ;;
            --dry-run|-n)                      DRY_RUN=true ;;
            --yes|-y)                          ASSUME_YES=true ;;
            --with-tools)                      WITH_TOOLS=true ;;
            --porcelain)                       PORCELAIN=true ;;
            *) echo "Argumento inválido: $arg" >&2; print_help >&2; exit 2 ;;
        esac
    done
    if $PORCELAIN; then exec 3>&1 1>&2; fi

    case "$ACTION" in
        help)          print_help ;;
        steam-options) cat "$SCRIPT_DIR/../references/steam-launch-options.md" ;;
        check)         run_check; emit_porcelain ;;
        apply)         run_check; apply_fixes; local rc=$?; emit_porcelain; exit $rc ;;
    esac
}

main "$@"
