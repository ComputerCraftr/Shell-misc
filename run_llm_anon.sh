#!/bin/sh
# run_llm_anon.sh - Secure-by-default local LLM launcher with ephemeral/persistent modes,
# Tor routing, context-safe defaults, and optional persistent chat history

set -eu # Exit on unset variables or errors for reliability and safety

# Base directory for resolving relative paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# === Default Configurations ===
MODEL=""
SESSION_NAME="llm_chat_$(date +%Y%m%d_%H%M%S)"
SESSION_FILE=""
CTX=0
TOKENS=256
THREADS=""
TEMP=""
TOP_P=""
SAVE=false
LOG=false
LLAMA_BIN="llama-cli"
WRAP="torsocks"
MODE="ephemeral"
CHAT_DIR="$HOME/.local/llm-chat"
PROMPT_TEMPLATE="$SCRIPT_DIR/prompts/chat.txt"
USER_NAME="anon"
AI_NAME="assistant"
HF_REPO=""

# === Help Text ===
show_help() {
  cat <<EOF
Usage: ${0##*/} -m MODEL_PATH|--hf REPO [options]

Options:
  -m MODEL_PATH     Path to GGUF model (required unless --hf is used)
  -s SESSION_NAME   tmux session name (default: auto-generated)
  -f SESSION_FILE   Session file for saving/loading (optional)
  -c CONTEXT_SIZE   Context tokens (0 = use model default)
  -n TOKENS         Tokens to predict (default: 256)
  -t THREADS        Number of CPU threads to use (optional)
  --temp VALUE      Sampling temperature (optional)
  --top-p VALUE     Nucleus sampling probability (optional)
  --save            Save session on exit (creates session_name.session)
  --log             Log output to ~/llm_logs/session_name_timestamp.log
  --bin PATH        Path to llama-cli or main binary (default: llama-cli from pkg)
  --hf REPO[:QUANT] Hugging Face repo for remote model download
  --no-tor          Disable torsocks (default is Tor-enabled)
  --mode MODE       Chat mode: ephemeral (default) or persistent
  --user NAME       Optional user name (default: anon)
  --ai NAME         Optional AI name (default: assistant)
  -h                Show this help message
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
  -f)
    SESSION_FILE="$2"
    shift 2
    ;;
  -c)
    CTX="$2"
    shift 2
    ;;
  -n)
    TOKENS="$2"
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
  --save)
    SAVE=true
    shift
    ;;
  --log)
    LOG=true
    shift
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

# === Validation ===
case "$MODE" in
ephemeral | persistent) : ;;
*)
  echo "Invalid --mode value: $MODE"
  exit 1
  ;;
esac

if [ -n "$MODEL" ]; then
  [ ! -f "$MODEL" ] && echo "Error: Model file not found: $MODEL" && exit 1
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

# === Persistent Chat Mode ===
if [ "$MODE" = "persistent" ]; then
  DATE_TIME=$(date +%H:%M)
  DATE_YEAR=$(date +%Y)
  mkdir -p "$CHAT_DIR"
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
    echo "[*] Warning: Prompt template not found. Starting with empty prompt."
    : >"$CUR_PROMPT_FILE"
  fi

  if [ ! -e "$NEXT_PROMPT_FILE" ]; then
    sed -r "/^($USER_NAME:|$AI_NAME:|\.\.\.)/,\$d" "$CUR_PROMPT_FILE" >"$NEXT_PROMPT_FILE"
    echo '...' >>"$NEXT_PROMPT_FILE"
  fi

  if [ ! -e "$PROMPT_CACHE_FILE" ]; then
    echo '[*] Building prompt cache...'
    $WRAP "$LLAMA_BIN" ${HF_REPO:+--hf-repo "$HF_REPO"} --batch_size 64 -c "$CTX" \
      --file "$CUR_PROMPT_FILE" --prompt-cache "$PROMPT_CACHE_FILE" --n_predict 1
  fi

  cp "$PROMPT_CACHE_FILE" "$CUR_PROMPT_CACHE"
  cp "$PROMPT_CACHE_FILE" "$NEXT_PROMPT_CACHE"

  echo '[*] Launching persistent chat with context rotation.'
  CMD="$WRAP \"$LLAMA_BIN\" ${MODEL:+--model \"$MODEL\"} ${HF_REPO:+--hf-repo \"$HF_REPO\"} -n $TOKENS -i"
  CMD="$CMD --prompt-cache \"$CUR_PROMPT_CACHE\" --prompt-cache-all --file \"$CUR_PROMPT_FILE\" --reverse-prompt \"$USER_NAME:\""
  [ "$CTX" -gt 0 ] && CMD="$CMD -c $CTX"
  [ -n "$TEMP" ] && CMD="$CMD --temp $TEMP"
  [ -n "$TOP_P" ] && CMD="$CMD --top-p $TOP_P"
  [ -n "$THREADS" ] && CMD="$CMD -t $THREADS"
  eval "$CMD"
  exit 0
fi

# === Ephemeral Mode via tmux ===
if [ -f "$PROMPT_TEMPLATE" ]; then
  CUR_PROMPT_FILE=$(mktemp /tmp/llm_prompt.XXXXXX)
  sed -e "s/\[\[USER_NAME\]\]/$USER_NAME/g" \
    -e "s/\[\[AI_NAME\]\]/$AI_NAME/g" \
    -e "s/\[\[DATE_TIME\]\]/$(date +%H:%M)/g" \
    -e "s/\[\[DATE_YEAR\]\]/$(date +%Y)/g" \
    "$PROMPT_TEMPLATE" >"$CUR_PROMPT_FILE"
  trap 'rm -f "$CUR_PROMPT_FILE"' EXIT
  PROMPT_FILE_ARG="--file \"$CUR_PROMPT_FILE\""
else
  PROMPT_FILE_ARG=""
fi

LLM_CMD="$WRAP \"$LLAMA_BIN\" ${MODEL:+--model \"$MODEL\"} ${HF_REPO:+--hf-repo \"$HF_REPO\"} -i $PROMPT_FILE_ARG"
[ "$CTX" -gt 0 ] && LLM_CMD="$LLM_CMD -c $CTX"
[ -n "$TEMP" ] && LLM_CMD="$LLM_CMD --temp $TEMP"
[ -n "$TOP_P" ] && LLM_CMD="$LLM_CMD --top-p $TOP_P"
[ -n "$THREADS" ] && LLM_CMD="$LLM_CMD -t $THREADS"
LLM_CMD="$LLM_CMD -n $TOKENS"
[ -f "$SESSION_FILE" ] && LLM_CMD="$LLM_CMD --load-session \"$SESSION_FILE\""
[ "$SAVE" = true ] && LLM_CMD="$LLM_CMD ; $WRAP $LLAMA_BIN --model \"$MODEL\" --save-session \"$SESSION_FILE\""

tmux new-session -d -s "$SESSION_NAME" "$LLM_CMD"

# === Optional Logging ===
if [ "$LOG" = true ]; then
  LOGDIR="$HOME/llm_logs"
  mkdir -p "$LOGDIR"
  LOGFILE="${LOGDIR}/${SESSION_NAME}_$(date +%F_%H%M%S).log"
  tmux pipe-pane -t "$SESSION_NAME" -o "cat >> \"$LOGFILE\""
  echo "Logging to: $LOGFILE"
fi

echo "Started $MODE llama.cpp chat in tmux session: $SESSION_NAME"
echo "Attach with: tmux attach-session -t $SESSION_NAME"
exit 0
