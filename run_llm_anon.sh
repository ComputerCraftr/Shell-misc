#!/bin/sh
# run_llm_anon.sh - Secure-by-default local LLM launcher with ephemeral/persistent modes,
# Tor routing, context-safe defaults, and optional persistent chat history

set -eu # Exit on unset variables or errors for reliability and safety

# Base directory for resolving relative paths
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# === Default Configurations ===
MODEL=""                                       # Local model path (GGUF)
HF_REPO=""                                     # Hugging Face repo (e.g. user/model:Q4_K_M)
LLAMA_BIN="llama-cli"                          # Binary path (can be overridden with --bin)
WRAP="torsocks"                                # Network wrapper (Tor by default)
CTX=0                                          # Context size in tokens (0 = use model default)
TOKENS=256                                     # Tokens to predict per input
THREADS=""                                     # Number of CPU threads to use (optional)
TEMP=""                                        # Sampling temperature
TOP_P=""                                       # Top-p nucleus sampling
SAVE=false                                     # Whether to save the session on exit
LOG=false                                      # Enable logging of session
MODE="ephemeral"                               # Chat mode (ephemeral or persistent)
SESSION_NAME="llm_chat_$(date +%Y%m%d_%H%M%S)" # tmux session name
SESSION_FILE=""                                # Session file path for saving/loading state
CHAT_DIR="$HOME/.local/llm-chat"               # Persistent session storage path
PROMPT_TEMPLATE="$SCRIPT_DIR/prompts/chat.txt" # Optional chat prompt template
USER_NAME="anon"                               # Username label used in chat formatting
AI_NAME="assistant"                            # Assistant label used in chat formatting

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

MODEL_ARGS=""
[ -n "$MODEL" ] && MODEL_ARGS="--model \"$MODEL\""
[ -n "$HF_REPO" ] && MODEL_ARGS="$MODEL_ARGS --hf-repo \"$HF_REPO\""

# Token limit at which to rotate chat context (defaults to 60% of 32768 if CTX is unset)
CTX_ROTATE_POINT=$(((CTX > 0 ? CTX : 32768) * 3 / 5))

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
    sed -r "$SED_DELETE_MESSAGES" "$CUR_PROMPT_FILE" >"$NEXT_PROMPT_FILE"
    echo '...' >>"$NEXT_PROMPT_FILE"
  fi

  if [ ! -e "$PROMPT_CACHE_FILE" ]; then
    echo '[*] Building prompt cache...'
    $WRAP "$LLAMA_BIN" ${HF_REPO:+--hf-repo "$HF_REPO"} --batch_size 64 -c "$CTX" \
      --file "$CUR_PROMPT_FILE" --prompt-cache "$PROMPT_CACHE_FILE" --n_predict 1
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
  CTX=${CTX:-32768}
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
      --file \"$CUR_PROMPT_FILE\" \
      --reverse-prompt \"$USER_NAME:\" \
      --n_predict \"$n_predict\"" |
      dd bs=1 count=1 2>/dev/null 1>/dev/null && cat && dd bs=1 count="$n_prompt_len_pre" 2>/dev/null 1>/dev/null

    # Replace [[ ... ]] with [ ... ] for test
    if [ "$(tail -n1 "$CUR_PROMPT_FILE")" != "${USER_NAME}:" ]; then
      printf '\n%s:' "$USER_NAME"
      printf '\n%s:' "$USER_NAME" >>"$CUR_PROMPT_FILE"
    fi

    # Here-string <<< replaced with echo ... | pipeline
    if ! session_and_sample_msg=$(tail -n30 "$LOG" | grep -oE "$SESSION_AND_SAMPLE_PATTERN"); then
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
      --n_predict 1" >>"$LOG_BG" 2>&1 &
  done
  # --- End persistent chat loop ---
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

LLM_CMD="$WRAP \"$LLAMA_BIN\" $MODEL_ARGS -i $PROMPT_FILE_ARG"
[ "$CTX" -gt 0 ] && LLM_CMD="$LLM_CMD -c $CTX"
[ -n "$TEMP" ] && LLM_CMD="$LLM_CMD --temp $TEMP"
[ -n "$TOP_P" ] && LLM_CMD="$LLM_CMD --top-p $TOP_P"
[ -n "$THREADS" ] && LLM_CMD="$LLM_CMD -t $THREADS"
LLM_CMD="$LLM_CMD -n $TOKENS"
[ -f "$SESSION_FILE" ] && LLM_CMD="$LLM_CMD --load-session \"$SESSION_FILE\""
[ "$SAVE" = true ] && LLM_CMD="$LLM_CMD ; $WRAP $LLAMA_BIN --model \"$MODEL\" --save-session \"$SESSION_FILE\""

tmux new-session -d -s "$SESSION_NAME" "/bin/sh -c \"$LLM_CMD\""

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
