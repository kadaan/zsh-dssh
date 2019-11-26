dssh() {
  set +m
  set -o pipefail


  local AWS_HOSTFILE=$HOME/.aws-hosts
  local E_NOERROR=0
  local E_NOARGS=103
  local COLOR_PREFIX='\033[38;5;'
  local COLOR_SUFFIX='m'
  local GRAY="${COLOR_PREFIX}249${COLOR_SUFFIX}"
  local ORANGE="${COLOR_PREFIX}160${COLOR_SUFFIX}"
  local RED="${COLOR_PREFIX}208${COLOR_SUFFIX}"
  local BOLD_WHITE='\033[1m'
  local NC='\033[0m'
  local ENVS=()
  local HOSTS=[]
  local WAS_UPDATED=false
  local PUBLIC_FQDN_TARGET="ec2-[0-9]+-[0-9]+-[0-9]+-[0-9]+\.compute-1\.amazonaws\.com"
  local REQUIRED_PIP_VERSION="18.1"
  local REQUIRED_PYTHON_PACKAGES=("boto==2.46.1" "boto3==1.5.27" "six==1.12.0" "gevent==1.4.0")

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
      pyenv sh-shell 2.7.13 &>/dev/null || {
        brew --version &>/dev/null || {
          /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)" &>/dev/null || _pfatal "failed to install brew: $?"
        }
        brew list 2>/dev/null | grep "^pyenv$" &>/dev/null  || {
          brew update &>/dev/null || _pfatal "failed to update brew: $?"
          brew install 'pyenv' &>/dev/null || _pfatal "failed to install pyenv: $?"
        }
        pyenv install 2.7.13 --skip-existing &>/dev/null || _pfatal "failed to install python 2.7.13: $?"
      }
      (
        eval "$(pyenv sh-shell 2.7.13)" &>/dev/null || _pfatal "failed to switch to python 2.7.13: $?"
        if [[ ! -f $HOME/.dssh/bin/activate ]]; then
          if ! pyenv exec python -c "import virtualenv" &>/dev/null; then
            pyenv exec pip install virtualenv==16.2.0 &>/dev/null || fatal "failed to install package virtualenv: $?"
          fi
          if [[ ! -d $HOME/.dssh ]]; then
            pyenv exec virtualenv "$HOME/.dssh" --no-pip &>/dev/null || _pfatal "failed to create virtualenv '$HOME/.dssh': $?"
          fi
        fi
        source "$HOME/.dssh/bin/activate" &>/dev/null || _pfatal "failed to activate virtualenv '$HOME/.dssh': $?"
        local checksum_filename="$HOME/.dssh/packages.checksum"
        local expected_checksum=""
        if [[ -f $checksum_filename ]]; then
          expected_checksum="$(\cat $checksum_filename)"
        fi
        local actual_checksum="$(echo "$REQUIRED_PIP_VERSION;;$REQUIRED_PYTHON_PACKAGES[*]" | shasum)"
        if [[ "$expected_checksum" != "$actual_checksum" ]]; then
          python -m ensurepip &>/dev/null || _pfatal "failed to ensure baseline pip is installed: $?"
          python -m pip install pip==$REQUIRED_PIP_VERSION &>/dev/null || _pfatal "failed to install pip: $?"
          python -m pip install $REQUIRED_PYTHON_PACKAGES[*] &>/dev/null || _pfatal "failed to install [boto,boto3,six,gevent]: $?"
          echo "$actual_checksum" > $checksum_filename
        fi
      )
      dependencies_installed=true
    fi
  }
  _activate_python() {
    eval "$(pyenv sh-shell 2.7.13)" &>/dev/null || _pfatal "failed to switch to python 2.7.13: $?"
    source "$HOME/.dssh/bin/activate" &>/dev/null || _pfatal "failed to activate virtualenv '$HOME/.dssh': $?"
  }
  _get_host() {
      local host="${1%%,*}"
      echo $host
  }
  _get_region() {
      local tmp="${1%,*}"
      local region="${tmp##*,}"
      echo $region
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
    AWS_REGIONS=${ENV_AWS_REGIONS:?} python $ANSIBLE_INVENTORY/ec2.py --refresh-cache | python -c "$(echo $ANSIBLE_HOSTS_QUERY)" | sed "s/$/,$ENV_COLOR/" | sort -d -k "8,8" -k "9,9" -k "1,1" -t "," > "$AWS_HOSTFILE.$filename"
    return $?
  }
  _update_inventory() {
    (
      _activate_python
      cd $ANSIBLE_PATH || return
      set -o allexport
      source $1
      set +o allexport
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
  _is_inventory_old() {
    local needUpdates=0
    _lsenv | while read x; do
      (
        set -o allexport
        source $x
        set +o allexport
        if [[ "${ENV_DISABLED:-0}" -eq 0 ]]; then
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
        fi
      )
    done
    if [[ $needUpdates -gt 0 ]]; then
      return 0
    else
      return 1
    fi
  }
  _update_inventories() {
    if [[ "$WAS_UPDATED" == "false" ]]; then
      _lock
      echo -n "${GRAY}Updating inventories...${NC}" 1>&2
      _install_dependencies
      _lsenv | while read x; do
        _update_inventory $x &
      done
      wait
      echo "${GRAY}done${NC}" 1>&2
      WAS_UPDATED=true
      _unlock
    fi
  }
  _print_menu() {
    local term_width="$(tput cols)"
    local max_host_length="$(echo "$1" | cut -d "," -f 1 | awk '{print length}' | sort -nr | head -1)"
    max_host_length="$((max_host_length+1))"
    local lines="$(echo "$1" | awk -F ',' "{printf \"%s%s%s%3s: %s%-*s%s (%s)%s\n\", \"$COLOR_PREFIX\", \$3, \"$COLOR_SUFFIX\", NR, \"$NC\", $max_host_length-1, \$1, \"$GRAY\", \$2, \"$NC\"}")"
    local longest="$(echo "$1" | awk -F ',' "{printf \"%3s: %s%-*s (%s)\n\", NR, \"$NC\", $max_host_length-1, \$1, \$2}" | awk '{print length}' | sort -nr | head -1)"
    local column_count="$((term_width/longest))"
    echo "$lines" | rs -e -t -z -w$term_width -G3 0 $column_count 2>/dev/null
    echo -e "  ${BOLD_WHITE}R${NC}: Refresh" 1>&2
    echo -e "  ${BOLD_WHITE}Q${NC}: Quit" 1>&2
    echo "" 1>&2
  }
  _resolve_target() {
    local targets=("$@")
    local lookup_attempt_count=0
    local filtered_hosts=""
    while true; do
      for hostsfile in $AWS_HOSTFILE.*; do
        local filtered_hosts_partial=$(\cat $hostsfile)
        for target in "${targets[@]}"; do
          filtered_hosts_partial=$(echo "$filtered_hosts_partial" | grep -h -- "$target" | sort -d -k "8,8" -k "9,9" -k "1,1" -t ",")
          if [[ -z "$filtered_hosts_partial" ]]; then
            break;
          fi
        done
        if [[ "$filtered_hosts_partial" != "" ]]; then
          if [[ "$filtered_hosts" != "" ]]; then
            filtered_hosts="$filtered_hosts\n"
          fi
          filtered_hosts="$filtered_hosts$filtered_hosts_partial"
        fi
      done
      if [[ "$filtered_hosts" == "" && $lookup_attempt_count -eq 0 ]]; then
        lookup_attempt_count=$(($lookup_attempt_count+1))
        _update_inventory
      else
        break
      fi
    done
    echo "$filtered_hosts" | cut -d "," -f 1,9,10
    if [[ "$WAS_UPDATED" == true ]]; then
      return 1
    else
      return 0
    fi
  }
  _prompt_server() {
    local count=$(echo "$info" | wc -l)

    if [[ $count -gt 1 ]]; then
      while
        local refreshMenu=0
        _print_menu $info

        while true; do
          echo -n "Which server [#]: " 1>&2
          read position

          if [[ "$position" = "Q" ]] || [[ "$position" = "q" ]]; then
            return -1
          elif [[ "$position" = "R" ]] || [[ "$position" = "r" ]]; then
            _update_inventories
            info="$(_resolve_target "${params[@]}")"
            if [[ "$info" == "" ]]; then
              _pwarn "Host '$target' not found in inventory.  Attempting to connect anyway..."
              break;
            fi
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
        if [[ $verbose_level -ge 4 ]]; then
          if [[ "$ZSH_VERSION" != "" ]]; then
            local start_time="${${EPOCHREALTIME//.}:0:-6}"
            PS4="+ [\$(( \${\${EPOCHREALTIME//.}:0:-6} - $start_time ))] [%N:%i] "
          elif [[ "${BASH_VERSINFO[0]}" == "5" ]]; then
            local start_time="$(( ${EPOCHREALTIME//.} / 1000 ))"
            PS4="+ [\$(( (\${EPOCHREALTIME//.} / 1000) - $start_time ))] [\${FUNCNAME[0]}:\${LINENO}] "
          elif command -v gdate > /dev/null; then
            local start_time="$(gdate "+%s%3N")"
            PS4="+ [\$(( \$(gdate "+%s%3N") - $start_time ))] [\${FUNCNAME[0]}:\${LINENO}] "
          else
            local start_time="$(date "+%s")"
            PS4="+ [\$(( \$(date "+%s") - $start_time ))] [\${FUNCNAME[0]}:\${LINENO}] "
          fi
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
  fi

  if [[ "$completions_enabled" = true ]]; then
    COMPREPLY=($(\cat $AWS_HOSTFILE.* | cut -f1 -d , | uniq && \cat $AWS_HOSTFILE.* | cut -f2 -d , | uniq))
    return $E_NOERROR
  fi

  if [[ ${#params[@]} -eq 0 ]]; then
    return $E_NOERROR
  fi

  local addr=""
  if [[ ${#params[@]} -eq 1 && "${params[1]}" =~ $PUBLIC_FQDN_TARGET ]]; then
    addr="${params[1]}"
  else
    local info=""
    info="$(_resolve_target "${params[@]}")"
    if [[ "$?" -eq 1 ]]; then
      WAS_UPDATED=true
    fi
    if [ -z "$info" ]; then
      _update_inventories
      info="$(_resolve_target "${params[@]}")"
      if [[ "$?" -eq 1 ]]; then
        WAS_UPDATED=true
      fi
      if [ -z "$info" ]; then
        _pwarn "Host '${params[*]}' not found in inventory.  Attempting to connect anyway..."
        addr="${params[*]}"
      fi
    fi
    if [[ "$addr" == "" ]]; then
      local count=$(echo "$info" | wc -l)
      if [[ $count -gt 1 ]]; then
        if _is_inventory_old; then
          _update_inventories
        fi
        _prompt_server
        local result="$?"
        if [[ "$result" -eq -1 ]]; then
          return $E_NOERROR
        elif [[ "$result" -gt 0 ]]; then
          return $result
        fi
      fi
      addr=`echo $info | awk -F, '{print $2}'`
      local name=`echo $info | awk -F, '{print $1}'`
      if ! nc -G3 -z $addr 22 &>/dev/null; then
        if [[ "$WAS_UPDATED" == "false" ]]; then
          _update_inventories
          info="$(_resolve_target "$name")"
          if [[ "$?" -eq 1 ]]; then
            WAS_UPDATED=true
          fi
          if [[ "$info" == "" ]]; then
            info="$(_resolve_target "${params[@]}")"
          fi
          _prompt_server
          local result="$?"
          if [[ "$result" -eq -1 ]]; then
            return $E_NOERROR
          elif [[ "$result" -gt 0 ]]; then
            return $result
          fi
          addr=`echo $info | awk -F, '{print $2}'`
        fi
      fi
      fi
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
  ssh_command+=( "ConnectTimeout=10" )
  ssh_command+=( "${addr}" )
  ${ssh_command[@]}
  return $?
}