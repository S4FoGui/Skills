#!/usr/bin/env bash
# ==============================================================================
# PITON NVIDIA DOCTOR — v3.0.0 (edição para agentes)
# Diagnóstico, correção e rollback de NVIDIA no Linux
# (Debian/Ubuntu, Arch, Fedora/RHEL, openSUSE).
#
# Uso: piton-nvidia-doctor.sh <diag|fix|rollback|help> [--dry-run] [--porcelain] [--no-env]
#
#   diag        Somente leitura. Não altera nada.
#   fix         Aplica correções idempotentes (requer root, exceto com --dry-run).
#   rollback    Remove os arquivos gerados por este script e reconstrói o initramfs.
#   --dry-run   Mostra o que o fix/rollback faria, sem escrever nada.
#   --porcelain Logs humanos vão para stderr; stdout recebe só CHAVE=valor (p/ agentes).
#   --no-env    Não gera /etc/environment.d (variáveis Wayland/VA-API).
# ==============================================================================

set -u
set -o pipefail

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'; C_GRAY=$'\033[0;90m'
else
    C_RESET=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_CYAN=''; C_GRAY=''
fi

readonly BACKUP_ROOT="/var/backups/piton-nvidia"
readonly MODPROBE_NVIDIA="/etc/modprobe.d/99-piton-nvidia.conf"
readonly MODPROBE_BLACKLIST="/etc/modprobe.d/99-piton-nouveau-blacklist.conf"
readonly ENVIRONMENT_NVIDIA="/etc/environment.d/99-piton-nvidia.conf"

# --- Estado global (sempre inicializado: set -u) -------------------------------
DRY_RUN=false; PORCELAIN=false; APPLY_ENV=true; ACTION="diag"
DISTRO_ID="unknown"; DISTRO_LIKE="unknown"; DISTRO_NAME="Unknown Linux"
KERNEL="$(uname -r)"
NVIDIA_PRESENT=false; IS_HYBRID=false
DRIVER_PKG_PRESENT=false; NVIDIA_LOADED=false; NOUVEAU_LOADED=false
NV_VERSION=""; SMI_OK=false
MODESET_OK=false; PRESERVE_OK=false; SLEEP_SVC_ENABLED=0
SECURE_BOOT_ENABLED=false; DKMS_STATE="none"
SESSION_TYPE="unknown"; VULKAN_ICD=false; VAAPI_DRIVER=false
PENDING_REBOOT=false
ISSUES=""

# --- Logging --------------------------------------------------------------------
log_info()    { echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
log_ok()      { echo -e "${C_GREEN}[ OK ]${C_RESET} $*"; }
log_warn()    { echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
log_err()     { echo -e "${C_RED}[FAIL]${C_RESET} $*" >&2; }
log_section() { echo -e "\n${C_BOLD}${C_BLUE}══ $* ══${C_RESET}"; }
add_issue()   { case ",$ISSUES," in *",$1,"*) ;; *) ISSUES="${ISSUES:+$ISSUES,}$1" ;; esac; }

# --- Helpers --------------------------------------------------------------------
modprobe_has() { grep -rqsE "$1" /etc/modprobe.d /lib/modprobe.d /usr/lib/modprobe.d 2>/dev/null; }
have() { command -v "$1" >/dev/null 2>&1; }

nv_major() {
    local v="${NV_VERSION%%.*}"
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo 0
}

run() {
    if $DRY_RUN; then log_info "[dry-run] $*"; else "$@"; fi
}

write_file() { # write_file <caminho>  (conteúdo via stdin)
    local path="$1" content
    content="$(cat)"
    if $DRY_RUN; then
        log_info "[dry-run] escreveria $path:"
        printf '%s\n' "$content" | sed 's/^/      /'
    else
        mkdir -p "$(dirname "$path")"
        printf '%s\n' "$content" > "$path"
        log_ok "Arquivo gerado: $path"
    fi
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Esta ação precisa de root. Execute: sudo $0 $ACTION"
        exit 1
    fi
}

# ==============================================================================
# DIAGNÓSTICO
# ==============================================================================
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"; DISTRO_LIKE="${ID_LIKE:-$DISTRO_ID}"; DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    fi
    log_info "Distro: ${C_BOLD}${DISTRO_NAME}${C_RESET} (família: ${DISTRO_LIKE}) | Kernel: ${KERNEL}"
}

detect_hardware() {
    log_section "1. HARDWARE"
    local pci_gpus=""
    if have lspci; then
        pci_gpus="$(lspci -nn | grep -Ei 'vga|3d controller|display controller' || true)"
    else
        log_warn "lspci ausente (instale pciutils). Usando fallback em /sys."
        if grep -qis '^0x10de' /sys/bus/pci/devices/*/vendor 2>/dev/null; then pci_gpus="NVIDIA (via sysfs)"; fi
    fi

    if [[ -z "$pci_gpus" ]]; then
        log_err "Nenhuma GPU detectada no barramento PCI."
        add_issue "NO_GPU"
        return 0
    fi
    echo -e "${C_GRAY}${pci_gpus}${C_RESET}"

    if grep -qi 'nvidia' <<<"$pci_gpus"; then
        NVIDIA_PRESENT=true; log_ok "GPU NVIDIA encontrada."
    else
        log_warn "Nenhuma GPU NVIDIA no lspci."; add_issue "NO_NVIDIA_GPU"
    fi

    local gpu_count
    gpu_count="$(wc -l <<<"$pci_gpus")"
    if $NVIDIA_PRESENT && [[ $gpu_count -gt 1 ]] && grep -Eqi 'intel|amd|advanced micro' <<<"$pci_gpus"; then
        IS_HYBRID=true; log_info "Arquitetura híbrida (Optimus/PRIME) detectada."
    else
        log_info "GPU dedicada única (ou sem iGPU relevante)."
    fi
}

audit_driver_state() {
    log_section "2. DRIVER E MÓDULOS DE KERNEL"

    if grep -qs '^nouveau ' /proc/modules; then
        NOUVEAU_LOADED=true; log_warn "nouveau está CARREGADO (conflita com o driver proprietário)."
        add_issue "NOUVEAU_ACTIVE"
    else
        log_ok "nouveau não está carregado."
    fi

    if modinfo nvidia >/dev/null 2>&1 || have nvidia-smi || { have dkms && dkms status 2>/dev/null | grep -qi nvidia; }; then
        DRIVER_PKG_PRESENT=true
    fi
    NV_VERSION="$(cat /sys/module/nvidia/version 2>/dev/null || modinfo -F version nvidia 2>/dev/null || true)"

    if grep -qs '^nvidia ' /proc/modules; then
        NVIDIA_LOADED=true; log_ok "Módulo nvidia carregado (versão: ${NV_VERSION:-?})."
    elif $NVIDIA_PRESENT; then
        if $DRIVER_PKG_PRESENT; then
            log_err "Driver instalado, mas o módulo NÃO está carregado."; add_issue "MODULE_NOT_LOADED"
        else
            log_err "Driver proprietário NVIDIA não está instalado."; add_issue "NO_DRIVER"
        fi
    fi

    if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then
        SMI_OK=true; log_ok "nvidia-smi se comunica com a GPU."
    elif have nvidia-smi; then
        log_warn "nvidia-smi falhou ao falar com o driver."
    fi

    # DRM KMS
    if [[ -r /sys/module/nvidia_drm/parameters/modeset ]]; then
        local mv; mv="$(cat /sys/module/nvidia_drm/parameters/modeset)"
        if [[ "$mv" == "Y" || "$mv" == "1" ]]; then
            MODESET_OK=true; log_ok "nvidia-drm.modeset=1 ativo."
        else
            log_warn "nvidia-drm.modeset desativado (valor: $mv)."
            if modprobe_has 'options[[:space:]]+nvidia[-_]drm[[:space:]].*modeset=1'; then PENDING_REBOOT=true; else add_issue "NO_MODESET"; fi
        fi
    elif $NVIDIA_PRESENT && $DRIVER_PKG_PRESENT; then
        log_warn "nvidia_drm não carregado; modeset não verificável."
        modprobe_has 'options[[:space:]]+nvidia[-_]drm[[:space:]].*modeset=1' || add_issue "NO_MODESET"
    fi

    audit_secure_boot
    audit_dkms
}

audit_secure_boot() {
    if have mokutil; then
        if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
            SECURE_BOOT_ENABLED=true
            log_warn "Secure Boot ATIVO: módulos sem assinatura MOK serão recusados pelo kernel."
            if ! $NVIDIA_LOADED && $NVIDIA_PRESENT; then add_issue "SECURE_BOOT_BLOCK"; fi
        else
            log_ok "Secure Boot desativado."
        fi
    else
        log_info "mokutil ausente: estado do Secure Boot desconhecido."
    fi
}

audit_dkms() {
    if have dkms; then
        local st; st="$(dkms status 2>/dev/null | grep -i nvidia || true)"
        if [[ -z "$st" ]]; then
            DKMS_STATE="none"; log_info "Sem módulo nvidia no DKMS (pacote pré-compilado/akmods é normal)."
        else
            echo -e "${C_GRAY}${st}${C_RESET}"
            if grep -F "$KERNEL" <<<"$st" | grep -qi 'installed'; then
                DKMS_STATE="installed"; log_ok "DKMS: módulo nvidia instalado para $KERNEL."
            else
                DKMS_STATE="broken"; log_warn "DKMS: módulo nvidia NÃO instalado para $KERNEL."; add_issue "DKMS_BROKEN"
            fi
        fi
    else
        log_info "DKMS não instalado."
    fi
}

audit_power_and_sleep() {
    log_section "3. SUSPEND/RESUME E ENERGIA"

    if [[ -r /sys/module/nvidia/parameters/NVreg_PreserveVideoMemoryAllocations ]]; then
        if [[ "$(cat /sys/module/nvidia/parameters/NVreg_PreserveVideoMemoryAllocations)" == "1" ]]; then
            PRESERVE_OK=true; log_ok "NVreg_PreserveVideoMemoryAllocations=1 ativo."
        fi
    fi
    if ! $PRESERVE_OK; then
        if modprobe_has 'options[[:space:]]+nvidia[[:space:]].*NVreg_PreserveVideoMemoryAllocations=1'; then
            PENDING_REBOOT=true; log_warn "PreserveVideoMemoryAllocations configurado, aguardando reboot."
        elif $NVIDIA_PRESENT && $DRIVER_PKG_PRESENT; then
            log_warn "PreserveVideoMemoryAllocations=0 (causa clássica de tela preta ao acordar)."; add_issue "NO_PRESERVE_VRAM"
        fi
    fi

    if have systemctl; then
        local svc
        for svc in nvidia-suspend nvidia-hibernate nvidia-resume; do
            if ! systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q .; then
                log_warn "Unit ${svc}.service inexistente (pacote de driver incompleto?)."
            elif systemctl is-enabled "${svc}.service" >/dev/null 2>&1; then
                SLEEP_SVC_ENABLED=$((SLEEP_SVC_ENABLED + 1)); log_ok "Habilitado: ${svc}.service"
            else
                log_warn "Desabilitado: ${svc}.service"
            fi
        done
        if $DRIVER_PKG_PRESENT && [[ $SLEEP_SVC_ENABLED -lt 3 ]]; then add_issue "SLEEP_SVC_OFF"; fi
    fi
}

audit_display_server() {
    log_section "4. DISPLAY SERVER, VULKAN E VA-API"

    SESSION_TYPE="${XDG_SESSION_TYPE:-}"
    if [[ -z "$SESSION_TYPE" ]] && have loginctl; then
        local s t
        for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
            t="$(loginctl show-session "$s" -p Type --value 2>/dev/null || true)"
            if [[ "$t" == "wayland" || "$t" == "x11" ]]; then SESSION_TYPE="$t"; break; fi
        done
    fi
    SESSION_TYPE="${SESSION_TYPE:-unknown}"
    log_info "Sessão: ${C_BOLD}${SESSION_TYPE}${C_RESET}"

    if [[ "$SESSION_TYPE" == "wayland" && $(nv_major) -gt 0 && $(nv_major) -lt 555 ]]; then
        log_warn "Wayland com driver ${NV_VERSION} (<555): sem Explicit Sync → flickering/tearing."
        add_issue "OLD_DRIVER_WAYLAND"
    fi

    if compgen -G "/usr/share/vulkan/icd.d/*nvidia*" >/dev/null || compgen -G "/etc/vulkan/icd.d/*nvidia*" >/dev/null; then
        VULKAN_ICD=true; log_ok "Vulkan ICD da NVIDIA presente."
    elif $DRIVER_PKG_PRESENT; then
        log_warn "Vulkan ICD da NVIDIA ausente."; add_issue "NO_VULKAN_ICD"
    fi

    if compgen -G "/usr/lib*/dri/nvidia_drv_video.so" >/dev/null || compgen -G "/usr/lib/*/dri/nvidia_drv_video.so" >/dev/null; then
        VAAPI_DRIVER=true; log_ok "nvidia-vaapi-driver instalado."
    else
        log_info "nvidia-vaapi-driver ausente (opcional: decodificação por hardware em navegadores)."
        add_issue "NO_VAAPI"
    fi
}

full_diagnostic_run() {
    detect_distro
    detect_hardware
    if $NVIDIA_PRESENT; then
        audit_driver_state
        audit_power_and_sleep
        audit_display_server
    fi

    log_section "RESUMO"
    echo "Issues:         ${ISSUES:-nenhuma}"
    echo "Reboot pendente: $PENDING_REBOOT"
}

emit_porcelain() {
    $PORCELAIN || return 0
    cat >&3 <<EOF
DISTRO_ID=$DISTRO_ID
DISTRO_LIKE=$DISTRO_LIKE
KERNEL=$KERNEL
NVIDIA_PRESENT=$NVIDIA_PRESENT
IS_HYBRID=$IS_HYBRID
DRIVER_PKG_PRESENT=$DRIVER_PKG_PRESENT
NVIDIA_LOADED=$NVIDIA_LOADED
NV_VERSION=$NV_VERSION
NOUVEAU_LOADED=$NOUVEAU_LOADED
SMI_OK=$SMI_OK
MODESET_OK=$MODESET_OK
PRESERVE_VRAM_OK=$PRESERVE_OK
SLEEP_SERVICES_ENABLED=$SLEEP_SVC_ENABLED
SECURE_BOOT=$SECURE_BOOT_ENABLED
DKMS_STATE=$DKMS_STATE
SESSION_TYPE=$SESSION_TYPE
VULKAN_ICD=$VULKAN_ICD
VAAPI_DRIVER=$VAAPI_DRIVER
PENDING_REBOOT=$PENDING_REBOOT
ISSUES=$ISSUES
EOF
}

# ==============================================================================
# CORREÇÃO
# ==============================================================================
create_backup() {
    if $DRY_RUN; then log_info "[dry-run] criaria backup em $BACKUP_ROOT/<timestamp>"; return 0; fi
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    [[ -d /etc/modprobe.d ]]    && cp -r /etc/modprobe.d    "$BACKUP_DIR/modprobe.d"
    [[ -d /etc/environment.d ]] && cp -r /etc/environment.d "$BACKUP_DIR/environment.d"
    [[ -f /etc/default/grub ]]  && cp /etc/default/grub     "$BACKUP_DIR/grub"
    [[ -f /etc/mkinitcpio.conf ]] && cp /etc/mkinitcpio.conf "$BACKUP_DIR/mkinitcpio.conf"
    log_ok "Backup em: $BACKUP_DIR"
}

fix_nouveau_blacklist() {
    log_info "Blacklist do nouveau..."
    write_file "$MODPROBE_BLACKLIST" <<'EOF'
# Gerado por piton-nvidia-doctor
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
alias nouveau off
alias lbm-nouveau off
EOF
}

fix_nvidia_modprobe_params() {
    log_info "Parâmetros do módulo NVIDIA (DRM KMS, preserve VRAM)..."
    local drm_opts="modeset=1"
    # fbdev=1 só existe a partir da série 545
    [[ $(nv_major) -ge 545 ]] && drm_opts="modeset=1 fbdev=1"

    {
        echo "# Gerado por piton-nvidia-doctor"
        echo "options nvidia-drm ${drm_opts}"
        echo "options nvidia NVreg_PreserveVideoMemoryAllocations=1"
        echo "options nvidia NVreg_TemporaryFilePath=/var/tmp"
        # RTD3 só faz sentido em notebook híbrido
        if $IS_HYBRID; then echo "options nvidia NVreg_DynamicPowerManagement=0x02"; fi
    } | write_file "$MODPROBE_NVIDIA"
}

fix_environment() {
    if ! $APPLY_ENV; then log_info "--no-env: pulando variáveis de ambiente."; return 0; fi
    if $IS_HYBRID; then
        log_warn "Notebook híbrido: NÃO forço GBM_BACKEND/__GLX_VENDOR_LIBRARY_NAME/LIBVA globais (quebram PRIME offload e gastam bateria). Use prime-run por app."
        return 0
    fi
    log_info "Variáveis de ambiente Wayland/VA-API (desktop com GPU única)..."
    write_file "$ENVIRONMENT_NVIDIA" <<'EOF'
# Gerado por piton-nvidia-doctor
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
LIBVA_DRIVER_NAME=nvidia
VDPAU_DRIVER=nvidia
NVD_BACKEND=direct
ELECTRON_OZONE_PLATFORM_HINT=auto
EOF
}

fix_systemd_power_services() {
    have systemctl || { log_warn "systemctl ausente; pulando serviços."; return 0; }
    log_info "Habilitando serviços de suspend/hibernate/resume (apenas enable, sem restart)..."
    local svc
    for svc in nvidia-suspend nvidia-hibernate nvidia-resume; do
        if systemctl list-unit-files "${svc}.service" --no-legend 2>/dev/null | grep -q .; then
            if run systemctl enable "${svc}.service"; then log_ok "enable ${svc}.service"; else log_warn "falha ao habilitar ${svc}.service"; fi
        else
            log_warn "${svc}.service não existe nesta instalação."
        fi
    done
}

rebuild_modules() {
    local k="$KERNEL"
    if have akmods; then
        log_info "akmods: recompilando para $k..."
        run akmods --force --kernels "$k" || log_warn "akmods retornou erro."
    fi
    if have dkms && dkms status 2>/dev/null | grep -qi nvidia; then
        log_info "dkms autoinstall para $k..."
        run dkms autoinstall -k "$k" || log_warn "dkms autoinstall retornou erro (veja /var/lib/dkms/nvidia/*/build/make.log)."
    fi
}

rebuild_initramfs() {
    log_info "Reconstruindo initramfs..."
    if have update-initramfs; then
        run update-initramfs -u -k all
    elif have dracut; then
        run dracut --regenerate-all --force
    elif have mkinitcpio; then
        run mkinitcpio -P
    else
        log_warn "Nenhuma ferramenta de initramfs encontrada; reconstrua manualmente."
    fi
}

apply_complete_fix() {
    log_section "APLICANDO CORREÇÕES"
    if ! $NVIDIA_PRESENT; then log_err "Sem GPU NVIDIA: nada a corrigir."; return 1; fi
    if ! $DRIVER_PKG_PRESENT; then
        log_err "Driver proprietário não instalado. Instale-o primeiro (references/guia-nvidia-linux.md §2)."
        return 1
    fi
    if $SECURE_BOOT_ENABLED && ! $NVIDIA_LOADED; then
        log_warn "Secure Boot ativo e módulo não carrega: o fix NÃO assina módulos. Veja guia §3 (MOK)."
    fi

    create_backup
    fix_nouveau_blacklist
    fix_nvidia_modprobe_params
    fix_environment
    fix_systemd_power_services
    rebuild_modules
    rebuild_initramfs

    log_section "CONCLUÍDO"
    if $DRY_RUN; then log_info "Dry-run: nada foi alterado."; else log_ok "Configurações aplicadas. Reinicie para valer: sudo reboot"; fi
}

do_rollback() {
    log_section "ROLLBACK"
    local f
    for f in "$MODPROBE_NVIDIA" "$MODPROBE_BLACKLIST" "$ENVIRONMENT_NVIDIA"; do
        if [[ -e "$f" ]]; then run rm -f "$f" && ! $DRY_RUN && log_ok "Removido: $f"; fi
    done
    rebuild_initramfs
    log_info "Backups anteriores (se houver) estão em $BACKUP_ROOT. Reinicie para aplicar."
}

print_help() {
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

# ==============================================================================
# MAIN
# ==============================================================================
main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            diag|--diag|-d)       ACTION="diag" ;;
            fix|--fix|-f)         ACTION="fix" ;;
            rollback)             ACTION="rollback" ;;
            help|--help|-h)       ACTION="help" ;;
            --dry-run|-n)         DRY_RUN=true ;;
            --porcelain)          PORCELAIN=true ;;
            --no-env)             APPLY_ENV=false ;;
            *) echo "Argumento inválido: $arg" >&2; print_help >&2; exit 2 ;;
        esac
    done

    # Porcelain: logs humanos -> stderr; stdout (fd 3) só recebe CHAVE=valor
    if $PORCELAIN; then exec 3>&1 1>&2; fi

    case "$ACTION" in
        help)     print_help ;;
        diag)     full_diagnostic_run; emit_porcelain ;;
        fix)      $DRY_RUN || require_root
                  full_diagnostic_run
                  apply_complete_fix || { emit_porcelain; exit 1; }
                  emit_porcelain ;;
        rollback) $DRY_RUN || require_root; do_rollback ;;
    esac
}

main "$@"
