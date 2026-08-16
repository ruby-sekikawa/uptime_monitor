class SitesController < ApplicationController
  before_action :set_site, only: %i[ show edit update destroy check_now ]

  # GET /sites or /sites.json
  def index
    @sites = Site.order(:name)
    # 各行で uptime_ratio を呼ぶと N+1 になるため、全サイトの稼働率を 1 クエリでまとめて取得する。
    @uptime = Site.uptime_ratios(24.hours)
  end

  # GET /sites/1 or /sites/1.json
  def show
    @checks = @site.checks.recent.limit(50)
    @uptime_24h = @site.uptime_ratio(24.hours)
  end

  # POST /sites/1/check_now — 手動で即時チェックを enqueue（動作確認用）
  def check_now
    CheckSiteJob.perform_later(@site.id)
    redirect_to @site, notice: "チェックをキューに投入しました。数秒後に履歴へ反映されます。"
  end

  # GET /sites/new
  def new
    @site = Site.new
  end

  # GET /sites/1/edit
  def edit
  end

  # POST /sites or /sites.json
  def create
    @site = Site.new(site_params)

    respond_to do |format|
      if @site.save
        format.html { redirect_to @site, notice: "Site was successfully created." }
        format.json { render :show, status: :created, location: @site }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @site.errors, status: :unprocessable_content }
      end
    end
  end

  # PATCH/PUT /sites/1 or /sites/1.json
  def update
    respond_to do |format|
      if @site.update(site_params)
        format.html { redirect_to @site, notice: "Site was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @site }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @site.errors, status: :unprocessable_content }
      end
    end
  end

  # DELETE /sites/1 or /sites/1.json
  def destroy
    @site.destroy!

    respond_to do |format|
      format.html { redirect_to sites_path, notice: "Site was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_site
      @site = Site.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def site_params
      # last_status / last_checked_at はジョブが更新する項目なのでユーザー入力からは除外する
      params.expect(site: [ :name, :url, :interval_seconds, :enabled ])
    end
end
