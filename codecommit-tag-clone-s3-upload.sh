#!/usr/bin/env bash
#
# codecommit-tag-clone-s3-upload.sh
# =================================
# EC2 (RHEL 9.6) 上で、CodeCommit リポジトリの「指定タグ」を clone してそのタグへ
# 切り替え（チェックアウト）し、内容を指定した S3 バケットの指定フォルダ(prefix)へ
# アップロードするスクリプトです。
#
# 何をするか:
#   1. 一時(または指定)ディレクトリへ、指定タグを clone
#        既定では shallow clone（--depth 1）で対象タグのみ取得し高速・省容量
#   2. clone 結果が確かに「そのタグの断面」になっているか検証
#   3. .git を除いた作業ツリーを S3 (s3://<bucket>/<prefix>/) へ aws s3 sync で同期
#   4. （--work-dir 未指定で作った一時ディレクトリは）終了時に自動削除
#
#   => 対になる作成スクリプト: codecommit-tag-create.sh で固定した断面をそのまま配布できます。
#
# 認証について:
#   - CodeCommit へは HTTPS + AWS CLI 同梱の資格情報ヘルパ
#     （aws codecommit credential-helper）でアクセスします。git-remote-codecommit は不要です。
#   - clone には IAM 権限 codecommit:GitPull が必要です。
#   - S3 へのアップロードには IAM 権限 s3:PutObject（--delete 時は s3:DeleteObject）、
#     および s3:ListBucket が必要です。EC2 のインスタンスプロファイル等で付与してください。
#   - grc 形式（codecommit::<region>://<repo>）の URL を渡した場合も、内部で HTTPS URL に
#     変換してから clone します。
#
# 依存: bash, git, aws (CLI v2)
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
REPO_URL=""                 # CodeCommit の clone URL（--repo-name と排他で必須）
REPO_NAME=""                # CodeCommit リポジトリ名（--region と組み合わせ grc URL を生成）
TAG=""                      # clone/チェックアウトするタグ名（必須）
S3_BUCKET=""                # アップロード先バケット名（必須）
S3_PREFIX=""                # アップロード先フォルダ(prefix)。空ならバケット直下
REGION=""                   # AWS リージョン（grc URL 生成 / aws CLI に使用）
WORK_DIR=""                 # clone 先。未指定なら mktemp で作成し終了時に削除
FULL_CLONE="false"          # true なら全履歴 clone（既定: shallow --depth 1）
DELETE_EXTRA="false"        # true なら aws s3 sync --delete（同期先の余剰を削除）
DRY_RUN="false"             # true なら clone は行うが S3 は --dryrun（push しない）
ASSUME_YES="false"          # true なら対話確認をスキップ
DEBUG="${DEBUG:-false}"
export DEBUG

# 一時ディレクトリ後始末用（自分で作った場合のみ true）
CLEANUP_WORK_DIR="false"

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} (--repo-url <url> | --repo-name <name> --region <region>) \\
    --tag <name> --s3-bucket <bucket> [--s3-prefix <folder>] [オプション]

説明:
  CodeCommit の指定タグを clone してそのタグへ切り替え、内容を
  s3://<bucket>/<prefix>/ へ aws s3 sync でアップロードします。

リポジトリ指定（いずれか必須）:
  --repo-url   <url>      clone URL（例: codecommit::ap-northeast-1://my-repo,
                          または https://git-codecommit...../my-repo）
  --repo-name  <name>     CodeCommit リポジトリ名。--region と併用し grc URL を生成

必須:
  --tag        <name>     clone/チェックアウトするタグ名
  --s3-bucket  <bucket>   アップロード先 S3 バケット名

オプション:
  --s3-prefix  <folder>   アップロード先フォルダ(prefix)。末尾の / は不要 (既定: バケット直下)
  --region     <region>   AWS リージョン (--repo-name 使用時は必須)
  --work-dir   <path>     clone 先ディレクトリ。未指定なら一時領域に作成し終了時に削除
  --full-clone            全履歴を clone (既定: --depth 1 の shallow clone)
  --delete                S3 同期先にあってローカルに無いオブジェクトを削除 (aws s3 sync --delete)
  --dry-run               clone はするが S3 へは書き込まず、アップロード予定を表示 (aws s3 sync --dryrun)
  -y, --yes               アップロード前の対話確認をスキップ
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

例:
  # ドライラン（何がアップロードされるか確認）
  ./${SCRIPT_NAME} --repo-name my-repo --region ap-northeast-1 \\
    --tag release-2026-06-29 --s3-bucket my-artifacts --s3-prefix snapshots/my-repo --dry-run

  # 実行（非対話環境では -y）
  ./${SCRIPT_NAME} --repo-url codecommit::ap-northeast-1://my-repo \\
    --tag release-2026-06-29 --s3-bucket my-artifacts \\
    --s3-prefix snapshots/my-repo/2026-06-29 --delete --yes

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
      --repo-url)   REPO_URL="${2:-}"; shift 2 ;;
      --repo-name)  REPO_NAME="${2:-}"; shift 2 ;;
      --tag)        TAG="${2:-}"; shift 2 ;;
      --s3-bucket)  S3_BUCKET="${2:-}"; shift 2 ;;
      --s3-prefix)  S3_PREFIX="${2:-}"; shift 2 ;;
      --region)     REGION="${2:-}"; shift 2 ;;
      --work-dir)   WORK_DIR="${2:-}"; shift 2 ;;
      --full-clone) FULL_CLONE="true"; shift 1 ;;
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
  [[ -n "${TAG}" ]]       || { usage; die "--tag は必須です。"; }
  [[ -n "${S3_BUCKET}" ]] || { usage; die "--s3-bucket は必須です。"; }

  # リポジトリ指定の検証（--repo-url か --repo-name のいずれか）
  if [[ -n "${REPO_URL}" && -n "${REPO_NAME}" ]]; then
    die "--repo-url と --repo-name は同時に指定できません。どちらか一方にしてください。"
  fi
  if [[ -z "${REPO_URL}" && -z "${REPO_NAME}" ]]; then
    usage; die "--repo-url または --repo-name のいずれかが必須です。"
  fi
  if [[ -n "${REPO_NAME}" && -z "${REGION}" ]]; then
    die "--repo-name 使用時は --region が必須です（grc URL の生成に必要）。"
  fi

  # タグ名の妥当性
  if ! git check-ref-format "refs/tags/${TAG}" >/dev/null 2>&1; then
    die "タグ名として不正です: '${TAG}'"
  fi

  # prefix の前後 / を正規化（先頭/末尾の / を除去）
  S3_PREFIX="${S3_PREFIX#/}"
  S3_PREFIX="${S3_PREFIX%/}"
}

# ---------------------------------------------------------------------------
# 5. 前提確認 / URL 確定
# ---------------------------------------------------------------------------
preflight() {
  require_command git
  require_command aws

  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  # --repo-name から CodeCommit HTTPS URL を生成
  if [[ -z "${REPO_URL}" ]]; then
    REPO_URL="https://git-codecommit.${REGION}.amazonaws.com/v1/repos/${REPO_NAME}"
    log_debug "CodeCommit HTTPS URL を生成: ${REPO_URL}"
  else
    # 利用者が grc 形式（codecommit::...）を渡した場合は HTTPS URL へ変換する
    if ! REPO_URL="$(codecommit_to_https_url "${REPO_URL}" "${REGION}")"; then
      die "grc 形式 URL の HTTPS 変換にリージョンが必要です。--region を指定してください: ${REPO_URL}"
    fi
  fi
  log_info "clone URL: ${REPO_URL}"
  # HTTPS の認証は git の資格情報ヘルパ（aws codecommit credential-helper 等）が
  # 環境側で設定済みであることを前提とする。

  # S3 バケットへアクセスできるか軽く確認（権限/存在の早期検出）
  if ! aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1; then
    log_warn "バケット '${S3_BUCKET}' に head-bucket できませんでした。"
    log_warn "  バケット名/リージョン/IAM 権限(s3:ListBucket 等)を確認してください。続行はします。"
  else
    log_debug "バケット '${S3_BUCKET}' へのアクセス確認 OK。"
  fi
}

# ---------------------------------------------------------------------------
# 6. work-dir の準備
# ---------------------------------------------------------------------------
prepare_work_dir() {
  if [[ -n "${WORK_DIR}" ]]; then
    if [[ -e "${WORK_DIR}" ]]; then
      # 既存パスが空でないと clone が失敗するため事前に確認
      if [[ -n "$(ls -A "${WORK_DIR}" 2>/dev/null)" ]]; then
        die "--work-dir が空ではありません: ${WORK_DIR}（空のディレクトリか未作成パスを指定してください）"
      fi
    else
      run mkdir -p "${WORK_DIR}"
    fi
    WORK_DIR="$(cd "${WORK_DIR}" 2>/dev/null && pwd || echo "${WORK_DIR}")"
  else
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cc-tag-clone.XXXXXX")"
    CLEANUP_WORK_DIR="true"
    log_debug "一時 work-dir を作成: ${WORK_DIR}"
  fi
  log_info "clone 先: ${WORK_DIR}"
}

# 終了時に一時ディレクトリを削除
cleanup() {
  if [[ "${CLEANUP_WORK_DIR}" == "true" && -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    log_debug "一時 work-dir を削除: ${WORK_DIR}"
    rm -rf "${WORK_DIR}" || log_warn "一時ディレクトリの削除に失敗: ${WORK_DIR}"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 7. 指定タグを clone
#    --branch にタグ名を渡すと、そのタグ(detached HEAD)で clone できる。
#    DRY-RUN でも clone は読み取り専用操作なので実行する（S3 書き込みのみ抑止）。
# ---------------------------------------------------------------------------
CLONE_DIR=""    # 実際に clone されたディレクトリ
clone_tag() {
  CLONE_DIR="${WORK_DIR}/repo"
  local depth_args=()
  if [[ "${FULL_CLONE}" != "true" ]]; then
    depth_args=(--depth 1)
  fi

  log_info "タグ '${TAG}' を clone します（$([[ "${FULL_CLONE}" == "true" ]] && echo '全履歴' || echo 'shallow --depth 1')）..."
  # clone は read-only のため run() ではなく直接実行（dry-run でも実施）
  if ! git -c advice.detachedHead=false \
        clone "${depth_args[@]}" --branch "${TAG}" --single-branch \
        "${REPO_URL}" "${CLONE_DIR}"; then
    die "clone に失敗しました。タグ名 '${TAG}' の存在、URL、認証（git 資格情報ヘルパ / IAM codecommit:GitPull）を確認してください。"
  fi
}

# ---------------------------------------------------------------------------
# 8. 断面の検証: HEAD が指定タグを指しているか
# ---------------------------------------------------------------------------
verify_checkout() {
  local head_commit tag_commit described
  head_commit="$(git -C "${CLONE_DIR}" rev-parse HEAD)"

  # タグの指すコミット（注釈付きタグは ^{commit} で peel）
  if ! tag_commit="$(git -C "${CLONE_DIR}" rev-parse --verify --quiet "refs/tags/${TAG}^{commit}")"; then
    die "検証失敗: clone 後にタグ '${TAG}' が見つかりません。"
  fi
  if [[ "${head_commit}" != "${tag_commit}" ]]; then
    die "検証失敗: HEAD(${head_commit:0:12}) がタグ '${TAG}'(${tag_commit:0:12}) と一致しません。"
  fi

  described="$(git -C "${CLONE_DIR}" describe --tags --exact-match 2>/dev/null || echo "${TAG}")"
  log_success "検証 OK: タグ '${TAG}' (${tag_commit:0:12}) をチェックアウト済み。describe=${described}"
  log_info "  $(git -C "${CLONE_DIR}" --no-pager log -1 --format='%h %ci  %s')"
}

# ---------------------------------------------------------------------------
# 9. S3 へアップロード（aws s3 sync）
#    .git は除外。dry-run 時は aws s3 sync --dryrun で予定のみ表示。
# ---------------------------------------------------------------------------
upload_to_s3() {
  local dest="s3://${S3_BUCKET}"
  [[ -n "${S3_PREFIX}" ]] && dest="${dest}/${S3_PREFIX}"

  local sync_args=(s3 sync "${CLONE_DIR}/" "${dest}/" --exclude ".git/*")
  [[ "${DELETE_EXTRA}" == "true" ]] && sync_args+=(--delete)
  [[ "${DRY_RUN}" == "true" ]]      && sync_args+=(--dryrun)

  log_info "S3 へアップロードします: ${CLONE_DIR}/ -> ${dest}/"
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
# 10. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight
  prepare_work_dir

  local dest="s3://${S3_BUCKET}"
  [[ -n "${S3_PREFIX}" ]] && dest="${dest}/${S3_PREFIX}"

  log_info "=== 実行内容 ==="
  log_info "  リポジトリ  : ${REPO_URL}"
  log_info "  タグ        : ${TAG}"
  log_info "  アップロード先: ${dest}/"
  log_info "  clone 方式  : $([[ "${FULL_CLONE}" == "true" ]] && echo '全履歴' || echo 'shallow(--depth 1)')"
  log_info "  --delete    : ${DELETE_EXTRA}"
  log_info "  DRY-RUN     : ${DRY_RUN}"

  # clone と検証は read-only。実アップロード前にのみ確認を取る。
  clone_tag
  verify_checkout

  if [[ "${DRY_RUN}" != "true" && "${ASSUME_YES}" != "true" ]]; then
    if [[ -t 0 ]]; then
      if ! confirm "このタグの内容を ${dest}/ へアップロードしますか?"; then
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
    log_success "完了: タグ '${TAG}' の断面を ${dest}/ へアップロードしました。"
  fi
}

main "$@"
