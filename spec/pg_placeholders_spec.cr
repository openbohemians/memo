require "./spec_helper"
require "../src/memo/pg"

private def numbered(clauses : Array(String), after = 0) : {Array(String), Int32}
  Memo::Queries::Postgres.number_placeholders(clauses, after)
end

describe "Postgres placeholders" do
  it "numbers ? across clauses, after the given start" do
    numbered(["a = ?", "b = ? AND c = ?"], after: 1).should eq({["a = $2", "b = $3 AND c = $4"], 4})
  end

  it "leaves ? inside quoted strings and identifiers alone" do
    numbered(["b = 'what?' AND c = ?"]).should eq({["b = 'what?' AND c = $1"], 1})
    numbered(["x = 'it''s ?' AND y = ?"]).should eq({["x = 'it''s ?' AND y = $1"], 1})
    numbered([%("odd?col" = ?)]).should eq({[%("odd?col" = $1)], 1})
  end

  it "leaves ? inside comments and dollar quotes alone" do
    numbered(["a = ? -- why?\n AND b = ?"]).should eq({["a = $1 -- why?\n AND b = $2"], 2})
    numbered(["/* ? */ a = ?"]).should eq({["/* ? */ a = $1"], 1})
    numbered(["a = $$what?$$ AND b = ?"]).should eq({["a = $$what?$$ AND b = $1"], 1})
    numbered(["a = $t$ ? $t$ AND b = ?"]).should eq({["a = $t$ ? $t$ AND b = $1"], 1})
  end

  it "doesn't mistake a numbered parameter for a dollar quote" do
    numbered(["a = $1 AND b = ?"], after: 1).should eq({["a = $1 AND b = $2"], 2})
  end
end
