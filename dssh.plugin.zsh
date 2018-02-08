dssh() {
    set +m
    set -o pipefail


    AWS_HOSTFILE=$HOME/.aws-hosts
    E_NOERROR=0
    E_NOARGS=103
    E_UHOST=104
    GRAY='\033[38;5;249m'
    ORANGE='\033[38;5;160m'
    RED='\033[38;5;208m'
    BOLD_WHITE='\033[1m'
    NC='\033[0m'
    ENVS=()
    HOSTS=[]

    _pverbose() { echo -e "${GRAY}$1${NC}" 1>&2; }
    _pwarn() { echo -e "${ORANGE}$1${NC}" 1>&2; }
    _perror() { echo -e "${RED}ERROR: $1${NC}" 1>&2; }
    _lock() { dotlockfile -l -p $AWS_HOSTFILE.lock; }
    _unlock() { dotlockfile -u -p $AWS_HOSTFILE.lock; }
    _prepare_locking() { trap _unlock EXIT; }
    _usage() {
        echo
        echo "Locates and connects to AWS servers server via SSH."
        echo
        echo "Usage: dssh [options] tag"
        echo "    -r, --refresh         refresh the cached host information"
        echo "    -v, --verbose         verbose logging"
        echo "    -h, --help            display this help message"
    }
    _get_host() {
        tmp="${1%%,*}"
        host="${1%%,*}"
        echo $host
    }
    _get_color() {
        color="${1##*,}"
        echo -e "\\033[38;5;${color}m"
    }
    _lsenv() {
        ls -1 $HOME/.env/*.sh
    }
    _get_envname() {
        filename=$(basename "$1")
        filename="${filename%.*}"
        echo $filename
    }
    _refresh_inventory() {
      rm -rf "$AWS_HOSTFILE.$filename"
      python $ANSIBLE_INVENTORY/ec2.py --refresh-cache | python -c "$(echo $ANSIBLE_HOSTS_QUERY)" | sed "s/$/,$ENV_COLOR/" | sort > "$AWS_HOSTFILE.$filename"
      return $?
    }
    _update_inventory() {
        (
            cd $ANSIBLE_PATH || return
            source $1
            filename=$(_get_envname "$1")
            if [ ! -f $ANSIBLE_INVENTORY/ec2.py ]; then
                return
            fi
            i=0
            _refresh_inventory
            result=$?
            while [ $result -ne 0 ]; do
                i=$(($i+1))
                if [ "$i" -gt 5 ]; then
                    break;
                fi

                _refresh_inventory
                result=$?
            done
        )
    }
    _update_inventories() {
        _lock
        echo -n "${GRAY}Updating inventories...${NC}" 1>&2
        _lsenv | while read x; do
          _update_inventory $x &
        done
        wait
        echo "${GRAY}done${NC}" 1>&2
        _unlock
    }
    _print_menu() {
      index=1
      for line in $(echo "$1"); do
          host="$(_get_host $line)"
          color="$(_get_color $line)"
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

    params=( "$@" );
    index=1
    refresh_enabled=false
    verbose_enabled=false
    completions_enabled=false
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
            -v | --verbose)
                verbose_enabled=true
                params[$index]=()
            ;;
            --completions)
                completions_enabled=true
                params[$index]=()
            ;;
        esac
        index=$((index+1))
    done

    lastIndex=$((${#params[@]}-1))
    if [[ "$refresh_enabled" = true ]]; then
        _update_inventories
    else
        (
            needUpdates=0
            _lsenv | while read x; do
                source $x
                filename=$(_get_envname "$x")
                if [ -f $ANSIBLE_INVENTORY/ec2.py ]; then
                    if [[ ! -f $AWS_HOSTFILE.$filename ]] || [[ ! -s $AWS_HOSTFILE.$filename ]]; then
                      needUpdates=$((needUpdates+1))
                    else
                      currentTimestamp=$(date +%s)
                      fileTimestamp=$(stat -f "%m" "$AWS_HOSTFILE.$filename")
                      elapsedTime=$(($currentTimestamp-$fileTimestamp))
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

    lookup_attempt_count=0
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

    if [ -z "$info" ]; then
        _perror "Unknown host: $target"
        return $E_UHOST
    fi

    count=$(echo "$info" | wc -l)

    if [[ $count -gt 1 ]]; then
      while
          refreshMenu=0
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

    addr=`echo $info | awk -F, '{print $2}'`

    echo "" 1>&2
    _pverbose "Connecting to $addr..."
    verbose_flag="$(if [[ "$verbose_enabled" == true ]]; then echo "-v"; else echo ""; fi)"
    ssh_command=(ssh $verbose_flag -o ConnectTimeout=30 ${addr})
    ${ssh_command[@]}
    return $?
}
