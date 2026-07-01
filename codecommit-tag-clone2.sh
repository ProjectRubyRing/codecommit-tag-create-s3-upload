#!/usr/bin/env bash
#
# codecommit-tag-clone.sh
# =======================
# EC2 (RHEL 9.6) 上で、CodeCommit リポジトリの「指定タグ」を
#   <ベースディレクトリ>/<タグ名>
# へ clone し、そのタグへ切り替え（チェックアウト）します（S3 へのアップロードは行いません）。
#
# 統合スクリプト codecommit-tag-clone-s3-upload.sh の「clone 部分」だけを単体で使えるように
# 切り出したものです。clone 結果のディレクトリを、別途 s3-upload.sh へ渡してアップロードできます。
#
# ★世代管理（本改修ポイント）
#   - --dest は「ベースディレクトリ」として扱います。その直下に「タグ名」のディレクトリを
#     作成し、その中へ clone します（例: --dest /opt/snapshots/my-repo, --tag release-2026-06-29
#     → /opt/snapshots/my-repo/release-2026-06-29 へ clone）。
#   - 保持する世代数は既定 3（--keep で変更可）。clone 後にベース直下の世代数が上限を超えた
#     場合は、更新時刻(mtime)が最も古いディレクトリから順に、中のファイル群ごと削除します。
#   - 「世代」とみなすのは、ベース直下のディレクトリのうち .git を持つもの（本スクリプトが
#     作成した clone）に限定します。無関係なディレクトリは削除対象になりません。
#
#   例:
#     ./codecommit-tag-clone.sh --repo-name my-repo --region ap-northeast-1 \
#         --tag release-2026-06-29 --dest /opt/snapshots/my-repo
#       => /opt/snapshots/my-repo/release-2026-06-29 に clone
#     ./s3-upload.sh --src /opt/snapshots/my-repo/release-2026-06-29 \
#         --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 --exclude-git
#
# 認証について:
#   - CodeCommit へは HTTPS + AWS CLI 同梱の資格情報ヘルパ
#     （aws codecommit credential-helper）でアクセスします。git-remote-codecommit は不要です。
#   - IAM 権限 codecommit:GitPull が必要です。
#   - grc 形式（codecommit::<region>://<repo>）の URL を渡した場合も、内部で HTTPS URL に
#     変換してから clone します。
#
# 依存: bash, git, GNU find, aws (CLI v2)
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
DEST=""                     # ★ベースディレクトリ（必須）。直下に <タグ名> ディレクトリを作成
CLONE_DIR=""                # 実際の clone 先 = <DEST>/<TAG>（validate_inputs で確定）
REGION=""                   # AWS リージョン（grc URL 生成 / aws CLI に使用）
FULL_CLONE="false"          # true なら全履歴 clone（既定: shallow --depth 1）
MAX_GEN="3"                 # ★保持世代数の上限（既定 3）
DRY_RUN="false"             # true なら clone/削除を行わず、実行内容を表示

# --- 認証 / 権限（スイッチロール）関連 ---
# true なら CodeCommit 権限が無いとき、警告終了せず自動でスイッチロールする
AUTO_SWITCH_ROLE="false"
# 別チーム提供の「スイッチロール用シェル」のパス（source で呼び出す）。環境変数でも指定可
SWITCH_ROLE_SCRIPT="${SWITCH_ROLE_SCRIPT:-}"

DEBUG="${DEBUG:-false}"
export DEBUG

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} (--repo-url <url> | --repo-name <name> --region <region>) \\
    --tag <name> --dest <base-dir> [オプション]

説明:
  CodeCommit の指定タグを <base-dir>/<タグ名> へ clone し、そのタグへ切り替えます。
  （S3 へのアップロードは行いません。アップロードは s3-upload.sh を使用してください）

  世代管理:
    <base-dir> 直下にタグ名ディレクトリを作成して clone します。clone 後に世代数が
    --keep（既定 3）を超えた場合、mtime が最も古い世代からディレクトリごと削除します。
    世代とみなすのは <base-dir> 直下の .git を持つディレクトリのみです。

リポジトリ指定（いずれか必須）:
  --repo-url   <url>      clone URL（例: codecommit::ap-northeast-1://my-repo,
                          または https://git-codecommit...../my-repo）
  --repo-name  <name>     CodeCommit リポジトリ名。--region と併用し grc URL を生成

必須:
  --tag        <name>     clone/チェックアウトするタグ名（'/' を含むタグは不可）
  --dest       <base-dir> ベースディレクトリ。直下に <タグ名> ディレクトリを作成して clone

オプション:
  --region     <region>   AWS リージョン (--repo-name 使用時は必須)
  --keep       <n>        保持する世代数 (1 以上の整数, 既定: 3)
  --full-clone            全履歴を clone (既定: --depth 1 の shallow clone)
  --dry-run               clone/削除は行わず、実行内容（clone と世代削除）を表示
  --auto-switch-role      CodeCommit 権限が無い場合、警告終了せず自動でスイッチロールする
                          （既定: 警告メッセージを出して終了）
  --switch-role-script <path>
                          自動スイッチロール時に source する専用シェルのパス
                          （別チーム提供。環境変数 SWITCH_ROLE_SCRIPT でも指定可）
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

認証 / 権限について:
  - 実行開始時に AWS 認証済みか（aws sts get-caller-identity）を確認します。未認証の
    場合は「aws login --remote で認証してください」と警告して終了します。
  - 現在の IAM 権限で CodeCommit を操作できない場合:
      * 既定                : スイッチロールするよう警告して終了します。
      * --auto-switch-role  : --switch-role-script で指定した専用シェルを source して
                              自動的にスイッチロールし、再判定して続行します。

例:
  # ドライラン（clone と世代削除の内容を表示）
  ./${SCRIPT_NAME} --repo-name my-repo --region ap-northeast-1 \\
    --tag release-2026-06-29 --dest /opt/snapshots/my-repo --dry-run

  # 実行（/opt/snapshots/my-repo/release-2026-06-29 へ clone、最大 3 世代保持）
  ./${SCRIPT_NAME} --repo-url codecommit::ap-northeast-1://my-repo \\
    --tag release-2026-06-29 --dest /opt/snapshots/my-repo

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
      --dest)       DEST="${2:-}"; shift 2 ;;
      --region)     REGION="${2:-}"; shift 2 ;;
      --keep)       MAX_GEN="${2:-}"; shift 2 ;;
      --full-clone) FULL_CLONE="true"; shift 1 ;;
      --dry-run)    DRY_RUN="true"; shift 1 ;;
      --auto-switch-role)  AUTO_SWITCH_ROLE="true"; shift 1 ;;
      --switch-role-script) SWITCH_ROLE_SCRIPT="${2:-}"; shift 2 ;;
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
  [[ -n "${TAG}" ]]  || { usage; die "--tag は必須です。"; }
  [[ -n "${DEST}" ]] || { usage; die "--dest は必須です。"; }

  if [[ ! "${MAX_GEN}" =~ ^[1-9][0-9]*$ ]]; then
    die "--keep は 1 以上の整数で指定してください: '${MAX_GEN}'"
  fi

  if [[ -n "${REPO_URL}" && -n "${REPO_NAME}" ]]; then
    die "--repo-url と --repo-name は同時に指定できません。どちらか一方にしてください。"
  fi
  if [[ -z "${REPO_URL}" && -z "${REPO_NAME}" ]]; then
    usage; die "--repo-url または --repo-name のいずれかが必須です。"
  fi
  if [[ -n "${REPO_NAME}" && -z "${REGION}" ]]; then
    die "--repo-name 使用時は --region が必須です（grc URL の生成に必要）。"
  fi

  if ! git check-ref-format "refs/tags/${TAG}" >/dev/null 2>&1; then
    die "タグ名として不正です: '${TAG}'"
  fi
  # タグ名をそのまま 1 階層のディレクトリ名として使うため、'/' を含むタグは拒否
  # （'/' を許すとネストしたパスになり、世代カウントが正しく行えないため）
  if [[ "${TAG}" == */* ]]; then
    die "'/' を含むタグはディレクトリ名に使用できません: '${TAG}'（1 階層のタグ名を指定してください）"
  fi

  # ベースディレクトリ直下に <タグ名> ディレクトリを作成して clone する
  CLONE_DIR="${DEST%/}/${TAG}"

  # clone 先（= ベース/タグ名）が空でないと clone が失敗するため事前確認
  if [[ -e "${CLONE_DIR}" && -n "$(ls -A "${CLONE_DIR}" 2>/dev/null)" ]]; then
    die "clone 先が空ではありません: ${CLONE_DIR}（既に同名タグの世代が存在します）"
  fi
}

# ---------------------------------------------------------------------------
# 4b. CodeCommit 操作権限の判定（ensure_permission_or_switch から呼ばれる）
#     軽量な読み取り API で権限を確認する（0=権限あり）。
#       - リポジトリ名が分かる場合: get-repository（対象リポジトリに絞って確認）
#       - 分からない場合         : list-repositories
# ---------------------------------------------------------------------------
probe_codecommit_permission() {
  if [[ -n "${REPO_NAME}" ]]; then
    aws codecommit get-repository --repository-name "${REPO_NAME}" >/dev/null 2>&1
  else
    aws codecommit list-repositories >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------------------
# 5. 前提確認 / URL 確定
# ---------------------------------------------------------------------------
preflight() {
  require_command git

  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  # 認証チェック（未認証なら aws login --remote を促して終了）
  require_aws_authenticated

  # CodeCommit 操作権限の確認（無ければスイッチロール: 自動 or 警告終了）
  ensure_permission_or_switch \
    "CodeCommit" probe_codecommit_permission \
    "${AUTO_SWITCH_ROLE}" "${SWITCH_ROLE_SCRIPT}" "スイッチロール"

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
}

# ---------------------------------------------------------------------------
# 6. 指定タグを <DEST>/<TAG> へ clone
#    --branch にタグ名を渡すと、そのタグ(detached HEAD)で clone できる。
# ---------------------------------------------------------------------------
clone_tag() {
  local depth_args=()
  if [[ "${FULL_CLONE}" != "true" ]]; then
    depth_args=(--depth 1)
  fi

  log_info "タグ '${TAG}' を clone します（$([[ "${FULL_CLONE}" == "true" ]] && echo '全履歴' || echo 'shallow --depth 1')）..."
  log_info "  ${REPO_URL} -> ${CLONE_DIR}"

  # ベースディレクトリを用意（CLONE_DIR 自体は git clone に作らせる）
  run mkdir -p "${DEST}"

  # DRY-RUN 時は run() が表示のみ行う（clone は実行しない）
  run git -c advice.detachedHead=false \
    clone "${depth_args[@]}" --branch "${TAG}" --single-branch \
    "${REPO_URL}" "${CLONE_DIR}"
}

# ---------------------------------------------------------------------------
# 7. 断面の検証: HEAD が指定タグを指しているか
# ---------------------------------------------------------------------------
verify_checkout() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY-RUN のため検証はスキップします。"
    return 0
  fi

  local head_commit tag_commit described
  head_commit="$(git -C "${CLONE_DIR}" rev-parse HEAD)"

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
# 8. 世代管理
#    <DEST> 直下の clone 世代（.git を持つディレクトリ）を mtime 降順に並べ、
#    上限(MAX_GEN)を超える分を、古い順にディレクトリごと削除する。
# ---------------------------------------------------------------------------
enforce_retention() {
  local keep="${MAX_GEN}"
  local base="${DEST%/}"
  local -a dirs=()
  local d

  # ベース直下のディレクトリのうち .git を持つ（本スクリプトが作成した clone）ものを、
  # mtime 降順（新しい順）で収集する
  if [[ -d "${base}" ]]; then
    while IFS= read -r d; do
      [[ -n "${d}" ]] || continue
      [[ -e "${d}/.git" ]] || continue
      dirs+=("${d}")
    done < <(find "${base}" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null \
               | sort -rn | cut -f2-)
  fi

  # DRY-RUN ではまだ clone していないため、これから作成される世代を最新として補い、
  # 実行時と同じ判定結果（プレビュー）を表示する
  if [[ "${DRY_RUN}" == "true" ]]; then
    local already="false"
    if (( ${#dirs[@]} > 0 )); then
      for d in "${dirs[@]}"; do
        [[ "${d}" == "${CLONE_DIR}" ]] && already="true"
      done
    fi
    [[ "${already}" == "true" ]] || dirs=("${CLONE_DIR}" "${dirs[@]}")
  fi

  local total="${#dirs[@]}"
  log_info "=== 世代管理 ==="
  log_info "  対象ベース    : ${base}"
  log_info "  保持世代上限  : ${keep}"
  log_info "  現在の世代数  : ${total}"

  if (( total <= keep )); then
    log_info "  上限以内のため、削除は行いません。"
    return 0
  fi

  log_info "  上限を超過: 古い世代から $((total - keep)) 個を削除します。"
  local i target
  for (( i = keep; i < total; i++ )); do
    target="${dirs[i]}"
    # 安全確認: 必ず <ベース> 直下のパスのみ削除対象とする
    case "${target}" in
      "${base}"/*) : ;;
      *) log_info "  [skip] 想定外のパスのため削除しません: ${target}"; continue ;;
    esac
    log_info "  削除(古い世代): ${target}"
    run rm -rf -- "${target}"
  done
}

# ---------------------------------------------------------------------------
# 9. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight

  log_info "=== 実行内容 ==="
  log_info "  リポジトリ    : ${REPO_URL}"
  log_info "  タグ          : ${TAG}"
  log_info "  ベース        : ${DEST}"
  log_info "  clone 先      : ${CLONE_DIR}"
  log_info "  clone 方式    : $([[ "${FULL_CLONE}" == "true" ]] && echo '全履歴' || echo 'shallow(--depth 1)')"
  log_info "  保持世代上限  : ${MAX_GEN}"
  log_info "  自動スイッチロール: ${AUTO_SWITCH_ROLE}"
  [[ "${AUTO_SWITCH_ROLE}" == "true" ]] && \
    log_info "  切替用シェル  : ${SWITCH_ROLE_SCRIPT:-(未指定)}"
  log_info "  DRY-RUN       : ${DRY_RUN}"

  clone_tag
  verify_checkout
  enforce_retention

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY-RUN 完了: 上記の clone と世代削除が実行されます。"
  else
    log_success "完了: タグ '${TAG}' を ${CLONE_DIR} に clone・チェックアウトしました。"
    log_info "アップロードするには: ${SCRIPT_DIR}/s3-upload.sh --src ${CLONE_DIR} --s3-bucket <bucket> --s3-prefix <prefix> --exclude-git"
  fi
}

main "$@"