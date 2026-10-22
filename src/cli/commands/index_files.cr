require "json"

module Memo::CLI::Commands::IndexFiles
  extend self

  def run(memo : Memo::Service, files : Array(String), input : Hash(String, JSON::Any), json : Bool)
    recursive = Input.bool(input, "recursive", false)
    ignore_file = Input.string(input, "ignore-file") || ".gitignore"
    full = Input.bool(input, "full", false)

    file_paths, dir_paths = resolve_paths(files, recursive)

    if json
      run_json(memo, file_paths, dir_paths, ignore_file, full)
    else
      run_text(memo, file_paths, dir_paths, ignore_file, full)
    end
  end

  def dry_run(files : Array(String), input : Hash(String, JSON::Any), json : Bool)
    recursive = Input.bool(input, "recursive", false)
    ignore_file = Input.string(input, "ignore-file") || ".gitignore"

    file_paths, dir_paths = resolve_paths(files, recursive)

    if json
      dry_run_json(file_paths, dir_paths, ignore_file)
    else
      dry_run_text(file_paths, dir_paths, ignore_file)
    end
  end

  # A file's path for display: relative to the current directory when the
  # file is under it, absolute otherwise
  def display_path(path : String) : String
    cwd = Dir.current.rstrip('/') + "/"
    path.starts_with?(cwd) ? path[cwd.size..] : path
  end

  private def resolve_paths(files : Array(String), recursive : Bool) : {Array(String), Array(String)}
    file_paths = [] of String
    dir_paths = [] of String

    files.each do |path|
      expanded = File.expand_path(path)
      if Dir.exists?(expanded)
        dir_paths << expanded
      elsif File.exists?(expanded)
        file_paths << expanded
      else
        STDERR.puts "Error: No such file or directory: #{path}"
        exit 1
      end
    end

    unless dir_paths.empty? || recursive
      dir_paths.each do |d|
        STDERR.puts "Error: '#{d}' is a directory. Use -r to index recursively."
      end
      exit 1
    end

    {file_paths, dir_paths}
  end

  private def run_text(memo, file_paths, dir_paths, ignore_file, full)
    indexed = 0
    skipped = 0
    removed = 0
    total = 0

    unless file_paths.empty?
      root = Dir.current
      i, s, t = memo.index_file_list(
        paths: file_paths,
        root: root,
        incremental: !full,
      ) do |file_path, status|
        case status
        when :indexed then puts "  + #{display_path(file_path)}"
        when :removed
          puts "  - #{display_path(file_path)}"
          removed += 1
        when :skipped then nil
        end
      end
      indexed += i
      skipped += s
      total += t
    end

    dir_paths.each do |dir|
      i, s, t = memo.index_files(
        root: dir,
        ignore_file: ignore_file,
        incremental: !full,
      ) do |file_path, status|
        case status
        when :indexed then puts "  + #{display_path(file_path)}"
        when :removed
          puts "  - #{display_path(file_path)}"
          removed += 1
        when :skipped then nil
        end
      end
      indexed += i
      skipped += s
      total += t
    end

    puts
    summary = "Indexed: #{indexed}, Skipped: #{skipped}"
    summary += ", Removed: #{removed}" if removed > 0
    puts "#{summary}, Total: #{total}"
  end

  private def run_json(memo, file_paths, dir_paths, ignore_file, full)
    results = [] of Hash(String, JSON::Any)
    indexed = 0
    skipped = 0
    removed = 0
    total = 0

    unless file_paths.empty?
      root = Dir.current
      i, s, t = memo.index_file_list(
        paths: file_paths,
        root: root,
        incremental: !full,
      ) do |file_path, status|
        removed += 1 if status == :removed
        results << {
          "path"   => JSON::Any.new(file_path),
          "status" => JSON::Any.new(status.to_s),
        }
      end
      indexed += i
      skipped += s
      total += t
    end

    dir_paths.each do |dir|
      i, s, t = memo.index_files(
        root: dir,
        ignore_file: ignore_file,
        incremental: !full,
      ) do |file_path, status|
        removed += 1 if status == :removed
        results << {
          "path"   => JSON::Any.new(file_path),
          "status" => JSON::Any.new(status.to_s),
        }
      end
      indexed += i
      skipped += s
      total += t
    end

    output = {
      "indexed" => JSON::Any.new(indexed.to_i64),
      "skipped" => JSON::Any.new(skipped.to_i64),
      "removed" => JSON::Any.new(removed.to_i64),
      "total"   => JSON::Any.new(total.to_i64),
      "dry_run" => JSON::Any.new(false),
      "files"   => JSON::Any.new(results.map { |h| JSON::Any.new(h) }),
    }
    puts output.to_pretty_json
  end

  private def dry_run_text(file_paths, dir_paths, ignore_file)
    total = 0

    puts "Dry run - files that would be indexed:"
    puts

    cwd = Dir.current

    file_paths.each do |path|
      next if Memo::Files.binary?(path)
      relative = Path.new(path).relative_to(cwd).to_s
      puts "  #{relative}"
      total += 1
    end

    dir_paths.each do |dir|
      Memo::Files.walk(dir, ignore_file) do |file_path|
        relative = Path.new(file_path).relative_to(cwd).to_s
        puts "  #{relative}"
        total += 1
      end
    end

    puts
    puts "Would index: #{total} files"
  end

  private def dry_run_json(file_paths, dir_paths, ignore_file)
    results = [] of Hash(String, JSON::Any)
    total = 0
    cwd = Dir.current

    file_paths.each do |path|
      next if Memo::Files.binary?(path)
      relative = Path.new(path).relative_to(cwd).to_s
      results << {
        "path"   => JSON::Any.new(relative),
        "status" => JSON::Any.new("would_index"),
      }
      total += 1
    end

    dir_paths.each do |dir|
      Memo::Files.walk(dir, ignore_file) do |file_path|
        relative = Path.new(file_path).relative_to(cwd).to_s
        results << {
          "path"   => JSON::Any.new(relative),
          "status" => JSON::Any.new("would_index"),
        }
        total += 1
      end
    end

    output = {
      "indexed" => JSON::Any.new(0_i64),
      "skipped" => JSON::Any.new(0_i64),
      "total"   => JSON::Any.new(total.to_i64),
      "dry_run" => JSON::Any.new(true),
      "files"   => JSON::Any.new(results.map { |h| JSON::Any.new(h) }),
    }
    puts output.to_pretty_json
  end
end
