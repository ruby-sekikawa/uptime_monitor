# mission_control-jobs（/jobs ダッシュボード）の HTTP Basic 認証設定。
# 本番では環境変数で必ず上書きすること（Kamal の env で渡す）。開発は下記デフォルトで十分。
Rails.application.config.after_initialize do
  MissionControl::Jobs.http_basic_auth_user =
    ENV.fetch("MISSION_CONTROL_HTTP_BASIC_AUTH_USER", "admin")
  MissionControl::Jobs.http_basic_auth_password =
    ENV.fetch("MISSION_CONTROL_HTTP_BASIC_AUTH_PASSWORD", "password")
end
