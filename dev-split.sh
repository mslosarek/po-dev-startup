#!/bin/zsh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="${0:A:h}"
DEFAULT_ROOT="$SCRIPT_DIR/../core"

SESSION_NAME="dev-env"
# tmux session environment variable that records which monorepo checkout
# the running session was started from, so stop/status/restart can find it.
ROOT_ENV_VAR="DEV_SPLIT_ROOT"

# Reads the monorepo root the running session was started from, if any.
session_root() {
    tmux show-environment -t "$SESSION_NAME" "$ROOT_ENV_VAR" 2>/dev/null | sed -n "s/^$ROOT_ENV_VAR=//p"
}

# Picks the monorepo root and sets CORE_DIR/UI_DIR/ADMIN_UI_DIR from it.
# core/azure/common merged into a single "core" monorepo on 2026-11-05, and
# ui/admin-ui followed on 2026-11-10 — all five now live as subfolders of
# the one "core" repo instead of as separate sibling repos.
# Order: the explicit argument, then the running session's root, then ../core.
resolve_root() {
    local requested="$1" root
    if [[ -n "$requested" ]]; then
        root="$requested"
    else
        root="$(session_root)"
        [[ -z "$root" ]] && root="$DEFAULT_ROOT"
    fi

    if [[ ! -d "$root" ]]; then
        echo -e "${RED}Monorepo directory '$root' does not exist.${NC}"
        exit 1
    fi
    ROOT_DIR="${root:A}"

    for sub in core ui admin-ui; do
        if [[ ! -d "$ROOT_DIR/$sub" ]]; then
            echo -e "${RED}'$ROOT_DIR' has no '$sub' folder — is it the ProsperOps monorepo?${NC}"
            exit 1
        fi
    done

    CORE_DIR="$ROOT_DIR/core"
    UI_DIR="$ROOT_DIR/ui"
    ADMIN_UI_DIR="$ROOT_DIR/admin-ui"
}

# Types a command into a tmux pane, with a colored header on start and a
# colored exit message (so a crashed pane doesn't just close silently).
# Usage: run_pane <target> <dir> <label> <command> [login]
#   login=login sources ~/.zshrc first (needed for nvm).
# The exit code is written as \$? so the pane's own shell passes it through
# unexpanded and the inner zsh reports the command's real status.
run_pane() {
    local target="$1" dir="$2" label="$3" inner_cmd="$4" login="$5"
    local prelude=""
    [[ "$login" == "login" ]] && prelude='export DISABLE_AUTO_UPDATE=true && source ~/.zshrc && '

    tmux send-keys -t "$target" "cd '$dir'" Enter
    tmux send-keys -t "$target" 'zsh -lc "'"$prelude"'echo -e \"\033[1;36m==== '"$label"' ====\033[0m\" && '"$inner_cmd"'; echo -e \"\033[1;31m'"$label"' exited with code \$?. Press Enter to close pane.\033[0m\"; read"' Enter
}

start() {
    # Check if tmux is installed
    if ! command -v tmux &> /dev/null; then
        echo -e "${RED}tmux is not installed. Please install it first.${NC}"
        echo "On macOS: brew install tmux"
        exit 1
    fi

    # Check if Docker is installed and running
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}docker is not installed. Please install it first.${NC}"
        exit 1
    fi
    if ! docker info &> /dev/null; then
        echo -e "${RED}Docker is not running. Please start Docker Desktop first.${NC}"
        exit 1
    fi

    # Check if session already exists
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        local running_root="$(session_root)"
        if [[ -n "$running_root" && "$running_root" != "$ROOT_DIR" ]]; then
            echo -e "${YELLOW}Session '$SESSION_NAME' is already running from '$running_root', not '$ROOT_DIR'.${NC}"
            echo -e "${YELLOW}Run '$0 restart $ROOT_DIR' to switch. Attaching to the existing session...${NC}"
        else
            echo -e "${YELLOW}Session '$SESSION_NAME' already exists. Attaching...${NC}"
        fi
        tmux attach-session -t "$SESSION_NAME"
        return
    fi

    echo -e "${GREEN}Starting development environment with split panes...${NC}"
    echo -e "${GREEN}Using monorepo at $ROOT_DIR${NC}"

    # Perform AWS SSO login
    echo -e "${YELLOW}Performing AWS SSO login...${NC}"
    if ! aws sso login; then
        echo -e "${RED}AWS SSO login failed. Exiting...${NC}"
        exit 1
    fi
    echo -e "${GREEN}AWS SSO login successful!${NC}"

    # Server and Server Admin share several projects (BusinessLogic, Models,
    # Utilities, and transitively Common/Analyzers from the merged-in common/
    # folder). If both panes' first `dotnet watch run` build those shared
    # projects at the same moment, they race on the same obj/ output files
    # and one of them fails. Building once up front here, serially, warms
    # that shared chain so neither watch pane has to cold-build it.
    echo -e "${YELLOW}Pre-building shared backend projects...${NC}"
    if ! (cd "$CORE_DIR/src/ProsperOps.API" && dotnet build); then
        echo -e "${RED}Initial build failed — Server/Server Admin panes will likely show the same error.${NC}"
    fi

    # Create tmux session with first pane
    tmux new-session -d -s "$SESSION_NAME" -n "dev"
    tmux set-environment -t "$SESSION_NAME" "$ROOT_ENV_VAR" "$ROOT_DIR"

    # Create the 3-row layout
    tmux split-window -v -t "$SESSION_NAME:dev"    # Creates row 2
    tmux split-window -v -t "$SESSION_NAME:dev.0"  # Creates row 3 (splits pane 0)

    # Now split the top row horizontally (UI | Admin UI)
    tmux split-window -h -t "$SESSION_NAME:dev.0"

    # Split the middle row horizontally (Server | Server Admin)
    tmux split-window -h -t "$SESSION_NAME:dev.2"

    # Pane 0: UI (top-left)
    # `nvm install` (not `nvm use`) so a Node version bump in .nvmrc gets
    # installed automatically; it switches to that version either way.
    run_pane "$SESSION_NAME:dev.0" "$UI_DIR" "UI" "nvm install && yarn && yarn dev" login

    # Pane 1: Admin UI (top-right)
    run_pane "$SESSION_NAME:dev.1" "$ADMIN_UI_DIR" "ADMIN UI" "nvm install && yarn && yarn dev" login

    # Pane 2: Server (middle-left)
    run_pane "$SESSION_NAME:dev.2" "$CORE_DIR" "SERVER" "echo 'Waiting for Docker services to start...' && sleep 10 && ./scripts/server watch"

    # Pane 3: Server Admin (middle-right)
    run_pane "$SESSION_NAME:dev.3" "$CORE_DIR" "SERVER ADMIN" "echo 'Waiting for Docker services to start...' && sleep 10 && ./scripts/server-admin watch"

    # Pane 4: Docker Compose (bottom - full width)
    run_pane "$SESSION_NAME:dev.4" "$CORE_DIR" "DOCKER COMPOSE" "docker-compose up"

    # Create second window for control shell
    tmux new-window -t "$SESSION_NAME" -n "control" -c "$SCRIPT_DIR" \
        'echo -e "\033[1;36m==== CONTROL SHELL ====\033[0m" && echo "Use this shell for running commands" && zsh'

    # Go back to first window
    tmux select-window -t "$SESSION_NAME:dev"

    echo -e "${GREEN}All services started in tmux session '$SESSION_NAME'!${NC}"
    echo ""
    echo -e "${YELLOW}Layout:${NC}"
    echo "  Window 1 (dev): 5 panes"
    echo "    Row 1: UI (left), Admin UI (right)"
    echo "    Row 2: Server (left), Server Admin (right)"
    echo "    Row 3: Docker Compose (full width)"
    echo "  Window 2 (control): Control shell"
    echo ""
    echo -e "${YELLOW}Pane Numbers:${NC}"
    echo "    0: UI                1: Admin UI"
    echo "    2: Server            3: Server Admin"
    echo "    4: Docker Compose"
    echo ""
    echo -e "${YELLOW}Tmux Commands:${NC}"
    echo "  Switch windows:     Ctrl+b 1 or Ctrl+b 2"
    echo "  Switch panes:       Ctrl+b arrow keys"
    echo "  Resize panes:       Ctrl+b Alt+arrow keys"
    echo "  Zoom pane:          Ctrl+b z (toggle)"
    echo "  Detach:            Ctrl+b d"
    echo "  Scroll mode:        Ctrl+b [ (then q to exit)"
    echo ""

    # Attach to session
    tmux attach-session -t "$SESSION_NAME"
}

stop() {
    echo -e "${RED}Stopping development environment...${NC}"

    # Kill tmux session
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        tmux kill-session -t "$SESSION_NAME"
        echo -e "${GREEN}Tmux session '$SESSION_NAME' terminated${NC}"
    else
        echo -e "${YELLOW}No tmux session '$SESSION_NAME' found${NC}"
    fi

    # Stop Docker Compose just in case
    echo -e "${YELLOW}Stopping Docker Compose...${NC}"
    cd "$CORE_DIR" && docker-compose down

    echo -e "${GREEN}All services stopped!${NC}"
}

restart() {
    local requested="$1"
    # Stop from whatever checkout the running session uses, so docker-compose
    # down runs in the right folder, then start from the requested one (or
    # the same one again if none was given).
    resolve_root ""
    local previous_root="$ROOT_DIR"
    stop
    sleep 2
    resolve_root "${requested:-$previous_root}"
    start
}

status() {
    echo -e "${GREEN}Development Environment Status:${NC}"
    echo "================================"
    echo "Monorepo: $ROOT_DIR"

    # Check tmux session
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo -e "${GREEN}Tmux session '$SESSION_NAME' is running${NC}"
        echo -e "\n${YELLOW}Windows and Panes:${NC}"
        tmux list-windows -t "$SESSION_NAME" | while read window; do
            echo "  $window"
            window_index=$(echo "$window" | cut -d: -f1)
            tmux list-panes -t "$SESSION_NAME:$window_index" | while read pane; do
                echo "    - $pane"
            done
        done
    else
        echo -e "${RED}Tmux session '$SESSION_NAME' is not running${NC}"
    fi

    # Check Docker Compose
    echo -e "\n${YELLOW}Docker Compose:${NC}"
    cd "$CORE_DIR" && docker-compose ps
}

attach() {
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        tmux attach-session -t "$SESSION_NAME"
    else
        echo -e "${RED}No session '$SESSION_NAME' found. Run '$0 start [monorepo-dir]' first.${NC}"
    fi
}

logs() {
    if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        echo -e "${GREEN}Capturing pane contents to logs...${NC}"

        # Capture each pane's content
        for window in $(tmux list-windows -t "$SESSION_NAME" -F '#{window_index}'); do
            pane_count=$(tmux list-panes -t "$SESSION_NAME:$window" | wc -l)
            for ((pane=0; pane<$pane_count; pane++)); do
                tmux capture-pane -t "$SESSION_NAME:$window.$pane" -p > "$SCRIPT_DIR/pane-$window-$pane.log"
                echo "  Saved window $window pane $pane to pane-$window-$pane.log"
            done
        done

        echo -e "${YELLOW}Log files saved to $SCRIPT_DIR${NC}"
    else
        echo -e "${RED}No session '$SESSION_NAME' found.${NC}"
    fi
}

# Main command handling
case "$1" in
    start)
        resolve_root "$2"
        start
        ;;
    stop)
        resolve_root "$2"
        stop
        ;;
    restart)
        restart "$2"
        ;;
    status)
        resolve_root "$2"
        status
        ;;
    attach)
        attach
        ;;
    logs)
        logs
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|attach|logs} [monorepo-dir]"
        echo ""
        echo "Commands:"
        echo "  start    - Start all services in split-pane tmux layout"
        echo "  stop     - Stop all services and close tmux session"
        echo "  restart  - Restart all services"
        echo "  status   - Show status of all services"
        echo "  attach   - Reattach to existing tmux session"
        echo "  logs     - Save current pane contents to log files"
        echo ""
        echo "monorepo-dir (optional; start, stop, restart, status):"
        echo "  The ProsperOps monorepo checkout to run from, e.g. a git worktree."
        echo "  Defaults to the folder the running session was started from, or"
        echo "  else ../core next to this script."
        echo ""
        echo "Layout: 3 rows - Row 1: UI, Admin UI; Row 2: Server, Server Admin; Row 3: Docker Compose"
        echo "Server processes wait 10 seconds for Docker services to start."
        exit 1
        ;;
esac
