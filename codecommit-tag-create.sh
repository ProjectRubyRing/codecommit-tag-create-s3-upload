#!/usr/bin/env bash
#
# codecommit-tag-create.sh
# ========================
# EC2 (RHEL 9.6) 上で、CodeCommit リポジトリに「Git タグ」を打って
# 特定時点の資産の断面（スナップショット）を固定するスクリプトです。
#
# 何をするか:
#   1. clone 済みのローカルリポジトリで、リモート(origin)から最新を fetch
#   2. 断面とするコミット(ref)を決定
#        --ref 指定なし -> origin/<branch> の先頭コミット（既定: origin/main）
#        --ref 指定あり -> その値（コミットハッシュ / ブランチ名 / 既存タグ等）
#   3. その時点を指す「注釈付きタグ(annotated tag)」を作成
#   4. リモート(CodeCommit)へタグを push
#
#   => 以降、このタグ名を指定すれば「その瞬間の資産」を再現・取得できます。
#      （対になる取得スクリプト: codecommit-tag-clone-s3-upload.sh）
#
# 認証について:
#   - 「すでに clone 済み」のリポジトリに対して fetch/push するため、origin の URL と
#     Git 資格情報ヘルパ（git-remote-codecommit / HTTPS+IAM 等）が設定済みであることを前提とします。
#   - grc(git-remote-codecommit) 形式の remote（codecommit::<region>://<repo>）の場合は
#     aws CLI / git-remote-codecommit が必要です。
#   - タグ push には IAM 権限 codecommit:GitPush が必要です。
#
# 依存: bash, git （grc remote の場合は aws, git-remote-codecommit）
# 共通部品: common.sh （log_info / log_success / log_warn / log_error / die / run /
#           confirm / require_command）
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

# common.sh には log_debug が無いため、DEBUG=true のときだけ stderr に出力する
# デバッグログヘルパをローカル定義する（色は common.sh の定義を流用）。
log_debug() {
  [[ "${DEBUG:-false}" == "true" ]] || return 0
  printf '%s[DEBUG]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

# ---------------------------------------------------------------------------
# 1. 既定値
# ---------------------------------------------------------------------------
REPO_DIR=""                 # clone 済みディレクトリ（必須）
TAG=""                      # 作成するタグ名（必須）
REF=""                      # 断面とするコミット/ブランチ/タグ（未指定なら origin/<branch>）
BRANCH="main"               # --ref 未指定時に断面とするブランチ
REMOTE="origin"             # リモート名
MESSAGE=""                  # 注釈付きタグのメッセージ（未指定なら既定文言を生成）
REPO_NAME=""                # （任意）CodeCommit リポジトリ名。remote URL の検証に使う
REGION=""                   # （任意）AWS リージョン。grc remote 利用時などに export する
FORCE="false"               # true の場合、既存タグを上書き（-f / --force）
DRY_RUN="false"             # true の場合は push 等を行わず、何が起きるかだけ表示
ASSUME_YES="false"          # true の場合は対話確認をスキップ
DEBUG="${DEBUG:-false}"     # true の場合 log_debug を有効化
export DEBUG

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --repo-dir <path> --tag <name> [オプション]

説明:
  clone 済みの CodeCommit リポジトリで、特定時点の断面を指す「注釈付きタグ」を
  作成し、リモート(${REMOTE})へ push します。既定では origin/${BRANCH} の先頭を
  断面とします。

必須:
  --repo-dir   <path>     clone 済みディレクトリの絶対パス
  --tag        <name>     作成するタグ名（例: release-2026-06-29 / v1.0.0）

オプション:
  --ref        <ref>      断面とするコミット/ブランチ/タグ
                          (未指定なら ${REMOTE}/<branch>)
  --branch     <name>     --ref 未指定時に断面とするブランチ (既定: ${BRANCH})
  --message    <text>     注釈付きタグのメッセージ (未指定なら自動生成)
  --remote     <name>     リモート名 (既定: ${REMOTE})
  --repo-name  <name>     CodeCommit リポジトリ名。remote URL に含まれるか検証する (任意)
  --region     <region>   AWS リージョン。AWS_DEFAULT_REGION 等として export する (任意)
  -f, --force             同名タグが既に存在する場合に上書きする (既定: 上書きしない)
  --dry-run               タグ作成/ push を行わず、実行内容を表示するだけ
  -y, --yes               push 前の対話確認をスキップする
  --debug                 デバッグログを出力する
  -h, --help              このヘルプを表示

例:
  # origin/main の現在の先頭を断面として固定（ドライラン）
  ./${SCRIPT_NAME} --repo-dir /opt/app/my-repo --tag release-2026-06-29 --dry-run

  # 実行（非対話環境では -y）
  ./${SCRIPT_NAME} --repo-dir /opt/app/my-repo --tag release-2026-06-29 \\
    --message "2026-06-29 本番リリース断面" --yes

  # 特定コミットを断面として固定
  ./${SCRIPT_NAME} --repo-dir /opt/app/my-repo --tag hotfix-base \\
    --ref 1a2b3c4 --yes

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
      --repo-dir)   REPO_DIR="${2:-}"; shift 2 ;;
      --tag)        TAG="${2:-}"; shift 2 ;;
      --ref)        REF="${2:-}"; shift 2 ;;
      --branch)     BRANCH="${2:-}"; shift 2 ;;
      --message)    MESSAGE="${2:-}"; shift 2 ;;
      --remote)     REMOTE="${2:-}"; shift 2 ;;
      --repo-name)  REPO_NAME="${2:-}"; shift 2 ;;
      --region)     REGION="${2:-}"; shift 2 ;;
      -f|--force)   FORCE="true"; shift 1 ;;
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
  [[ -n "${REPO_DIR}" ]] || { usage; die "--repo-dir は必須です。"; }
  [[ -n "${TAG}" ]]      || { usage; die "--tag は必須です。"; }
  [[ -d "${REPO_DIR}" ]] || die "指定ディレクトリが存在しません: ${REPO_DIR}"
  [[ -n "${BRANCH}" ]]   || die "--branch が空です。"
  [[ -n "${REMOTE}" ]]   || die "--remote が空です。"

  # タグ名として妥当か（git check-ref-format で検証）
  if ! git check-ref-format "refs/tags/${TAG}" >/dev/null 2>&1; then
    die "タグ名として不正です: '${TAG}'（空白や ~ ^ : ? * [ \\ 等は使えません）"
  fi

  # 絶対パスに正規化
  REPO_DIR="$(cd "${REPO_DIR}" && pwd)"
}

# ---------------------------------------------------------------------------
# 5. git ラッパ（常に対象ディレクトリで実行 / safe.directory を都度指定）
# ---------------------------------------------------------------------------
git_r() {
  git -C "${REPO_DIR}" -c "safe.directory=${REPO_DIR}" "$@"
}

# ---------------------------------------------------------------------------
# 6. 前提確認 / リポジトリ確認
# ---------------------------------------------------------------------------
preflight() {
  require_command git

  if [[ -n "${REGION}" ]]; then
    export AWS_DEFAULT_REGION="${REGION}"
    export AWS_REGION="${REGION}"
    log_debug "AWS リージョンを設定: ${REGION}"
  fi

  if ! git_r rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "Git の作業ツリーではありません: ${REPO_DIR}"
  fi

  local toplevel
  toplevel="$(git_r rev-parse --show-toplevel)"
  if [[ "${toplevel}" != "${REPO_DIR}" ]]; then
    log_warn "指定ディレクトリは Git のトップレベルではありません。トップレベルを対象にします。"
    log_warn "  指定        : ${REPO_DIR}"
    log_warn "  トップレベル: ${toplevel}"
    REPO_DIR="${toplevel}"
  fi
  log_info "対象リポジトリ: ${REPO_DIR}"

  if ! git_r remote get-url "${REMOTE}" >/dev/null 2>&1; then
    die "リモート '${REMOTE}' が設定されていません。git remote -v で確認してください。"
  fi
  local remote_url
  remote_url="$(git_r remote get-url "${REMOTE}")"
  log_info "リモート ${REMOTE}: ${remote_url}"

  if [[ -n "${REPO_NAME}" ]]; then
    if [[ "${remote_url}" != *"${REPO_NAME}"* ]]; then
      die "リモート URL に指定リポジトリ名 '${REPO_NAME}' が含まれていません。URL: ${remote_url}"
    fi
    log_debug "リポジトリ名の検証 OK: '${REPO_NAME}' は remote URL に含まれています。"
  fi

  if [[ "${remote_url}" == codecommit::* ]]; then
    require_command aws
    require_command git-remote-codecommit
    log_debug "grc 形式の remote を検出しました（aws / git-remote-codecommit 確認済み）。"
  fi
}

# ---------------------------------------------------------------------------
# 7. リモート最新を取得（タグ衝突検出のためタグも取得）
# ---------------------------------------------------------------------------
fetch_remote() {
  log_info "リモートから fetch します（${REMOTE}, --prune --tags）..."
  if ! git_r fetch --prune --tags "${REMOTE}"; then
    die "fetch に失敗しました。ネットワーク / 認証（git-remote-codecommit, IAM 権限 codecommit:GitPull 等）を確認してください。"
  fi
}

# ---------------------------------------------------------------------------
# 8. 断面とする ref を解決し、コミットハッシュを確定する
# ---------------------------------------------------------------------------
RESOLVED_REF=""     # 解決に使った参照表現
TARGET_COMMIT=""    # 断面の完全コミットハッシュ
resolve_ref() {
  if [[ -n "${REF}" ]]; then
    RESOLVED_REF="${REF}"
  else
    RESOLVED_REF="${REMOTE}/${BRANCH}"
    if ! git_r rev-parse --verify --quiet "refs/remotes/${REMOTE}/${BRANCH}" >/dev/null; then
      die "リモートブランチ '${REMOTE}/${BRANCH}' が見つかりません。--branch / --remote / --ref を確認してください。"
    fi
  fi

  if ! TARGET_COMMIT="$(git_r rev-parse --verify --quiet "${RESOLVED_REF}^{commit}")"; then
    die "断面の参照を解決できません: '${RESOLVED_REF}'"
  fi
  log_info "断面とするコミット: ${RESOLVED_REF} -> ${TARGET_COMMIT:0:12}"
  log_info "  $(git_r --no-pager log -1 --format='%h %ci  %s' "${TARGET_COMMIT}")"
}

# ---------------------------------------------------------------------------
# 9. 既存タグの衝突確認
# ---------------------------------------------------------------------------
check_tag_collision() {
  local local_exists="false" remote_exists="false"

  if git_r rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
    local_exists="true"
  fi
  if [[ -n "$(git_r ls-remote --tags "${REMOTE}" "refs/tags/${TAG}" 2>/dev/null)" ]]; then
    remote_exists="true"
  fi

  if [[ "${local_exists}" == "true" || "${remote_exists}" == "true" ]]; then
    log_warn "タグ '${TAG}' は既に存在します（local=${local_exists}, remote=${remote_exists}）。"
    if [[ "${FORCE}" != "true" ]]; then
      die "既存タグを上書きするには -f/--force を指定してください（断面の取り違え防止のため既定では上書きしません）。"
    fi
    log_warn "--force 指定のため、既存タグを上書きします。"
  fi
}

# ---------------------------------------------------------------------------
# 10. メッセージの確定
# ---------------------------------------------------------------------------
build_message() {
  if [[ -z "${MESSAGE}" ]]; then
    MESSAGE="Snapshot tag ${TAG} @ ${RESOLVED_REF} (${TARGET_COMMIT:0:12}) created on $(date '+%Y-%m-%d %H:%M:%S %z')"
    log_debug "タグメッセージを自動生成: ${MESSAGE}"
  fi
}

# ---------------------------------------------------------------------------
# 11. タグ作成 + push
#     run() が DRY_RUN=true のとき実コマンドを実行せず表示のみ行う。
# ---------------------------------------------------------------------------
create_and_push_tag() {
  local force_flag=""
  [[ "${FORCE}" == "true" ]] && force_flag="-f"

  log_info "注釈付きタグを作成します: ${TAG} -> ${TARGET_COMMIT:0:12}"
  # ${force_flag} は空のとき引数を増やさないよう非クォートで展開
  run git_r tag -a ${force_flag} -m "${MESSAGE}" "${TAG}" "${TARGET_COMMIT}"

  log_info "リモートへタグを push します: ${REMOTE} ${TAG}"
  if [[ "${FORCE}" == "true" ]]; then
    run git_r push --force "${REMOTE}" "refs/tags/${TAG}"
  else
    run git_r push "${REMOTE}" "refs/tags/${TAG}"
  fi
}

# ---------------------------------------------------------------------------
# 12. 検証: リモートのタグが断面コミットを指しているか
# ---------------------------------------------------------------------------
verify_pushed() {
  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY-RUN のため検証はスキップします。"
    return 0
  fi

  local ls remote_obj peeled
  ls="$(git_r ls-remote --tags "${REMOTE}" "refs/tags/${TAG}" 2>/dev/null || true)"
  if [[ -z "${ls}" ]]; then
    die "検証失敗: リモートにタグ '${TAG}' が見つかりません。"
  fi
  # 注釈付きタグは tag オブジェクトを指すため ^{} 行（peeled）でコミットを確認する。
  # ref 名末尾の "^{}" は固定文字列として一致させる（awk の正規表現に頼らない）。
  peeled="$(printf '%s\n' "${ls}" | grep -F '^{}' | awk '{print $1}' | head -n1)"
  remote_obj="$(printf '%s\n' "${ls}" | grep -vF '^{}' | awk '{print $1}' | head -n1)"

  if [[ -n "${peeled}" ]]; then
    if [[ "${peeled}" != "${TARGET_COMMIT}" ]]; then
      die "検証失敗: リモートタグの指すコミット(${peeled:0:12}) が断面(${TARGET_COMMIT:0:12}) と一致しません。"
    fi
  elif [[ "${remote_obj}" != "${TARGET_COMMIT}" ]]; then
    die "検証失敗: リモートタグ(${remote_obj:0:12}) が断面(${TARGET_COMMIT:0:12}) と一致しません。"
  fi

  log_success "検証 OK: リモートタグ '${TAG}' は断面 ${TARGET_COMMIT:0:12} を指しています。"
}

# ---------------------------------------------------------------------------
# 13. メイン
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  validate_inputs
  preflight
  fetch_remote
  resolve_ref
  check_tag_collision
  build_message

  log_info "=== 実行内容 ==="
  log_info "  タグ名     : ${TAG}"
  log_info "  断面        : ${RESOLVED_REF} (${TARGET_COMMIT:0:12})"
  log_info "  リモート    : ${REMOTE}"
  log_info "  上書き      : ${FORCE}"
  log_info "  メッセージ  : ${MESSAGE}"

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "=== DRY-RUN（実際のタグ作成 / push は行いません） ==="
  else
    if [[ "${ASSUME_YES}" != "true" ]]; then
      if [[ -t 0 ]]; then
        if ! confirm "このタグを作成してリモートへ push しますか?"; then
          die "ユーザーによって中止されました。"
        fi
      else
        die "非対話環境です。実行するには -y/--yes を指定してください（確認には --dry-run）。"
      fi
    fi
  fi

  create_and_push_tag
  verify_pushed

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "DRY-RUN 完了: 上記が実行されます。"
  else
    log_success "完了: タグ '${TAG}' で断面 ${TARGET_COMMIT:0:12} を固定し、${REMOTE} へ push しました。"
  fi
}

main "$@"
