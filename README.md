1) in a new server do:

```shell
git clone https://github.com/HDCharles/devenv
source devenv/.bash_profile
```

2) follow the prompts

note: if you make changes, you'll break the automatic sync functionality so you'll need to fork the repo and git clone from it (at which point that fork will always be the source of truth that will be auto updated to and you need to push changes to that)

# Functionality

## One Time Setup

upon cloning and sourcing the repo, a number of things will be automatically set up. This functionality can be found in 
[.one_time_setup](https://github.com/HDCharles/devenv/tree/main) which consists of a number of helpers and the setup code to use them for
dev environment setup. This usually runs a single time upon starting with a new server though each setup step is independent and only runs if necessary (If you delete a repo, it will reclone the repo, not redo the entire setup).

once the automatic setup completes you will be asked to run `finish_setup` to do the user interactive setup (gh auth, claude auth)

### Setup Overview:
#### Automatic Setup
These things will work without user input (assuming no errors)

1) you won't have to manually source again, a .bash_profile source will be added to your .bashrc (### OTS .BASHRC CALLS .BASH_PROFILE ###)
2) it will create /home/repos and clone llm-compressor, compressed-tensors, vllm, speculators and llm-compressor-testing repos
3) it will set up a rhdev virtual environment (using uv) and install llm-compressor and compressed-tensors. This env is used to quantize models
4) it will set up a vllm virtual environment (using uv) and install vllm. This env is used for vllm evaluation of models
5) install [fzf](https://github.com/junegunn/fzf)
6) install a bunch of vscode extensions
7) look for a network share directory (or general non home directory for storing data) and symlink it in $HOME/network-share
8) look for hf_hub (model/data cache) within network-share and symlink it at $HOME/hf_hub
9) automatically use devenv/other_files/.tmux.conf to configure tmux with a bunch of QoL features
10) automatically use devenv/other_files/launch.json (needed for debugpy)
11) claude code installation

#### Finish Setup
These setup steps require user input

11) gh auth
12) claude auth

Once these authorizations are complete, additional setup steps will now run that don't require user input
13) git configuration, template, username, email (info pulled from gh auth), difftool

## Bash Profile

The entrypoint to the whole thing, this calls all other configuration/setup scripts and can be found in [.bash_profile](https://github.com/HDCharles/devenv/tree/main)

This consists of 4 parts

1) AUTO UPDATE DEVENV - Automatically update the devenv repo so all servers always have the same configuration
2) EXTERNAL SETUPS - sources .colors, .secrets, .tmux ...etc (see below)
3) exports for various environment variables that are used both in this script and elsewhere
  3a) DIRS - directories like hf_hub_cache
  3b) VARS - things like PATH updates, claude setup vars...etc
4) helpers are various shortcuts and commands i use
  - ALIASES - shortcuts i use to call other things
    - debug - for invoking debugpy correctly
    - ref - refresh environment
    - seebash - show the .bash_profile 
    - godev - go to the devenv repo folder
    - setwin - setwindow name, doesn't work with spaces (I use this to set the vscode window names so i know what i'm working on in each devserver)
  - COMMANDS - like aliases but more complicated (ordered by usefulness)
    - res, rel, run - all are shortcuts for chg functionality, short for reserve, release and run
      - `res 2 30m` reserves 2 gpus for 30 minutes
      - `rel` releases any reserved gpus
      - `run <command>` runs a command with 1 gpu
      - `run 3 <command>` runs a command with 3 gpus
    - dolog - general command line logging, puts log in `$HOME/logs`
      `dolog <command>` all output of command will be put in a log file with cur time and part of command in the name
      `dolog -t <label> <command>` the log file will also have the label as part of the time
    - seelogs - see all logfiles in fzf window (shows you size, preview and colors files by size)
    - repo_refresh/env_install/vllm_install_main/vllm_install_source - various uv venv helpers
      repo_refresh - goes to each repo and does git pull
      env_install - installs llm-comprsesor and compressed-tensors from source to rhdev venv
      vllm_install_main - installs prebuilt vllm to vllm venv
      vllm_install_source - installs vllm to vllm venv from source (necessary on B200/H100 sometimes, very slow)
    - setwindow - the actual functionality for setwin
    - uva/uvl - uv activate and uv list, for activating and listing uv virtual environments
      `uva rhdev` activates rhdev venv
      `uvl` gives fzf window of uv venvs which you can select to activate
    - running - open a file that includes info about all running processes, usefull so you can `kill -9 pid`
    - goto - goes to directory containing a file
    
    rarely used commands:

    - getdirs - lists most important directory paths
    - toggle_env - swaps between rhdev and vllm venvs
    - selfcache - change hf_hub to not be the shared hf_hub but instead be a personal one usually /raid/engine/hub_cache -> /raid/engine/$USER/hub_cache
    - hfread/hfwrite - changes the HF_TOKEN from one with read permissions to one with write permissions, expects HF_TOKEN_READ and HF_TOKEN_WRITE to be specified in .secrets
    - setshare - change network share drive e.g. `setshare /raid/engine` updates symlinks and VARS
    - gdt - git diff tool, opens changed files in repo branch using diff tool to see changes, or `gdt <file>` opens only that one file, (the git tree compare extention mostly does the same thing)

## COLORS

the .colors file has a bunch of setup to make the command line more colorful, this was a default on an older devserver and i just copied it

## TMUX

has a bunch of tmux setup stuff, mostly contains the commands `tmuxhelp` for a reminder of tmux commands and `tma` to help connecting to existing tmux sessions
