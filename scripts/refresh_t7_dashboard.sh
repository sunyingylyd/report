#!/bin/zsh
# 本机每天 18:00 刷新 T7 看板并推送到两个 GitHub Pages 仓库。
# GitHub 托管 runner 访问不了数仓 47.89.225.85:8000，必须在能连库的电脑上跑。
# 密码只从环境变量或 ~/.t7_dashboard.env 读取，不要写进仓库。
set -euo pipefail
REPO="${REPO:-$HOME/Documents/trae_projects/sunyingylyd-report}"
PAGES_REPO="${PAGES_REPO:-$HOME/Documents/trae_projects/github_pages_repo}"
ENV_FILE="${ENV_FILE:-$HOME/.t7_dashboard.env}"
cd "$REPO"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
if [[ -z "${PGPASSWORD:-}" ]]; then
  echo "缺少 PGPASSWORD。请写在 $ENV_FILE 或先 export。" >&2
  exit 1
fi
python3 appendix_t7_0818_dashboard.py

push_if_changed() {
  local dir="$1"
  git -C "$dir" add "T7召回0818前端看板.html" t7_0818_dashboard_data.json
  if git -C "$dir" diff --cached --quiet; then
    echo "no changes in $dir"
    return 0
  fi
  git -C "$dir" commit -m "Refresh T7 0818 dashboard for $(date +%Y-%m-%d)."
  git -C "$dir" push origin HEAD
}

push_if_changed "$REPO"

if [[ -d "$PAGES_REPO/.git" ]]; then
  cp "$REPO/T7召回0818前端看板.html" "$PAGES_REPO/"
  cp "$REPO/t7_0818_dashboard_data.json" "$PAGES_REPO/"
  cp "$REPO/appendix_t7_0818_dashboard.py" "$PAGES_REPO/"
  push_if_changed "$PAGES_REPO"
fi
