# frozen_string_literal: true

module Inventory
  # Typeahead search over projects — GET /api/v1/projects/search?q=.
  #
  # Built for a search box that fires on every keystroke over a pool that is
  # expected to grow: a short, ranked, capped list, answered from trigram
  # indexes rather than by scanning the table. The full project is one tap away
  # at GET /projects/:id, so a hit carries only what a result row shows.
  #
  # Two stages, and the order is the point:
  #
  # 1. **Literal matches** — the name or RERA number contains what was typed.
  #    Ranked exact, then starts-with, then contains.
  # 2. **Fuzzy matches, only when stage 1 finds nothing** and the query is at
  #    least FUZZY_MIN_LENGTH characters. This is the "did you mean" case.
  #
  # Mixing the two in one ranked list was tried first and was wrong, measurably.
  # Trigram similarity cannot tell a typo from a name that merely starts the
  # same way: at four characters "aurm" -> Aurum Vista scores 0.60, and so does
  # "godr" -> Godavari Heights. No threshold separates those. What does
  # separate them is whether the text appears literally — "godr" is a substring
  # of Godrej, so stage 1 answers it and Godavari is never considered. Fuzzy
  # matching is kept for what it is good at: text that matches nothing as typed.
  #
  # The name is matched fuzzily; the RERA number never is. People misspell
  # names. A near-miss registration number is a *different* project, so
  # surfacing it would be wrong rather than forgiving.
  #
  # Tenancy comes from Project's FirmScoped default scope, like every other
  # project read. Only active projects are searched, matching GET /projects.
  class ProjectSearch
    # Counted in letters and numbers, not raw characters: "___" or "!!!" is
    # three characters but nothing a trigram index can use, so it would read
    # every row the firm owns.
    MIN_LENGTH = 3
    MAX_LENGTH = Project::NAME_MAX_LENGTH
    LIMIT = 10

    # Below four characters a fuzzy match is almost all noise: a three-letter
    # query shares two of its four trigrams with any name whose word starts with
    # the same two letters, so "lod" scored 0.50 against Lotus, Loft and
    # Lokhandwala — the same as a genuine typo.
    FUZZY_MIN_LENGTH = 4

    # Measured against typos and against names sharing a two- or three-letter
    # word prefix, rather than guessed:
    #
    #   typos kept            aurm 0.60  godrj 0.67  lodah 0.50  runwl 0.67
    #                         oberio 0.57  skypak 0.71  hiranandni 0.73
    #   noise rejected        aurm -> Austin / Autumn / Autograph 0.40
    #                         lodah -> Loft / Lotus / Lokhandwala 0.33
    #
    # `<%` accepts scores strictly above the threshold. 0.45 keeps every typo
    # above and drops two-letter-prefix noise. A name sharing a three-letter
    # prefix with a typo can still appear alongside it — "godrj" offers Godavari
    # after Godrej — which is a reasonable "did you mean", and only happens when
    # nothing matched literally. A doubled letter ("auurm", 0.33) is the known
    # miss. The "lodah" and "aurm" specs fail if this stops being applied.
    SIMILARITY_THRESHOLD = 0.45

    SEARCHABLE = /[\p{L}\p{M}\p{N}]/
    # Zero-width characters ride along when text is copied from a web page or a
    # chat. They are not whitespace, so they survive a plain strip.
    INVISIBLE = /[​-‍⁠﻿]/

    Result = Struct.new(:ok?, :projects, :query, :more, :fuzzy, :error_code, :error_message, :details,
                        keyword_init: true)

    def initialize(query:)
      @query = normalise(query)
    end

    def call
      return too_short if searchable_length < MIN_LENGTH

      # Each stage fetches one past the limit to learn whether there is more,
      # so the app can say "keep typing" rather than implying ten is everything.
      rows, fuzzy = within_search_settings do
        literal = literal_matches.limit(LIMIT + 1).to_a
        fall_back = literal.empty? && searchable_length >= FUZZY_MIN_LENGTH

        [ fall_back ? fuzzy_matches.limit(LIMIT + 1).to_a : literal, fall_back ]
      end

      Result.new(ok?: true, projects: rows.first(LIMIT), query:, more: rows.size > LIMIT, fuzzy:)
    end

    private

    attr_reader :query

    # A query sent as an array or object is not a query: treating it as blank
    # gives the same clear query_too_short as an empty box, instead of searching
    # for the string "[\"aur\"]".
    #
    # Whitespace is normalised before measuring, because String#strip leaves a
    # non-breaking space in place — and a RERA number pasted from a web page
    # usually ends in one, which made an exact registration match nothing.
    def normalise(raw)
      return "" unless raw.is_a?(String)

      raw.gsub(INVISIBLE, "").gsub(/[[:space:]]+/, " ").strip.first(MAX_LENGTH)
    end

    def searchable_length = query.scan(SEARCHABLE).size

    def base
      Project.includes(:builder, :city, :locality).where(status: "active")
    end

    def literal_matches
      base
        .where("projects.name ILIKE :contains OR projects.rera_number ILIKE :contains", contains:)
        .order(literal_ranking)
    end

    def fuzzy_matches
      base
        .where(":q <% projects.name", q: query)
        .order(Arel.sql(Project.sanitize_sql_array([
          "word_similarity(?, projects.name) DESC, projects.name ASC, projects.id ASC", query
        ])))
    end

    # Exact, then prefix, then substring; within a tier, the closest name first.
    # `id` last so equal rows have a defined order.
    def literal_ranking
      Arel.sql(Project.sanitize_sql_array([ <<~SQL.squish, { q: query, prefix:, contains: } ]))
        CASE
          WHEN lower(projects.name) = lower(:q)
            OR lower(projects.rera_number) = lower(:q) THEN 0
          WHEN projects.name ILIKE :prefix
            OR projects.rera_number ILIKE :prefix      THEN 1
          ELSE 2
        END,
        word_similarity(:q, projects.name) DESC,
        projects.name ASC,
        projects.id ASC
      SQL
    end

    # Both settings are transaction-local — set_config(..., true) is SET LOCAL
    # with a bound value — so neither can leak onto a pooled connection that
    # another request picks up next.
    #
    # The threshold: `<%` reads it from a setting rather than taking an
    # argument, and it has to be the operator, not a word_similarity()
    # comparison, or the trigram index cannot be used.
    #
    # enable_seqscan: Postgres estimates `ILIKE '%...%'` with a generic rule that
    # knows nothing about trigram indexes, guesses a large share of the table
    # matches, and reads every row. Measured at 50,000 projects, the literal
    # stage did a sequential scan on every query — 24 ms even for text matching
    # nothing, where the index answers in well under a millisecond. Turning it
    # off does not forbid a scan when no index applies; it makes one the last
    # resort, so the planner takes the trigram index or, for a small firm in a
    # large table, the firm_id index — either of which beats reading the table.
    def within_search_settings
      Project.transaction do
        set_local("pg_trgm.word_similarity_threshold", SIMILARITY_THRESHOLD.to_s)
        set_local("enable_seqscan", "off")
        yield
      end
    end

    # exec_query, not select_value: select_value goes through Rails' query
    # cache, and an identical `SELECT set_config(...)` later in the same request
    # or job is answered from the cache without reaching Postgres. The second
    # search would then silently run with pg_trgm's default threshold and a
    # sequential scan. exec_query always executes.
    def set_local(name, value)
      Project.connection.exec_query(
        Project.sanitize_sql_array([ "SELECT set_config(?, ?, true)", name, value ]), "search settings"
      )
    end

    def escaped = Project.sanitize_sql_like(query)
    def contains = "%#{escaped}%"
    def prefix = "#{escaped}%"

    def too_short
      Result.new(
        ok?: false, error_code: "query_too_short",
        error_message: "Type at least #{MIN_LENGTH} letters or numbers to search.",
        details: { min_length: MIN_LENGTH, length: searchable_length }
      )
    end
  end
end
