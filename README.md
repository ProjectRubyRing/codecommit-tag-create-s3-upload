# CodeCommit Git タグによる断面固定 & S3 アップロード

EC2 (RHEL 9.6) 上で動作するシェルスクリプト群です。CodeCommit リポジトリの
特定時点の資産を **Git タグ** で固定（断面化）し、そのタグを指定して clone・
チェックアウトした内容を **S3 バケットの指定フォルダ** へアップロードします。

| ファイル | 役割 |
| --- | --- |
| `common.sh` | 共通ユーティリティ（ログ / `run` / `confirm` / `require_command` 等）。<br>※ claude 資材の中で最新（`CodeCommit_Git_Clean_Pull` 由来）のものを使用。 |
| `codecommit-tag-create.sh` | CodeCommit に注釈付きタグを作成し push（断面の固定） |
| `codecommit-tag-clone-s3-upload.sh` | 指定タグを clone→切替し、内容を S3 へアップロード（**統合版**） |
| `codecommit-tag-clone.sh` | 指定タグを clone→切替するだけ（**単体版**・統合版の clone 部分） |
| `s3-upload.sh` | ローカルディレクトリを S3 へアップロードするだけ（**単体版**・統合版のアップロード部分） |

clone とアップロードは、用途に応じて **統合版 1 本** でも、**単体版 2 本の組み合わせ** でも
実行できます（統合版はそのまま残してあります）。いずれも **`--dry-run`** に対応しています
（破壊的・外向き操作を行わず内容のみ表示）。

---

## 前提（RHEL 9.6）

```bash
sudo dnf install -y git
# AWS CLI v2（公式インストーラ）
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install
# CodeCommit を grc 形式 URL で扱う場合（codecommit::<region>://<repo>）
sudo dnf install -y python3-pip && pip3 install --user git-remote-codecommit
```

- 認証は EC2 のインスタンスプロファイル（IAM ロール）を推奨。
- 必要な IAM 権限:
  - タグ作成: `codecommit:GitPull`, `codecommit:GitPush`
  - clone/アップロード: `codecommit:GitPull`, `s3:ListBucket`, `s3:PutObject`（`--delete` 時は `s3:DeleteObject`）

---

## 1. 断面を固定する（タグ作成）

`codecommit-tag-create.sh` は **clone 済みリポジトリ** に対して fetch し、
`origin/main`（既定）または `--ref` 指定の断面を指す注釈付きタグを作成・push します。

```bash
# ドライラン（何が起きるか確認。タグ作成・push はしない）
./codecommit-tag-create.sh --repo-dir /opt/app/my-repo \
  --tag release-2026-06-29 --dry-run

# 実行（非対話環境では -y）
./codecommit-tag-create.sh --repo-dir /opt/app/my-repo \
  --tag release-2026-06-29 --message "2026-06-29 本番リリース断面" --yes

# 特定コミットを断面にする
./codecommit-tag-create.sh --repo-dir /opt/app/my-repo \
  --tag hotfix-base --ref 1a2b3c4 --yes
```

主なオプション: `--branch`（既定 main）, `--ref`, `--message`, `--remote`,
`--repo-name`/`--region`（remote URL 検証）, `-f/--force`（既存タグ上書き）。

同名タグが既に存在する場合、断面の取り違えを防ぐため既定では失敗します
（上書きするときだけ `--force`）。push 後、リモートのタグが断面コミットを指して
いるか検証します。

---

## 2. タグを取得して S3 へアップロード

`codecommit-tag-clone-s3-upload.sh` は指定タグを clone（既定は `--depth 1` の
shallow clone）してそのタグへ切り替え、`.git` を除いた内容を
`s3://<bucket>/<prefix>/` へ `aws s3 sync` でアップロードします。

```bash
# ドライラン（clone はするが S3 へは書かず、アップロード予定を表示）
./codecommit-tag-clone-s3-upload.sh \
  --repo-name my-repo --region ap-northeast-1 \
  --tag release-2026-06-29 \
  --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 --dry-run

# 実行（URL 直接指定 + 余剰削除あり）
./codecommit-tag-clone-s3-upload.sh \
  --repo-url codecommit::ap-northeast-1://my-repo \
  --tag release-2026-06-29 \
  --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 \
  --delete --yes
```

リポジトリ指定は `--repo-url`（grc/HTTPS）か `--repo-name`+`--region`（grc URL を
自動生成）のいずれか。主なオプション: `--s3-prefix`, `--work-dir`（未指定なら一時
ディレクトリを作成し終了時に自動削除）, `--full-clone`（全履歴）, `--delete`。

clone 後に HEAD が指定タグ（注釈付きタグは peel 済みコミット）を指しているか検証
してからアップロードします。`--dry-run` 時は `aws s3 sync --dryrun` を使い、
実際のアップロードを行いません。

---

## 2b. 単体版を組み合わせて使う（clone と S3 を分離）

統合版と同じことを、clone とアップロードの 2 段階に分けて実行できます。clone 結果を
ローカルに残して検査・加工してからアップロードしたい場合や、片方だけ再実行したい場合に便利です。

```bash
# (1) 指定タグを任意のディレクトリへ clone（S3 へは触れない）
./codecommit-tag-clone.sh \
  --repo-name my-repo --region ap-northeast-1 \
  --tag release-2026-06-29 --dest /opt/snapshots/my-repo-2026-06-29

# (2) clone 結果を S3 へアップロード（.git は除外）
#     まず --dry-run で内容確認 → 問題なければ --yes で実行
./s3-upload.sh \
  --src /opt/snapshots/my-repo-2026-06-29 \
  --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 \
  --exclude-git --dry-run

./s3-upload.sh \
  --src /opt/snapshots/my-repo-2026-06-29 \
  --s3-bucket my-artifacts --s3-prefix snapshots/my-repo/2026-06-29 \
  --exclude-git --delete --yes
```

- `codecommit-tag-clone.sh`: リポジトリ指定は統合版と同じ（`--repo-url` か `--repo-name`+`--region`）。
  `--dest`（clone 先・空 or 未作成）が必須。`--full-clone` / `--dry-run` 対応。
  統合版と違い `--dest` は自動削除されず**ローカルに残ります**。
- `s3-upload.sh`: `--src`（アップロード元）と `--s3-bucket` が必須。`--s3-prefix`, `--exclude-git`
  （`.git/*` 除外）, `--exclude <pat>`（追加除外・複数可）, `--delete`, `--dry-run`, `-y/--yes` 対応。
  git リポジトリを丸ごとアップロードする場合は `--exclude-git` の付与を推奨します。

---

## dry-run の挙動まとめ

| 操作 | 通常 | `--dry-run` |
| --- | --- | --- |
| `codecommit-tag-create.sh` の `git tag` / `git push` | 実行 | 表示のみ（`[DRY-RUN]`） |
| 統合版 `codecommit-tag-clone-s3-upload.sh` の `git clone`（読み取り） | 実行 | **実行**（読み取りのため。アップロード予定の算出に必要） |
| 統合版 / `s3-upload.sh` の `aws s3 sync` | アップロード | `--dryrun` で予定のみ表示 |
| 単体版 `codecommit-tag-clone.sh` の `git clone` | 実行 | 表示のみ（`[DRY-RUN]`。これ単体では clone が主目的のため実行しない） |

## 終了コード

- `0` 成功 / `1` エラー
