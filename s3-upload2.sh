#!/usr/bin/env bash
#
# s3-upload.sh
# ============
# EC2 (RHEL 9.6) 上で、1 つ以上のローカルディレクトリの内容を S3 バケットの指定先へ
# aws s3 sync でアップロードします（clone は行いません）。
#
# 統合スクリプト codecommit-tag-clone-s3-upload.sh の「アップロード部分」だけを単体で使える
# ように切り出したものです。codecommit-tag-clone.sh で clone したディレクトリを --src に
# 渡せば、タグ断面の S3 アップロードを 2 段階で実行できます。
#
# 主な機能:
#   - --src を複数回指定して、複数のローカルディレクトリを一度にアップロードできます。
#   - アップロード先は「バケット直下」「prefix(フォルダ)配下」「src ごとにサブフォルダを
#     新規作成してその配下」のいずれにも対応します。
#       * --s3-prefix <folder>     共通のベースフォルダ(prefix)配下へ
#       * --subdir-per-src         各 src を そのディレクトリ名(basename) のサブフォルダ配下へ
#       * --src <dir>=<subpath>    その src だけ任意のサブフォルダ配下へ（個別指定が最優先）
#
#   転送先の決定ルール（src ごと）:
#       s3://<bucket>/<s3-prefix>/<subpath>/
#         <subpath> は次の優先順位で決まります:
#           1) --src <dir>=<subpath> の <subpath>（明示指定）
#           2) --subdir-per-src 指定時は basename(<dir>)
#           3) 上記いずれも無ければ空（= prefix 直下、prefix も無ければバケット直下）
#
#   例:
#     # 2 つのディレクトリを それぞれ basename のサブフォルダ配下へ
#     #   /opt/a -> s3://my-artifacts/snapshots/a/
#     #   /opt/b -> s3://my-artifacts/snapshots/b/
#     ./s3-upload.sh \
#         --src /opt/a --src /opt/b \
#         --s3-bucket my-artifacts --s3-prefix snapshots \
#         --subdir-per-src --exclude-git
#
#     # src ごとに任意の転送先サブパスを割り当てる
#     #   /opt/a -> s3://my-artifacts/release/appA/v1/
#     #   /opt/b -> s3://my-artifacts/release/appB/
#     ./s3-upload.sh \
#         --src /opt/a=appA/v1 --src /opt/b=appB \
#         --s3-bucket my-artifacts --s3-prefix release --exclude-git
#
# 認証について:
#   - S3 へのアップロードには IAM 権限 s3:PutObject（--delete 時は s3:DeleteObject）、
#     および s3:ListBucket が必要です。EC2 のインスタンスプロファイル等で付与してください。
#
# 依存: bash, aws (CLI v2)
# 共通部品: common.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. 共通部品(common.sh)の読み込み
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
  echo "[${SCRIPT_NAME}][ERROR] common.sh が見つかりません: ${SCRIPT_DIR}/common.sh" >&2
  exit 1
fi
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

log_debug() {
  [[ "${DEBUG:-false}" == "true" ]] || return 0
  printf '%s[DEBUG]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

# ---------------------------------------------------------------------------
# 1. 既定値
# ---------------------------------------------------------------------------
S3_BUCKET=""                # アップロード先バケット名（必須）
S3_PREFIX=""                # 共通のベースフォルダ(prefix)。空ならバケット直下
REGION=""                   # AWS リージョン（aws CLI に使用）
EXCLUDE_GIT="false"         # true なら .git/* を除外
DELETE_EXTRA="false"        # true なら aws s3 sync --delete
DRY_RUN="false"             # true なら aws s3 sync --dryrun（実書き込みなし）
ASSUME_YES="false"          # true なら対話確認をスキップ
SUBDIR_PER_SRC="false"      # true なら各 src を basename のサブフォルダ配下へ
DEBUG="${DEBUG:-false}"
export DEBUG

# --src で受け取った生の指定（"dir" または "dir=subpath"）。順序保持・複数可。
SRC_SPECS=()
# 追加の --exclude パターン（繰り返し指定可）
EXCLUDES=()

# 検証後の並行配列（インデックスで対応）
SRC_LOCALS=()               # ローカル絶対パス
SRC_SUBPATHS=()             # prefix 配下の相対サブパス（正規化済み。空可）
SRC_DESTS=()                # 表示・実行用の最終 S3 URL（s3://bucket/...）

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --src <dir>[=<subpath>] [--src <dir2>[=<subpath2>] ...] \\
    --s3-bucket <bucket> [--s3-prefix <folder>] [オプション]

説明:
  1 つ以上のローカルディレクトリ <dir> の内容を s3://<bucket>/<s3-prefix>/<subpath>/
  へ aws s3 sync でアップロードします。

  各 src の転送先サブパス <subpath> は次の優先順位で決まります:
    1) --src <dir>=<subpath> の <subpath>（個別の明示指定が最優先）
    2) --subdir-per-src 指定時は basename(<dir>)
    3) いずれも無ければ空（prefix 直下、prefix も無ければバケット直下）

必須:
  --src        <dir>[=<subpath>]   アップロード元ローカルディレクトリ（複数回指定可）
                                   "=<subpath>" を付けると その src の転送先サブフォルダを明示
  --s3-bucket  <bucket>            アップロード先 S3 バケット名

オプション:
  --s3-prefix  <folder>   全 src 共通のベースフォルダ(prefix)。末尾 / 不要 (既定: バケット直下)
  --subdir-per-src        各 src を そのディレクトリ名(basename) のサブフォルダ配下へ配置
  --region     <region>   AWS リージョン (任意)
  --exclude-git           .git/* を除外する（git clone 結果をアップロードする場合に推奨）
  --exclude    <pattern>  追加の除外パターン（aws s3 sync --exclude に渡す。複数回指定可）
  --delete                各転送先にあってローカルに無いオブジェクトを削除 (aws s3 sync --delete)
  --dry-run               S3 へは書き込まず、アップロード予定を表示 (aws s3 sync --dryrun)
  -y, --yes               アップロード前の対話確認をスキップ
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

注意:
  - --src の "=" 区切りはローカルパスに "=" を含めない前提です（最初の "=" で分割します）。
  - 複数の src が同一の転送先を指す構成で --delete を併用すると、後続の同期が先行分を
    削除してしまうため、その場合は実行を中止します（--subdir-per-src か =<subpath> で分離）。

例:
  # ドライラン（何がアップロードされるか確認。.git 除外。src ごとにサブフォルダ）
  ./${SCRIPT_NAME} --src /opt/a --src /opt/b \\
    --s3-bucket my-artifacts --s3-prefix snapshots \\
    --subdir-per-src --exclude-git --dry-run

  # 実行（src ごとに任意サブパス、余剰削除あり）
  ./${SCRIPT_NAME} --src /opt/a=appA/v1 --src /opt/b=appB \\
    --s3-bucket my-artifacts --s3-prefix release \\
    --exclude-git --delete --yes

終了コード:
  0  成功
  1  エラー
USAGE
}

# ---------------------------------------------------------------------------
# 3. 引数パース
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "${1}" in
      --src)            SRC_SPECS+=("${2:-}"); shift 2 ;;
      --s3-bucket)      S3_BUCKET="${2:-}"; shift 2 ;;
      --s3-prefix)      S3_PREFIX="${2:-}"; shift 2 ;;
      --subdir-per-src) SUBDIR_PER_SRC="true"; shift 1 ;;
      --region)         REGION="${2:-}"; shift 2 ;;
      --exclude-git)    EXCLUDE_GIT="true"; shift 1 ;;
      --exclude)        EXCLUDES+=("${2:-}"); shift 2 ;;
      --delete)         DELETE_EXTRA="true"; shift 1 ;;
      --dry-run)        DRY_RUN="true"; shift 1 ;;
      -y|--yes)         ASSUME_YES="true"; shift 1 ;;
      --debug)          DEBUG="true"; export DEBUG; shift 1 ;;
      -h|--help)        usage; exit 0 ;;
      *)                usage; die "不明なオプションです: ${1}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 4. 補助: サブパス(prefix/サブフォルダ)の前後 / を除去して正規化
# ---------------------------------------------------------------------------
normalize_subpath() {
  local p="${1}"
  p="${p#/}"
  p="${p%/}"
  printf '%s' "${p}"
}

# ---------------------------------------------------------------------------
# 5. 入力検証 + 転送先(SRC_DESTS)の確定
# ---------------------------------------------------------------------------
validate_inputs() {
  [[ "${#SRC_SPECS[@]}" -gt 0 ]] || { usage; die "--src は必須です（複数指定可）。"; }
  [[ -n "${S3_BUCKET}" ]]        || { usage; die "--s3-bucket は必須です。"; }

  # 共通 prefix の正規化
  S3_PREFIX="$(normalize_subpath "${S3_PREFIX}")"

  local spec localpath subpath
  for spec in "${SRC_SPECS[@]}"; do
    [[ -n "${spec}" ]] || die "--src に空の値が指定されました。"

    # "dir=subpath" 形式の分解（最初の "=" で分割）
    if [[ "${spec}" == *"="* ]]; then
      localpath="${spec%%=*}"
      subpath="${spec#*=}"
    else
      localpath="${spec}"
      subpath=""
    fi

    [[ -n "${localpath}" ]] || die "--src のローカルパスが空です: '${spec}'"
    [[ -d "${localpath}" ]] || die "アップロード元ディレクトリが存在しません: ${localpath}"

    # 絶対パスに正規化
    localpath="$(cd "${localpath}" && pwd)"

    # サブパス決定（優先順位: 明示指定 > --subdir-per-src の basename > 空）
    if [[ -n "${subpath}" ]]; then
      subpath="$(normalize_subpath "${subpath}")"
      log_debug "src '${localpath}' のサブパス(明示): '${subpath}'"
    elif [[ "${SUBDIR_PER_SRC}" == "true" ]]; then
      subpath="$(basename "${localpath}")"
      log_debug "src '${localpath}' のサブパス(basename): '${subpath}'"
    else
      subpath=""
      log_debug "src '${localpath}' のサブパス: (なし)"
    fi

    SRC_LOCALS+=("${localpath}")
    SRC_SUBPATHS+=("${subpath}")
  done

  build_dests
  check_dest_collisions
}

# ---------------------------------------------------------------------------
# 6. 各 src の最終 S3 URL を組み立てる
#    s3://<bucket>[/<prefix>][/<subpath>]
# ---------------------------------------------------------------------------
build_dests() {
  SRC_DESTS=()
  local i full
  for i in "${!SRC_LOCALS[@]}"; do
    full="s3://${S3_BUCKET}"
    [[ -n "${S3_PREFIX}" ]]        && full="${full}/${S3_PREFIX}"
    [[ -n "${SRC_SUBPATHS[$i]}" ]] && full="${full}/${SRC_SUBPATHS[$i]}"
    SRC_DESTS+=("${full}")
  done
}

# ---------------------------------------------------------------------------
# 7. 転送先の衝突チェック
#    複数 src が同じ最終転送先を指す場合の取り扱い。
#    --delete 併用時は相互破壊（後続 sync が先行分を削除）するため中止する。
# ---------------------------------------------------------------------------
check_dest_collisions() {
  local i j n="${#SRC_DESTS[@]}"
  for (( i = 0; i < n; i++ )); do
    for (( j = i + 1; j < n; j++ )); do
      [[ "${SRC_DESTS[$i]}" == "${SRC_DESTS[$j]}" ]] || continue
      if [[ "${DELETE_EXTRA}" == "true" ]]; then
        die "複数の --src が同じ転送先を指しています: ${SRC_DESTS[$i]}/
  --delete 指定時は後続の同期が先行アップロード分を削除してしまうため中止します。
  --subdir-per-src か --src <dir>=<subpath> で転送先を分けてください。"
      else
        log_warn "複数の --src が同じ転送先を指しています: ${SRC_DESTS[$i]}/"
        log_warn "  同名ファイルは後勝ちで上書きされます。意図しない場合は転送先を分けてください。"
      fi
    done
  done
}

# ---------------------------------------------------------------------------
# 8. 前提確認
# ---------------------------------------------------------------------------
preflight() {
  require_command aws

  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  if ! aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1; then
    log_warn "バケット '${S3_BUCKET}' に head-bucket できませんでした。"
    log_warn "  バケット名/リージョン/IAM 権限(s3:ListBucket 等)を確認してください。続行はします。"
  else
    log_debug "バケット '${S3_BUCKET}' へのアクセス確認 OK。"
  fi
}

# ---------------------------------------------------------------------------
# 9. 1 ディレクトリ分の S3 同期（aws s3 sync）
#    dry-run 時は aws s3 sync --dryrun で予定のみ表示。
# ---------------------------------------------------------------------------
sync_one() {
  local src_dir="${1}"
  local dest="${2}"

  local sync_args=(s3 sync "${src_dir}/" "${dest}/")
  [[ "${EXCLUDE_GIT}" == "true" ]] && sync_args+=(--exclude ".git/*")
  local pat
  for pat in "${EXCLUDES[@]:-}"; do
    [[ -n "${pat}" ]] && sync_args+=(--exclude "${pat}")
  done
  [[ "${DELETE_EXTRA}" == "true" ]] && sync_args+=(--delete)
  [[ "${DRY_RUN}" == "true" ]]      && sync_args+=(--dryrun)

  log_info "S3 へアップロード: ${src_dir}/ -> ${dest}/"

  # aws CLI のネイティブ --dryrun を使うため run() は使わず直接実行する
  if ! aws "${sync_args[@]}"; then
    local perms="s3:PutObject, s3:ListBucket"
    [[ "${DELETE_EXTRA}" == "true" ]] && perms="${perms}, s3:DeleteObject"
    die "S3 への同期に失敗しました（${src_dir} -> ${dest}）。バケット/権限(${perms})を確認してください。"
  fi
}

# ---------------------------------------------------------------------------
# 10. 全 src を順にアップロード
# ---------------------------------------------------------------------------
upload_to_s3() {
  [[ "${EXCLUDE_GIT}" == "true" ]]  && log_info "  .git/* を除外します。"
  [[ "${DELETE_EXTRA}" == "true" ]] && log_warn "  --delete 有効: 各転送先にあってローカルに無いオブジェクトは削除されます。"
  [[ "${DRY_RUN}" == "true" ]]      && log_info "  （--dryrun: 実際にはアップロードしません）"

  local i
  for i in "${!SRC_LOCALS[@]}"; do
    sync_one "${SRC_LOCALS[$i]}" "${SRC_DESTS[$i]}"
  done
}

# ---------------------------------------------------------------------------
# 11. 実行計画の表示
# ---------------------------------------------------------------------------
print_plan() {
  log_info "=== 実行内容 ==="
  log_info "  バケット      : ${S3_BUCKET}"
  log_info "  ベースprefix  : ${S3_PREFIX:-(なし: バケット直下)}"
  log_info "  subdir-per-src: ${SUBDIR_PER_SRC}"
  log_info "  .git 除外     : ${EXCLUDE_GIT}"
  log_info "  --delete      : ${DELETE_EXTRA}"
  log_info "  DRY-RUN       : ${DRY_RUN}"
  log_info "  src 件数      : ${#SRC_LOCALS[@]}"
  local i
  for i in "${!SRC_LOCALS[@]}"; do
    log_info "    [$((i + 1))] ${SRC_LOCALS[$i]}/  ->  ${SRC_DESTS[$i]}/"
  done
}

# ---------------------------------------------------------------------------
# 12. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight

  print_plan

  if [[ "${DRY_RUN}" != "true" && "${ASSUME_YES}" != "true" ]]; then
    if [[ -t 0 ]]; then
      if ! confirm "上記 ${#SRC_LOCALS[@]} 件をアップロードしますか?"; then
        die "ユーザーによって中止されました。"
      fi
    else
      die "非対話環境です。実行するには -y/--yes を指定してください（確認には --dry-run）。"
    fi
  fi

  upload_to_s3

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY-RUN 完了: 上記の内容がアップロードされます。"
  else
    log_success "完了: ${#SRC_LOCALS[@]} 件のディレクトリをアップロードしました。"
  fi
}

main "$@"