require "./spec_helper"

private def file_paths(memo : Memo::Service) : Array(String)
  memo.list_files.map(&.path).sort!
end

describe "Memo::Service file indexing" do
  it "doesn't follow symlinks out of the tree or around a loop" do
    with_test_tree({"a.md" => "apple pie recipe"}) do |tree|
      with_test_tree({"secret.md" => "private notes"}) do |outside|
        File.symlink(outside, File.join(tree, "elsewhere"))
        File.symlink(tree, File.join(tree, "loop"))
        File.symlink(File.join(tree, "a.md"), File.join(tree, "alias.md"))

        with_test_service do |memo|
          memo.index_files(tree).should eq({1, 0, 1})
          file_paths(memo).should eq [File.join(tree, "a.md")]
        end
      end
    end
  end

  it "keeps apart files with the same path under different roots" do
    with_test_tree({"README.md" => "apple pie recipe"}) do |a|
      with_test_tree({"README.md" => "banana bread recipe"}) do |b|
        with_test_service do |memo|
          memo.index_files(a)
          memo.index_files(b)
          file_paths(memo).should eq [File.join(a, "README.md"), File.join(b, "README.md")].sort
          memo.index_files(a).should eq({0, 1, 1}) # unchanged
        end
      end
    end
  end

  it "indexes a batch in which one file takes up a text another drops" do
    with_test_tree({"x.md" => "alpha alpha alpha", "y.md" => "beta beta beta"}) do |tree|
      x, y = File.join(tree, "x.md"), File.join(tree, "y.md")
      with_test_service do |memo|
        memo.index_file_list([x, y])
        File.write(x, "gamma gamma gamma")
        File.write(y, "alpha alpha alpha")

        memo.index_file_list([x, y], incremental: false).should eq({2, 0, 2})
        y_id = memo.get_file(y).should_not be_nil
        memo.search(query: "alpha alpha alpha", min_score: -1.0).first.internal_source_id.should eq y_id.source_id
      end
    end
  end

  it "removes the files deleted from the tree" do
    with_test_tree({"a.md" => "apple pie recipe", "sub/b.md" => "banana bread recipe"}) do |tree|
      a, b = File.join(tree, "a.md"), File.join(tree, "sub", "b.md")
      sibling = "#{tree}2" # its path starts with the tree's
      Dir.mkdir(sibling)
      File.write(File.join(sibling, "c.md"), "cherry tart recipe")
      begin
        with_test_service do |memo|
          memo.index_files(tree)
          memo.index_files(sibling)
          b_id = memo.get_file(b).should_not be_nil
          File.delete(b)

          events = [] of {String, Symbol}
          memo.index_files(tree, dry_run: true) { |path, status| events << {path, status} }
          events.should contain({b, :would_remove})
          file_paths(memo).size.should eq 3

          events.clear
          memo.index_files(tree) { |path, status| events << {path, status} }
          events.should contain({b, :removed})
          file_paths(memo).should eq [a, File.join(sibling, "c.md")]
          memo.search(query: "banana bread recipe", min_score: -1.0).map(&.internal_source_id).should_not contain(b_id.source_id)
        end
      ensure
        FileUtils.rm_rf(sibling)
      end
    end
  end

  it "takes over a file's record from when files were keyed by relative path" do
    with_test_tree({"a.md" => "apple pie recipe"}) do |tree|
      a = File.join(tree, "a.md")
      with_test_service do |memo|
        memo.index_files(tree)
        id = memo.get_file(a).should_not be_nil

        memo.db.exec("UPDATE memo_files SET path = 'a.md'") # as memo 0.15.2 recorded it
        memo.index_files(tree).should eq({0, 1, 1})
        memo.get_file(a).try(&.source_id).should eq id.source_id

        memo.db.exec("UPDATE memo_files SET path = 'a.md'")
        memo.index_file_list([a], root: tree).should eq({0, 1, 1})
        file_paths(memo).should eq [a]
      end
    end
  end
end
