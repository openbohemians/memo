module Memo::CLI::Commands::Search
  extend self

  def run(memo : Memo::Service, input : Hash(String, JSON::Any), json : Bool)
    results = memo.search(
      query: input["query"].as_s,
      limit: Input.int(input, "limit") || 10,
      min_score: Input.float(input, "min-score") || 0.7,
      source_type: Input.string(input, "source-type"),
      source_id: Input.external_id(input, "source-id"),
      include_text: Input.bool(input, "include-text", true),
      like: Input.string(input, "like"),
      match: Input.string(input, "match"),
    )

    if json
      output = results.map do |r|
        result = Hash(String, JSON::Any).new
        result["chunk-id"] = JSON::Any.new(r.chunk_id)
        result["source-type"] = JSON::Any.new(r.source_type)
        result["internal-source-id"] = JSON::Any.new(r.internal_source_id)
        case sid = r.source_id
        when Int64
          result["source-id"] = JSON::Any.new(sid)
        when String
          result["source-id"] = JSON::Any.new(sid)
        when Bytes
          result["source-id"] = JSON::Any.new(sid.hexstring)
        end
        result["score"] = JSON::Any.new(r.score)
        result["offset"] = r.offset ? JSON::Any.new(r.offset.not_nil!.to_i64) : JSON::Any.new(nil)
        result["size"] = JSON::Any.new(r.size.to_i64)
        if text = r.text
          result["text"] = JSON::Any.new(text)
        end
        result
      end
      puts output.to_pretty_json
    else
      if results.empty?
        puts "No results found."
      else
        results.each do |r|
          # Display source info
          source_display = if r.source_type == "file" && !r.source_id
            # Memo-managed file - look up path
            file_record = memo.get_file_by_source(r.internal_source_id)
            path = file_record.try { |record| IndexFiles.display_path(record.path) } || "unknown"
            "[F#{r.internal_source_id}] #{path}"
          elsif sid = r.source_id
            "#{r.source_type}:#{sid}"
          else
            "#{r.source_type}:##{r.internal_source_id}"
          end
          puts "#{source_display} (score: #{"%.3f" % r.score})"
          if text = r.text
            # Calculate starting line number from offset
            start_line = if r.source_type == "file" && (offset = r.offset)
              file_record = memo.get_file_by_source(r.internal_source_id)
              if file_record && (full_text = memo.get_source_text(r.internal_source_id))
                # Count newlines before offset
                full_text[0, offset].count('\n') + 1
              else
                1
              end
            else
              1
            end

            # Show first few lines with line numbers
            lines = text.split('\n')
            lines[0, 4].each_with_index do |line, idx|
              next if line.blank?
              line_num = start_line + idx
              truncated = line.size > 70 ? line[0, 67] + "..." : line
              puts "   %4d | %s" % [line_num, truncated]
            end
          end
          puts
        end
        puts "#{results.size} result(s)"
      end
    end
  end
end
