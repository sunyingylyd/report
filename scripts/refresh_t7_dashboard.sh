#!/bin/zsh
# 本机每天 18:00 刷新 T7 看板并推送到 GitHub Pages。
# 密码只从环境变量或 ~/.t7_dashboard.env 读取，不要写进仓库。
set -euo pipefail
REPO="${REPO:-$HOME/Documents/trae_projects/sunyingylyd-report}"
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
git add "T7召回0818前端看板.html" t7_0818_dashboard_data.json
if git diff --cached --quiet; then
  echo "no changes"
  exit 0
fi
git commit -m "Refresh T7 0818 dashboard for $(date +%Y-%m-%d)."
git push origin HEAD
