#!/bin/bash

set -euo pipefail

# Configuration par défaut
LLAMA_SERVER="/home/perru/Git/models/llama.cpp/build/bin/llama-server"
HOST="127.0.0.1"
PORT="8080"
#CTX_SIZE="16384" # 128K tokens
CTX_SIZE="16384"          # Valeur de repli générique si aucun CTX_SIZE spécifique au modèle n'est défini
THREADS="16"
FLASH_ATTN="${FLASH_ATTN:-on}"    # on | off | auto (support llama.cpp --flash-attn) - surchargeable: FLASH_ATTN=off ./llama-manager.sh start qwen

# Fichiers de configuration persistants
PIDFILE="/tmp/llama-manager.pid"
MODELFILE="/tmp/llama-manager.model"
LOGDIR="/tmp/llama-manager-logs"
LOGFILE="$LOGDIR/llama-server.log"
PERSISTENT_STATE="$HOME/.llama_manager_state"

# Configuration Redis
REDIS_HOST="localhost"
REDIS_PORT="6379"
REDIS_PREFIX="llama_conv_"

# Timeout pour le démarrage
START_TIMEOUT=180

# Configuration ACE Server
ACE_SERVER_BIN="/home/perru/Git/models/acestep.cpp/build/ace-server"
ACE_MODELS_DIR="$HOME/models/acestep/models"
ACE_ADAPTERS_DIR="$HOME/models/acestep/adapters"

# Déclaration des tableaux associatifs
declare -A MODELS
declare -A HF_REPOS
declare -A HF_FILES
declare -A MODEL_DIRS
declare -A MMPROJ_REPOS
declare -A MMPROJ_FILES
declare -A MMPROJ_PATHS
declare -A MODEL_CTX_SIZE   # <-- NOUVEAU : taille de contexte spécifique par modèle

# ------------------------------------------------------------
# Modèles
# ------------------------------------------------------------

# Qwen
MODELS[qwen]="$HOME/models/qwen3-coder-30b/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
HF_REPOS[qwen]="unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"
HF_FILES[qwen]="Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
MODEL_DIRS[qwen]="$HOME/models/qwen3-coder-30b"
MODEL_CTX_SIZE[qwen]="65536"

# Gemma
MODELS[gemma]="$HOME/models/gemma-4-26b-a4b/gemma-4-26B-A4B-it-UD-IQ4_XS.gguf"
HF_REPOS[gemma]="unsloth/gemma-4-26B-A4B-it-GGUF"
HF_FILES[gemma]="gemma-4-26B-A4B-it-UD-IQ4_XS.gguf"
MODEL_DIRS[gemma]="$HOME/models/gemma-4-26b-a4b"
MODEL_CTX_SIZE[gemma]="65536"

# Qwen3.6 35B A3B Uncensored (HauhauCS, variante Aggressive, MoE, vision multimodale)
MODELS[qwen3.6]="$HOME/models/qwen3.6-35b-uncensored/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
HF_REPOS[qwen3.6]="HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive"
HF_FILES[qwen3.6]="Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
MODEL_DIRS[qwen3.6]="$HOME/models/qwen3.6-35b-uncensored"
MMPROJ_REPOS[qwen3.6]="HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive"
MMPROJ_FILES[qwen3.6]="mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf"
MMPROJ_PATHS[qwen3.6]="$HOME/models/qwen3.6-35b-uncensored/mmproj-Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-f16.gguf"
MODEL_CTX_SIZE[qwen3.6]="65536"

# Qwen3 Coder Next (REAM, AWQ 4bit -> GGUF requantisé Q4_K_M, 60B params, ~36.7 GB)
MODELS[qwen-next]="$HOME/models/qwen3-coder-next/qwen3-coder-next-ream-awq-4bit-q4_k_m.gguf"
HF_REPOS[qwen-next]="Tho465/Qwen3-Coder-Next-REAM-AWQ-4bit-Q4_K_M-GGUF"
HF_FILES[qwen-next]="qwen3-coder-next-ream-awq-4bit-q4_k_m.gguf"
MODEL_DIRS[qwen-next]="$HOME/models/qwen3-coder-next"
MODEL_CTX_SIZE[qwen-next]="65536"

# ACE Server (Gestion de modèles locaux / répertoires)
MODELS[acestep]="$ACE_MODELS_DIR"
HF_REPOS[acestep]="acestep/acestep"
HF_FILES[acestep]="models"
MODEL_DIRS[acestep]="$ACE_MODELS_DIR"
# Pas de CTX_SIZE pour acestep (non applicable, ace-server ne prend pas -c)

# ============================================================
# Fonctions utilitaires
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# ============================================================
# Résolution du CTX_SIZE effectif pour un modèle donné
# ============================================================
#
# Ordre de priorité :
#   1. Variable d'environnement CTX_SIZE_<nom_modele_normalise>
#      (ex: CTX_SIZE_qwen_next=98304 ./llama-manager.sh start qwen-next)
#   2. Valeur définie dans MODEL_CTX_SIZE[<nom>]
#   3. Valeur générique $CTX_SIZE (fallback)
#
resolve_ctx_size() {
    local name="$1"
    local env_var_name
    # Normalisation du nom pour en faire un nom de variable bash valide
    # (remplace tout caractère non alphanumérique par '_')
    env_var_name="CTX_SIZE_$(echo "$name" | tr -c '[:alnum:]' '_')"

    if [[ -n "${!env_var_name:-}" ]]; then
        echo "${!env_var_name}"
        return 0
    fi

    if [[ -n "${MODEL_CTX_SIZE[$name]+x}" ]]; then
        echo "${MODEL_CTX_SIZE[$name]}"
        return 0
    fi

    echo "$CTX_SIZE"
}

# ============================================================
# Fonctions d'affichage du contexte
# ============================================================

show_context_info() {
    local ctx_size="${1:-$CTX_SIZE}"

    log "Context Size: $ctx_size tokens"
    log "Context Size: $((ctx_size / 1024))K tokens"
    log "Flash Attention: $FLASH_ATTN"

    # Estimation de la mémoire utilisée par le contexte
    local estimated_mem_mb=$((ctx_size * 4 / 1024))  # Approximation 4 bytes par token
    log "Estimated VRAM usage: ~${estimated_mem_mb} MB"

    # Vérification si le contexte est trop grand
    if [[ $ctx_size -gt 262144 ]]; then
        log "WARNING: Context size > 256K tokens - may cause memory issues"
    elif [[ $ctx_size -gt 131072 ]]; then
        log "WARNING: Context size > 128K tokens - may cause memory issues"
    elif [[ $ctx_size -gt 65536 ]]; then
        log "INFO: Context size > 64K tokens - running with caution"
    else
        log "INFO: Context size within normal range"
    fi
}

# ============================================================
# Mise à jour de llama.cpp
# ============================================================

update_llama_cpp() {
    local llama_cpp_dir="/home/perru/Git/models/llama.cpp"

    log "Updating llama.cpp..."

    if [[ ! -d "$llama_cpp_dir" ]]; then
        log "ERROR: llama.cpp directory not found at $llama_cpp_dir"
        log "Please clone the repository first:"
        log "  git clone https://github.com/ggerganov/llama.cpp.git $llama_cpp_dir"
        exit 1
    fi

    cd "$llama_cpp_dir" || exit 1
    git fetch origin

    local current_commit=$(git rev-parse HEAD)
    local upstream_commit=""

    if upstream_commit=$(git rev-parse origin/main 2>/dev/null); then
        :
    elif upstream_commit=$(git rev-parse origin/master 2>/dev/null); then
        :
    elif upstream_commit=$(git rev-parse origin/HEAD 2>/dev/null); then
        :
    else
        log "ERROR: Could not find upstream branch reference"
        exit 1
    fi

    if [[ "$current_commit" != "$upstream_commit" ]]; then
        log "New updates available for llama.cpp"
        log "Current commit: $current_commit"
        log "Upstream commit: $upstream_commit"

        if ! git pull origin "$(git rev-parse --abbrev-ref HEAD)"; then
            log "ERROR: Failed to pull updates from origin"
            exit 1
        fi

        log "llama.cpp updated successfully"
    else
        log "llama.cpp is already up to date"
    fi

    log "Building llama.cpp with Vulkan support..."
    rm -rf build
    cmake -B build \
      -DGGML_VULKAN=ON \
      -DCMAKE_BUILD_TYPE=Release

    cmake --build build -j$(nproc)

    if [[ ! -f "build/bin/llama-server" ]]; then
        log "ERROR: Failed to build llama-server"
        exit 1
    fi

    log "llama.cpp built successfully with Vulkan support"
    cd - > /dev/null || exit 1
    log "llama.cpp update completed"
}

# ============================================================
# Mise à jour de acestep.cpp
# ============================================================

update_acestep_cpp() {
    local acestep_dir="/home/perru/Git/models/acestep.cpp"

    log "Updating acestep.cpp..."

    if [[ ! -d "$acestep_dir" ]]; then
        log "ERROR: acestep.cpp directory not found at $acestep_dir"
        log "Please clone the repository first:"
        log "  git clone https://github.com/acestep/acestep.cpp.git $acestep_dir"
        exit 1
    fi

    cd "$acestep_dir" || exit 1
    git fetch origin

    local current_commit=$(git rev-parse HEAD)
    local upstream_commit=""

    if upstream_commit=$(git rev-parse origin/main 2>/dev/null); then
        :
    elif upstream_commit=$(git rev-parse origin/master 2>/dev/null); then
        :
    elif upstream_commit=$(git rev-parse origin/HEAD 2>/dev/null); then
        :
    else
        log "ERROR: Could not find upstream branch reference"
        exit 1
    fi

    if [[ "$current_commit" != "$upstream_commit" ]]; then
        log "New updates available for acestep.cpp"
        log "Current commit: $current_commit"
        log "Upstream commit: $upstream_commit"

        if ! git pull origin "$(git rev-parse --abbrev-ref HEAD)"; then
            log "ERROR: Failed to pull updates from origin"
            exit 1
        fi

        log "acestep.cpp updated successfully"
    else
        log "acestep.cpp is already up to date"
    fi

    log "Building acestep.cpp with Vulkan support..."
    rm -rf build
    cmake -B build \
      -DGGML_VULKAN=ON \
      -DCMAKE_BUILD_TYPE=Release

    cmake --build build -j$(nproc)

    if [[ ! -f "build/bin/ace-server" ]]; then
        log "ERROR: Failed to build ace-server"
        exit 1
    fi

    log "acestep.cpp built successfully with Vulkan support"
    cd - > /dev/null || exit 1
    log "acestep.cpp update completed"
}

# ============================================================
# PID
# ============================================================

get_pid() {
    if [[ -f "$PIDFILE" ]]; then
        cat "$PIDFILE"
    fi
}

server_running() {
    local pid
    pid="$(get_pid || true)"
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# ============================================================
# Redis - Gestion des conversations
# ============================================================

save_conversation() {
    local session_id="$1"
    local conversation_data="$2"
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" SET "${REDIS_PREFIX}${session_id}" "$conversation_data" 2>/dev/null || true
    fi
}

load_conversation() {
    local session_id="$1"
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" GET "${REDIS_PREFIX}${session_id}" 2>/dev/null || true
    fi
}

delete_conversation() {
    local session_id="$1"
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" DEL "${REDIS_PREFIX}${session_id}" 2>/dev/null || true
    fi
}

list_conversations() {
    if command -v redis-cli >/dev/null 2>&1; then
        redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" KEYS "${REDIS_PREFIX}*" 2>/dev/null | sed "s/${REDIS_PREFIX}//" || true
    fi
}

generate_session_id() {
    echo "session_$(date +%s)_$(openssl rand -hex 4)"
}

# ============================================================
# Persistance
# ============================================================

save_state() {
    local model_name="$1"
    local pid="$2"
    local ctx_size="$3"
    cat > "$PERSISTENT_STATE" << EOF
MODEL=$model_name
PID=$pid
HOST=$HOST
PORT=$PORT
CTX_SIZE=$ctx_size
THREADS=$THREADS
FLASH_ATTN=$FLASH_ATTN
EOF
}

load_state() {
    if [[ -f "$PERSISTENT_STATE" ]]; then
        source "$PERSISTENT_STATE" 2>/dev/null || true
        if [[ -n "${MODELS[$MODEL]+x}" ]]; then
            log "Loading persistent state: $MODEL"
            return 0
        fi
    fi
    return 1
}

# ============================================================
# Stop
# ============================================================

stop_server() {
    local pid
    pid="$(get_pid || true)"

    if [[ -n "$pid" ]]; then
        log "Stopping server (PID $pid)..."
        # Tuer les processus enfants
        pkill -P "$pid" 2>/dev/null || true
        # Tuer le processus principal
        kill -TERM "$pid" 2>/dev/null || true
        sleep 2

        # Force kill si nécessaire
        if kill -0 "$pid" 2>/dev/null; then
            log "Force killing server (PID $pid)..."
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    # Nettoyage des fichiers
    rm -f "$PIDFILE" "$MODELFILE" "$PERSISTENT_STATE" 2>/dev/null
    rm -f "/tmp/llama-server-*.log" 2>/dev/null || true
    # Tuer tous les processus liés
    pkill -f "llama-server|ace-server" 2>/dev/null || true
}

force_stop() {
    log "Force stopping all server processes..."
    pkill -f "llama-server|ace-server" 2>/dev/null || true
    rm -f "$PIDFILE" "/tmp/llama-server-*.log" 2>/dev/null || true
    rm -f "$PERSISTENT_STATE" 2>/dev/null || true
    if pgrep -f "llama-server|ace-server" > /dev/null; then
        log "WARNING: Some processes still running"
        pgrep -f "llama-server|ace-server"
    else
        log "All server processes stopped"
    fi
}

# ============================================================
# GPU Information
# ============================================================

show_gpu_info() {
    if ! command -v vulkaninfo >/dev/null 2>&1; then
        echo "  vulkaninfo: unavailable"
        return
    fi
    vulkaninfo --summary 2>/dev/null |
        grep -E 'deviceName|driverName|driverInfo|deviceType' |
        head -10 || true
}

show_gpu_memory() {
    if [[ -r /sys/class/drm/card1/device/mem_info_vram_total ]]; then
        local total used free
        total="$(cat /sys/class/drm/card1/device/mem_info_vram_total)"
        used="$(cat /sys/class/drm/card1/device/mem_info_vram_used)"
        total=$((total / 1024 / 1024))
        used=$((used / 1024 / 1024))
        free=$((total - used))
        echo "  VRAM total : ${total} MiB"
        echo "  VRAM used  : ${used} MiB"
        echo "  VRAM free  : ${free} MiB"
    else
        echo "  VRAM information unavailable"
    fi
}

# ============================================================
# Hugging Face update
# ============================================================

update_model() {
    local name="$1"
    local repo="${HF_REPOS[$name]}"
    local file="${HF_FILES[$name]}"
    local dir="${MODEL_DIRS[$name]}"

    log "Checking Hugging Face model..."
    log "  Repository: $repo"
    log "  File:       $file"
    log

    if [[ "$name" == "acestep" ]]; then
        log "ACE Server mode: skipping HF download, using local directory: $dir"
        mkdir -p "$dir"
        log "✓ ACE Server directory ready"
        return 0
    fi

    mkdir -p "$dir"

    if ! command -v hf >/dev/null 2>&1; then
        log "ERROR: Hugging Face CLI 'hf' not found."
        log "Install it with:"
        log "  curl -LsSf https://hf.co/cli/install.sh | bash"
        exit 1
    fi

    if ! hf download "$repo" "$file" --local-dir "$dir"; then
        log "ERROR: failed to download model from Hugging Face."
        exit 1
    fi

    if [[ -n "${MMPROJ_FILES[$name]+x}" ]]; then
        local mmproj_repo="${MMPROJ_REPOS[$name]}"
        local mmproj_file="${MMPROJ_FILES[$name]}"
        log "Checking mmproj (vision) file..."
        log "  Repository: $mmproj_repo"
        log "  File:       $mmproj_file"
        if ! hf download "$mmproj_repo" "$mmproj_file" --local-dir "$dir"; then
            log "ERROR: failed to download mmproj file from Hugging Face."
            exit 1
        fi
        log "✓ mmproj checked/updated"
    fi

    log "✓ Model checked/updated"
}

# ============================================================
# Model validation
# ============================================================

check_model() {
    local name="$1"
    local model="${MODELS[$name]}"

    if [[ "$name" == "acestep" ]]; then
        if [[ ! -d "$model" ]]; then
            log "ERROR: acestep model directory not found: $model"
            log "Place your GGUF models in: $model"
            exit 1
        fi
        local size
        size="$(du -sh "$model" 2>/dev/null | awk '{print $1}')"
        log "Model:"
        log "  Name: $name (acestep)"
        log "  Path: $model (directory)"
        log "  Size: $size"
        return 0
    fi

    if [[ ! -f "$model" ]] || [[ ! -r "$model" ]]; then
        log "ERROR: model not found or not readable:"
        log "  $model"
        exit 1
    fi

    local size
    size="$(du -h "$model" 2>/dev/null | awk '{print $1}')"
    log "Model:"
    log "  Name: $name"
    log "  File: $model"
    log "  Size: $size"
}

# ============================================================
# Start
# ============================================================

list_models() {
    log "Available models:"
    for name in "${!MODELS[@]}"; do
        local ctx
        ctx="$(resolve_ctx_size "$name")"
        if [[ "$name" == "acestep" ]]; then
            echo "  - $name : ${MODELS[$name]} (pas de contexte, ace-server)"
        else
            echo "  - $name : ${MODELS[$name]} (CTX_SIZE=$ctx)"
        fi
    done
}

start_model() {
    local name="$1"

    if [[ -z "${MODELS[$name]+x}" ]]; then
        log "ERROR: Unknown model: $name"
        list_models
        exit 1
    fi

    if server_running; then
        log "ERROR: A server is already running (PID $(get_pid))"
        log "Stop it first with: $0 stop"
        exit 1
    fi

    update_model "$name"
    check_model "$name"

    # Résolution du CTX_SIZE effectif pour ce modèle
    local ctx_size
    ctx_size="$(resolve_ctx_size "$name")"

    if [[ "$name" != "acestep" ]]; then
        case "$FLASH_ATTN" in
            on|off|auto) ;;
            *)
                log "ERROR: FLASH_ATTN invalide: '$FLASH_ATTN' (valeurs acceptées: on, off, auto)"
                exit 1
                ;;
        esac

        # Validation basique du CTX_SIZE résolu
        if ! [[ "$ctx_size" =~ ^[0-9]+$ ]] || [[ "$ctx_size" -le 0 ]]; then
            log "ERROR: CTX_SIZE invalide pour le modèle '$name': '$ctx_size'"
            exit 1
        fi
    fi

    local pid

    if [[ "$name" == "acestep" ]]; then
        if [[ ! -x "$ACE_SERVER_BIN" ]]; then
            log "ERROR: ace-server binary not found or not executable: $ACE_SERVER_BIN"
            exit 1
        fi
        log "Starting ACE Server..."
        nohup "$ACE_SERVER_BIN" \
            --models "$ACE_MODELS_DIR" \
            --adapters "$ACE_ADAPTERS_DIR" \
            --host "$HOST" \
            --port "$PORT" \
            > "$LOGFILE" 2>&1 &
        pid=$!
    else
        local model_path="${MODELS[$name]}"
        if [[ ! -x "$LLAMA_SERVER" ]]; then
            log "ERROR: llama-server binary not found or not executable: $LLAMA_SERVER"
            exit 1
        fi

        local extra_args=()
        if [[ -n "${MMPROJ_PATHS[$name]+x}" ]]; then
            local mmproj_path="${MMPROJ_PATHS[$name]}"
            if [[ -f "$mmproj_path" ]]; then
                log "Vision (mmproj): $mmproj_path"
                extra_args+=(--mmproj "$mmproj_path" --jinja)
            else
                log "WARNING: mmproj attendu mais introuvable: $mmproj_path (vision désactivée)"
            fi
        fi

        log "Starting llama-server with model: $name"
        log "Context size: $ctx_size tokens (résolu pour '$name')"
        log "Flash Attention: $FLASH_ATTN"
        log "GPU offload: auto (géré par llama-server, -ngl non spécifié)"
        nohup "$LLAMA_SERVER" \
            -m "$model_path" \
            --host "$HOST" \
            --port "$PORT" \
            -c "$ctx_size" \
            -t "$THREADS" \
            --flash-attn "$FLASH_ATTN" \
            --tools all \
            "${extra_args[@]}" \
            > "$LOGFILE" 2>&1 &
        pid=$!
    fi

    # Le process a démarré en arrière-plan avant qu'on puisse vérifier qu'il tient debout
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        log "ERROR: server process exited immediately, check $LOGFILE"
        tail -n 30 "$LOGFILE" 2>/dev/null || true
        exit 1
    fi

    echo "$pid" > "$PIDFILE"
    echo "$name" > "$MODELFILE"
    save_state "$name" "$pid" "$ctx_size"

    log "Server started with PID $pid, logs: $LOGFILE"
    log "Waiting for server to be ready (timeout ${START_TIMEOUT}s)..."

    local waited=0
    until curl -sf --max-time 2 "http://$HOST:$PORT/health" >/dev/null 2>&1; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log "ERROR: server process died during startup, check $LOGFILE"
            rm -f "$PIDFILE" "$MODELFILE" "$PERSISTENT_STATE"
            exit 1
        fi
        sleep 2
        waited=$((waited + 2))
        if [[ "$waited" -ge "$START_TIMEOUT" ]]; then
            log "ERROR: server did not become ready within ${START_TIMEOUT}s"
            exit 1
        fi
    done

    log "✓ Server is up and running at http://$HOST:$PORT"
}

# ============================================================
# Status
# ============================================================

status() {
    local pid
    pid="$(get_pid || true)"

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        log "server: RUNNING"
        log "PID:          $pid"
        log "URL:          http://$HOST:$PORT"

        local current_model=""
        if [[ -f "$MODELFILE" ]]; then
            current_model="$(cat "$MODELFILE")"
            log "Model:        $current_model"
        fi

        log
        if curl -sf --max-time 3 "http://$HOST:$PORT/health" >/dev/null 2>&1; then
            log "Health:       OK"
        else
            log "Health:       NOT READY (or endpoint not exposed)"
        fi

        log
        log "Context Info:"
        # On récupère le CTX_SIZE réellement utilisé, sauvegardé dans l'état persistant
        local used_ctx="$CTX_SIZE"
        if [[ -f "$PERSISTENT_STATE" ]]; then
            local saved_ctx
            saved_ctx="$(grep -E '^CTX_SIZE=' "$PERSISTENT_STATE" | cut -d= -f2 || true)"
            [[ -n "$saved_ctx" ]] && used_ctx="$saved_ctx"
        elif [[ -n "$current_model" ]]; then
            used_ctx="$(resolve_ctx_size "$current_model")"
        fi
        show_context_info "$used_ctx"
    else
        log "server: STOPPED"
        if load_state; then
            log "Last model was: $MODEL"
            log "Last PID was: $PID"
            log "Last CTX_SIZE was: $CTX_SIZE"
        fi
    fi

    log
    log "GPU:"
    show_gpu_info

    log
    log "Memory:"
    show_gpu_memory
}

show_status_window() {
    local status_output
    status_output=$(status 2>&1)
    if command -v zenity >/dev/null 2>&1; then
        echo "$status_output" | zenity --text-info --title="Server Status" --width=600 --height=400 2>/dev/null
    elif command -v xterm >/dev/null 2>&1; then
        echo "$status_output" | xterm -e less 2>/dev/null
    else
        echo "$status_output"
    fi
}

# ============================================================
# Afficher l'aide
# ============================================================

usage() {
    cat << EOF
Usage: $0 [command] [options]

Commands:
  start <model>           Start a model (qwen, gemma, qwen-next, qwen3.6, acestep)
  stop                    Stop the server
  force-stop              Force stop all servers
  status                  Show server status
  list-models             List all available models (with resolved CTX_SIZE)
  list-conversations      List all conversations
  save-conversation <session_id> <data> Save conversation
  load-conversation <session_id> Load conversation
  delete-conversation <session_id> Delete conversation
  update-llama            Update llama.cpp to latest version
  update-acestep          Update acestep.cpp to latest version

Examples:
  $0 start qwen
  $0 start qwen-next
  $0 start qwen3.6
  $0 start acestep
  $0 status
  $0 list-models
  $0 update-llama
  $0 update-acestep
  $0 save-conversation session_123 "User: Hello\nAI: Hi!"
  $0 load-conversation session_123

Contexte par modèle (CTX_SIZE):
  Chaque modèle a une taille de contexte par défaut définie dans le tableau
  MODEL_CTX_SIZE (voir le début du script). Priorité de résolution :
    1. Variable d'environnement CTX_SIZE_<nom_modele> (caractères non
       alphanumériques remplacés par '_'), ex:
         CTX_SIZE_qwen_next=98304 $0 start qwen-next
    2. MODEL_CTX_SIZE[<nom>] défini dans le script
    3. Valeur générique \$CTX_SIZE (actuellement: $CTX_SIZE)

Notes:
  L'offload GPU (-ngl) n'est pas géré par ce script: llama-server utilise
  son comportement par défaut. Consulte $LLAMA_SERVER --help pour le configurer
  manuellement si besoin.
EOF
    exit 1
}

# ============================================================
# Point d'entrée principal
# ============================================================

main() {
    # Initialisation
    mkdir -p "$LOGDIR"

    if [[ $# -eq 0 ]]; then
        usage
    fi

    local command="$1"
    shift

    case "$command" in
        start)
            if [[ $# -lt 1 ]]; then
                log "ERROR: Missing model name"
                usage
            fi
            start_model "$1"
            ;;
        stop)
            stop_server
            ;;
        force-stop)
            force_stop
            ;;
        status)
            if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
                show_status_window
            else
                status
            fi
            ;;
        list-models)
            list_models
            ;;
        list-conversations)
            log "Active conversations:"
            list_conversations
            ;;
        save-conversation)
            if [[ $# -lt 2 ]]; then
                log "ERROR: Missing session ID or data"
                usage
            fi
            save_conversation "$1" "$2"
            log "Conversation saved with ID: $1"
            ;;
        load-conversation)
            if [[ $# -lt 1 ]]; then
                log "ERROR: Missing session ID"
                usage
            fi
            local data=$(load_conversation "$1")
            if [[ -n "$data" ]]; then
                log "Conversation data for $1:"
                echo "$data"
            else
                log "No conversation found for ID: $1"
            fi
            ;;
        delete-conversation)
            if [[ $# -lt 1 ]]; then
                log "ERROR: Missing session ID"
                usage
            fi
            delete_conversation "$1"
            log "Conversation deleted: $1"
            ;;
        update-llama)
            if command -v zenity >/dev/null 2>&1; then
                update_llama_cpp 2>&1 | zenity --text-info --title="Update llama.cpp" --width=800 --height=600 2>/dev/null
            elif command -v xterm >/dev/null 2>&1; then
                update_llama_cpp 2>&1 | xterm -e less 2>/dev/null
            else
                update_llama_cpp
            fi
            ;;
        update-acestep)
            if command -v zenity >/dev/null 2>&1; then
                update_acestep_cpp 2>&1 | zenity --text-info --title="Update acestep.cpp" --width=800 --height=600 2>/dev/null
            elif command -v xterm >/dev/null 2>&1; then
                update_acestep_cpp 2>&1 | xterm -e less 2>/dev/null
            else
                update_acestep_cpp
            fi
            ;;
        *)
            log "Unknown command: $command"
            usage
            ;;
    esac
}

main "$@"