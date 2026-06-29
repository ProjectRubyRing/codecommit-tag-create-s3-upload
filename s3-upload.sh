#!/usr/bin/env bash
#
# s3-upload.sh
# ============
# EC2 (RHEL 9.6) 上で、ローカルディレクトリの内容を S3 バケットの指定フォルダ(prefix)へ
# aws s3 sync でアップロードするだけのスクリプトです（clone は行いません）。
#
# 統合スクリプト codecommit-tag-clone-s3-upload.sh の「アップロード部分」だけを単体で使える
# ように切り出したものです。codecommit-tag-clone.sh で clone したディレクトリを --src に
# 渡せば、タグ断面の S3 アップロードを 2 段階で実行できます。
#
#   例:
#     ./codecommit-tag-clone.sh --repo-name my-repo --region ap-northeast-1 \
#         --tag release-2026-06-29 --dest /opt/snapshots/my-repo-2026-06-29
#     ./s3-upload.sh --src /opt/snapshots/my-repo-2026-06-29 \
#         --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 --exclude-git
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
SRC=""                      # アップロード元ローカルディレクトリ（必須）
S3_BUCKET=""                # アップロード先バケット名（必須）
S3_PREFIX=""                # アップロード先フォルダ(prefix)。空ならバケット直下
REGION=""                   # AWS リージョン（aws CLI に使用）
EXCLUDE_GIT="false"         # true なら .git/* を除外
DELETE_EXTRA="false"        # true なら aws s3 sync --delete
DRY_RUN="false"             # true なら aws s3 sync --dryrun（実書き込みなし）
ASSUME_YES="false"          # true なら対話確認をスキップ
DEBUG="${DEBUG:-false}"
export DEBUG

# 追加の --exclude パターン（繰り返し指定可）
EXCLUDES=()

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --src <dir> --s3-bucket <bucket> [--s3-prefix <folder>] [オプション]

説明:
  ローカルディレクトリ <dir> の内容を s3://<bucket>/<prefix>/ へ aws s3 sync で
  アップロードします。

必須:
  --src        <dir>      アップロード元ローカルディレクトリ
  --s3-bucket  <bucket>   アップロード先 S3 バケット名

オプション:
  --s3-prefix  <folder>   アップロード先フォルダ(prefix)。末尾の / は不要 (既定: バケット直下)
  --region     <region>   AWS リージョン (任意)
  --exclude-git           .git/* を除外する（git clone 結果をアップロードする場合に推奨）
  --exclude    <pattern>  追加の除外パターン（aws s3 sync --exclude に渡す。複数回指定可）
  --delete                S3 同期先にあってローカルに無いオブジェクトを削除 (aws s3 sync --delete)
  --dry-run               S3 へは書き込まず、アップロード予定を表示 (aws s3 sync --dryrun)
  -y, --yes               アップロード前の対話確認をスキップ
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

例:
  # ドライラン（何がアップロードされるか確認。.git は除外）
  ./${SCRIPT_NAME} --src /opt/snapshots/my-repo-2026-06-29 \\
    --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 \\
    --exclude-git --dry-run

  # 実行（余剰削除あり）
  ./${SCRIPT_NAME} --src /opt/snapshots/my-repo-2026-06-29 \\
    --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 \\
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
      --src)        SRC="${2:-}"; shift 2 ;;
      --s3-bucket)  S3_BUCKET="${2:-}"; shift 2 ;;
      --s3-prefix)  S3_PREFIX="${2:-}"; shift 2 ;;
      --region)     REGION="${2:-}"; shift 2 ;;
      --exclude-git) EXCLUDE_GIT="true"; shift 1 ;;
      --exclude)    EXCLUDES+=("${2:-}"); shift 2 ;;
      --delete)     DELETE_EXTRA="true"; shift 1 ;;
      --dry-run)    DRY_RUN="true"; shift 1 ;;
      -y|--yes)     ASSUME_YES="true"; shift 1 ;;
      --debug)      DEBUG="true"; export DEBUG; shift 1 ;;
      -h|--help)    usage; exit 0 ;;
      *)            usage; die "不明なオプションです: ${1}" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# 4. 入力検証
# ---------------------------------------------------------------------------
validate_inputs() {
  [[ -n "${SRC}" ]]       || { usage; die "--src は必須です。"; }
  [[ -n "${S3_BUCKET}" ]] || { usage; die "--s3-bucket は必須です。"; }
  [[ -d "${SRC}" ]]       || die "アップロード元ディレクトリが存在しません: ${SRC}"

  # 絶対パスに正規化
  SRC="$(cd "${SRC}" && pwd)"

  # prefix の前後 / を正規化
  S3_PREFIX="${S3_PREFIX#/}"
  S3_PREFIX="${S3_PREFIX%/}"
}

# ---------------------------------------------------------------------------
# 5. 前提確認
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
# 6. S3 へアップロード（aws s3 sync）
#    dry-run 時は aws s3 sync --dryrun で予定のみ表示。
# ---------------------------------------------------------------------------
DEST=""     # 表示用 S3 URL
upload_to_s3() {
  DEST="s3://${S3_BUCKET}"
  [[ -n "${S3_PREFIX}" ]] && DEST="${DEST}/${S3_PREFIX}"

  local sync_args=(s3 sync "${SRC}/" "${DEST}/")
  [[ "${EXCLUDE_GIT}" == "true" ]] && sync_args+=(--exclude ".git/*")
  local pat
  for pat in "${EXCLUDES[@]:-}"; do
    [[ -n "${pat}" ]] && sync_args+=(--exclude "${pat}")
  done
  [[ "${DELETE_EXTRA}" == "true" ]] && sync_args+=(--delete)
  [[ "${DRY_RUN}" == "true" ]]      && sync_args+=(--dryrun)

  log_info "S3 へアップロードします: ${SRC}/ -> ${DEST}/"
  [[ "${EXCLUDE_GIT}" == "true" ]] && log_info "  .git/* を除外します。"
  [[ "${DELETE_EXTRA}" == "true" ]] && log_warn "  --delete 有効: 同期先にあってローカルに無いオブジェクトは削除されます。"
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "  （--dryrun: 実際にはアップロードしません）"
  fi

  # aws CLI のネイティブ --dryrun を使うため run() は使わず直接実行する
  if ! aws "${sync_args[@]}"; then
    local perms="s3:PutObject, s3:ListBucket"
    [[ "${DELETE_EXTRA}" == "true" ]] && perms="${perms}, s3:DeleteObject"
    die "S3 への同期に失敗しました。バケット/権限(${perms})を確認してください。"
  fi
}

# ---------------------------------------------------------------------------
# 7. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight

  local dest="s3://${S3_BUCKET}"
  [[ -n "${S3_PREFIX}" ]] && dest="${dest}/${S3_PREFIX}"

  log_info "=== 実行内容 ==="
  log_info "  アップロード元: ${SRC}/"
  log_info "  アップロード先: ${dest}/"
  log_info "  .git 除外   : ${EXCLUDE_GIT}"
  log_info "  --delete    : ${DELETE_EXTRA}"
  log_info "  DRY-RUN     : ${DRY_RUN}"

  if [[ "${DRY_RUN}" != "true" && "${ASSUME_YES}" != "true" ]]; then
    if [[ -t 0 ]]; then
      if ! confirm "${SRC}/ の内容を ${dest}/ へアップロードしますか?"; then
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
    log_success "完了: ${SRC}/ を ${dest}/ へアップロードしました。"
  fi
}

main "$@"
