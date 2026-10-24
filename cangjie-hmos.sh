#!/bin/bash
# 适配鸿蒙PC (HarmonyOS PC / OpenHarmony aarch64) 的仓颉环境脚本
# 由 cangjie.sh 改写：
#   - 路径 /mnt/d/docs/work/cangjie -> ~/Documents/cangjie
#   - SDK/stdx 下载源改为 gitcode nightly 的 ohos-aarch64 产物
#   - 去掉 lsb_release / /usr/local/openssl 等 Linux x64 依赖
# Please copy this file to the location you need,
# and add 'source /path/of/cangjie-hmos.sh' to the end of ~/.bashrc

# 仓颉安装根目录（SDK、stdx、study 等都放在这里）

alias hmrm='/usr/bin/rm'

export CANGJIE_ROOT=${CANGJIE_ROOT:-$HOME/cangjie}
export CANGJIE_HOME=$( cd -- "$( dirname -- "${BASH_SOURCE}" )" &> /dev/null && pwd -P )
export FOUNTAIN_HOME=Documents/cangjie/projects/fountain

cangjie_version(){
  echo '### 系统环境'
  echo '```bash'
  echo '$ uname -a'
  uname -a
  echo
  echo '$ cat /etc/os-release 2>/dev/null || param get const.product.software.version 2>/dev/null'
  cat /etc/os-release 2>/dev/null || param get const.product.software.version 2>/dev/null
  echo
  echo '$ cjc -v'
  cjc -v
  echo
  echo '$ echo $CANGJIE_STDX_DYNAMIC_PATH'
  echo $CANGJIE_STDX_DYNAMIC_PATH
  echo '```'
  STDX_VERSION=`echo $CANGJIE_STDX_DYNAMIC_PATH|awk -F'/' '{print $8}'`
  echo '
### 问题描述
```bash
git clone https://gitcode.com/Cangjie-TPC/fountain.git
cd fountain'
echo "git checkout -t origin/issue/<CurrentIssueID>" \# '把<CurrentIssueID>换成当前issue的ID'
echo 'cd fboot'
echo "export CANGJIE_STDX_DYNAMIC_PATH=/path/of/stdx/$STDX_VERSION/ohos_aarch64_cjnative/dynamic/stdx"
echo '
cjpm install --root ../installed
cd ../installed
CJPM_INSTALL=`pwd`
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$CJPM_INSTALL/libs/fboot
export PATH=$PATH:$CJPM_INSTALL/bin
cd ../fdemo
./boot.sh build
```
'
  echo
}

cangjie_env(){
  # $1 = SDK 版本, $2 = stdx 版本
  local bin_root=$CANGJIE_ROOT/cangjie-bin
  export CJPM_CONFIG=$bin_root/repository
  export CJPM_INSTALL=$bin_root/installed
  local stdx_dir=$bin_root/stdx/$2
  # 自动探测 stdx 解压后的平台目录（ohos 上一般是 ohos_aarch64_cjnative）
  local platform
  platform=$( ls "$stdx_dir" | grep -E 'cjnative|static' | head -1 )
  export CANGJIE_STDX_PATH=$stdx_dir/$platform
  export CANGJIE_STDX_DYNAMIC_PATH=$CANGJIE_STDX_PATH/dynamic/stdx
  export CANGJIE_STDX_STATIC_PATH=$CANGJIE_STDX_PATH/static/stdx
  export CANGJIE_FOUNTAIN_LIBS=$CJPM_INSTALL/libs/fboot
  export CANGJIE_HOME=$bin_root/sdk/$1/cangjie
  # 鸿蒙PC没有 /usr/local/openssl，若自编译了 openssl 可放开下一行
  # export LD_LIBRARY_PATH=$HOME/Documents/cangjie/openssl/lib:$CANGJIE_FOUNTAIN_LIBS:$LD_LIBRARY_PATH
  export LD_LIBRARY_PATH=$CANGJIE_FOUNTAIN_LIBS:$LD_LIBRARY_PATH
  export PATH=$PATH:$CJPM_INSTALL/bin:$CANGJIE_HOME/third_party/llvm/lldb/bin
  source $CANGJIE_HOME/envsetup.sh
  hmrm -f $bin_root/sdk/current/cangjie
  hmrm -f $bin_root/sdk/current
  ln -s $CANGJIE_HOME $bin_root/sdk/current
  hmrm -f $bin_root/stdx/current
  ln -s $CANGJIE_STDX_PATH $bin_root/stdx/current
  # 如有自定义 cjpm 配置则复制进 SDK（find 检测，兼容 zsh 的 no-match glob 报错）
  if [ -n "$(find "$HOME/.cjpm/tools/config" -maxdepth 1 -name '*.json' 2>/dev/null)" ]; then
    cp "$HOME"/.cjpm/tools/config/*.json $CANGJIE_HOME/tools/config/
  fi
  cjc -v
}

cjsetup(){
  # 在鸿蒙PC(aarch64)上下载安装仓颉 SDK 和 stdx（gitcode nightly ohos-aarch64 产物）
  local arch=aarch64
  local platform=ohos
  local sdk_version=$1
  local stdx_version=$2
  local target=${CANGJIE_HOME:-$CANGJIE_ROOT/cangjie-bin}
  local sdk_url="https://gitcode.com/Cangjie/nightly_build/releases/download/$sdk_version/cangjie-sdk-$platform-$arch-$sdk_version.tar.gz"
  local stdx_url="https://gitcode.com/Cangjie/nightly_build/releases/download/$stdx_version/cangjie-stdx-$platform-$arch-$stdx_version.1.zip"

  local path=$target/sdk/$sdk_version
  mkdir -p $path
  cd $path
  wget $sdk_url
  tar zxf *.tar.gz
  hmrm -f *.tar.gz

  path=$target/stdx/$stdx_version
  mkdir -p $path
  cd $path
  wget $stdx_url
  unzip -o -q *.zip
  hmrm -f *.zip

  cj env $sdk_version $stdx_version
}

cj(){
  echo "cj $1 $2 $3 $4 $5"
  case "$1" in
  env)
    cangjie_env $2 $3
    ;;
  version)
    cangjie_version $2
    ;;
  cleanUpdate)
    fboot cleanUpdate
    ;;
  install)
    fboot version $2 $3 $4 $5
    cd fboot
    cjpm install --root $CJPM_INSTALL
    echo -e "\a"
    cd ..
    ;;
  installed)
    cd $CJPM_INSTALL
    ;;
  publish)
    sed -E "s/fountain\([0-9]+\.[0-9]+\.[0-9]+\)/fountain($1)/g" ./f_version/src/FountainVersion.cj
    fboot pub $1
    git add .
    git commit -m"升级版本：$1"
    ;;
  setup)
    cjsetup $2 $3
    ;;
  study)
    cd /mnt/linux_share/storage/Users/currentUser/Documents/cangjie/study
    ;;
  fountain)
    cd $FOUNTAIN_HOME
    if [[ "$2" == "install" ]]; then
        cj install
    elif [ -n "$2" ]; then
	cd $2
    fi
    ;;
  fboot)
    cd $FOUNTAIN_HOME/fboot
    ;;
  fdemo)
    cd $FOUNTAIN_HOME/fdemo
    ;;
  cj)
    cd $CANGJIE_ROOT/$2
    ;;
  '-c')
    f=$2
    cf=${f%.cj*}
    cjc $f -o $cf && ./$cf
    ;;
  esac
}

# 首次安装示例（tag 换成实际 nightly 版本，可先访问
# https://gitcode.com/Cangjie/nightly_build/releases 查看）：
# cj setup 1.3.0-alpha.20261015001050 1.3.0-alpha.20261015001050
cj env 1.3.0 1.3.0
