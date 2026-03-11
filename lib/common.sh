#!/bin/bash
################################################################################
# lib/common.sh - Utilidades comunes y funciones de logging
################################################################################

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
BOLD='\033[1m'
RESET='\033[0m'

# Version de la plataforma (unico punto de cambio para codigo ejecutable)
PLATFORM_VERSION="1.1"

# Funciones de logging
log_info() {
    echo -e "${BLUE}[INFO]${RESET} $1"
}

log_success() {
    echo -e "${GREEN}[ÉXITO]${RESET} $1"
}

log_warning() {
    echo -e "${YELLOW}[ADVERTENCIA]${RESET} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $1" >&2
}

log_debug() {
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "${CYAN}[DEBUG]${RESET} $1"
    fi
}

# Ejecutar comando con logging
exec_cmd() {
    local cmd="$1"
    local description="${2:-Ejecutando comando}"
    
    log_debug "Comando: $cmd"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}[DRY-RUN]${RESET} Ejecutaría: $cmd"
        return 0
    fi
    
    if eval "$cmd" >> "$LOG_FILE" 2>&1; then
        log_success "$description"
        return 0
    else
        local exit_code=$?
        log_error "$description falló (código de salida: $exit_code)"
        log_error "Revisar archivo de log: $LOG_FILE"
        return $exit_code
    fi
}

# Manejador de errores
error_handler() {
    local line_num=$1
    log_error "Script falló en la línea $line_num"
    log_error "Último comando: $BASH_COMMAND"
    log_error "Revisar log: $LOG_FILE"
    
    if [[ -n "${CURRENT_PHASE:-}" ]]; then
        log_warning "Instalación interrumpida en la Fase $CURRENT_PHASE"
        log_info "Puedes reanudar después con: sudo ./install.sh --resume"
    fi
    
    exit 1
}

trap 'error_handler $LINENO' ERR

command_exists() {
    command -v "$1" &> /dev/null
}

wait_for_confirmation() {
    local message="${1:-Presiona ENTER para continuar}"
    read -p "$message: "
}

detect_current_user() {
    if [[ $EUID -eq 0 ]]; then
        echo "root"
    elif [[ "$USER" == "debian" ]]; then
        echo "debian"
    else
        echo "otro"
    fi
}

is_service_running() {
    local service=$1
    systemctl is-active --quiet "$service"
}

backup_file() {
    local file=$1
    if [[ -f "$file" ]]; then
        local backup="${file}.backup-$(date +%Y%m%d-%H%M%S)"
        cp "$file" "$backup"
        log_info "Respaldado: $file → $backup"
    fi
}

replace_in_file() {
    local file=$1
    local search=$2
    local replace=$3
    
    if [[ ! -f "$file" ]]; then
        log_error "Archivo no encontrado: $file"
        return 1
    fi
    
    sed -i "s|${search}|${replace}|g" "$file"
}

create_dir() {
    local dir=$1
    local perms=${2:-755}
    local owner=${3:-root:root}
    
    mkdir -p "$dir"
    chmod "$perms" "$dir"
    chown "$owner" "$dir"
}

download_file() {
    local url=$1
    local dest=$2
    local max_retries=${3:-3}
    
    for i in $(seq 1 $max_retries); do
        if curl -fsSL "$url" -o "$dest"; then
            log_success "Descargado: $url"
            return 0
        else
            log_warning "Intento de descarga $i/$max_retries falló"
            sleep 2
        fi
    done
    
    log_error "Falló al descargar: $url"
    return 1
}

is_port_available() {
    local port=$1
    ! ss -tlnp | grep -q ":${port} "
}

get_system_info() {
    cat << EOF
SO: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)
Kernel: $(uname -r)
CPU: $(nproc) núcleos
RAM: $(free -h | awk '/^Mem:/ {print $2}')
Disco: $(df -h / | awk 'NR==2 {print $4}') disponible
EOF
}

calc_progress() {
    local current=$1
    local total=$2
    echo $(( (current * 100) / total ))
}

format_duration() {
    local seconds=$1
    local hours=$((seconds / 3600))
    local minutes=$(((seconds % 3600) / 60))
    local secs=$((seconds % 60))
    printf "%02d:%02d:%02d" $hours $minutes $secs
}

check_system_resources() {
    local min_ram_mb=3072
    local min_disk_gb=15
    
    local total_ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local total_ram_mb=$((total_ram_kb / 1024))
    
    if [[ $total_ram_mb -lt $min_ram_mb ]]; then
        log_warning "RAM baja: ${total_ram_mb}MB (recomendado: ${min_ram_mb}MB)"
    fi
    
    local avail_disk_gb=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    
    if [[ $avail_disk_gb -lt $min_disk_gb ]]; then
        log_error "Espacio en disco insuficiente: ${avail_disk_gb}GB (mínimo: ${min_disk_gb}GB)"
        return 1
    fi
    
    return 0
}

generate_random_string() {
    local length=${1:-32}
    openssl rand -base64 $length | tr -d "=+/" | cut -c1-$length
}

generate_random_hex() {
    local length=${1:-32}
    openssl rand -hex $length
}

is_docker() {
    [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null
}

ensure_not_docker() {
    if is_docker; then
        log_error "Este script no puede ejecutarse dentro de un contenedor Docker"
        exit 1
    fi
}
