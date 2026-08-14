# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_12_082831) do
  create_table "checks", force: :cascade do |t|
    t.datetime "checked_at", null: false
    t.datetime "created_at", null: false
    t.string "error_message"
    t.boolean "ok", null: false
    t.integer "response_time_ms"
    t.integer "site_id", null: false
    t.integer "status_code"
    t.datetime "updated_at", null: false
    t.index ["site_id", "checked_at"], name: "index_checks_on_site_id_and_checked_at"
    t.index ["site_id"], name: "index_checks_on_site_id"
  end

  create_table "sites", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "interval_seconds", default: 60, null: false
    t.datetime "last_checked_at"
    t.string "last_status"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.string "url", null: false
  end

  add_foreign_key "checks", "sites"
end
