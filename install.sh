#!/bin/bash
################################################################################
# Plataforma IoT con Seguridad Integrada - Instalador Automatizado v1.1
#
# Requisitos: Debian 13 (Trixie) limpio, acceso root/sudo
# Ejecución: sudo ./install.sh [--dry-run] [--resume]
#
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/ui.sh"
source "${SCRIPT_DIR}/lib/validation.sh"
source "${SCRIPT_DIR}/lib/secrets.sh"
source "${SCRIPT_DIR}/lib/phases.sh"

INSTALL_STATE_FILE="${SCRIPT_DIR}/.install-state"
CONFIG_FILE="${SCRIPT_DIR}/.config.env"
SECRETS_FILE="${HOME}/.iot-platform/.secrets"
LOG_FILE="${SCRIPT_DIR}/logs/install-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
RESUME_MODE=false
INTERNAL_RESUME=false  # Flag interno para continuación automática via runuser

################################################################################
# Helper: aceptar confirmación s/S/y/Y
################################################################################
is_yes() {
    [[ "${1:-}" =~ ^[sSyY]$ ]]
}

################################################################################
# Verificaciones Previas
################################################################################
preflight_checks() {
    log_info "Ejecutando verificaciones previas..."
    
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root o con sudo"
        log_error "Uso: sudo ./install.sh"
        exit 1
    fi
    
    if [[ ! -f /etc/debian_version ]]; then
        log_error "Este script requiere Debian Linux"
        exit 1
    fi
    
    local debian_version
    debian_version=$(cat /etc/debian_version | cut -d. -f1)
    if [[ "$debian_version" != "13" ]] && [[ "$debian_version" != "trixie"* ]]; then
        log_warning "Este script está diseñado para Debian 13 (Trixie)"
        log_warning "Tu versión: $(cat /etc/debian_version)"
        read -p "¿Continuar de todos modos? [s/N]: " confirm
        if ! is_yes "$confirm"; then
            exit 1
        fi
    fi
    
    local required_cmds=("git" "curl" "openssl" "bc")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Comando requerido no encontrado: $cmd"
            log_error "Por favor instala: apt-get update && apt-get install -y $cmd"
            exit 1
        fi
    done
    
    if ! curl -s --max-time 5 https://google.com > /dev/null 2>&1; then
        log_error "No se detectó conectividad a internet"
        exit 1
    fi
    
    log_success "Verificaciones previas completadas"
}

################################################################################
# Procesar Argumentos de Línea de Comandos
################################################################################
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --resume)
                RESUME_MODE=true
                shift
                ;;
            --internal-resume)
                # Flag interno usado por runuser para continuación automática
                # No requiere archivo de estado - comienza desde fase 2
                INTERNAL_RESUME=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Opción desconocida: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

################################################################################
# Mostrar Ayuda
################################################################################
show_help() {
    cat << EOF
Plataforma IoT con Seguridad Integrada - Instalador Automatizado v${PLATFORM_VERSION}

USO:
    sudo ./install.sh [OPCIONES]

OPCIONES:
    --dry-run       Vista previa de los pasos de instalación sin ejecutar cambios
    --resume        Reanudar desde el último punto de control exitoso
    -h, --help      Mostrar este mensaje de ayuda

EJEMPLOS:
    sudo ./install.sh              # Instalación normal
    sudo ./install.sh --dry-run    # Vista previa sin cambios
    sudo ./install.sh --resume     # Reanudar después de interrupción

REQUISITOS:
    - VPS Debian 13 (Trixie) limpio
    - Acceso root o sudo
    - Conectividad a internet
    - Mínimo 4GB RAM, 20GB disco
EOF
}

################################################################################
# Pantalla de Bienvenida
################################################################################
show_welcome() {
    clear
    show_banner "Plataforma IoT con Seguridad Integrada"
    
    echo -e "
${BLUE}═══════════════════════════════════════════════════════════════════${RESET}
${BOLD}              SISTEMA DE INSTALACIÓN AUTOMATIZADO v${PLATFORM_VERSION}                   ${RESET}
${BLUE}═══════════════════════════════════════════════════════════════════${RESET}

${YELLOW}ADVERTENCIA - LEE CUIDADOSAMENTE${RESET}

Este script hará:
  • Modificar la configuración del sistema (firewall, SSH, usuarios)
  • Instalar Docker, MySQL, Redis, Nginx y código de aplicación
  • Cambiar el puerto SSH de 22 a un puerto personalizado
  • Eliminar el usuario 'debian' por defecto (al final de la instalación)
  • Configurar seguridad de grado producción (5 capas)

${RED}REQUISITOS CRÍTICOS:${RESET}
  - VPS Debian 13 limpio (no sistema de producción)
  - Conexión a internet estable
  - ~10 minutos de tiempo dedicado
  - Acceso a consola VPS (en caso de que SSH falle)

${GREEN}LO QUE OBTENDRÁS:${RESET}
  - Plataforma IoT completa con backend FastAPI
  - 4 tipos de autenticación (Usuario, Admin, Gerente, Dispositivo)
  - Autenticación criptográfica de dispositivos (AES-256 + HMAC)
  - MySQL + Redis activos + MongoDB
  - 5 capas de seguridad (nftables -> Fail2Ban -> Nginx -> FastAPI -> BD)
  - Cero exposición de bases de datos (solo red interna Docker)

${BLUE}═══════════════════════════════════════════════════════════════════${RESET}
"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════════╗${RESET}"
        echo -e "${CYAN}║  MODO DRY-RUN ACTIVO - No se harán cambios al sistema   ║${RESET}"
        echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════════╝${RESET}"
        echo ""
    fi
}

################################################################################
# Menú Principal
################################################################################
show_main_menu() {
    echo ""
    echo -e "${BOLD}Selecciona una opción:${RESET}"
    echo ""
    echo -e "  ${GREEN}1)${RESET} Iniciar Instalación ${RED}(modificará tu sistema)${RESET}"
    echo -e "  ${CYAN}2)${RESET} Dry-Run ${CYAN}(solo vista previa, sin cambios)${RESET}"
    echo -e "  ${YELLOW}3)${RESET} Reanudar desde punto de control"
    echo -e "  ${RED}4)${RESET} Salir"
    echo ""
    echo -e "  ${YELLOW}CONSEJO:${RESET} Usa la bandera ${CYAN}--dry-run${RESET} para omitir este menú."
    echo ""
    
    local choice
    read -p "Ingresa tu elección [1-4]: " choice
    
    case $choice in
        1)
            echo ""
            echo -e "${YELLOW}Estás a punto de iniciar una instalación REAL.${RESET}"
            echo -e "${YELLOW}   Esto modificará la configuración de tu sistema.${RESET}"
            read -p "¿Estás seguro? [s/N]: " confirm_install
            if ! is_yes "$confirm_install"; then
                log_info "Instalación cancelada"
                show_main_menu
                return
            fi
            DRY_RUN=false
            return 0
            ;;
        2)
            DRY_RUN=true
            log_info "Entrando en modo dry-run (no se harán cambios)..."
            return 0
            ;;
        3)
            if [[ ! -f "$INSTALL_STATE_FILE" ]]; then
                log_error "No se encontró punto de control. No se puede reanudar."
                log_error "Inicia una nueva instalación en su lugar."
                exit 1
            fi
            RESUME_MODE=true
            return 0
            ;;
        4)
            log_info "Instalación cancelada por el usuario"
            exit 0
            ;;
        *)
            log_error "Opción inválida"
            show_main_menu
            ;;
    esac
}

################################################################################
# Recolectar Datos del Usuario
################################################################################
collect_user_inputs() {
    log_info "Recolectando parámetros de configuración..."
    echo ""
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${RESET}  ${BOLD}INFORMACIÓN IMPORTANTE${RESET}                                            ${CYAN}║${RESET}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${CYAN}║${RESET}                                                                        ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}  Los valores entre ${YELLOW}[corchetes]${RESET} son los valores por defecto o         ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}  auto-detectados por el sistema.                                       ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}                                                                        ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}  ${GREEN}Si deseas usar el valor por defecto: solo presiona ENTER${RESET}         ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}  ${GREEN}Si deseas cambiar el valor: escribe el nuevo valor y ENTER${RESET}       ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}                                                                        ${CYAN}║${RESET}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    
    # Auto-detectar IP actual
    local detected_ip
    detected_ip=$(hostname -I | awk '{print $1}')
    
    # Dirección IP del VPS
    read -p "Dirección IP del VPS [${detected_ip}]: " VPS_IP
    VPS_IP=${VPS_IP:-$detected_ip}
    validate_ip "$VPS_IP" || { log_error "Dirección IP inválida"; exit 1; }
    
    # Nuevo nombre de usuario
    read -p "Nuevo nombre de usuario (reemplazará debian/root) [iotadmin]: " NEW_USERNAME
    NEW_USERNAME=${NEW_USERNAME:-iotadmin}
    validate_username "$NEW_USERNAME" || { log_error "Nombre de usuario inválido"; exit 1; }
    
    # Puerto SSH
    read -p "Puerto SSH [5259]: " SSH_PORT
    SSH_PORT=${SSH_PORT:-5259}
    validate_port "$SSH_PORT" || { log_error "Puerto inválido"; exit 1; }
    
    # Dominio (opcional)
    read -p "Nombre de dominio (opcional, para SSL futuro) [ninguno]: " DOMAIN
    DOMAIN=${DOMAIN:-none}
    
    # Nombre de base de datos MySQL
    read -p "Nombre de base de datos MySQL [iot_platform]: " DB_NAME
    DB_NAME=${DB_NAME:-iot_platform}
    validate_db_name "$DB_NAME" || { log_error "Nombre de base de datos inválido"; exit 1; }
    
    # Subred Docker
    read -p "Subred de red Docker [172.20.0.0/16]: " DOCKER_SUBNET
    DOCKER_SUBNET=${DOCKER_SUBNET:-172.20.0.0/16}
    validate_subnet "$DOCKER_SUBNET" || { log_error "Subred inválida"; exit 1; }
    
    # Límite de memoria Redis
    read -p "Límite de memoria Redis [256MB]: " REDIS_MEMORY
    REDIS_MEMORY=${REDIS_MEMORY:-256MB}
    
    # Zona horaria (auto-detectar)
    local detected_tz
    detected_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "UTC")
    read -p "Zona horaria [${detected_tz}]: " TIMEZONE
    TIMEZONE=${TIMEZONE:-$detected_tz}
    
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║${RESET}  ${BOLD}CREDENCIALES DEL ADMINISTRADOR PRINCIPAL${RESET}                         ${CYAN}║${RESET}"
    echo -e "${CYAN}╠════════════════════════════════════════════════════════════════════════╣${RESET}"
    echo -e "${CYAN}║${RESET}                                                                        ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}  Configura el correo y contraseña para el administrador principal.     ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}  Este usuario tendrá ${YELLOW}TODOS los permisos${RESET} del sistema.                 ${CYAN}║${RESET}"
    echo -e "${CYAN}║${RESET}                                                                        ${CYAN}║${RESET}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    
    # Email del administrador
    while true; do
        read -p "Correo del administrador [admin@example.com]: " ADMIN_EMAIL
        ADMIN_EMAIL=${ADMIN_EMAIL:-admin@example.com}
        if validate_email "$ADMIN_EMAIL"; then
            break
        fi
        log_warning "Por favor ingresa un correo electrónico válido"
    done
    
    # Contraseña del administrador
    while true; do
        read -sp "Contraseña del administrador (mín. 8 caracteres): " ADMIN_PASSWORD
        echo ""
        if validate_password "$ADMIN_PASSWORD" 8; then
            read -sp "Confirma la contraseña: " ADMIN_PASSWORD_CONFIRM
            echo ""
            if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
                break
            else
                log_error "Las contraseñas no coinciden"
            fi
        fi
    done
    
    echo ""
    log_success "Configuración recolectada"
}

################################################################################
# Generar Resumen de Configuración
################################################################################
show_configuration_summary() {
    echo ""
    show_section_header "Resumen de Configuración"
    
    echo -e "
${BOLD}Configuración del Sistema:${RESET}
  IP del VPS:        ${GREEN}${VPS_IP}${RESET}
  Nuevo Usuario:     ${GREEN}${NEW_USERNAME}${RESET}
  Puerto SSH:        ${GREEN}${SSH_PORT}${RESET}
  Dominio:           ${GREEN}${DOMAIN}${RESET}
  Zona Horaria:      ${GREEN}${TIMEZONE}${RESET}

${BOLD}Configuración de Base de Datos:${RESET}
  Nombre de BD:      ${GREEN}${DB_NAME}${RESET}
  Subred Docker:     ${GREEN}${DOCKER_SUBNET}${RESET}
  Memoria Redis:     ${GREEN}${REDIS_MEMORY}${RESET}

${BOLD}Administrador Principal:${RESET}
  Email:             ${GREEN}${ADMIN_EMAIL}${RESET}
  Contraseña:        ${CYAN}[configurada]${RESET}

${BOLD}Secretos Auto-Generados:${RESET}
  Contraseña Root MySQL:   ${CYAN}[generada]${RESET}
  Contraseña Usuario MySQL: ${CYAN}[generada]${RESET}
  Contraseña Redis:         ${CYAN}[generada]${RESET}
  Clave Secreta JWT:        ${CYAN}[generada]${RESET}
  
${YELLOW}Los secretos se guardarán en: ${SECRETS_FILE}${RESET}
${YELLOW}¡DEBES respaldar este archivo después de la instalación!${RESET}
"
    
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${CYAN}═══ MODO DRY-RUN: No se harán cambios ═══${RESET}"
        echo ""
    fi
    
    read -p "¿Proceder con la instalación? [s/N]: " confirm
    if ! is_yes "$confirm"; then
        log_info "Instalación cancelada"
        exit 0
    fi
}

################################################################################
# Guardar Configuración
################################################################################
save_configuration() {
    log_info "Guardando configuración..."
    
    # Guardar tiempo de inicio para cálculo correcto de duración
    local start_time
    start_time=$(date +%s)
    
    # Escapar caracteres especiales en contraseña para evitar inyección
    # Escapa: \ → \\, " → \", $ → \$, ` → \`
    local escaped_password
    escaped_password=$(printf '%s' "$ADMIN_PASSWORD" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\$/\\$/g' -e 's/`/\\`/g')
    
    cat > "$CONFIG_FILE" << EOF
# Configuración de Instalación de Plataforma IoT
# Generado: $(date)

VPS_IP="$VPS_IP"
NEW_USERNAME="$NEW_USERNAME"
SSH_PORT="$SSH_PORT"
DOMAIN="$DOMAIN"
DB_NAME="$DB_NAME"
DOCKER_SUBNET="$DOCKER_SUBNET"
REDIS_MEMORY="$REDIS_MEMORY"
TIMEZONE="$TIMEZONE"

# Credenciales de Administrador
ADMIN_EMAIL="$ADMIN_EMAIL"
ADMIN_PASSWORD="$escaped_password"

# Tiempo de inicio para cálculo de duración
INSTALL_START_TIME="$start_time"
EOF
    
    chmod 600 "$CONFIG_FILE"
    log_success "Configuración guardada en $CONFIG_FILE"
}

################################################################################
# Ejecutar Instalación
################################################################################
execute_installation() {
    local start_phase=0
    
    # Si es continuación interna via runuser, comenzar desde fase 2
    if [[ "$INTERNAL_RESUME" == true ]]; then
        start_phase=2
        log_info "Continuación automática desde Fase 2 (como ${USER})"
        # Cargar configuración
        if [[ -f "$CONFIG_FILE" ]]; then
            source "$CONFIG_FILE"
        else
            log_error "Archivo de configuración no encontrado"
            exit 1
        fi
    # Cargar punto de control si está reanudando manualmente
    elif [[ "$RESUME_MODE" == true ]] && [[ -f "$INSTALL_STATE_FILE" ]]; then
        source "$INSTALL_STATE_FILE"
        start_phase=$((LAST_COMPLETED_PHASE + 1))
        log_info "Reanudando desde la Fase $start_phase"
    fi
    
    # Mostrar plan de instalación
    show_section_header "Plan de Instalación"
    echo "
Total de fases: 14 (FASE 0 - FASE 13)
Tiempo estimado: ~3 horas 15 minutos
Iniciando desde: Fase $start_phase
"
    
    # Generar secretos si no existen
    if [[ ! -f "$SECRETS_FILE" ]]; then
        generate_all_secrets
    fi
    
    # Lista de funciones de fase actualizada (14 fases: 0-13)
    local phases=(
        "phase_0_preparation"
        "phase_1_user_management"
        "phase_2_dependencies"
        "phase_3_firewall"
        "phase_4_fail2ban"
        "phase_5_ssh_hardening"
        "phase_6_docker"
        "phase_7_project_structure"
        "phase_8_fastapi_app"
        "phase_9_mysql_init"
        "phase_10_nginx"
        "phase_11_deployment"
        "phase_12_testing"
        "phase_13_cleanup"
    )
    
    # Ejecutar fases
    for i in "${!phases[@]}"; do
        if [[ $i -lt $start_phase ]]; then
            continue
        fi
        
        show_phase_header $i 14 "${phases[$i]}"
        
        if [[ "$DRY_RUN" == true ]]; then
            log_info "[DRY-RUN] Omitiendo ${phases[$i]}"
        else
            ${phases[$i]}
            
            # Si phase_1 retornó código especial 42, significa que hizo exec runuser
            # y este código nunca se ejecutará (el proceso fue reemplazado)
        fi
        
        # Guardar punto de control
        if [[ "$DRY_RUN" != true ]]; then
            echo "LAST_COMPLETED_PHASE=$i" > "$INSTALL_STATE_FILE"
            echo "TIMESTAMP=$(date +%s)" >> "$INSTALL_STATE_FILE"
            log_info "Punto de control guardado (Fase $i)"
        fi
        
        echo ""
        echo -e "${GREEN}Fase $i completada exitosamente${RESET}"
        echo ""
    done
    
    # Mostrar mensaje de finalización
    if [[ "$DRY_RUN" == true ]]; then
        show_dry_run_plan
    else
        show_completion_message
    fi
}

################################################################################
# Mensaje de Finalización
################################################################################
show_completion_message() {
    source "$CONFIG_FILE"
    
    local duration
    duration=$(calculate_duration)
    
    # Obtener la contraseña temporal para mostrar
    local temp_pass=""
    if [[ -f "$SECRETS_FILE" ]]; then
        temp_pass=$(grep 'TEMP_USER_PASSWORD=' "$SECRETS_FILE" 2>/dev/null | cut -d'"' -f2)
    fi
    
    clear
    show_banner "Plataforma IoT con Seguridad Integrada"
    
    echo -e "
${GREEN}+===================================================================+
|                                                                   |
|            INSTALACION COMPLETADA EXITOSAMENTE                    |
|                                                                   |
+===================================================================+${RESET}

  Duracion total:     ${duration}
  Fases completadas:  14 de 14
  Estado:             ${GREEN}EXITO${RESET}


${GREEN}+-------------------------------------------------------------------+
|  USUARIO DEBIAN - ELIMINACION AUTOMATICA                         |
+-------------------------------------------------------------------+${RESET}

  El usuario ${YELLOW}debian${RESET} será eliminado automáticamente en ~90 segundos.
  No necesitas hacer nada - el sistema se encargará (solo asegurate de no reiniciar ni apagar el servidor en ese tiempo).

  Para reconectar después, usa:

      ${CYAN}ssh ${NEW_USERNAME}@${VPS_IP} -p ${SSH_PORT}${RESET}
      Contraseña: ${GREEN}${temp_pass:-[ver archivo de secretos]}${RESET}


${RED}+-------------------------------------------------------------------+
|  RESPALDAR SECRETOS (CRITICO)                                    |
+-------------------------------------------------------------------+${RESET}

  El archivo de secretos contiene TODAS las contrasenas generadas.
  Si pierdes este archivo, perderas acceso a la base de datos.

  Ubicacion:  ${BOLD}${SECRETS_FILE}${RESET}

  Ejecuta para ver y respaldar tus secretos:

    ${CYAN}cat ${SECRETS_FILE}${RESET}


${YELLOW}+-------------------------------------------------------------------+
|  CREDENCIALES DE ACCESO                                           |
+-------------------------------------------------------------------+${RESET}

  ${BOLD}Administrador Principal:${RESET}
    Email:       ${GREEN}${ADMIN_EMAIL}${RESET}
    Contrasena:  ${CYAN}[la que configuraste]${RESET}

  ${BOLD}Usuarios de Prueba (opcional, eliminar en produccion):${RESET}
    gerente@iot-platform.local / password123
    user@iot-platform.local    / password123


${BLUE}+-------------------------------------------------------------------+
|  COMO ACCEDER A TU PLATAFORMA                                     |
+-------------------------------------------------------------------+${RESET}

  ${BOLD}Conexion SSH (administracion del servidor):${RESET}

    ssh ${NEW_USERNAME}@${VPS_IP} -p ${SSH_PORT}

  ${BOLD}API REST (integracion de aplicaciones):${RESET}

    Endpoint base:    http://${VPS_IP}/api/v1
    Verificar estado: http://${VPS_IP}/health

  ${BOLD}Probar autenticacion:${RESET}

    curl -X POST http://${VPS_IP}/api/v1/auth/login/admin \\
      -H \"Content-Type: application/json\" \\
      -d '{\"email\":\"${ADMIN_EMAIL}\",\"password\":\"TU_CONTRASENA\"}'


${CYAN}+-------------------------------------------------------------------+
|  PROXIMOS PASOS RECOMENDADOS                                      |
+-------------------------------------------------------------------+${RESET}

  1. Cambiar la contrasena del usuario ${NEW_USERNAME}
  2. Respaldar el archivo de secretos (ver arriba)
  3. Eliminar usuarios de prueba (gerente@iot-platform.local, user@iot-platform.local)
  4. Configurar certificado SSL/TLS para conexiones seguras
  5. Verificar eliminación de debian: ${CYAN}id debian${RESET} (debe dar error)


${WHITE}+-------------------------------------------------------------------+
|  DOCUMENTACION Y SOPORTE                                          |
+-------------------------------------------------------------------+${RESET}

  Log de instalacion:  ${LOG_FILE}

${GREEN}====================================================================${RESET}
${BOLD}          Gracias por usar el instalador de Plataforma IoT          ${RESET}
${GREEN}====================================================================${RESET}
"
}

################################################################################
# Calcular Duración (Usa INSTALL_START_TIME del config)
################################################################################
calculate_duration() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        
        # Usar INSTALL_START_TIME si existe, sino usar timestamp del state file
        local start_time="${INSTALL_START_TIME:-}"
        
        if [[ -z "$start_time" ]] && [[ -f "$INSTALL_STATE_FILE" ]]; then
            source "$INSTALL_STATE_FILE"
            start_time="${TIMESTAMP:-}"
        fi
        
        if [[ -n "$start_time" ]]; then
            local end_time
            end_time=$(date +%s)
            local duration=$((end_time - start_time))
            
            local hours=$((duration / 3600))
            local minutes=$(((duration % 3600) / 60))
            local seconds=$((duration % 60))
            
            printf "%02d:%02d:%02d" $hours $minutes $seconds
            return
        fi
    fi
    
    echo "N/A"
}

################################################################################
# Ejecución Principal
################################################################################
main() {
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE")
    exec 2>&1
    
    parse_arguments "$@"
    preflight_checks
    
    # Si es internal-resume, cargar config y continuar directamente
    if [[ "$INTERNAL_RESUME" == true ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "Archivo de configuración no encontrado para continuación interna"
            exit 1
        fi
        log_info "Modo de continuación interna activado"
        source "$CONFIG_FILE"
        execute_installation
        exit 0
    fi
    
    if [[ "$RESUME_MODE" != true ]]; then
        show_welcome
        
        if [[ "$DRY_RUN" == true ]]; then
            log_info "Modo dry-run activado vía bandera --dry-run. Omitiendo menú..."
            echo ""
        else
            show_main_menu
        fi
    fi
    
    if [[ "$RESUME_MODE" == true ]]; then
        if [[ ! -f "$CONFIG_FILE" ]]; then
            log_error "Archivo de configuración no encontrado. No se puede reanudar."
            exit 1
        fi
        log_info "Cargando configuración guardada..."
        [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
    else
        collect_user_inputs
        show_configuration_summary
        
        # Guardar config si NO existe O si NO estamos en dry-run con config existente
        if [[ "$DRY_RUN" != true ]]; then
            save_configuration
        elif [[ ! -f "$CONFIG_FILE" ]]; then
            save_configuration
        fi
    fi
    
    execute_installation
}

main "$@"
