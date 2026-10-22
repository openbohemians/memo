require "./spec_helper"
require "../src/arcana/bus_log"

describe Memo::BusLog do
  it "redacts the passwords in database URLs" do
    redact = ->(url : String) { Memo::BusLog.redact_db_url(url) }

    redact.call("postgres://memo:s3cret@db.local:5432/memo").should eq "postgres://memo:***@db.local:5432/memo"
    redact.call("postgres://:s3cret@db.local/memo").should eq "postgres://:***@db.local/memo"
    redact.call("postgres://memo:p@ss:w0rd@db.local/memo").should eq "postgres://memo:***@db.local/memo"
    redact.call("postgres://db.local/memo?user=memo&password=s3cret&sslmode=require")
      .should eq "postgres://db.local/memo?user=memo&password=***&sslmode=require"
    redact.call("postgres://db.local/memo?sslpassword=s3cret").should eq "postgres://db.local/memo?sslpassword=***"
  end

  it "leaves database URLs without passwords alone" do
    ["postgres://memo@db.local:5432/memo", "postgres://db.local:5432/memo?sslmode=require", "/var/lib/memo/notes.db"].each do |url|
      Memo::BusLog.redact_db_url(url).should eq url
    end
  end

  it "redacts database URLs within a message" do
    Memo::BusLog.redact_db_url("can't connect to postgres://memo:s3cret@db.local/memo: refused")
      .should eq "can't connect to postgres://memo:***@db.local/memo: refused"
  end
end
