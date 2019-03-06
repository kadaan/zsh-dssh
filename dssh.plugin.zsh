dssh() {
    set +m
    set -o pipefail


    local AWS_HOSTFILE=$HOME/.aws-hosts
    local E_NOERROR=0
    local E_NOARGS=103
    local GRAY='\033[38;5;249m'
    local ORANGE='\033[38;5;160m'
    local RED='\033[38;5;208m'
    local BOLD_WHITE='\033[1m'
    local NC='\033[0m'
    local ENVS=()
    local HOSTS=[]

    _pverbose() { echo -e "${GRAY}$1${NC}" 1>&2; }
    _pwarn() { echo -e "${ORANGE}$1${NC}" 1>&2; }
    _perror() { echo -e "${RED}ERROR: $1${NC}" 1>&2; }
    _pfatal() { echo -e "${RED}ERROR: $1${NC}" 1>&2; exit 1; }
    _lock() { dotlockfile -l -p $AWS_HOSTFILE.lock; }
    _unlock() { dotlockfile -u -p $AWS_HOSTFILE.lock; }
    _prepare_locking() { trap _unlock EXIT; }
    _usage() {
        echo
        echo "Locates and connects to AWS servers server via SSH."
        echo
        echo "Usage: dssh [options] tag"
        echo "    -r, --refresh         refresh the cached host information"
        echo "    -t, --tunnel=PORT     create a tunnel for the specified port"
        echo "    -v                    verbose logging, multiple -v options increase the verbosity"
        echo "    -h, --help            display this help message"
    }
    _install_dependencies() {
      if [[ "$dependencies_installed" == false ]]; then
        brew --version &>/dev/null || {
          /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)" &>/dev/null || _pfatal "failed to install brew: $?"
        }
        brew list 2>/dev/null | grep "^pyenv$" &>/dev/null  || {
          brew update &>/dev/null || _pfatal "failed to update brew: $?"
          brew install 'pyenv' &>/dev/null || _pfatal "failed to install pyenv: $?"
        }
        pyenv versions | grep -E '^[* ] 2.7.13 .+$' &>/dev/null || {
          pyenv install 2.7.13 --skip-existing &>/dev/null || _pfatal "failed to install python 2.7.13: $?"
        }
        (
          eval "$(pyenv sh-shell 2.7.13)" &>/dev/null || _pfatal "failed to switch to python 2.7.13: $?"
          pyenv exec pip install virtualenv==16.2.0 &>/dev/null || fatal "failed to install package virtualenv: $?"
          if [[ ! -d $HOME/.dssh ]]; then
            pyenv exec virtualenv "$HOME/.dssh" --no-pip &>/dev/null || _pfatal "failed to create virtualenv '$HOME/.dssh': $?"
          fi
          source "$HOME/.dssh/bin/activate" &>/dev/null || _pfatal "failed to activate virtualenv '$HOME/.dssh': $?"
          python -m ensurepip &>/dev/null || _pfatal "failed to ensure baseline pip is installed: $?"
          python -m pip install pip==18.1 &>/dev/null || _pfatal "failed to install pip: $?"
          python -m pip install boto boto3 six ansible &>/dev/null || _pfatal "failed to install [boto,boto3,six,ansible]: $?"
        )
        dependencies_installed=true
      fi
    }
    _activate_python() {
      eval "$(pyenv sh-shell 2.7.13)" &>/dev/null || _pfatal "failed to switch to python 2.7.13: $?"
      source "$HOME/.dssh/bin/activate" &>/dev/null || _pfatal "failed to activate virtualenv '$HOME/.dssh': $?"
    }
    _get_host() {
        local tmp="${1%%,*}"
        local host="${1%%,*}"
        echo $host
    }
    _get_color() {
        local color="${1##*,}"
        echo -e "\\033[38;5;${color}m"
    }
    _lsenv() {
        ls -1 $HOME/.env/*.sh
    }
    _get_envname() {
        local filename=$(basename "$1")
        filename="${filename%.*}"
        echo $filename
    }
    _refresh_inventory() {
      rm -rf "$AWS_HOSTFILE.$filename"
      local default_ec2_ini_path="$ANSIBLE_INVENTORY/ec2.ini"
      BOTO_USE_ENDPOINT_HEURISTICS=True EC2_INI_PATH=${EC2_INI_PATH:-$default_ec2_ini_path} AWS_REGIONS=${ENV_AWS_REGIONS:?} python $ANSIBLE_INVENTORY/ec2.py --refresh-cache | python -c "$(echo $ANSIBLE_HOSTS_QUERY)" | sed "s/$/,$ENV_COLOR/" | sort > "$AWS_HOSTFILE.$filename"
      return $?
    }
    _update_inventory() {
        (
            _activate_python
            cd $ANSIBLE_PATH || return
            source $1
            if [[ "${ENV_DISABLED:-0}" -eq 0 ]]; then
              local filename=$(_get_envname "$1")
              if [ ! -f $ANSIBLE_INVENTORY/ec2.py ]; then
                  return
              fi
              local i=0
              _refresh_inventory
              local result=$?
              while [ $result -ne 0 ]; do
                  i=$(($i+1))
                  if [ "$i" -gt 5 ]; then
                      break;
                  fi

                  _refresh_inventory
                  result=$?
              done
            fi
        )
    }
    _update_inventories() {
        _lock
        echo -n "${GRAY}Updating inventories...${NC}" 1>&2
        _install_dependencies
        _lsenv | while read x; do
          _update_inventory $x &
        done
        wait
        echo "${GRAY}done${NC}" 1>&2
        _unlock
    }
    _print_menu() {
      local index=1
      for line in $(echo "$1"); do
          local host="$(_get_host $line)"
          local color="$(_get_color $line)"
          echo -e "${color}$index:${NC} $host" 1>&2
          index=$((index+1))
      done
      echo -e "${BOLD_WHITE}R${NC}: Refresh" 1>&2
      echo -e "${BOLD_WHITE}Q${NC}: Quit" 1>&2
      echo "" 1>&2
    }

    _prepare_locking

    if [[ $# -eq 0 ]]; then
        _perror "wrong number of input parameters [$#]"
        _usage
        return $E_NOARGS
    fi

    local -a params=( "$@" );
    local index=1
    local dependencies_installed=false
    local refresh_enabled=false
    local verbose_level=0
    local verbose_flag=""
    local tunnel_port=""
    local completions_enabled=false
    for var in "$@"; do
        case "$var" in
            -h | --help)
                _usage
                return $E_NOERROR
            ;;
            -r | --refresh)
                refresh_enabled=true
                params[$index]=()
            ;;
            -v | -vv | -vvv | -vvvv)
                verbose_flag=${params[$index]}
                local verbose_elements=${params[$index]##-}
                verbose_level=${#verbose_elements}
                if [[ $verbose_level -eq 4 ]]; then
                  set -x
                fi
                params[$index]=()
            ;;
            --completions)
                completions_enabled=true
                params[$index]=()
            ;;
            *)
              if [[ $var == -t=* || $var == --tunnel=* ]]; then
                  tunnel_port=${params[$index]##*=}
                  params[$index]=()
              else
                index=$((index+1))
              fi
            ;;
        esac
    done

    if [[ "$refresh_enabled" = true ]]; then
        _update_inventories
    else
        (
            local needUpdates=0
            _lsenv | while read x; do
                source $x
                filename=$(_get_envname "$x")
                if [ -f $ANSIBLE_INVENTORY/ec2.py ]; then
                    if [[ ! -f $AWS_HOSTFILE.$filename ]] || [[ ! -s $AWS_HOSTFILE.$filename ]]; then
                      needUpdates=$((needUpdates+1))
                    else
                      local currentTimestamp=$(date +%s)
                      local fileTimestamp=$(stat -f "%m" "$AWS_HOSTFILE.$filename")
                      local elapsedTime=$(($currentTimestamp-$fileTimestamp))
                      if [[ $elapsedTime -gt ${DSSH_HOST_UPDATE_FREQUENCY:-3600} ]]; then
                          needUpdates=$((needUpdates+1))
                      fi
                    fi
                fi
            done
            if [[ $needUpdates -gt 0 ]]; then
              _update_inventories
            fi
        )
    fi

    if [[ "$completions_enabled" = true ]]; then
        COMPREPLY=($(\cat $AWS_HOSTFILE.* | cut -f1 -d , | uniq && \cat $AWS_HOSTFILE.* | cut -f2 -d , | uniq))
        return $E_NOERROR
    fi

    if [[ ${#params[@]} -eq 0 ]]; then
        return $E_NOERROR
    fi

    local lookup_attempt_count=0
    local info=""
    while [[ $lookup_attempt_count -le ${DSSH_LOOKUP_RETRY_COUNT:-1} ]]; do
      info=$(\cat $AWS_HOSTFILE.*)
      for target in "${params[@]}"; do
        info=$(echo "$info" | grep -h -- "$target")
        if [[ -z "$info" ]]; then
          _update_inventories
          break;
        fi
      done
      if [ -z "$info" ]; then
        lookup_attempt_count=$(($lookup_attempt_count+1))
      else
        break
      fi
    done

    local addr=""
    if [ -z "$info" ]; then
      _pwarn "Host '$target' not found in inventory.  Attempting to connect anyway..."
      addr=$target
    else
      local count=$(echo "$info" | wc -l)

      if [[ $count -gt 1 ]]; then
        while
            local refreshMenu=0
            _print_menu $info

            while true; do
                echo -n "Which server [#]: " 1>&2
                read position

                if [[ "$position" = "Q" ]] || [[ "$position" = "q" ]]; then
                    return $E_NOERROR
                elif [[ "$position" = "R" ]] || [[ "$position" = "r" ]]; then
                    _update_inventories
                    info=$(grep -h -- "$target" $AWS_HOSTFILE.*)
                    refreshMenu=1
                    break
                elif [ $position -ge 1 ] 2>/dev/null && [ $position -le $count ] 2>/dev/null;  then
                    info=$(echo "$info" | sed -n "${position}p")
                    break
                fi
            done
            (( refreshMenu > 0 ))
        do
            continue
        done
      fi

      local addr=`echo $info | awk -F, '{print $2}'`
    fi

    echo "" 1>&2
    _pverbose "Connecting to $addr..."
    local -a ssh_command=(ssh)
    if [[ $verbose_level -gt 0 ]]; then
      ssh_command+=( "-$(printf 'v%.0s' {1..$verbose_level})" )
    fi
    if [[ "$tunnel_port" != "" ]]; then
      ssh_command+=( "-nNT" )
      ssh_command+=( "-L" )
      ssh_command+=( "${tunnel_port}:localhost:${tunnel_port}" )
    fi
    ssh_command+=( "-o" )
    ssh_command+=( "ConnectTimeout=30" )
    ssh_command+=( "${addr}" )
    ${ssh_command[@]}
    return $?
}
