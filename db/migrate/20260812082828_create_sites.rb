class CreateSites < ActiveRecord::Migration[8.1]
  def change
    create_table :sites do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.integer :interval_seconds, null: false, default: 60
      t.boolean :enabled, null: false, default: true
      t.string :last_status # "up" / "down" / nil
      t.datetime :last_checked_at

      t.timestamps
    end
  end
end
