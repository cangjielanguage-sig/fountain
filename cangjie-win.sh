#!/bin/bash
# 并在home目录的.bashrc末尾添加source /path/of/cangjie.sh
# Please copy this file to the location you need,
# and add 'source /path/of/cangjie.sh' to the end of ~/.bashrc

export CANGJIE_HOME=$( cd -- "$( dirname -- "${BASH_SOURCE}" )" &> /dev/null && pwd -P )
export FOUNTAIN_HOME=$CANGJIE_HOME/projects/fountain

cangjie_version(){
  echo '### 系统环境'
  echo '```bash'
  echo "$ lsb_release -a"
  lsb_release -a
  echo
  echo "$ uname -a"
  uname -a
  echo
  echo "$ cjc -v"
  cjc -v
  echo '```'
  echo '
### 问题描述
```bash
git clone https://gitcode.com/Cangjie-SIG/fountain.git
cd fountain
git checkout -t origin/feature/<CurrentIssueID> # <CurrentIssueID> 换成当前ISSUE的ID
cd fboot
export CANGJIE_STDX_DYNAMIC_PATH=/path/of/stdx/dynamic/libs
cjpm install --root ../installed
export LDLIBRARY_PATH=$LD_LIBRARY_PATH:../installed/libs/fboot
export PATH=$PATH:../installed/bin
cd ../fdemo
export POSTGRES=<URL_OF_POSTGRES>
./boot.sh build
```
'
#  echo '$ echo $CANGJIE_HOME'
#  echo $CANGJIE_HOME
#  echo
#  echo '$ echo $CANGJIE_STDX_DYNAMIC_PATH'
#  echo $CANGJIE_STDX_DYNAMIC_PATH
#  echo
#  echo '$ ls $CANGJIE_STDX_DYNAMIC_PATH'
#  ls $CANGJIE_STDX_DYNAMIC_PATH
#  echo '$ ls $CANGJIE_FOUNTAIN_LIBS'
#  ls $CANGJIE_FOUNTAIN_LIBS
  echo
}
_link_dir(){
  # Windows 上 ln -s 需要符号链接权限（管理员/开发者模式），失败时退回 junction（无需权限），再退回复制
  local target=$1 link=$2
  ln -s "$target" "$link" 2>/dev/null && return 0
  rm -rf "$link"
  if command -v cygpath >/dev/null 2>&1 && command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "New-Item -ItemType Junction -Path '$(cygpath -w "$link")' -Target '$(cygpath -w "$target")' | Out-Null" 2>/dev/null \
      && [ -e "$link" ] && return 0
  fi
  cp -r "$target" "$link" 2>/dev/null && return 0
  echo "[cj env] WARN: 无法创建 $link" >&2
  return 1
}

cangjie_env(){
  # rm -rf 对 junction 只删链接本身，不会穿透删除目标（已验证）
  rm -rf /d/docs/work/cangjie/cangjie-win-bin/sdk/current
  rm -rf /d/docs/work/cangjie/cangjie-win-bin/stdx/current
  _link_dir /d/docs/work/cangjie/cangjie-win-bin/sdk/$1/cangjie /d/docs/work/cangjie/cangjie-win-bin/sdk/current
  _link_dir /d/docs/work/cangjie/cangjie-win-bin/stdx/$2 /d/docs/work/cangjie/cangjie-win-bin/stdx/current
  export CJPM_CONFIG=/d/docs/work/cangjie/repository
  export CJPM_INSTALL=/d/docs/work/cangjie/installed
  export CANGJIE_STDX_PATH=/d/docs/work/cangjie/cangjie-win-bin/stdx/$2/windows_x86_64_cjnative
  export CANGJIE_STDX_DYNAMIC_PATH=$CANGJIE_STDX_PATH/dynamic/stdx
  export CANGJIE_STDX_STATIC_PATH=$CANGJIE_STDX_PATH/static/stdx
  export CANGJIE_STDX_PATH=$CANGJIE_STDX_DYNAMIC_PATH
  export CANGJIE_FOUNTAIN_LIBS=$CJPM_INSTALL/libs/fboot
  export CANGJIE_HOME=/d/docs/work/cangjie/cangjie-win-bin/sdk/$1/cangjie
  export LD_LIBRARY_PATH=$CANGJIE_FOUNTAIN_LIBS:$LD_LIBRARY_PATH
  export PATH=$PATH:$CJPM_INSTALL/bin:$CANGJIE_HOME/third_party/llvm/lldb/bin:$CANGJIE_FOUNTAIN_LIBS
  source $CANGJIE_HOME/envsetup.sh
}
cj(){
  echo "cj $1 $2 $3 $4 $5"
  case "$1" in
  env)
    cangjie_env $2 $3
    ;;
  version)
    cangjie_version
    ;;
  cleanUpdate)
    fboot.exe cleanUpdate
    ;;
  install)
    fboot.exe version $2 $3 $4 $5
    cd fboot
    cjpm install --root $CJPM_INSTALL
    echo -e "\a"
    cd ..
    ;;
  installed)
    cd $CJPM_INSTALL
    ;;
  study)
    cd /d/docs/work/cangjie/study
    ;;
  fountain)
    cd $FOUNTAIN_HOME
    if [[ "$2" == "install" ]]; then                                                                                 
        cj install
    elif [ -n "$2" ]; then                                                                                           
        echo 'only "install" can be followed command "cj fountain"'
    fi
    ;;
  fboot)
    cd $FOUNTAIN_HOME/fboot
    ;;
  fdemo)
    cd $FOUNTAIN_HOME/fdemo
    ;;
  cj)
    cd /d/docs/work/cangjie/$2
    ;;
  '-c')
    f=$2
    cf=${f%.cj*}
    cjc $f -o $cf && ./$cf
    ;;
  esac
}

cj env 1.3.0 1.3.0
