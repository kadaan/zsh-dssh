_dssh_aws_hostfile_dir="$HOME"
_dssh_aws_hostfile_prefix=.aws-hosts
_dssh_aws_hostfile="$_dssh_aws_hostfile_dir/$_dssh_aws_hostfile_prefix"
_dssh_env_pattern="^${_dssh_aws_hostfile_dir}/\.env/[[:digit:]]*_(.*)\.sh$"
_dssh_e_noerror=0
_dssh_e_noargs=103
_dssh_e_noserver=104
_dssh_color_prefix='\033[38;5;'
_dssh_color_suffix='m'
_dssh_gray="${_dssh_color_prefix}249${_dssh_color_suffix}"
_dssh_orange="${_dssh_color_prefix}160${_dssh_color_suffix}"
_dssh_red="${_dssh_color_prefix}208${_dssh_color_suffix}"
_dssh_bold_white='\033[1m'
_dssh_nc='\033[0m'
_dssh_public_fqdn_target="ec2-[0-9]+-[0-9]+-[0-9]+-[0-9]+\.compute-1\.amazonaws\.com"
_dssh_required_pip_version="22.3.1"
_dssh_required_python_packages=("boto==2.49.0" "boto3==1.26.29" "six==1.16.0" "gevent==22.10.2")
_dssh_host_query="import sys\nimport json\n\ndata = json.load(sys.stdin)\n\nfor name, info in data['_meta']['hostvars'].items():\n    if 'ec2_tag_Name' in info:\n        print('%s,%s,%s,%s,%s,%s,%s,%s,%s,%s' % (info['ec2_tag_Name'], name, info['ec2_private_dns_name'], info['ec2_private_ip_address'], info['ec2_public_dns_name'], info['ec2_ip_address'], info['ec2_id'], info['ec2_tag_Service'], info['ec2_placement'], 'autoscaling' if 'ec2_tag_Autoscaling' in info else 'instance' ))"
_dssh_aws_okta_verbose_flag=""

function _dssh_pverbose() { echo -e "${_dssh_gray}$1${_dssh_nc}" 1>&2; }
function _dssh_pwarn() { echo -e "${_dssh_orange}$1${_dssh_nc}" 1>&2; }
function _dssh_perror() { echo -e "${_dssh_red}ERROR: $1${_dssh_nc}" 1>&2; }
function _dssh_pfatal() { echo -e "${_dssh_red}ERROR: $1${_dssh_nc}" 1>&2; exit 1; }
function _dssh_lock() { dotlockfile -l -p $_dssh_aws_hostfile.lock; }
function _dssh_unlock() { dotlockfile -u -p $_dssh_aws_hostfile.lock; }
function _dssh_prepare_dssh_locking() { trap _dssh_unlock EXIT; }

function _dssh_init() {
  _dssh_aws_okta_verbose_flag="-v=${verbose_level}"
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
  _dssh_install_python
  if [[ "$refresh_enabled" = true ]]; then
    _dssh_update_inventories false "$@"
  fi
}

function _dssh_common_usage() {
  echo "    -r, --refresh, --no_refresh     trigger or prevent refresh the cached host information"
  echo "    -v, -vv, -vvv, -vvvv            verbose logging, multiple -v options increase the verbosity"
  echo "    -h, --help                      display this help message"
}
function _dssh_tag_usage() {
  echo "TAGS:"
  echo "    Servers can be filtered and selected using tags."
  echo "    The tags filter the server lists by name, public and private FQDN,"
  echo "      public and private IP, instance id, service, region, availability zone,"
  echo "      lifecycle, and whether the server is in an ASG (autoscaling/instance)."
  echo "    Tags separated by spaces are intersected.  For instance 'imports dev' filters"
  echo "      the servers down to all those whose name or service contain 'imports' and"
  echo "      lifecycle is 'dev'."
  echo "    Tags separated by commas are unioned.  For instance 'imports,one' filters"
  echo "      the servers down to all those whose name or service contain either 'imports'"
  echo "      or 'one'."
  echo "    Tags can be negated by prefixing the tag with '%'."
  echo "    Union, intersection, and negation can all be used together."
  echo ""
}
function _dssh_install_python() {
  if [[ "$python_installed" == false ]]; then
    local checksum_filename
    if [[ "${DEVBOX_SHELL_ENABLED:-0}" == "0" ]]; then
      pyenv sh-shell 3.9.8 &>/dev/null || {
        _dssh_pverbose "\nInstalling python..."
        brew --version &>/dev/null || {
          /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)" &>/dev/null || _dssh_pfatal "failed to install brew: $?"
        }
        brew list 2>/dev/null | grep "^pyenv$" &>/dev/null  || {
          brew update &>/dev/null || _dssh_pfatal "failed to update brew: $?"
          brew install 'pyenv' &>/dev/null || _dssh_pfatal "failed to install pyenv: $?"
        }
        brew list 2>/dev/null | grep "^zlib$" &>/dev/null  || {
          brew update &>/dev/null || _dssh_pfatal "failed to update brew: $?"
          brew install 'zlib' &>/dev/null || _dssh_pfatal "failed to install zlib: $?"
        }
        brew list 2>/dev/null | grep "^bzip2$" &>/dev/null  || {
          brew update &>/dev/null || _dssh_pfatal "failed to update brew: $?"
          brew install 'bzip2' &>/dev/null || _dssh_pfatal "failed to install bzip2: $?"
        }
        pyenv install 3.9.8 --skip-existing &>/dev/null || _dssh_pfatal "failed to install python 3.9.8"
      }
      checksum_filename="$HOME/.dssh/packages.checksum"
    else
      source "${DEVBOX_PROJECT_ROOT}"/.devbox/virtenv/bin/venvShellHook.sh &> /dev/null
      source "${VENV_DIR}/bin/activate"
      checksum_filename="${VENV_DIR}/packages.checksum"
    fi
    (
      if [[ "${DEVBOX_SHELL_ENABLED:-0}" == "0" ]]; then
        eval "$(pyenv sh-shell 3.9.8)" &>/dev/null || _dssh_pfatal "failed to switch to python 3.9.8: $?"
        if [[ ! -f $HOME/.dssh/bin/activate ]]; then
          if ! pyenv exec python -c "import virtualenv" &>/dev/null; then
            pyenv exec pip install virtualenv==16.2.0 &>/dev/null || _dssh_pfatal "failed to install package virtualenv: $?"
          fi
          if [[ ! -d $HOME/.dssh ]]; then
            pyenv exec virtualenv "$HOME/.dssh" --no-pip &>/dev/null || _dssh_pfatal "failed to create virtualenv '$HOME/.dssh': $?"
          fi
        fi
        source "$HOME/.dssh/bin/activate" &>/dev/null || _dssh_pfatal "failed to activate virtualenv '$HOME/.dssh': $?"
      fi
      local expected_checksum=""
      if [[ -f $checksum_filename ]]; then
        expected_checksum="$(\cat $checksum_filename)"
      fi
      local actual_checksum="$(echo "$_dssh_required_pip_version;;$_dssh_required_python_packages[*]" | shasum)"
      if [[ "$expected_checksum" != "$actual_checksum" ]]; then
        python -m ensurepip &>/dev/null || _dssh_pfatal "failed to ensure baseline pip is installed: $?"
        python -m pip install pip==$_dssh_required_pip_version &>/dev/null || _dssh_pfatal "failed to install pip: $?"
        python -m pip install $_dssh_required_python_packages[*] &>/dev/null || _dssh_pfatal "failed to install [boto,boto3,six,gevent]: $?"
        echo "$actual_checksum" >! $checksum_filename
      fi
    )
    python_installed=true
  fi
}
function _dssh_lsenv() {
    \ls -1 $HOME/.env/*.sh
}
function _dssh_get_envname() {
    local filename=$(basename "$1")
    filename="${filename%.*}"
    echo $filename
}
function _dssh_refresh_inventory() {
  rm -rf "$_dssh_aws_hostfile.$filename"
  local ec2_ini_path="$ANSIBLE_INVENTORY/ci.ini"
  if [ -f "$ANSIBLE_INVENTORY/ec2_private.ini" ]; then
    ec2_ini_path="$ANSIBLE_INVENTORY/ec2_private.ini"
  fi
  if command -v aws-okta &>/dev/null; then
    if [[ "$AWS_PROFILE" != "" ]]; then
      AWS_OKTA_IGNORE_UPDATES=true AWS_REGIONS=${ENV_AWS_REGIONS:?} EC2_INI_PATH=$ec2_ini_path aws-okta exec ${_dssh_aws_okta_verbose_flag} $AWS_PROFILE --disable-server -- python $ANSIBLE_INVENTORY/ec2.py --refresh-cache | python -c "$(echo $_dssh_host_query)" | sed "s/$/,$AWS_PROFILE,$ENV_COLOR,$filename/" | sort -d -k "8,8" -k "9,9" -k "1,1" -t "," > "$_dssh_aws_hostfile.$filename"
      return $?
    fi
  fi
  AWS_REGIONS=${ENV_AWS_REGIONS:?} EC2_INI_PATH=$ec2_ini_path python $ANSIBLE_INVENTORY/ec2.py --refresh-cache | python -c "$(echo $_dssh_host_query)" | sed "s/$/,$AWS_PROFILE,$ENV_COLOR,$filename/" | sort -d -k "8,8" -k "9,9" -k "1,1" -t "," > "$_dssh_aws_hostfile.$filename"
  return $?
}
function _dssh_okta_authenticate() {
  set -o allexport
  source $1
  set +o allexport
  AWS_OKTA_IGNORE_UPDATES=true aws-okta exec ${_dssh_aws_okta_verbose_flag} $AWS_PROFILE --disable-server -- echo -n "." 1>&2
}
function _dssh_update_inventory() {
  (
    cd $ANSIBLE_PATH || return
    set -o allexport
    source $1
    set +o allexport
    local filename=$(_dssh_get_envname "$1")
    if [ ! -f $ANSIBLE_INVENTORY/ec2.py ]; then
        return
    fi
    local i=0
    if [[ "$verbose_level" -gt 2 ]]; then
      _dssh_pverbose "Updating $ENV_NAME:l..."
    fi
    _dssh_refresh_inventory
    local result=$?
    while [ $result -ne 0 ]; do
      i=$(($i+1))
      if [ "$i" -gt 5 ]; then
        break;
      fi
      if [[ "$verbose_level" -gt 2 ]]; then
        _dssh_pverbose "Updating $ENV_NAME:l failed.  Retrying..."
      fi
      _dssh_refresh_inventory
      result=$?
    done
    if [[ "$verbose_level" -gt 2 ]]; then
      local update_status="complete"
      if [[ "$result" -ne 0 ]]; then
        update_status="failed"
      fi
      _dssh_pverbose "Updating $ENV_NAME:l $update_status"
    fi
  )
}
function _dssh_is_inventory_old() {
  local needUpdates=0
  for env_file in "${env_files[@]}"; do
    (
      set -o allexport
      source $env_file
      set +o allexport
      filename=$(_dssh_get_envname "$env_file")
      if [ -f $ANSIBLE_INVENTORY/ec2.py ]; then
        if [[ ! -f $_dssh_aws_hostfile.$filename ]] || [[ ! -s $_dssh_aws_hostfile.$filename ]]; then
          needUpdates=$((needUpdates+1))
        else
          local currentTimestamp=$(date +%s)
          local fileTimestamp=$(stat -c '%Y' "$_dssh_aws_hostfile.$filename")
          local elapsedTime=$(($currentTimestamp-$fileTimestamp))
          if [[ $elapsedTime -gt ${DSSH_HOST_UPDATE_FREQUENCY:-3600} ]]; then
              needUpdates=$((needUpdates+1))
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
function _dssh_update_inventories() {
  local force="${1:?}"
  shift 1
  local targets=( "$@" )
  if [[ "$WAS_UPDATED" == "false" || "$force" == "true" ]]; then
    _dssh_lock
    if command -v aws-okta &>/dev/null; then
      local aws_profile
      for env_file in "${env_files[@]}"; do
        aws_profile="$(grep 'AWS_PROFILE=' "$env_file" | sed 's/^AWS_PROFILE=\(.*\)$/\1/')"
        if [[ "$?" -eq 0 ]]; then
          break
        fi
      done
      if [[ "$aws_profile" != "" ]]; then
        AWS_OKTA_IGNORE_UPDATES=true aws-okta exec ${_dssh_aws_okta_verbose_flag} ${aws_profile} -- echo -n ""
      fi
      echo -n "${_dssh_gray}Updating inventories" 1>&2
      for env_file in "${env_files[@]}"; do
        _dssh_okta_authenticate $env_file
      done
      echo -n "${_dssh_nc}" 1>&2
    else
      echo -n "${_dssh_gray}Updating inventories...${_dssh_nc}" 1>&2
    fi
    if [[ "$verbose_level" -gt 2 ]]; then
      echo "" 1>&2
    fi
    for env_file in "${env_files[@]}"; do
      _dssh_update_inventory $env_file &
    done
    wait
    echo "${_dssh_gray}done${_dssh_nc}" 1>&2
    WAS_UPDATED=true
    _dssh_unlock
  fi
}
function _dssh_print_menu_hosts() {
  local term_width="$(tput cols)"
  local max_host_length="$(echo "$1" | cut -d "," -f 1 | awk '{print length}' | sort -nr | head -1)"
  max_host_length="$((max_host_length+1))"
  local lines="$(echo "$1" | awk -F ',' "{printf \"%s%s%s%3s: %s%-*s%s (%s)%s\n\", \"$_dssh_color_prefix\", \$5, \"$_dssh_color_suffix\", NR, \"$_dssh_nc\", $max_host_length-1, \$1, \"$_dssh_gray\", \$4, \"$_dssh_nc\"}")"
  local line_count="$(echo "$lines" | wc -l)"
  if [[ "$line_count" -gt 10 ]]; then
    local longest="$(echo "$1" | awk -F ',' "{printf \"%3s: %s%-*s (%s)\n\", NR, \"$_dssh_nc\", $max_host_length-1, \$1, \$4}" | awk '{print length}' | sort -nr | head -1)"
    local column_count="$((term_width/longest))"
    echo "$lines" | rs -e -t -z -w$term_width -G3 0 $column_count 2>/dev/null
  else
    echo "$lines"
  fi
}
function _dssh_print_menu() {
  _dssh_print_menu_hosts "$1"
  echo -e "  ${_dssh_bold_white}R${_dssh_nc}: Refresh"
  echo -e "  ${_dssh_bold_white}Q${_dssh_nc}: Quit"
  echo "" 1>&2
}
function _dssh_resolve_target_full() {
  local targets=("$@")
  local lookup_attempt_count=0
  local filtered_hosts=""
  while true; do
    if test -z "$(find $_dssh_aws_hostfile_dir -maxdepth 1 -name "$_dssh_aws_hostfile_prefix.*" -print -quit)"; then
      _dssh_update_inventories false "${targets[@]}"
    else
      local needs_update="false"
      for env in "${envs[@]}"; do
        if test -z "$(find $_dssh_aws_hostfile_dir -maxdepth 1 -name "$_dssh_aws_hostfile_prefix.*_$env" -print -quit)"; then
          needs_update="true"
          break
        fi
      done
      if [[ "$needs_update" == "true" ]]; then
        _dssh_update_inventories false "${targets[@]}"
      fi
    fi
    for hostsfile in $_dssh_aws_hostfile.*; do
      local filtered_hosts_partial=$(\cat $hostsfile)
      for target in "${targets[@]}"; do
        local filtered_hosts_target_partial=""
        for target_part in ${(@s/,/)target}; do
          local grep_command=( 'grep' '-h' )
          if [[ ${target_part:0:1} == "%" ]]; then
            grep_command+=( '-v' )
            target_part="${target_part:1}"
          fi
          grep_command+=( '--' "$target_part" )
          local filtered_hosts_target_partial_result=""
          filtered_hosts_target_partial_result=$(echo "$filtered_hosts_partial" | ${grep_command[@]} | sort -u -d -k "8,8" -k "9,9" -k "1,1" -t ",")
          if [[ ${#filtered_hosts_target_partial_result} -gt 0 ]]; then
            if [[ ${#filtered_hosts_target_partial} -gt 0 ]]; then
              filtered_hosts_target_partial="$filtered_hosts_target_partial\n"
            fi
            filtered_hosts_target_partial="$filtered_hosts_target_partial$filtered_hosts_target_partial_result"
          fi
        done
        filtered_hosts_partial="$filtered_hosts_target_partial"
        if [[ ${#filtered_hosts_partial} -le 0 ]]; then
          break;
        fi
      done
      if [[ ${#filtered_hosts_partial} -gt 0 ]]; then
        if [[ ${#filtered_hosts} -gt 0 ]]; then
          filtered_hosts="$filtered_hosts\n"
        fi
        filtered_hosts="$filtered_hosts$filtered_hosts_partial"
      fi
    done
    if [[ ${#filtered_hosts} -le 0 && $lookup_attempt_count -eq 0 ]]; then
      lookup_attempt_count=$(($lookup_attempt_count+1))
      _dssh_update_inventories false "${targets[@]}"
    else
      break
    fi
  done
  echo "$filtered_hosts" | sort -u -d -k "11,11" -k "8,8" -k "9,9" -k "1,1" -t "," | sort -d -k "13,13" -k "8,8" -k "9,9" -k "1,1" -t ","
  if [[ "$WAS_UPDATED" == true ]]; then
    return 1
  else
    return 0
  fi
}
function _dssh_resolve_target() {
  local result
  local filtered_hosts
  filtered_hosts="$(_dssh_resolve_target_full "$@")"
  result="$?"
  echo "$filtered_hosts" | cut -d "," -f 1,4,6,9,12
  return $result
}
function _dssh_prompt_server() {
  local count=$(echo "$info" | wc -l)

  if [[ $count -gt 1 ]]; then
    while
      local refreshMenu=0
      _dssh_print_menu $info

      while true; do
        echo -n "Which server [#]: " 1>&2
        read position

        if [[ "$position" = "Q" ]] || [[ "$position" = "q" ]]; then
          return -1
        elif [[ "$position" = "R" ]] || [[ "$position" = "r" ]]; then
          _dssh_update_inventories true "${tags[@]}"
          info="$(_dssh_resolve_target "${tags[@]}")"
          if [[ ${#info} -le 0 ]]; then
            _dssh_pwarn "Host '$target' not found in inventory.  Attempting to connect anyway..."
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
      count=$(echo "$info" | wc -l)
      continue
    done
  fi
}
function _dssh_add_ssh_option() {
  local ssh_option_key_regex=""
  local ssh_option_option_regex="^-o .+=.+$"
  local ssh_option_arg_regex="^-[a-zA-Z] .+$"
  if [[ "$1" =~ $ssh_option_option_regex ]]; then
    ssh_option_key_regex="^${1%%=*}.+$"
  elif [[ "$1" =~ $ssh_option_arg_regex ]]; then
    ssh_option_key_regex="^${1%% *} .*$"
  else
    ssh_option_key_regex="^${1%% *}$"
  fi
  local updated_ssh_option=false
  for ((i = 1; i <= ${#ssh_options[@]}; ++i)); do
    if [[ "${ssh_options[$i]}" =~ $ssh_option_key_regex ]]; then
      ssh_options[$i]="$1"
      updated_ssh_option=true
      break
    fi
  done
  if [[ "$updated_ssh_option" == "false" ]]; then
    ssh_options+=( "$1" )
  fi
}
function _dssh_parse_common_parameters() {
  local shift_count=1
  case "$1" in
    -r | --refresh)
      refresh_enabled=true
    ;;
    --no_refresh)
      refresh_enabled=false
    ;;
    --ip_mode=*)
      local ip_mode_temp="${1#*=}"
      ip_mode_temp="${ip_mode_temp:u}"
      case "$ip_mode_temp" in
        PUBLIC|PRIVATE|AUTO)
          ip_mode="$ip_mode_temp"
        ;;
        *)
          _dssh_perror "unsupported ip mode [$format]"
          _usage
          return $_dssh_e_noargs
        ;;
      esac
    ;;
    *)
      if [[ "$1" != "" ]]; then
        tags+=( "$1" )
      fi
    ;;
  esac
  return $shift_count
}
function _dssh_parse_priority_parameters() {
   for var in "$@"; do
    case "$var" in
      -h | --help)
        _usage
        return 1
      ;;
      -v | -vv | -vvv | -vvvv)
        local verbose_elements=${var##-}
        verbose_level=${#verbose_elements}
        if [[ $verbose_level -ge 4 ]]; then
        echo "$ZSH_VERSION"
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
          trap 'setopt xtrace' EXIT
        fi
      ;;
    esac
  done
  return 0
}
function _dssh_parse_default_parameters() {
  if [[ -n $DEFAULT_PARAMETERS ]]; then
    for var in "${DEFAULT_PARAMETERS[@]}"; do
      _parse_parameter "$var"
    done
  fi
}
function _dssh_parse_file_parameters() {
  local dssh_config_file="${DSSH_CONFIG_FILE:-$HOME/$1}"
  if [[ -f "$dssh_config_file" ]]; then
    while IFS="" read -r var || [ -n "$var" ]; do
      _parse_parameter "$var"
    done < $dssh_config_file
  fi
}
function _dssh_parse_commandline_parameters() {
  while [[ $# -gt 0 ]]; do
    local shift_count=1
    _parse_parameter $@
    shift_count="$?"
    if [[ "$shift_count" -gt $# ]]; then
      shift_count=$#
    fi
    shift $shift_count
  done
}
function _dssh_parse_parameters() {
  local filename="$1"
  shift 1
  if ! _dssh_parse_priority_parameters "$@"; then
    return 1
  fi
  [[ ${-/x} != $- ]] && trap 'setopt xtrace' EXIT
  _dssh_parse_default_parameters
  _dssh_parse_file_parameters "$filename"
  _dssh_parse_commandline_parameters "$@"

  if [[ ${#tags[@]} -eq 0 ]]; then
    return $_dssh_e_noerror
  fi

  local all_envs=()
  local all_env_types=()
  local all_env_files=()
  local env_type
  while read env_file; do
    if [[ "$env_file" =~ $_dssh_env_pattern ]]; then
      if [[ "${#match[1]}" -gt 0 ]]; then
        if grep -q 'ENV_DISABLED=0' "$env_file"; then
          all_envs+=( "${match[1]}" )
          all_env_files+=( "$env_file" )
          env_type="$(awk -F= '/^ENV_TYPE=/ {print $2}' "$env_file")"
          all_env_types+=( "${env_type:-}" )
        fi
      fi
    fi
  done <<< "$(_dssh_lsenv)"
  for tag in "${tags[@]}"; do
    for (( env_index = 1; env_index <= $#all_envs; env_index++ )); do
      local env="${all_envs[$env_index]}"
      local env_type="${all_env_types[$env_index]}"
      local env_file="${all_env_files[$env_index]}"
      for tag_part in ${(@s/,/)tag}; do
        if [[ "$env_type" == "" || "${tag_part:l}" == "${env_type:l}" || "${tag_part:l}" == "%${env_type:l}" ]]; then
          local has_env="false"
          for found_env in "${envs[@]}"; do
            if [[ "$found_env" == "$env" ]]; then
              has_env="true"
              break
            fi
          done
          if [[ "$has_env" == "false" ]]; then
            envs+=( "$env" )
            env_files+=( "$env_file" )
          fi
        fi
      done
    done
  done
  if [[ "${#envs[@]}" -eq 0 ]]; then
    envs=( "${all_envs[@]}" )
  fi
  if [[ "${#env_files[@]}" -eq 0 ]]; then
    env_files=( "${all_env_files[@]}" )
  fi
}

0=${${ZERO:-${0:#$ZSH_ARGZERO}}:-${(%):-%N}}
0=${${(M)0:#/*}:-$PWD/$0}

if [[ ${zsh_loaded_plugins[-1]} != */zsh-dssh && -z ${fpath[(r)${0:h}]} ]];then
    fpath+=( "${0:h}" )
fi

typeset -g ZSH_DSSH_DIR=${0:h}

autoload -Uz dssh
autoload -Uz pdssh
autoload -Uz dwhois
