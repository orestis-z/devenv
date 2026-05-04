# these are always enabled (the if statements are so you can collapse code sections)
export AUTO_UPDATE_DEVENV="true"
export EXTERNAL_SETUPS="true"
export DIRS_SETUP="true"
export VARS_SETUP="true"
export ALIASES_SETUP="true"
export COMMANDS_SETUP="true"
export ONE_TIME_SETUP="true"

############ AUTO UPDATE DEVENV ############
# MARK: AUTO UPDATE DEVENV
# git pull the dev env to get any updates
if [ $AUTO_UPDATE_DEVENV ]; then
    export DEV_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Only run auto-update in interactive shells (runs in background to avoid slow NFS blocking shell startup)
    if [[ $- == *i* ]] && [ -n "$DEV_ENV_DIR" ] && [ -d "$DEV_ENV_DIR/.git" ]; then
        (
            old_head=$(cd "$DEV_ENV_DIR" && git rev-parse HEAD 2>/dev/null)
            git_output=$(cd "$DEV_ENV_DIR" && git pull 2>&1)
            git_exit_code=$?
            new_head=$(cd "$DEV_ENV_DIR" && git rev-parse HEAD 2>/dev/null)
            if [ $git_exit_code -eq 0 ] && [ "$old_head" != "$new_head" ]; then
                echo -e "\nDevenv updated. Run 'ref' to load changes."
            elif [ $git_exit_code -ne 0 ]; then
                echo -e "\nWarning: devenv git pull failed. Run 'cd \$DEV_ENV_DIR && git status' to check."
            fi
        ) &
        disown
    fi
fi

############ EXTERNAL SETUPS ###########
# MARK: EXTERNAL SETUPS
if [ $EXTERNAL_SETUPS ]; then
    type deactivate &>/dev/null && deactivate # need to deactivate or else colors wont work
    safe_source() { if [ -f "$1" ]; then . "$1"; else echo "Warning: File not found: $1"; fi }
    safe_source "$DEV_ENV_DIR/.colors" # colorful terminal
    safe_source "$DEV_ENV_DIR/.secrets" # setup secrets
    safe_source "$DEV_ENV_DIR/.tmux" # setup secrets
    safe_source ~/rhdev/bin/activate # uv venv activate
    if [ -f ~/.fzf.bash ]; then # some devservers have fzf in usr/bin which takes precedence over this one
        export PATH="/home/HDCharles/.fzf/bin:${PATH}"
    fi
fi
############ DIRS ############
# MARK: DIRS
if [ $DIRS_SETUP ]; then
    export REPOS="$HOME/repos"
    export PYTHONSTARTUP="$DEV_ENV_DIR/.pythonrc"
    export HF_HUB_CACHE="$HOME/hf_hub"
    export HF_HOME="$HOME/hf_hub"
    export TRANSFORMERS_CACHE="$HOME/hf_hub"
    export HF_DATASETS_CACHE="$HOME/hf_hub"
fi
############ VARS ############
# MARK: VARS
if [ $VARS_SETUP ]; then
    export CLAUDE_CODE_USE_VERTEX=1
    export CLOUD_ML_REGION=us-east5
    export ANTHROPIC_VERTEX_PROJECT_ID=itpc-gcp-ai-eng-claude
    export PATH=$PATH:$HOME/.npm-global/bin
    # Detect CUDA version from nvcc, fallback to cu129 if not available
    export UV_TORCH_BACKEND="cu$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9]*\.[0-9]*\).*/\1/p' | tr -d '.' || echo '129')"
    export EDITOR=vim
    export VISUAL=vim
fi
############ ALIASES ############
# MARK: ALIASES
if [ $ALIASES_SETUP ]; then
    alias debug='python -Xfrozen_modules=off -m debugpy --listen 5678 --wait-for-client'
    alias ref='source ~/.bashrc'
    alias seebash="code $DEV_ENV_DIR/.bash_profile"
    alias godev="cd $DEV_ENV_DIR"
    alias setwin="setwindow"
fi
############ COMMANDS ############
# MARK: COMMANDS
if [ $COMMANDS_SETUP ]; then
    res () {
        if [ -z "$1" ] || [ -z "$2" ]; then
        echo "Error: res requires 2 args: res <# gpus> <duration>"
        return
        fi
        output=$(canhazgpu reserve --gpus "$1" --duration "$2")
        export_cmd=$(echo "$output" | grep "export CUDA_VISIBLE_DEVICES" | tail -1)
        if [ -n "$export_cmd" ]; then
            eval "$export_cmd"
            echo "Successfully ran: $export_cmd"
        else
            echo "Warning: Could not find export command in output"
            return
        fi
    }

    rel () {
        chg release
        export CUDA_VISIBLE_DEVICES=
    }

    run() {
        if [[ "$1" =~ ^[0-9]+$ ]]; then
        # First arg is an integer
            eval "chg run --gpus $1 -- ${*:2}"
        else
        # First arg is not an integer
            eval "chg run --gpus 1 -- $*"
        fi
    }

    dolog() {
        local timestamp logfile logdir title=""
        logdir="$HOME/logs"
        mkdir -p "$logdir"

        # Parse optional -t flag
        if [ "$1" = "-t" ]; then
            title="$2"
            shift 2
        fi

        timestamp="$(date '+%Y%m%d-%H%M%S')"
        if [ -n "$title" ]; then
            logfile="${logdir}/${timestamp}_${title}_$(echo "$@" | tr ' /./' '-' | tr -s '-').log"
        else
            logfile="${logdir}/${timestamp}_$(echo "$@" | tr ' /./' '-' | tr -s '-').log"
        fi
        echo "Logging to: $logfile"
        {
            echo "Command: $*"
            "$@"
        } 2>&1 | tee "$logfile"
        echo "Log saved to: $logfile"
    }

    seelogs() {
        local logdir="$HOME/logs"
        if [ ! -d "$logdir" ]; then
            echo "No logs directory found at $logdir"
            return 1
        fi
        local selected
        selected=$(ls -1t "$logdir"/*.log 2>/dev/null | fzf --preview 'tail -50 {}')
        if [ -n "$selected" ]; then
            code "$selected"
        fi
    }

    # Function to set VS Code window title prefix
    setwindow() {
        local new_prefix="$1"
        local settings_file="/home/HDCharles/.vscode-server/data/Machine/settings.json"

        if [ -z "$new_prefix" ]; then
            echo "Usage: setwindow <prefix>"
            return 1
        fi

        # Create settings directory if it doesn't exist
        local settings_dir=$(dirname "$settings_file")
        if [ ! -d "$settings_dir" ]; then
            echo "Creating settings directory: $settings_dir"
            mkdir -p "$settings_dir"
        fi

        # 1. Check if settings.json exists, create if not
        if [ ! -f "$settings_file" ]; then
            echo "Creating settings file: $settings_file"
            echo '{}' > "$settings_file"
        fi

        # 2. Check if window.title is in settings.json
        if ! grep -q '"window.title"' "$settings_file"; then
            # Insert default window.title (escape $ to preserve VS Code template variables)
            local default_title=':${remoteName})${activeEditorShort}${separator}${rootName}${separator}${profileName}'
            jq --arg title "$default_title" '. + {"window.title": $title}' "$settings_file" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"
            echo "Added default window.title to settings"
        fi

        # 3. Modify the title - replace everything before the first ':' with the new prefix
        local current_title=$(grep '"window.title"' "$settings_file" | sed 's/.*"window.title": "\(.*\)".*/\1/')
        local suffix=$(echo "$current_title" | sed 's/^[^:]*//')
        local new_title="${new_prefix}${suffix}"

        sed -i "s|\"window.title\": \".*\"|\"window.title\": \"$new_title\"|" "$settings_file"

        echo "Window title updated to: $new_title"
    }

    hfread() {
        HF_TOKEN=$HF_TOKEN_READ
    }

    hfwrite() {
        HF_TOKEN=$HF_TOKEN_WRITE
    }

    running() {
        ps aux | grep HDCharles 2>&1 | tee ~/running.log
        code ~/running.log
    }

    selfcache () {
        if [ ! -d "$NETWORK_SHARE_DIR/hf_hub" ]; then
            mkdir "$NETWORK_SHARE_DIR/hf_hub"
        fi
        ln -snf "$NETWORK_SHARE_DIR/hf_hub" "$HOME/hf_hub"
    }

    setshare() {
        local base="$1"
        if [ -z "$base" ]; then
            echo "Usage: setshare <base_dir>  (e.g. setshare /mnt/nvme-data/engine)"
            echo "Current network-share -> $(readlink -f "$HOME/network-share")"
            echo "Current hf_hub        -> $(readlink -f "$HOME/hf_hub")"
            return 1
        fi

        if [ ! -d "$base" ]; then
            echo "Error: directory '$base' does not exist"
            return 1
        fi

        # Update network-share symlink
        local share_dir="$base/$USER"
        if [ ! -d "$share_dir" ]; then
            echo "Creating directory: $share_dir"
            mkdir -p "$share_dir"
        fi
        ln -snf "$share_dir" "$HOME/network-share"
        export NETWORK_SHARE_DIR="$share_dir"
        echo "network-share -> $share_dir"

        # Update hf_hub symlink: prefer shared hf_hub, fall back to personal
        if [ -d "$base/hf_hub" ]; then
            ln -snf "$base/hf_hub" "$HOME/hf_hub"
            echo "hf_hub        -> $base/hf_hub"
        elif [ -d "$base/hub_cache" ]; then
            ln -snf "$base/hub_cache" "$HOME/hf_hub"
            echo "hf_hub        -> $base/hub_cache"
        else
            local personal="$share_dir/hf_hub"
            if [ ! -d "$personal" ]; then
                mkdir -p "$personal"
            fi
            ln -snf "$personal" "$HOME/hf_hub"
            echo "hf_hub        -> $personal (personal, no shared cache found)"
        fi
        export HF_HUB_DIR="$(readlink -f "$HOME/hf_hub")"
        export SELF_HF_HUB="$share_dir/hf_hub"
    }

    uva() {
        local env_path="$1"
        
        # If it's a full path to the environment, use it directly
        if [ -d "$env_path/bin" ]; then
            source "$env_path/bin/activate"
        elif [ -d "$HOME/$env_path/bin" ]; then
            source "$HOME/$env_path/bin/activate"
        else
            echo "Environment not found: $env_path"
            return 1
        fi
    }

    uvl() {
        local env_paths=()
        local env_display=()

        # Collect environments from home directory
        for dir in ~/*; do
            if [ -d "$dir" ] && [ -f "$dir/bin/activate" ] && [ -f "$dir/pyvenv.cfg" ]; then
                env_paths+=("$dir")
                env_display+=("$(basename "$dir")")
            fi
        done

        # Also check in common project directories
        if [ -d ~/repos ]; then
            for dir in ~/repos/*; do
                if [ -d "$dir" ] && [ -f "$dir/bin/activate" ] && [ -f "$dir/pyvenv.cfg" ]; then
                    env_paths+=("$dir")
                    env_display+=("repos/$(basename "$dir")")
                fi
            done
        fi

        if [ ${#env_paths[@]} -eq 0 ]; then
            echo "No UV virtual environments found"
            return 1
        fi

        # Use fzf to select environment - display name but return the full path
        local selected
        selected=$(for i in "${!env_display[@]}"; do echo "${env_display[$i]} ${env_paths[$i]}"; done | fzf --prompt="Select environment: ")

        if [ -n "$selected" ]; then
            local env_path="${selected##* }"
            echo "Activating: $env_path"
            source "$env_path/bin/activate"
        fi
    }

    toggle_env() {
        if [ -z "$VIRTUAL_ENV" ]; then
            echo "No virtual environment active. Activating rhdev..."
            . ~/rhdev/bin/activate
        elif [[ "$VIRTUAL_ENV" == *"/rhdev" ]]; then
            deactivate
            . ~/vllm/bin/activate
        elif [[ "$VIRTUAL_ENV" == *"/vllm" ]]; then
            deactivate
            . ~/rhdev/bin/activate
        else
            echo "Unknown virtual environment: $VIRTUAL_ENV"
            echo "Available options: rhdev, vllm"
            return 1
        fi
        echo "Active environment: $VIRTUAL_ENV"
    }

    te() {
        toggle_env
    }

    gitclean() {
        set -e

        echo "Fetching from remote...\n"
        git fetch -p

        echo "Checking for merged branches that are deleted from remote..."
        echo ""

        # Find branches that are gone from remote and merged
        branches_to_delete=()
        for branch in $(git branch -vv | grep ': gone]' | awk '{print $1}'); do
            if git branch --merged | grep -q "^  $branch$"; then
                branches_to_delete+=("$branch")
            fi
        done

        # Display results
        if [ ${#branches_to_delete[@]} -eq 0 ]; then
            echo "No merged branches to clean up."
            return 0
        fi

        echo "The following branches are merged and deleted from remote:"
        for branch in "${branches_to_delete[@]}"; do
            echo "  - $branch"
        done
        echo ""

        # Prompt for confirmation
        read -p "Delete all these branches? (y/n): " confirm

        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            for branch in "${branches_to_delete[@]}"; do
                git branch -d "$branch"
                echo "Deleted: $branch"
            done
            echo "Cleanup complete!"
        else
            echo "Cleanup cancelled."
        fi
    }

    getdirs(){
        echo "DEV_ENV_DIR= $DEV_ENV_DIR"
        echo "HF_HUB_DIR= $HF_HUB_DIR"
        echo "NETWORK_SHARE_DIR= $NETWORK_SHARE_DIR"
        echo "SELF_HF_HUB= $SELF_HF_HUB"
    }

    gdt() {
        if [ -z "$1" ]; then
            echo "Usage: diffmain <file_path>"
            return 1
        fi

        local file="$1"

        # Check if file exists in current state or in main
        if [ ! -f "$file" ] && ! git ls-tree -r main --name-only | grep -q "^$file$"; then
            echo "Error: File '$file' not found in current state or main branch"
            return 1
        fi

        # Use git difftool to compare main branch version with current
        git difftool main -- "$file"
    }

    repo_refresh(){
        refresh_repo_impl "llm-compressor"
        refresh_repo_impl "vllm"
        refresh_repo_impl "compressed-tensors"
        refresh_repo_impl "speculators"
        cd
        echo "repos updated, to install use \`env_install\`"
    }

    env_install() {
        cd
        . ~/rhdev/bin/activate
        cd repos

        cd llm-compressor
        uv pip install -e .[dev]
        cd ..

        cd compressed-tensors
        uv pip install -e .[dev]
        cd ..

        echo "rhdev environment packages installed"
    }

    vllm_install_main() {
        cd
        . ~/vllm/bin/activate
        cd repos

        # cd vllm
        # VLLM_USE_PRECOMPILED=1 uv pip install --editable . --prerelease=allow
        # cd ..
        uv pip install vllm --extra-index-url https://download.pytorch.org/whl/${UV_TORCH_BACKEND}

        echo "vllm environment packages installed (precompiled)"
    }

    vllm_install_source() {
        cd
        . ~/vllm/bin/activate
        cd repos

        cd vllm
        uv pip install -e .[dev]
        cd ..

        echo "vllm environment packages installed (from source)"
    }

    goto() {
        if [ -z "$1" ]; then
            echo "Usage: goto <file>"
            return 1
        fi

        local target="$1"
        local dir

        # If file exists, resolve to absolute path first
        if [ -e "$target" ]; then
            target=$(realpath "$target")
        fi

        # Get parent directory
        dir=$(dirname "$target")

        cd "$dir" || return 1
    }
fi
############ ONE TIME SETUP ############
# MARK: ONE TIME SETUP
# one time setup tasks like installing extensions, setting git config, etc that we only want to do once
# but want to be chekced on every shell start
if [ $ONE_TIME_SETUP ]; then
    safe_source "$DEV_ENV_DIR/.one_time_setup"
fi