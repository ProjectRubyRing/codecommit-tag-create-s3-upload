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
#   - --archive を付けると、各 src ディレクトリを zip アーカイブに固めてから
#     アップロードします（--archive 無しは従来どおり aws s3 sync）。
#       * 既定の zip 名は basename(<dir>).zip。--archive-name で上書き可（単一 src 時のみ）。
#       * zip は一時ディレクトリに作成し、s3://.../<subpath>/<name>.zip へ aws s3 cp します。
#       * 一時ファイルは終了時に自動削除します。
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
S3_BUCKET=""                # アップロード先バケット名（必須）
S3_PREFIX=""                # 共通のベースフォルダ(prefix)。空ならバケット直下
REGION=""                   # AWS リージョン（aws CLI に使用）
EXCLUDE_GIT="false"         # true なら .git/* を除外
DELETE_EXTRA="false"        # true なら aws s3 sync --delete
DRY_RUN="false"             # true なら aws s3 sync --dryrun（実書き込みなし）
ASSUME_YES="false"          # true なら対話確認をスキップ
SUBDIR_PER_SRC="false"      # true なら各 src を basename のサブフォルダ配下へ
ARCHIVE="false"             # true なら各 src を zip に固めてからアップロード
ARCHIVE_NAME=""             # 生成する zip のファイル名（単一 src 時のみ上書き可）
ARCHIVE_TMPDIR=""           # zip を一時作成するディレクトリ（実行時に mktemp で確保）

# --- 認証 / 権限（スイッチバック）関連 ---
# true なら S3 権限が無いとき、警告終了せず自動でスイッチバックする
AUTO_SWITCH_BACK="false"
# 別チーム提供の「スイッチバック用シェル」のパス（source で呼び出す）。環境変数でも指定可
SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-}"

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
SRC_ZIPNAMES=()             # --archive 時に各 src を固める zip のファイル名

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
  --archive               各 src を zip アーカイブに固めてからアップロードする
                          （転送先は s3://.../<subpath>/<zip名>。既定 zip 名は basename(<dir>).zip）
  --archive-name <name>   生成する zip のファイル名を指定（--archive と併用。単一 src 時のみ）
                          拡張子 .zip が無ければ自動付与します
  --region     <region>   AWS リージョン (任意)
  --exclude-git           .git/* を除外する（git clone 結果をアップロードする場合に推奨）
  --exclude    <pattern>  追加の除外パターン（sync は --exclude、archive は zip -x に渡す。複数指定可）
  --delete                各転送先にあってローカルに無いオブジェクトを削除 (aws s3 sync --delete)
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

注意:
  - --src の "=" 区切りはローカルパスに "=" を含めない前提です（最初の "=" で分割します）。
  - 複数の src が同一の転送先を指す構成で --delete を併用すると、後続の同期が先行分を
    削除してしまうため、その場合は実行を中止します（--subdir-per-src か =<subpath> で分離）。
  - --archive 使用時は zip コマンドが必要です。zip は一時ディレクトリに作成し、終了時に
    自動削除します。--delete は --archive 時には効果がありません（無視されます）。
  - --archive で複数 src が同一の zip 転送先を指す場合は、後勝ちで上書きされるため中止します。

例:
  # ドライラン（何がアップロードされるか確認。.git 除外。src ごとにサブフォルダ）
  ./${SCRIPT_NAME} --src /opt/a --src /opt/b \\
    --s3-bucket my-artifacts --s3-prefix snapshots \\
    --subdir-per-src --exclude-git --dry-run

  # 実行（src ごとに任意サブパス、余剰削除あり）
  ./${SCRIPT_NAME} --src /opt/a=appA/v1 --src /opt/b=appB \\
    --s3-bucket my-artifacts --s3-prefix release \\
    --exclude-git --delete --yes

  # zip アーカイブにしてからアップロード（各 src を basename.zip に固めて配置）
  #   /opt/a -> s3://my-artifacts/release/a/a.zip
  #   /opt/b -> s3://my-artifacts/release/b/b.zip
  ./${SCRIPT_NAME} --src /opt/a --src /opt/b \\
    --s3-bucket my-artifacts --s3-prefix release \\
    --subdir-per-src --archive --exclude-git --yes

  # 単一 src を任意の zip 名でアップロード
  #   /opt/snap -> s3://my-artifacts/release/snapshot-2026-07-02.zip
  ./${SCRIPT_NAME} --src /opt/snap \\
    --s3-bucket my-artifacts --s3-prefix release \\
    --archive --archive-name snapshot-2026-07-02.zip --exclude-git --yes

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
      --archive)        ARCHIVE="true"; shift 1 ;;
      --archive-name)   ARCHIVE_NAME="${2:-}"; shift 2 ;;
      --region)         REGION="${2:-}"; shift 2 ;;
      --exclude-git)    EXCLUDE_GIT="true"; shift 1 ;;
      --exclude)        EXCLUDES+=("${2:-}"); shift 2 ;;
      --delete)         DELETE_EXTRA="true"; shift 1 ;;
      --dry-run)        DRY_RUN="true"; shift 1 ;;
      -y|--yes)         ASSUME_YES="true"; shift 1 ;;
      --auto-switch-back)   AUTO_SWITCH_BACK="true"; shift 1 ;;
      --switch-back-script) SWITCH_BACK_SCRIPT="${2:-}"; shift 2 ;;
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

  # --archive 関連の整合性チェック
  if [[ -n "${ARCHIVE_NAME}" ]]; then
    [[ "${ARCHIVE}" == "true" ]] || die "--archive-name は --archive と併用してください。"
    [[ "${#SRC_SPECS[@]}" -eq 1 ]] || \
      die "--archive-name は単一 --src のときのみ指定できます（複数指定時は既定の basename.zip）。"
    # パス区切りを含む zip 名は転送先が意図とずれるため禁止
    [[ "${ARCHIVE_NAME}" != */* ]] || die "--archive-name にパス区切り '/' は含められません: ${ARCHIVE_NAME}"
  fi

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
  [[ "${ARCHIVE}" == "true" ]] && resolve_archive_names
  check_dest_collisions
}

# ---------------------------------------------------------------------------
# 5b. --archive 時、各 src の zip ファイル名を決定する
#     優先順位: --archive-name（単一 src 時） > basename(<dir>).zip
# ---------------------------------------------------------------------------
resolve_archive_names() {
  SRC_ZIPNAMES=()
  local i name
  for i in "${!SRC_LOCALS[@]}"; do
    if [[ -n "${ARCHIVE_NAME}" ]]; then
      name="${ARCHIVE_NAME}"
      # 拡張子 .zip が無ければ付与
      [[ "${name}" == *.zip ]] || name="${name}.zip"
    else
      name="$(basename "${SRC_LOCALS[$i]}").zip"
    fi
    SRC_ZIPNAMES+=("${name}")
    log_debug "src '${SRC_LOCALS[$i]}' の zip 名: '${name}'"
  done
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
  # --archive 時は最終転送先が s3://.../<subpath>/<zip名> という単一オブジェクトになる。
  # 同一 zip オブジェクトを指す src があれば後勝ち上書きになるため中止する。
  if [[ "${ARCHIVE}" == "true" ]]; then
    local i j n="${#SRC_DESTS[@]}"
    for (( i = 0; i < n; i++ )); do
      for (( j = i + 1; j < n; j++ )); do
        [[ "${SRC_DESTS[$i]}/${SRC_ZIPNAMES[$i]}" == "${SRC_DESTS[$j]}/${SRC_ZIPNAMES[$j]}" ]] || continue
        die "複数の --src が同じ zip 転送先を指しています: ${SRC_DESTS[$i]}/${SRC_ZIPNAMES[$i]}
  後勝ちで上書きされてしまうため中止します。
  --subdir-per-src か --src <dir>=<subpath> で転送先を分けてください。"
      done
    done
    return 0
  fi

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
# 7b. S3 操作権限の判定（ensure_permission_or_switch から呼ばれる）
#     対象バケットへの head-bucket で確認する（0=操作可能）。
#     ※ バケット不存在/リージョン相違でも失敗するため、失敗時はスイッチバック
#       または警告終了の対象となる（切替後も失敗すれば明示的に終了する）。
# ---------------------------------------------------------------------------
probe_s3_permission() {
  aws s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 8. 前提確認
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
# 9b. 一時ディレクトリの確保と後始末（--archive 用）
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
# 9c. 1 ディレクトリ分の zip アーカイブ作成
#     src_dir の内容を out_zip（絶対パス）へ再帰的に格納する。
#     --exclude-git / --exclude は zip の -x（除外パターン）に渡す。
# ---------------------------------------------------------------------------
create_archive() {
  local src_dir="${1}"
  local out_zip="${2}"

  # 除外パターンの組み立て（zip の -x は sync の --exclude と書式がやや異なる点に注意）
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
# 9d. 1 ディレクトリ分の zip 化 + S3 アップロード（aws s3 cp）
#     dry-run 時は zip を作成したうえで aws s3 cp --dryrun で予定のみ表示。
# ---------------------------------------------------------------------------
archive_one() {
  local src_dir="${1}"
  local dest="${2}"
  local zipname="${3}"

  local out_zip="${ARCHIVE_TMPDIR}/${zipname}"
  create_archive "${src_dir}" "${out_zip}"

  local obj="${dest}/${zipname}"
  local cp_args=(s3 cp "${out_zip}" "${obj}")
  [[ "${DRY_RUN}" == "true" ]] && cp_args+=(--dryrun)

  log_info "S3 へアップロード: ${zipname} -> ${obj}"

  # aws CLI のネイティブ --dryrun を使うため run() は使わず直接実行する
  if ! aws "${cp_args[@]}"; then
    die "S3 へのアップロードに失敗しました（${obj}）。バケット/権限(s3:PutObject)を確認してください。"
  fi
}

# ---------------------------------------------------------------------------
# 10. 全 src を順にアップロード
# ---------------------------------------------------------------------------
upload_to_s3() {
  [[ "${EXCLUDE_GIT}" == "true" ]]  && log_info "  .git/* を除外します。"
  [[ "${DRY_RUN}" == "true" ]]      && log_info "  （--dryrun: 実際にはアップロードしません）"

  # --- アーカイブモード: 各 src を zip 化して aws s3 cp ---
  if [[ "${ARCHIVE}" == "true" ]]; then
    [[ "${DELETE_EXTRA}" == "true" ]] && \
      log_warn "  --archive 指定のため --delete は無視されます（単一オブジェクト転送）。"
    setup_tmpdir
    local i
    for i in "${!SRC_LOCALS[@]}"; do
      archive_one "${SRC_LOCALS[$i]}" "${SRC_DESTS[$i]}" "${SRC_ZIPNAMES[$i]}"
    done
    return 0
  fi

  # --- 通常モード: aws s3 sync ---
  [[ "${DELETE_EXTRA}" == "true" ]] && log_warn "  --delete 有効: 各転送先にあってローカルに無いオブジェクトは削除されます。"

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
  log_info "  アーカイブ    : ${ARCHIVE}$([[ "${ARCHIVE}" == "true" ]] && printf ' (zip)')"
  log_info "  .git 除外     : ${EXCLUDE_GIT}"
  log_info "  --delete      : ${DELETE_EXTRA}$([[ "${ARCHIVE}" == "true" && "${DELETE_EXTRA}" == "true" ]] && printf ' (archive時は無視)')"
  log_info "  自動スイッチバック: ${AUTO_SWITCH_BACK}"
  [[ "${AUTO_SWITCH_BACK}" == "true" ]] && \
    log_info "  切替用シェル  : ${SWITCH_BACK_SCRIPT:-(未指定)}"
  log_info "  DRY-RUN       : ${DRY_RUN}"
  log_info "  src 件数      : ${#SRC_LOCALS[@]}"
  local i
  for i in "${!SRC_LOCALS[@]}"; do
    if [[ "${ARCHIVE}" == "true" ]]; then
      log_info "    [$((i + 1))] ${SRC_LOCALS[$i]}/  ->  ${SRC_DESTS[$i]}/${SRC_ZIPNAMES[$i]}"
    else
      log_info "    [$((i + 1))] ${SRC_LOCALS[$i]}/  ->  ${SRC_DESTS[$i]}/"
    fi
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