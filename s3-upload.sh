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
# --archive を付けると、アップロード元ディレクトリを zip アーカイブに固めてから
# アップロードします（--archive 無しは従来どおり aws s3 sync）。
#   * 既定の zip 名は basename(<dir>).zip。--archive-name で上書き可。
#   * zip は一時ディレクトリに作成し、s3://<bucket>/<prefix>/<zip名> へ aws s3 cp します。
#   * 一時ファイルは終了時に自動削除します。
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
# 依存: bash, aws (CLI v2), zip（--archive 使用時のみ）
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
ARCHIVE="false"             # true なら src を zip に固めてからアップロード
ARCHIVE_NAME=""             # 生成する zip のファイル名（既定: basename(src).zip）
ARCHIVE_TMPDIR=""           # zip を一時作成するディレクトリ（実行時に mktemp で確保）

# --- 認証 / 権限（スイッチバック）関連 ---
# true なら S3 権限が無いとき、警告終了せず自動でスイッチバックする
AUTO_SWITCH_BACK="false"
# 別チーム提供の「スイッチバック用シェル」のパス（source で呼び出す）。環境変数でも指定可
SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-}"

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
  --archive               src を zip アーカイブに固めてからアップロードする
                          （転送先は s3://<bucket>/<prefix>/<zip名>。既定 zip 名は basename(src).zip）
  --archive-name <name>   生成する zip のファイル名を指定（--archive と併用）
                          拡張子 .zip が無ければ自動付与します
  --region     <region>   AWS リージョン (任意)
  --exclude-git           .git/* を除外する（git clone 結果をアップロードする場合に推奨）
  --exclude    <pattern>  追加の除外パターン（sync は --exclude、archive は zip -x に渡す。複数指定可）
  --delete                S3 同期先にあってローカルに無いオブジェクトを削除 (aws s3 sync --delete)
                          （--archive 時は単一オブジェクト転送のため無視されます）
  --dry-run               S3 へは書き込まず、アップロード予定を表示 (aws s3 sync/cp --dryrun)
  -y, --yes               アップロード前の対話確認をスキップ
  --auto-switch-back      S3 権限が無い場合、警告終了せず自動でスイッチバックする
                          （既定: 警告メッセージを出して終了）
  --switch-back-script <path>
                          自動スイッチバック時に source する専用シェルのパス
                          （別チーム提供。環境変数 SWITCH_BACK_SCRIPT でも指定可）
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

認証 / 権限について:
  - 実行開始時に AWS 認証済みか（aws sts get-caller-identity）を確認します。未認証の
    場合は「aws login --remote で認証してください」と警告して終了します。
  - 現在の IAM 権限で S3 を操作できない場合（CodeCommit 用にスイッチロール中など）:
      * 既定                : スイッチバックするよう警告して終了します。
      * --auto-switch-back  : --switch-back-script で指定した専用シェルを source して
                              自動的にスイッチバックし、再判定して続行します。

例:
  # ドライラン（何がアップロードされるか確認。.git は除外）
  ./${SCRIPT_NAME} --src /opt/snapshots/my-repo-2026-06-29 \\
    --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 \\
    --exclude-git --dry-run

  # 実行（余剰削除あり）
  ./${SCRIPT_NAME} --src /opt/snapshots/my-repo-2026-06-29 \\
    --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 \\
    --exclude-git --delete --yes

  # zip アーカイブにしてからアップロード
  #   -> s3://my-artifacts/snapshots/my-repo/my-repo-2026-06-29.zip
  ./${SCRIPT_NAME} --src /opt/snapshots/my-repo-2026-06-29 \\
    --s3-bucket my-artifacts --s3-prefix snapshots/my-repo \\
    --archive --archive-name my-repo-2026-06-29.zip --exclude-git --yes

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
      --src)        SRC="${2:-}"; shift 2 ;;
      --s3-bucket)  S3_BUCKET="${2:-}"; shift 2 ;;
      --s3-prefix)  S3_PREFIX="${2:-}"; shift 2 ;;
      --archive)    ARCHIVE="true"; shift 1 ;;
      --archive-name) ARCHIVE_NAME="${2:-}"; shift 2 ;;
      --region)     REGION="${2:-}"; shift 2 ;;
      --exclude-git) EXCLUDE_GIT="true"; shift 1 ;;
      --exclude)    EXCLUDES+=("${2:-}"); shift 2 ;;
      --delete)     DELETE_EXTRA="true"; shift 1 ;;
      --dry-run)    DRY_RUN="true"; shift 1 ;;
      -y|--yes)     ASSUME_YES="true"; shift 1 ;;
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
ZIPNAME=""      # --archive 時に生成する zip のファイル名
validate_inputs() {
  [[ -n "${SRC}" ]]       || { usage; die "--src は必須です。"; }
  [[ -n "${S3_BUCKET}" ]] || { usage; die "--s3-bucket は必須です。"; }
  [[ -d "${SRC}" ]]       || die "アップロード元ディレクトリが存在しません: ${SRC}"

  # 絶対パスに正規化
  SRC="$(cd "${SRC}" && pwd)"

  # prefix の前後 / を正規化
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
      ZIPNAME="$(basename "${SRC}").zip"
    fi
    log_debug "生成する zip 名: '${ZIPNAME}'"
  fi
}

# ---------------------------------------------------------------------------
# 4b. S3 操作権限の判定（ensure_permission_or_switch から呼ばれる）
#     対象バケットへの head-bucket で確認する（0=操作可能）。
#     ※ バケット不存在/リージョン相違でも失敗するため、失敗時はスイッチバック
#       または警告終了の対象となる（切替後も失敗すれば明示的に終了する）。
# ---------------------------------------------------------------------------
probe_s3_permission() {
  aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 5. 前提確認
# ---------------------------------------------------------------------------
preflight() {
  require_command aws
  [[ "${ARCHIVE}" == "true" ]] && require_command zip

  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  # 認証チェック（未認証なら aws login --remote を促して終了）
  require_aws_authenticated

  # S3 操作権限の確認（無ければスイッチバック: 自動 or 警告終了）
  ensure_permission_or_switch \
    "S3" probe_s3_permission \
    "${AUTO_SWITCH_BACK}" "${SWITCH_BACK_SCRIPT}" "スイッチバック"

  log_debug "バケット '${S3_BUCKET}' へのアクセス確認 OK。"
}

# ---------------------------------------------------------------------------
# 5b. 一時ディレクトリの確保と後始末（--archive 用）
#     zip はここに作成し、スクリプト終了時（trap）に丸ごと削除する。
# ---------------------------------------------------------------------------
cleanup_tmpdir() {
  [[ -n "${ARCHIVE_TMPDIR}" && -d "${ARCHIVE_TMPDIR}" ]] || return 0
  rm -rf "${ARCHIVE_TMPDIR}"
  log_debug "一時ディレクトリを削除しました: ${ARCHIVE_TMPDIR}"
}

setup_tmpdir() {
  ARCHIVE_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/s3-upload-archive.XXXXXX")" \
    || die "一時ディレクトリの作成に失敗しました。"
  trap cleanup_tmpdir EXIT
  log_debug "zip 用の一時ディレクトリ: ${ARCHIVE_TMPDIR}"
}

# ---------------------------------------------------------------------------
# 5c. src を zip アーカイブに固める
#     src の内容を out_zip（絶対パス）へ再帰的に格納する。
#     --exclude-git / --exclude は zip の -x（除外パターン）に渡す。
# ---------------------------------------------------------------------------
create_archive() {
  local src_dir="${1}"
  local out_zip="${2}"

  local excludes=()
  [[ "${EXCLUDE_GIT}" == "true" ]] && excludes+=(".git/*")
  local pat
  for pat in "${EXCLUDES[@]:-}"; do
    [[ -n "${pat}" ]] && excludes+=("${pat}")
  done

  log_info "zip を作成: ${src_dir}/ -> $(basename "${out_zip}")"

  # 相対パスで格納するため src_dir へ cd してから zip する。out_zip は絶対パス。
  # -r 再帰 / -q 静音（DEBUG 時のみ冗長表示）。
  local zip_flags="-r"
  [[ "${DEBUG}" == "true" ]] || zip_flags="${zip_flags}q"

  local zip_cmd=(zip "${zip_flags}" "${out_zip}" .)
  if [[ "${#excludes[@]}" -gt 0 ]]; then
    zip_cmd+=(-x "${excludes[@]}")
  fi

  if ! ( cd "${src_dir}" && "${zip_cmd[@]}" ); then
    die "zip アーカイブの作成に失敗しました（${src_dir} -> ${out_zip}）。"
  fi
}

# ---------------------------------------------------------------------------
# 6. S3 へアップロード
#    通常   : aws s3 sync でディレクトリを同期
#    archive: src を zip に固めて aws s3 cp で単一オブジェクトを転送
#    dry-run 時は aws CLI のネイティブ --dryrun で予定のみ表示。
# ---------------------------------------------------------------------------
DEST=""     # 表示用 S3 URL（prefix まで。archive 時は末尾に zip 名が付く）
upload_to_s3() {
  DEST="s3://${S3_BUCKET}"
  [[ -n "${S3_PREFIX}" ]] && DEST="${DEST}/${S3_PREFIX}"

  # --- アーカイブモード: zip 化して aws s3 cp ---
  if [[ "${ARCHIVE}" == "true" ]]; then
    [[ "${DELETE_EXTRA}" == "true" ]] && \
      log_warn "  --archive 指定のため --delete は無視されます（単一オブジェクト転送）。"

    setup_tmpdir
    local out_zip="${ARCHIVE_TMPDIR}/${ZIPNAME}"
    create_archive "${SRC}" "${out_zip}"

    local obj="${DEST}/${ZIPNAME}"
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

  # 表示用の最終転送先（archive 時は zip 名まで含める）
  local shown_dest="${dest}/"
  [[ "${ARCHIVE}" == "true" ]] && shown_dest="${dest}/${ZIPNAME}"

  log_info "=== 実行内容 ==="
  log_info "  アップロード元: ${SRC}/"
  log_info "  アップロード先: ${shown_dest}"
  log_info "  アーカイブ  : ${ARCHIVE}$([[ "${ARCHIVE}" == "true" ]] && printf ' (zip: %s)' "${ZIPNAME}")"
  log_info "  .git 除外   : ${EXCLUDE_GIT}"
  log_info "  --delete    : ${DELETE_EXTRA}$([[ "${ARCHIVE}" == "true" && "${DELETE_EXTRA}" == "true" ]] && printf ' (archive時は無視)')"
  log_info "  自動スイッチバック: ${AUTO_SWITCH_BACK}"
  [[ "${AUTO_SWITCH_BACK}" == "true" ]] && \
    log_info "  切替用シェル: ${SWITCH_BACK_SCRIPT:-(未指定)}"
  log_info "  DRY-RUN     : ${DRY_RUN}"

  if [[ "${DRY_RUN}" != "true" && "${ASSUME_YES}" != "true" ]]; then
    if [[ -t 0 ]]; then
      if ! confirm "${SRC}/ の内容を ${shown_dest} へアップロードしますか?"; then
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
    log_success "完了: ${SRC}/ を ${shown_dest} へアップロードしました。"
  fi
}

main "$@"
