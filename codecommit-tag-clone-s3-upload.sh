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
#      （--archive 指定時は作業ツリーを zip に固めて s3://<bucket>/<prefix>/<zip名> へ aws s3 cp）
#   4. （--work-dir 未指定で作った一時ディレクトリ / zip 用一時ファイルは）終了時に自動削除
#
#   => 対になる作成スクリプト: codecommit-tag-create.sh で固定した断面をそのまま配布できます。
#
# --archive について:
#   - --archive を付けると、clone した作業ツリー(.git 除外)を zip アーカイブに固めてから
#     アップロードします（--archive 無しは従来どおり aws s3 sync）。
#   - 既定の zip 名は <リポジトリ名>-<タグ>.zip（タグ中の '/' は '-' に置換）。
#     --archive-name で任意のファイル名に上書きできます（拡張子 .zip は自動付与）。
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
# 依存: bash, git, aws (CLI v2), zip（--archive 使用時のみ）
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
ARCHIVE="false"             # true なら作業ツリーを zip に固めてからアップロード
ARCHIVE_NAME=""             # 生成する zip のファイル名（既定: <リポジトリ名>-<タグ>.zip）
ARCHIVE_TMPDIR=""           # zip を一時作成するディレクトリ（実行時に mktemp で確保）

# --- 認証 / 権限（スイッチロール / スイッチバック）関連 ---
# clone(CodeCommit) 用: true なら権限が無いとき警告終了せず自動でスイッチロールする
AUTO_SWITCH_ROLE="false"
# 別チーム提供の「スイッチロール用シェル」のパス（source で呼び出す）。環境変数でも指定可
SWITCH_ROLE_SCRIPT="${SWITCH_ROLE_SCRIPT:-}"
# upload(S3) 用: true なら権限が無いとき警告終了せず自動でスイッチバックする
AUTO_SWITCH_BACK="false"
# 別チーム提供の「スイッチバック用シェル」のパス（source で呼び出す）。環境変数でも指定可
SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-}"

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
  --archive               作業ツリー(.git 除外)を zip アーカイブに固めてからアップロードする
                          （転送先は s3://<bucket>/<prefix>/<zip名>。既定 zip 名は <repo>-<tag>.zip）
  --archive-name <name>   生成する zip のファイル名を指定（--archive と併用）
                          拡張子 .zip が無ければ自動付与します
  --delete                S3 同期先にあってローカルに無いオブジェクトを削除 (aws s3 sync --delete)
                          （--archive 時は単一オブジェクト転送のため無視されます）
  --dry-run               clone はするが S3 へは書き込まず、アップロード予定を表示 (aws s3 sync/cp --dryrun)
  -y, --yes               アップロード前の対話確認をスキップ
  --auto-switch-role      CodeCommit(clone) 権限が無い場合、警告終了せず自動でスイッチロールする
                          （既定: 警告メッセージを出して終了）
  --switch-role-script <path>
                          自動スイッチロール時に source する専用シェルのパス
                          （別チーム提供。環境変数 SWITCH_ROLE_SCRIPT でも指定可）
  --auto-switch-back      S3(upload) 権限が無い場合、警告終了せず自動でスイッチバックする
                          （既定: 警告メッセージを出して終了）
  --switch-back-script <path>
                          自動スイッチバック時に source する専用シェルのパス
                          （別チーム提供。環境変数 SWITCH_BACK_SCRIPT でも指定可）
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

認証 / 権限について:
  - 実行開始時に AWS 認証済みか（aws sts get-caller-identity）を確認します。未認証の
    場合は「aws login --remote で認証してください」と警告して終了します。
  - clone 前に CodeCommit を操作できるか確認します。権限が無い場合:
      * 既定                : スイッチロールするよう警告して終了します。
      * --auto-switch-role  : --switch-role-script の専用シェルを source して自動切替します。
  - upload 前に S3 を操作できるか確認します（スイッチロール中は S3 権限が無いことがあるため）。
    権限が無い場合:
      * 既定                : スイッチバックするよう警告して終了します。
      * --auto-switch-back  : --switch-back-script の専用シェルを source して自動切替します。

例:
  # ドライラン（何がアップロードされるか確認）
  ./${SCRIPT_NAME} --repo-name my-repo --region ap-northeast-1 \\
    --tag release-2026-06-29 --s3-bucket my-artifacts --s3-prefix snapshots/my-repo --dry-run

  # 実行（非対話環境では -y）
  ./${SCRIPT_NAME} --repo-url codecommit::ap-northeast-1://my-repo \\
    --tag release-2026-06-29 --s3-bucket my-artifacts \\
    --s3-prefix snapshots/my-repo/2026-06-29 --delete --yes

  # タグ断面を zip アーカイブにしてアップロード
  #   -> s3://my-artifacts/snapshots/my-repo/my-repo-release-2026-06-29.zip
  ./${SCRIPT_NAME} --repo-name my-repo --region ap-northeast-1 \\
    --tag release-2026-06-29 --s3-bucket my-artifacts \\
    --s3-prefix snapshots/my-repo --archive --yes

注意:
  - --archive 使用時は zip コマンドが必要です。zip は一時ディレクトリに作成し、終了時に
    自動削除します。--delete は --archive 時には効果がありません（無視されます）。

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
      --archive)    ARCHIVE="true"; shift 1 ;;
      --archive-name) ARCHIVE_NAME="${2:-}"; shift 2 ;;
      --delete)     DELETE_EXTRA="true"; shift 1 ;;
      --dry-run)    DRY_RUN="true"; shift 1 ;;
      -y|--yes)     ASSUME_YES="true"; shift 1 ;;
      --auto-switch-role)   AUTO_SWITCH_ROLE="true"; shift 1 ;;
      --switch-role-script) SWITCH_ROLE_SCRIPT="${2:-}"; shift 2 ;;
      --auto-switch-back)   AUTO_SWITCH_BACK="true"; shift 1 ;;
      --switch-back-script) SWITCH_BACK_SCRIPT="${2:-}"; shift 2 ;;
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

  # --archive 関連の整合性チェックと zip 名の決定
  if [[ -n "${ARCHIVE_NAME}" ]]; then
    [[ "${ARCHIVE}" == "true" ]] || die "--archive-name は --archive と併用してください。"
    [[ "${ARCHIVE_NAME}" != */* ]] || die "--archive-name にパス区切り '/' は含められません: ${ARCHIVE_NAME}"
  fi
  if [[ "${ARCHIVE}" == "true" ]]; then
    if [[ -n "${ARCHIVE_NAME}" ]]; then
      ZIPNAME="${ARCHIVE_NAME}"
      [[ "${ZIPNAME}" == *.zip ]] || ZIPNAME="${ZIPNAME}.zip"
    else
      # 既定 zip 名: <リポジトリ名>-<タグ>.zip
      #   リポジトリ名は --repo-name、無ければ URL 末尾から導出。
      #   単一オブジェクト名にするため、タグ/リポジトリ中の '/' は '-' に置換する。
      local repo_label="${REPO_NAME}"
      [[ -n "${repo_label}" ]] || repo_label="${REPO_URL##*/}"
      local tag_label="${TAG//\//-}"
      repo_label="${repo_label//\//-}"
      ZIPNAME="${repo_label}-${tag_label}.zip"
    fi
    log_debug "生成する zip 名: '${ZIPNAME}'"
  fi
}

ZIPNAME=""      # --archive 時に生成する zip のファイル名（validate_inputs で確定）

# ---------------------------------------------------------------------------
# 4b. 操作権限の判定（ensure_permission_or_switch から呼ばれる）
#     いずれも軽量な読み取り API で権限を確認する（0=権限あり）。
#       - CodeCommit: リポジトリ名が分かれば get-repository、無ければ list-repositories
#       - S3        : 対象バケットへの head-bucket
# ---------------------------------------------------------------------------
probe_codecommit_permission() {
  if [[ -n "${REPO_NAME}" ]]; then
    aws codecommit get-repository --repository-name "${REPO_NAME}" >/dev/null 2>&1
  else
    aws codecommit list-repositories >/dev/null 2>&1
  fi
}

probe_s3_permission() {
  aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1
}

# S3 操作権限の確認（無ければスイッチバック: 自動 or 警告終了）。
# clone のあと、実アップロードの直前に呼び出す（スイッチロール中は S3 権限が
# 無いことがあるため、clone 用の権限確認とは分けて実施する）。
ensure_s3_ready() {
  ensure_permission_or_switch \
    "S3" probe_s3_permission \
    "${AUTO_SWITCH_BACK}" "${SWITCH_BACK_SCRIPT}" "スイッチバック"
  log_debug "バケット '${S3_BUCKET}' へのアクセス確認 OK。"
}

# ---------------------------------------------------------------------------
# 5. 前提確認 / URL 確定
# ---------------------------------------------------------------------------
preflight() {
  require_command git
  require_command aws
  [[ "${ARCHIVE}" == "true" ]] && require_command zip

  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  # 認証チェック（未認証なら aws login --remote を促して終了）
  require_aws_authenticated

  # clone(CodeCommit) 操作権限の確認（無ければスイッチロール: 自動 or 警告終了）
  ensure_permission_or_switch \
    "CodeCommit" probe_codecommit_permission \
    "${AUTO_SWITCH_ROLE}" "${SWITCH_ROLE_SCRIPT}" "スイッチロール"

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
  # ※ S3 の操作権限は、スイッチロール後に権限が変わり得るため、clone 後・
  #   アップロード直前に ensure_s3_ready() で確認する。
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

# 終了時に一時ディレクトリを削除（work-dir と zip 用 tmpdir の両方）
cleanup() {
  if [[ "${CLEANUP_WORK_DIR}" == "true" && -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    log_debug "一時 work-dir を削除: ${WORK_DIR}"
    rm -rf "${WORK_DIR}" || log_warn "一時ディレクトリの削除に失敗: ${WORK_DIR}"
  fi
  if [[ -n "${ARCHIVE_TMPDIR}" && -d "${ARCHIVE_TMPDIR}" ]]; then
    log_debug "zip 用一時ディレクトリを削除: ${ARCHIVE_TMPDIR}"
    rm -rf "${ARCHIVE_TMPDIR}" || log_warn "一時ディレクトリの削除に失敗: ${ARCHIVE_TMPDIR}"
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
# 9a. 作業ツリーを zip アーカイブに固める（--archive 用）
#     .git は常に除外する。zip は tmpdir に作成し、cleanup() で削除される。
# ---------------------------------------------------------------------------
create_archive() {
  local src_dir="${1}"
  local out_zip="${2}"

  ARCHIVE_TMPDIR="$(dirname "${out_zip}")"    # cleanup() 対象として記録
  log_info "zip を作成: ${src_dir}/ -> $(basename "${out_zip}")（.git は除外）"

  # 相対パスで格納するため src_dir へ cd してから zip する。out_zip は絶対パス。
  # -r 再帰 / -q 静音（DEBUG 時のみ冗長表示）。.git/* は常に除外。
  local zip_flags="-r"
  [[ "${DEBUG}" == "true" ]] || zip_flags="${zip_flags}q"

  if ! ( cd "${src_dir}" && zip "${zip_flags}" "${out_zip}" . -x ".git/*" ); then
    die "zip アーカイブの作成に失敗しました（${src_dir} -> ${out_zip}）。"
  fi
}

# ---------------------------------------------------------------------------
# 9. S3 へアップロード
#    通常   : aws s3 sync（.git は除外）
#    archive: 作業ツリーを zip に固めて aws s3 cp で単一オブジェクトを転送
#    dry-run 時は aws CLI のネイティブ --dryrun で予定のみ表示。
# ---------------------------------------------------------------------------
upload_to_s3() {
  local dest="s3://${S3_BUCKET}"
  [[ -n "${S3_PREFIX}" ]] && dest="${dest}/${S3_PREFIX}"

  # --- アーカイブモード: zip 化して aws s3 cp ---
  if [[ "${ARCHIVE}" == "true" ]]; then
    [[ "${DELETE_EXTRA}" == "true" ]] && \
      log_warn "  --archive 指定のため --delete は無視されます（単一オブジェクト転送）。"

    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cc-tag-archive.XXXXXX")" \
      || die "一時ディレクトリの作成に失敗しました。"
    local out_zip="${tmpdir}/${ZIPNAME}"
    create_archive "${CLONE_DIR}" "${out_zip}"

    local obj="${dest}/${ZIPNAME}"
    local cp_args=(s3 cp "${out_zip}" "${obj}")
    [[ "${DRY_RUN}" == "true" ]] && cp_args+=(--dryrun)

    log_info "S3 へアップロードします: ${ZIPNAME} -> ${obj}"
    [[ "${DRY_RUN}" == "true" ]] && log_info "  （--dryrun: 実際にはアップロードしません）"

    # aws CLI のネイティブ --dryrun を使うため run() は使わず直接実行する
    if ! aws "${cp_args[@]}"; then
      die "S3 へのアップロードに失敗しました（${obj}）。バケット/権限(s3:PutObject)を確認してください。"
    fi
    return 0
  fi

  # --- 通常モード: aws s3 sync ---
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

  # 表示用の最終転送先（archive 時は zip 名まで含める）
  local shown_dest="${dest}/"
  [[ "${ARCHIVE}" == "true" ]] && shown_dest="${dest}/${ZIPNAME}"

  log_info "=== 実行内容 ==="
  log_info "  リポジトリ  : ${REPO_URL}"
  log_info "  タグ        : ${TAG}"
  log_info "  アップロード先: ${shown_dest}"
  log_info "  clone 方式  : $([[ "${FULL_CLONE}" == "true" ]] && echo '全履歴' || echo 'shallow(--depth 1)')"
  log_info "  アーカイブ  : ${ARCHIVE}$([[ "${ARCHIVE}" == "true" ]] && printf ' (zip: %s)' "${ZIPNAME}")"
  log_info "  --delete    : ${DELETE_EXTRA}$([[ "${ARCHIVE}" == "true" && "${DELETE_EXTRA}" == "true" ]] && printf ' (archive時は無視)')"
  log_info "  自動スイッチロール: ${AUTO_SWITCH_ROLE}"
  [[ "${AUTO_SWITCH_ROLE}" == "true" ]] && \
    log_info "  切替用シェル(role): ${SWITCH_ROLE_SCRIPT:-(未指定)}"
  log_info "  自動スイッチバック: ${AUTO_SWITCH_BACK}"
  [[ "${AUTO_SWITCH_BACK}" == "true" ]] && \
    log_info "  切替用シェル(back): ${SWITCH_BACK_SCRIPT:-(未指定)}"
  log_info "  DRY-RUN     : ${DRY_RUN}"

  # clone と検証は read-only。実アップロード前にのみ確認を取る。
  clone_tag
  verify_checkout

  # アップロード直前に S3 操作権限を確認（無ければスイッチバック: 自動 or 警告終了）
  ensure_s3_ready

  if [[ "${DRY_RUN}" != "true" && "${ASSUME_YES}" != "true" ]]; then
    if [[ -t 0 ]]; then
      if ! confirm "このタグの内容を ${shown_dest} へアップロードしますか?"; then
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
    log_success "完了: タグ '${TAG}' の断面を ${shown_dest} へアップロードしました。"
  fi
}

main "$@"
