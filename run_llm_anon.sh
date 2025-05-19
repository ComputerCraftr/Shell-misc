#!/bin/sh
# run_llm_anon.sh - Secure-by-default local LLM launcher with ephemeral/persistent modes,
# Tor routing, context-safe defaults, and optional persistent chat history

set -eu # Exit on unset variables or errors for reliability and safety

DATE_TIME=$(date +"%H:%M:%S %Z")                  # Current time with seconds and timezone
DATE_YEAR=$(date +%B\ %Y)                         # Current month and year used in prompts
DATE_FULL=$(date +"%A, %B %d, %Y at %H:%M:%S %Z") # Full formatted date and time

# === Default Configurations ===
MODEL=""                                       # Local model path (GGUF)
HF_REPO=""                                     # Hugging Face repo (e.g. user/model:Q4_K_M)
LLAMA_BIN="llama-cli"                          # Binary path (can be overridden with --bin)
WRAP="torsocks"                                # Network wrapper (Tor by default)
CTX=0                                          # Context size in tokens (0 = use model default)
THREADS=$(sysctl -n hw.ncpu || echo -1)        # Number of CPU threads to use (optional)
TEMP=""                                        # Sampling temperature
TOP_P=""                                       # Top-p nucleus sampling
MODE="ephemeral"                               # Chat mode (ephemeral or persistent)
SESSION_NAME="llm_chat_$(date +%Y%m%d_%H%M%S)" # tmux session name
CHAT_DIR="$HOME/.local/llm-chat"               # Persistent session storage path
PROMPT_TEMPLATE="$CHAT_DIR/prompts/chat.txt"   # Optional chat prompt template
SYSTEM_TEMPLATE="$CHAT_DIR/prompts/system.txt" # Optional system prompt template path
USER_NAME="anon"                               # Username label used in chat formatting
AI_NAME="assistant"                            # Assistant label used in chat formatting

# === Help Text ===
show_help() {
  cat <<EOF
Usage: ${0##*/} -m MODEL_PATH|--hf REPO [options]

Options:
  -m MODEL_PATH           Path to GGUF model (required unless --hf is used)
  -s SESSION_NAME         tmux session name (default: auto-generated)
  -c CONTEXT_SIZE         Context tokens (0 = use model default)
  -t THREADS              Number of CPU threads to use (optional)
  --temp VALUE            Sampling temperature (optional)
  --top-p VALUE           Nucleus sampling probability (optional)
  --bin PATH              Path to llama-cli or main binary (default: llama-cli from pkg)
  --hf REPO[:QUANT]       Hugging Face repo for remote model download
  --no-tor                Disable torsocks (default is Tor-enabled)
  --mode MODE             Chat mode: ephemeral (default) or persistent
  --prompt-template PATH  Optional chat prompt template path
  --system-template PATH  Optional system prompt template path
  --user NAME             Optional user name (default: anon)
  --ai NAME               Optional AI name (default: assistant)
  -h                      Show this help message
EOF
}

# === Argument Parsing ===
while [ "$#" -gt 0 ]; do
  case "$1" in
  -m)
    MODEL="$2"
    shift 2
    ;;
  -s)
    SESSION_NAME="$2"
    shift 2
    ;;
  -c)
    CTX="$2"
    shift 2
    ;;
  -t)
    THREADS="$2"
    shift 2
    ;;
  --temp)
    TEMP="$2"
    shift 2
    ;;
  --top-p)
    TOP_P="$2"
    shift 2
    ;;
  --bin)
    LLAMA_BIN="$2"
    shift 2
    ;;
  --hf)
    HF_REPO="$2"
    shift 2
    ;;
  --no-tor)
    WRAP=""
    shift
    ;;
  --mode)
    MODE="$2"
    shift 2
    ;;
  --user)
    USER_NAME="$2"
    shift 2
    ;;
  --ai)
    AI_NAME="$2"
    shift 2
    ;;
  --prompt-template)
    PROMPT_TEMPLATE="$2"
    shift 2
    ;;
  --system-template)
    SYSTEM_TEMPLATE="$2"
    shift 2
    ;;
  -h)
    show_help
    exit 0
    ;;
  *)
    echo "Unknown option: $1"
    show_help
    exit 1
    ;;
  esac
done

MODEL_ARGS=""
[ -n "$MODEL" ] && MODEL_ARGS="--model \"$MODEL\""
[ -n "$HF_REPO" ] && MODEL_ARGS="$MODEL_ARGS --hf-repo \"$HF_REPO\""

# Optional NUMA optimization
if [ -z "${NUMA_OPT+x}" ]; then
  if sysctl -n vm.ndomains 2>/dev/null | grep -qE '^[2-9][0-9]*$'; then
    NUMA_OPT="--numa distribute" # Enable if multiple NUMA nodes exist
  else
    NUMA_OPT=""
  fi
fi

# === Shared system prompt used if SYSTEM_TEMPLATE is missing ===
SYSTEM_PROMPT="It is $DATE_FULL and you are a helpful assistant answering with \"$AI_NAME:\" and \
using colors and formatting compatible with a text terminal."

# === Shared fallback prompt used if PROMPT_TEMPLATE is missing ===
FALLBACK_PROMPT="$USER_NAME: Can you help answer some questions quickly? /nothink"

# Token limit at which to rotate chat context (defaults to 60% of 40960 if CTX is unset)
CTX_ROTATE_POINT=$(((CTX > 0 ? CTX : 40960) * 3 / 5))

# sed pattern to strip trailing messages for context trimming
SED_DELETE_MESSAGES="/^(${USER_NAME}:|${AI_NAME}:|\\.\\.\\.)/,\$d"

# Pattern to extract session token stats from llama-cli logs
SESSION_AND_SAMPLE_PATTERN='main: session file matches [[:digit:]]+ / [[:digit:]]+|sampling time =[[:space:]]+[[:digit:]]+\.[[:digit:]]+ ms /[[:space:]]+[[:digit:]]+'

# === Validation ===
case "$MODE" in
ephemeral | persistent) : ;;
*)
  echo "Invalid --mode value: $MODE"
  exit 1
  ;;
esac

# Ensure exactly one of -m or --hf is provided
if [ -n "$MODEL" ] && [ -n "$HF_REPO" ]; then
  echo "Error: Specify only one of -m MODEL_PATH or --hf REPO, not both."
  show_help
  exit 1
fi

if [ -n "$MODEL" ]; then
  if [ ! -f "$MODEL" ]; then
    echo "Error: Model file not found: $MODEL"
    exit 1
  fi
elif [ -z "$HF_REPO" ]; then
  echo "Error: Either -m MODEL_PATH or --hf REPO must be specified."
  show_help
  exit 1
fi

if ! command -v "$LLAMA_BIN" >/dev/null 2>&1; then
  echo "Error: llama binary not found: $LLAMA_BIN"
  exit 1
fi

if [ -n "$WRAP" ] && ! command -v "$WRAP" >/dev/null 2>&1; then
  echo "Error: torsocks not installed, or --no-tor not specified."
  exit 1
fi

# === Resolve system prompt file ===
if [ -f "$SYSTEM_TEMPLATE" ]; then
  SYSTEM_PROMPT_FILE="$SYSTEM_TEMPLATE"
  CLEANUP_SYSTEM_PROMPT=false
else
  SYSTEM_PROMPT_FILE=$(mktemp /tmp/system_prompt.XXXXXX)
  echo "$SYSTEM_PROMPT" >"$SYSTEM_PROMPT_FILE"
  CLEANUP_SYSTEM_PROMPT=true
fi

# === Persistent Chat Mode ===
if [ "$MODE" = "persistent" ]; then
  mkdir -p "$CHAT_DIR"
  LOG_CHAT="$CHAT_DIR/main.log"  # Main interactive log
  LOG_BG="$CHAT_DIR/main-bg.log" # Background prompt cache log
  PROMPT_CACHE_FILE="$CHAT_DIR/prompt-cache.bin"
  CUR_PROMPT_FILE="$CHAT_DIR/current-prompt.txt"
  CUR_PROMPT_CACHE="$CHAT_DIR/current-cache.bin"
  NEXT_PROMPT_FILE="$CHAT_DIR/next-prompt.txt"
  NEXT_PROMPT_CACHE="$CHAT_DIR/next-cache.bin"

  # Initialize prompt
  if [ -f "$PROMPT_TEMPLATE" ]; then
    if [ ! -e "$CUR_PROMPT_FILE" ]; then
      sed -e "s/\[\[USER_NAME\]\]/$USER_NAME/g" \
        -e "s/\[\[AI_NAME\]\]/$AI_NAME/g" \
        -e "s/\[\[DATE_TIME\]\]/$DATE_TIME/g" \
        -e "s/\[\[DATE_YEAR\]\]/$DATE_YEAR/g" \
        "$PROMPT_TEMPLATE" >"$CUR_PROMPT_FILE"
    fi
  else
    echo "[*] Warning: Prompt template not found. Using simple default user prompt."
    echo "$FALLBACK_PROMPT" >"$CUR_PROMPT_FILE"
  fi

  if [ ! -e "$NEXT_PROMPT_FILE" ]; then
    sed -r "$SED_DELETE_MESSAGES" "$CUR_PROMPT_FILE" >"$NEXT_PROMPT_FILE"
    echo '...' >>"$NEXT_PROMPT_FILE"
  fi

  if [ ! -e "$PROMPT_CACHE_FILE" ]; then
    echo '[*] Building prompt cache...'
    $WRAP "$LLAMA_BIN" ${HF_REPO:+--hf-repo "$HF_REPO"} --batch_size 64 -c "$CTX" \
      --file "$CUR_PROMPT_FILE" --prompt-cache "$PROMPT_CACHE_FILE" --n-predict 1
  fi

  # Only initialize CUR_PROMPT_CACHE if it does not already exist
  if [ ! -e "$CUR_PROMPT_CACHE" ]; then
    cp "$PROMPT_CACHE_FILE" "$CUR_PROMPT_CACHE"
  fi

  # Only initialize NEXT_PROMPT_CACHE if it does not already exist
  if [ ! -e "$NEXT_PROMPT_CACHE" ]; then
    cp "$PROMPT_CACHE_FILE" "$NEXT_PROMPT_CACHE"
  fi

  echo '[*] Launching persistent chat with context rotation.'
  # --- Begin persistent chat loop ---
  CTX=${CTX:-40960}
  n_tokens=0

  # read -e is not POSIX; use plain read (no editing support)
  while IFS= read -r line; do # -e removed for POSIX compatibility
    n_predict=$((CTX - n_tokens - (${#line} / 2) - 32))
    if [ "$n_predict" -le 0 ]; then
      wait
      mv "$NEXT_PROMPT_FILE" "$CUR_PROMPT_FILE"
      mv "$NEXT_PROMPT_CACHE" "$CUR_PROMPT_CACHE"

      sed -r "$SED_DELETE_MESSAGES" "$CUR_PROMPT_FILE" >"$NEXT_PROMPT_FILE"
      echo '...' >>"$NEXT_PROMPT_FILE"
      cp "$PROMPT_CACHE_FILE" "$NEXT_PROMPT_CACHE"

      n_tokens=0
      n_predict=$((CTX / 2))
    fi

    echo " ${line}" >>"$CUR_PROMPT_FILE"
    if [ "$n_tokens" -gt "$CTX_ROTATE_POINT" ]; then
      echo " ${line}" >>"$NEXT_PROMPT_FILE"
    fi

    n_prompt_len_pre=$(wc -c <"$CUR_PROMPT_FILE")
    printf '%s: ' "$AI_NAME" >>"$CUR_PROMPT_FILE"

    eval "$WRAP \"$LLAMA_BIN\" $MODEL_ARGS \
      --prompt-cache \"$CUR_PROMPT_CACHE\" \
      --prompt-cache-all \
      --conversation \
      --color \
      --system-prompt-file \"$SYSTEM_PROMPT_FILE\" \
      --file \"$CUR_PROMPT_FILE\" \
      --reverse-prompt \"$USER_NAME:\" \
      --temp \"$TEMP\" \
      --top-p \"$TOP_P\" \
      --ctx-size \"$CTX\" \
      --threads \"$THREADS\" \
      --n-predict \"$n_predict\" \
      $NUMA_OPT" |
      dd bs=1 count=1 2>/dev/null 1>/dev/null && cat && dd bs=1 count="$n_prompt_len_pre" 2>/dev/null 1>/dev/null

    # Replace [[ ... ]] with [ ... ] for test
    if [ "$(tail -n1 "$CUR_PROMPT_FILE")" != "${USER_NAME}:" ]; then
      printf '\n%s:' "$USER_NAME"
      printf '\n%s:' "$USER_NAME" >>"$CUR_PROMPT_FILE"
    fi

    # Here-string <<< replaced with echo ... | pipeline
    if ! session_and_sample_msg=$(tail -n30 "$LOG_CHAT" | grep -oE "$SESSION_AND_SAMPLE_PATTERN"); then
      echo >&2 "Couldn't get number of tokens from llama-cli output!"
      exit 1
    fi

    n_tokens=$(
      cut -d/ -f2 <<EOF | awk '{sum+=$1} END {print sum}'
$session_and_sample_msg
EOF
    )

    if [ "$n_tokens" -gt "$CTX_ROTATE_POINT" ]; then
      tail -c+$((n_prompt_len_pre + 1)) "$CUR_PROMPT_FILE" >>"$NEXT_PROMPT_FILE"
    fi

    eval "$WRAP \"$LLAMA_BIN\" $MODEL_ARGS \
      --prompt-cache \"$NEXT_PROMPT_CACHE\" \
      --file \"$NEXT_PROMPT_FILE\" \
      --n-predict 1 $NUMA_OPT" >>"$LOG_BG" 2>&1 &
  done
  # --- End persistent chat loop ---
  [ "${CLEANUP_SYSTEM_PROMPT:-false}" = true ] && rm -f "$SYSTEM_PROMPT_FILE"
  exit 0
fi

# === Ephemeral Mode via tmux ===
CUR_PROMPT_FILE=$(mktemp /tmp/llm_prompt.XXXXXX)
if [ -f "$PROMPT_TEMPLATE" ]; then
  sed -e "s/\[\[USER_NAME\]\]/$USER_NAME/g" \
    -e "s/\[\[AI_NAME\]\]/$AI_NAME/g" \
    -e "s/\[\[DATE_TIME\]\]/$DATE_TIME/g" \
    -e "s/\[\[DATE_YEAR\]\]/$DATE_YEAR/g" \
    "$PROMPT_TEMPLATE" >"$CUR_PROMPT_FILE"
else
  echo "$FALLBACK_PROMPT" >"$CUR_PROMPT_FILE"
fi

# Construct argument string for ephemeral mode
ARGS="$MODEL_ARGS"
ARGS="$ARGS --conversation"
ARGS="$ARGS --color"
ARGS="$ARGS --system-prompt-file \"$SYSTEM_PROMPT_FILE\""
ARGS="$ARGS --file \"$CUR_PROMPT_FILE\""
ARGS="$ARGS --reverse-prompt \"$USER_NAME:\""
[ -n "$TEMP" ] && ARGS="$ARGS --temp $TEMP"
[ -n "$TOP_P" ] && ARGS="$ARGS --top-p $TOP_P"
[ "$CTX" -gt 0 ] && ARGS="$ARGS --ctx-size $CTX"
[ -n "$THREADS" ] && ARGS="$ARGS --threads $THREADS"
ARGS="$ARGS $NUMA_OPT"

LLM_CMD="$WRAP \"$LLAMA_BIN\" $ARGS; rm -f \"$CUR_PROMPT_FILE\""
[ "${CLEANUP_SYSTEM_PROMPT:-false}" = true ] && LLM_CMD="$LLM_CMD \"$SYSTEM_PROMPT_FILE\""

tmux new-session -d -s "$SESSION_NAME" "/bin/sh -c '$LLM_CMD'"

echo "Started $MODE llama.cpp chat in tmux session: $SESSION_NAME"
echo "Attach with: tmux attach-session -t $SESSION_NAME"
exit 0
