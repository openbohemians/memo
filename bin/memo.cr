require "jargon"
require "../src/memo"
require "../src/cli/schema"
require "../src/cli/input"
require "../src/cli/commands/*"

module Memo::CLI
  VERSION = Memo::VERSION

  def self.run(args = ARGV)
    # Nested CLI for service subcommands
    service_cli = Jargon.new("service")
    service_cli.subcommand("list", json: Jargon.merge(SERVICE_LIST_SCHEMA, GLOBAL_SCHEMA))
    service_cli.subcommand("use", json: Jargon.merge(SERVICE_USE_SCHEMA, GLOBAL_SCHEMA))
    service_cli.subcommand("create", json: Jargon.merge(SERVICE_CREATE_SCHEMA, GLOBAL_SCHEMA))
    service_cli.subcommand("delete", json: Jargon.merge(SERVICE_DELETE_SCHEMA, GLOBAL_SCHEMA))
    service_cli.default_subcommand("list")

    # Main CLI
    cli = Jargon.new("memo")
    cli.subcommand("index", json: Jargon.merge(INDEX_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("search", json: Jargon.merge(SEARCH_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("terms", json: Jargon.merge(TERMS_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("build-vocab", json: Jargon.merge(BUILD_VOCAB_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("delete", json: Jargon.merge(DELETE_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("stats", json: Jargon.merge(STATS_SCHEMA, GLOBAL_SCHEMA))
    cli.subcommand("service", service_cli)

    # The completion scripts (--completions) ask memo for candidates on each
    # Tab, through jargon's hidden __complete verb: answer and exit
    cli.handle_completion(args)

    # Handle --version before parsing
    if args.includes?("--version") || args.includes?("-v")
      puts "memo #{VERSION}"
      return
    end

    # Parse arguments
    result = cli.parse(args)

    # Handle help (Jargon detects --help/-h during parse)
    if result.help_requested?
      if subcmd = result.help_subcommand
        puts cli.help(subcmd)
      else
        puts help_text
      end
      return
    end

    # Handle --completions bash|zsh|fish
    if result.completion_requested?
      case result.completion_shell
      when "bash" then puts cli.bash_completion
      when "zsh"  then puts cli.zsh_completion
      when "fish" then puts cli.fish_completion
      end
      return
    end

    unless result.valid?
      result.errors.each { |e| STDERR.puts "Error: #{e}" }
      exit 1
    end

    # Extract global options
    input = result.data.as_h
    db_path = input["db"]?.try(&.as_s) || "memo.db"
    service_name = input["service"]?.try(&.as_s)
    api_key = input["api-key"]?.try(&.as_s) || ENV["MEMO_API_KEY"]? || ENV["OPENAI_API_KEY"]? || ENV["VOYAGE_API_KEY"]?
    json_output = input["json"]?.try(&.as_bool) || false
    no_vocab = input["no-vocab"]?.try(&.as_bool) || false

    # Route to command handler
    case result.subcommand
    when "service list"
      db = Memo::Database.create(db_path)
      begin
        Commands::Services.run(db, input, json_output)
      ensure
        db.close
      end
    when "service use"
      db = Memo::Database.create(db_path)
      begin
        Commands::ServiceUse.run(db, input, json_output)
      ensure
        db.close
      end
    when "service create"
      db = Memo::Database.create(db_path)
      begin
        Commands::ServiceCreate.run(db, input, json_output)
      ensure
        db.close
      end
    when "service delete"
      db = Memo::Database.create(db_path)
      begin
        Commands::ServiceDelete.run(db, input, json_output)
      ensure
        db.close
      end
    when "index"
      files = input["files"]?.try(&.as_a?.try(&.map(&.as_s))) || [] of String
      dry_run = Input.bool(input, "dry-run", false)
      stdin_text = nil

      if files.empty? && !STDIN.tty?
        stdin_text = STDIN.gets_to_end
        if stdin_text.empty?
          STDERR.puts "Error: No input provided on stdin."
          exit 1
        end
      elsif files.empty?
        STDERR.puts "Error: No files specified."
        STDERR.puts
        STDERR.puts "Usage: memo index <files>... [options]"
        STDERR.puts "       memo index -r <dir>     Recursively index directory"
        STDERR.puts "       echo \"text\" | memo index  Index text from stdin"
        exit 1
      end

      # Dry run doesn't need an API connection
      if dry_run && stdin_text.nil?
        Commands::IndexFiles.dry_run(files, input, json_output)
        return
      end

      memo = Memo::Service.new(
        db_path: db_path,
        service: service_name,
        api_key: api_key,
        build_vocab: !no_vocab
      )
      begin
        if text = stdin_text
          Commands::IndexText.run(memo, text, input, json_output)
        else
          Commands::IndexFiles.run(memo, files, input, json_output)
        end
      ensure
        memo.close
      end
    when "search", "terms", "build-vocab", "delete", "stats"
      memo = Memo::Service.new(
        db_path: db_path,
        service: service_name,
        api_key: api_key,
        build_vocab: !no_vocab
      )
      begin
        case result.subcommand
        when "search"      then Commands::Search.run(memo, input, json_output)
        when "terms"       then Commands::Terms.run(memo, input, json_output)
        when "build-vocab" then Commands::BuildVocab.run(memo, input, json_output)
        when "delete"      then Commands::Delete.run(memo, input, json_output)
        when "stats"       then Commands::Stats.run(memo, input, json_output)
        end
      ensure
        memo.close
      end
    else
      STDERR.puts "Unknown command: #{result.subcommand || args.first?}"
      STDERR.puts "\nRun 'memo --help' for usage."
      exit 1
    end
  rescue ex
    STDERR.puts "Error: #{ex.message}"
    exit 1
  end

  private def self.help_text : String
    <<-HELP
    Usage: memo <command> [options]

    Semantic search CLI for Memo.

    Commands:
      index         Index files or text from stdin
      search        Search indexed content
      terms         Find similar words
      build-vocab   Build vocabulary from indexed content
      delete        Delete indexed content
      stats         Show statistics
      service       Manage embedding services

    Index Usage:
      memo index <files>...          Index specific files
      memo index -r <dir>            Recursively index a directory
      echo "text" | memo index       Index text from stdin

    Global Options:
      -d, --db=PATH       Database path (default: memo.db)
      -s, --service=NAME  Service name to use
      -k, --api-key=KEY   API key for embedding provider
      -j, --json          Output as JSON

    Run 'memo <command> --help' for command-specific help.

    Environment Variables:
      MEMO_API_KEY, OPENAI_API_KEY, VOYAGE_API_KEY
    HELP
  end
end

Memo::CLI.run
