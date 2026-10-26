#!/usr/bin/env bash
# apkfind.sh —— 按关键字搜索安卓手机上已安装的 APK，并可选把 APK 拉到本地
#
# 用法:
#   ./apkfind.sh <关键字>             # 模糊搜索：包名「包含」关键字（不区分大小写）
#   ./apkfind.sh -e <包名>            # 精确匹配：只认包名完全等于它的那一个
#   ./apkfind.sh -p <关键字>          # 拉取 APK 到 ./apks/；多结果时按序号挑，不会全下
#   ./apkfind.sh -i <关键字>          # 额外显示版本 / 安装时间 / 全部分片(split)路径
#   ./apkfind.sh -3 <关键字>          # 只搜第三方应用（默认全部）
#   ./apkfind.sh -s <关键字>          # 只搜系统应用
#   ./apkfind.sh -a                   # 列出全部（不给关键字）
#   ./apkfind.sh -S <序列号> <关键字>  # 多设备时指定设备
#   ./apkfind.sh -y                   # 多结果时不询问，直接全部拉取
#   ./apkfind.sh -o <目录>            # 指定输出目录（默认 ./apks）
#
# 示例: ./apkfind.sh -p -e com.tencent.mm      ./apkfind.sh -i -3 tencent

set -uo pipefail

ADB="${ADB:-$(cd "$(dirname "$0")" && pwd)/adb}"
OUT_DIR="${OUT_DIR:-./apks}"

FILTER=""
EXACT=0
PULL=0
YES=0
INFO=0
ALL=0
SERIAL="${ANDROID_SERIAL:-}"
KEYWORDS=()

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }
die()   { echo "✗ $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--pull)   PULL=1 ;;
    -e|--exact)  EXACT=1 ;;
    -y|--yes)    YES=1 ;;
    -i|--info)   INFO=1 ;;
    -3)          FILTER="-3" ;;
    -s)          FILTER="-s" ;;
    -a|--all)    ALL=1 ;;
    -S|--serial) shift; [ $# -gt 0 ] || die "-S 需要跟设备序列号"; SERIAL="$1" ;;
    -o|--out)    shift; [ $# -gt 0 ] || die "-o 需要跟输出目录";   OUT_DIR="$1" ;;
    -h|--help)   usage ;;
    -*)          die "未知参数: $1（用 -h 看用法）" ;;
    *)           KEYWORDS[${#KEYWORDS[@]}]="$1" ;;
  esac
  shift
done

[ -x "$ADB" ] || die "找不到 adb: $ADB"

adb_cmd() { "$ADB" ${SERIAL:+-s "$SERIAL"} "$@"; }

# ---------- 小工具 ----------
human() {
  awk -v b="${1:-0}" 'BEGIN{
    if (b >= 1073741824) printf "%.2f GB", b/1073741824
    else if (b >= 1048576) printf "%.1f MB", b/1048576
    else if (b >= 1024) printf "%.0f KB", b/1024
    else printf "%d B", b }'
}

bar() {   # $1=百分比
  _p="${1:-0}"; _w=24; _f=$((_p * _w / 100)); _i=0; _o=""
  while [ "$_i" -lt "$_w" ]; do
    # 必须写 ${_o}：bash 3.2 会把后面的 UTF-8 字节并进变量名，导致 unbound variable
    if [ "$_i" -lt "$_f" ]; then _o="${_o}█"; else _o="${_o}░"; fi
    _i=$((_i + 1))
  done
  printf '%s' "$_o"
}

TOTAL_BYTES=0

# pull_one <远端路径> <本地路径> <显示名>：带进度条、耗时、失败原因
pull_one() {
  _remote="$1"; _dest="$2"; _label="$3"
  _total=$(adb_cmd shell stat -c %s "$_remote" </dev/null 2>/dev/null | tr -d '\r')
  case "$_total" in ''|*[!0-9]*) _total=0 ;; esac
  _log=$(mktemp /tmp/apkfind_pull.XXXXXX)
  _t0=$(date +%s)

  if [ -s "$_dest" ]; then
    printf '→ %s  %s（本地已存在，覆盖）\n' "$_label" "$(human "$_total")"
  else
    printf '→ %s  %s\n' "$_label" "$(human "$_total")"
  fi

  adb_cmd pull "$_remote" "$_dest" >"$_log" 2>&1 &
  _pid=$!
  if [ "$_total" -gt 0 ] && [ -t 1 ]; then
    while kill -0 "$_pid" 2>/dev/null; do
      _cur=$(stat -f%z "$_dest" 2>/dev/null || echo 0)
      case "$_cur" in ''|*[!0-9]*) _cur=0 ;; esac
      _pct=$((_cur * 100 / _total)); [ "$_pct" -gt 100 ] && _pct=100
      printf '\r   [%s] %3d%%  %s / %s' "$(bar "$_pct")" "$_pct" "$(human "$_cur")" "$(human "$_total")"
      sleep 0.2
    done
  fi
  wait "$_pid"; _rc=$?
  if [ -t 1 ]; then printf '\r%*s\r' 80 ''; fi   # 只在终端里清进度行

  _cost=$(( $(date +%s) - _t0 ))
  if [ "$_rc" -eq 0 ]; then
    _size=$(stat -f%z "$_dest" 2>/dev/null || echo 0)
    TOTAL_BYTES=$((TOTAL_BYTES + _size))
    echo "  ✓ 完成  $(human "$_size")  耗时 ${_cost}s"
    echo "     $_dest"
    rm -f "$_log"
    return 0
  fi
  echo "  ✗ 失败（耗时 ${_cost}s）"
  sed 's/^/     /' "$_log" | tail -3
  rm -f "$_log"
  return 1
}

# ---------- 选设备 ----------
DEVS=()
while IFS= read -r line; do
  _s=$(printf '%s' "$line" | awk '{print $1}')
  _m=$(printf '%s' "$line" | sed -n 's/.*model:\([^ ]*\).*/\1/p')
  [ -n "$_s" ] && DEVS[${#DEVS[@]}]="$_s|${_m:-$_s}"
done < <(adb_cmd devices -l 2>/dev/null | awk 'NR>1 && $2=="device"')

if [ ${#DEVS[@]} -eq 0 ]; then
  die "没有可用设备。检查：手机已开『USB 调试』、数据线已连、手机上点了『允许调试』。用 '$ADB devices' 查看。"
fi

if [ ${#DEVS[@]} -gt 1 ] && [ -z "$SERIAL" ]; then
  echo "检测到 ${#DEVS[@]} 台设备："
  i=0
  while [ $i -lt ${#DEVS[@]} ]; do
    printf '  [%d] %s\n' $((i + 1)) "${DEVS[$i]#*|}"
    i=$((i + 1))
  done
  printf '选择> '
  if ! read -r -t 20 _pick; then
    echo
    echo "（20 秒无输入，默认用第 1 台；换设备请用 -S）"
  fi
  case "$_pick" in
    ''|*[!0-9]*) _pick=1 ;;
  esac
  [ "$_pick" -lt 1 ] && _pick=1
  [ "$_pick" -gt ${#DEVS[@]} ] && _pick=1
  _sel="${DEVS[$((_pick - 1))]}"
  SERIAL="${_sel%%|*}"
  echo "→ 使用 ${_sel#*|}"
fi

# ---------- 取包列表：package:/data/app/~~xx==/com.a.b-hash==/base.apk=com.a.b ----------
LIST=$(adb_cmd shell pm list packages -f $FILTER </dev/null 2>/dev/null | tr -d '\r')

if [ -z "$LIST" ]; then
  die "adb 没取到包列表（设备未授权或 shell 权限不足）。"
fi

# ---------- 关键字过滤 ----------
if [ ${#KEYWORDS[@]} -eq 0 ] && [ "$ALL" -eq 0 ]; then
  die "请给一个包名关键字，或用 -a 列出全部。例：$0 tencent"
fi
i=0
while [ $i -lt ${#KEYWORDS[@]} ]; do
  kw="${KEYWORDS[$i]}"
  if [ "$EXACT" -eq 1 ]; then
    # 精确：行尾 '=' 之后的包名必须完全等于关键字
    LIST=$(printf '%s\n' "$LIST" | awk -F= -v kw="$kw" 'tolower($NF)==tolower(kw)')
  else
    LIST=$(printf '%s\n' "$LIST" | grep -iF -- "$kw" || true)
  fi
  i=$((i + 1))
done

# 多用户/工作资料下可能重复，去重
LIST=$(printf '%s\n' "$LIST" | sort -u)

if [ -z "${LIST//[[:space:]]/}" ]; then
  echo "没有匹配的应用。"
  exit 1
fi

# ---------- 输出 ----------
printf '%-46s %s\n' "PACKAGE" "APK PATH"
printf '%-46s %s\n' "-------" "--------"
MATCH=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  body="${line#package:}"
  pkg="${body##*=}"
  path="${body%=*}"
  MATCH[${#MATCH[@]}]="$pkg|$path"
  printf '%-46s %s\n' "$pkg" "$path"
  if [ "$INFO" -eq 1 ]; then
    # </dev/null 必需：adb shell 会把外层循环的 stdin 吃掉，导致后续 read 提前 EOF（只输出第一个包）
    adb_cmd shell dumpsys package "$pkg" </dev/null 2>/dev/null | tr -d '\r' \
      | awk '/versionName=/ && !vs++ {print "   "$1} /firstInstallTime=/ && !f++ && $0 !~ /1970-01-01/ {print "   "$1}'
    # 分包(split APK / App Bundle)会返回多行：base.apk + split_*.apk
    SP=$(adb_cmd shell pm path "$pkg" </dev/null 2>/dev/null | tr -d '\r' | sed 's/^package://')
    cnt=$(printf '%s\n' "$SP" | grep -c '.' )
    printf '   分片: %s 个%s\n' "$cnt" "$([ "$cnt" -gt 1 ] && echo '（分包应用，需 install-multiple 回装）' || echo '')"
    printf '%s\n' "$SP" | sed 's/^/     /'
  fi
done <<< "$LIST"

echo
echo "共 ${#MATCH[@]} 个"

# ---------- 拉取 ----------
if [ "$PULL" -eq 1 ]; then
  SEL=()
  if [ ${#MATCH[@]} -eq 1 ]; then
    SEL[0]="${MATCH[0]}"
  elif [ "$YES" -eq 1 ]; then
    SEL=("${MATCH[@]}")
  else
    echo
    echo "要拉取哪一个？序号多选请用逗号（如 1,3）；a=全部；q=取消"
    i=0
    while [ $i -lt ${#MATCH[@]} ]; do
      printf '  [%d] %s\n' $((i + 1)) "${MATCH[$i]%%|*}"
      i=$((i + 1))
    done
    printf '选择> '
    read -r pick
    pick="${pick:-q}"
    if [ "$pick" = "q" ] || [ "$pick" = "Q" ]; then echo "已取消。"; exit 0; fi
    if [ "$pick" = "a" ] || [ "$pick" = "A" ]; then
      SEL=("${MATCH[@]}")
    else
      bad=""
      OLDIFS="$IFS"; IFS=,
      for tok in $pick; do
        idx=$(printf '%s' "$tok" | tr -d ' ')
        case "$idx" in
          ''|*[!0-9]*) bad="$bad $idx" ;;
          *) if [ "$idx" -ge 1 ] 2>/dev/null && [ "$idx" -le ${#MATCH[@]} ]; then
               SEL[${#SEL[@]}]="${MATCH[$((idx - 1))]}"
             else
               bad="$bad $idx"
             fi ;;
        esac
      done
      IFS="$OLDIFS"
      if [ -n "$bad" ]; then die "无效序号:$bad"; fi
      UNIQ=(); for s in "${SEL[@]}"; do
        dup=0
        if [ ${#UNIQ[@]} -gt 0 ]; then
          for u in "${UNIQ[@]}"; do [ "$u" = "$s" ] && dup=1; done
        fi
        [ "$dup" -eq 0 ] && UNIQ[${#UNIQ[@]}]="$s"
      done
      SEL=("${UNIQ[@]}")
    fi
  fi

  mkdir -p "$OUT_DIR"
  OK=0
  FAIL=0
  T0=$(date +%s)
  for m in "${SEL[@]}"; do
    pkg="${m%%|*}"
    PATHS=$(adb_cmd shell pm path "$pkg" </dev/null 2>/dev/null | tr -d '\r' | sed 's/^package://')
    [ -z "$PATHS" ] && PATHS="${m#*|}"
    n=$(printf '%s\n' "$PATHS" | grep -c '.')
    echo
    if [ "$n" -eq 1 ]; then
      if pull_one "$PATHS" "$OUT_DIR/$pkg.apk" "$pkg"; then
        OK=$((OK + 1))
      else
        FAIL=$((FAIL + 1))
      fi
    else
      d="$OUT_DIR/$pkg"; mkdir -p "$d"
      echo "→ $pkg  分包（$n 个分片）"
      got=0
      while IFS= read -r p; do
        [ -z "$p" ] && continue
        b=$(basename "$p")
        pull_one "$p" "$d/$b" "  $b" && got=$((got + 1))
      done <<< "$PATHS"
      if [ "$got" -eq "$n" ]; then
        OK=$((OK + 1))
        files=$(cd "$d" && ls *.apk 2>/dev/null | tr '\n' ' ')
        echo "  回装: adb install-multiple -r $files"
      else
        FAIL=$((FAIL + 1))
        echo "  ⚠ 分片不全（$got/$n），回装会失败"
      fi
    fi
  done

  COST=$(( $(date +%s) - T0 ))
  echo
  echo "──────────────"
  if [ "$FAIL" -eq 0 ]; then
    echo "✓ 全部完成：${OK} 个包，共 $(human "$TOTAL_BYTES")，用时 ${COST}s"
  else
    echo "⚠ 部分完成：成功 ${OK} / 失败 ${FAIL}，共 $(human "$TOTAL_BYTES")，用时 ${COST}s"
  fi
  echo "输出目录: $(cd "$OUT_DIR" && pwd)"
fi
